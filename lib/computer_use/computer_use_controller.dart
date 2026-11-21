import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../settings/user_settings.dart';
import 'computer_use_native.dart';
import 'computer_use_settings.dart';
import 'cua_driver_service.dart';

/// Registration state of the global emergency stop hotkey.
enum StopHotkeyStatus {
  inactive,
  active,
  disabled,
  conflict,
}

/// An active desktop window shared with agents.
class SharedWindowEntry {
  SharedWindowEntry({
    required this.window,
    required this.level,
    DateTime? sharedAt,
  }) : sharedAt = sharedAt ?? DateTime.now(),
       lastAccessedAt = sharedAt ?? DateTime.now();

  DesktopWindowInfo window;
  WindowShareLevel level;
  final DateTime sharedAt;
  DateTime lastAccessedAt;

  void touch() => lastAccessedAt = DateTime.now();
}

/// Coordinates Computer Use settings, macOS permissions, shared desktop
/// windows, idle auto-revocation, global stop hotkey, and floating stop bar.
class ComputerUseController extends ChangeNotifier {
  ComputerUseController._();
  static final instance = ComputerUseController._();

  ComputerUseConfig _config = const ComputerUseConfig();
  ComputerUsePermissions _permissions = const ComputerUsePermissions(
    accessibility: false,
    screenRecording: false,
  );
  List<DesktopWindowInfo> _windows = const [];
  final Map<int, SharedWindowEntry> _shared = {};
  bool _fullScreenShared = false;
  DateTime? _fullScreenLastAccessed;
  StopHotkeyStatus _hotkeyStatus = StopHotkeyStatus.inactive;

  Timer? _pollTimer;
  Listenable? _settingsSource;
  Object? Function(String key)? _settingsRead;
  UserSettings? _userSettings;

  ComputerUseConfig get config => _config;
  ComputerUsePermissions get permissions => _permissions;
  List<DesktopWindowInfo> get windows => _windows;
  Map<int, SharedWindowEntry> get sharedWindows => Map.unmodifiable(_shared);
  bool get fullScreenShared => _fullScreenShared;
  StopHotkeyStatus get hotkeyStatus => _hotkeyStatus;
  bool get hasActiveShares => _shared.isNotEmpty || _fullScreenShared;
  int get sharedCount => _shared.length;

  /// Follows `User/settings.json` changes and starts background maintenance.
  void follow(UserSettings settings) {
    _userSettings = settings;
    _settingsSource?.removeListener(_readSettings);
    _settingsSource = settings;
    _settingsRead = (key) => settings[key];
    settings.addListener(_readSettings);
    _readSettings();
    _ensureTimer();
    unawaited(CuaDriverService.instance.refresh());
    refreshPermissions();
  }

  /// Replaces the current config and persists changed keys to `settings.json`.
  Future<void> saveConfig(
    ComputerUseConfig next, {
    UserSettings? settings,
  }) async {
    final prev = _config;
    _config = next;
    _onConfigApplied(prev, next);
    notifyListeners();

    final target = settings ?? _userSettings;
    if (target == null) return;
    final map = next.toSettingsMap();
    for (final entry in map.entries) {
      try {
        await target.update(entry.key, entry.value);
      } on Object catch (e) {
        debugPrint('${entry.key} not kept: $e');
      }
    }
  }

  void _readSettings() {
    final read = _settingsRead;
    if (read == null) return;
    final prev = _config;
    final next = ComputerUseConfig.fromSettings(read);
    _config = next;
    _onConfigApplied(prev, next);
    notifyListeners();
  }

  void _onConfigApplied(ComputerUseConfig prev, ComputerUseConfig next) {
    if (!next.enabled) {
      stopAllSharing(silent: true);
    } else if (!next.allowFullScreen && _fullScreenShared) {
      _fullScreenShared = false;
    }
    // Remove any shared windows that are now blocked by the updated blacklist.
    _shared.removeWhere(
      (_, entry) => isWindowBlocked(entry.window),
    );
    _syncHotkey();
    _syncStopBar();
  }

  void _ensureTimer() {
    if (_pollTimer != null || Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (ComputerUseNative.pollStopEvent()) {
        stopAllSharing();
      }
      _checkIdleTimeout();
    });
  }

  void refreshPermissions() {
    if (!ComputerUseNative.supported) return;
    final next = ComputerUseNative.checkPermissions();
    if (next.accessibility != _permissions.accessibility ||
        next.screenRecording != _permissions.screenRecording) {
      _permissions = next;
      notifyListeners();
    } else {
      _permissions = next;
    }
  }

  void refreshWindows() {
    if (!ComputerUseNative.supported) {
      _windows = const [];
      notifyListeners();
      return;
    }
    _windows = ComputerUseNative.listWindows();
    // Prune closed windows from shared map and update geometry/title.
    final byId = {for (final w in _windows) w.windowId: w};
    _shared.removeWhere((id, _) => !byId.containsKey(id));
    for (final entry in _shared.values) {
      final fresh = byId[entry.window.windowId];
      if (fresh != null) entry.window = fresh;
    }
    _syncStopBar();
    notifyListeners();
  }

  /// Ayte's own windows and blacklisted apps can never be shared.
  bool isWindowBlocked(DesktopWindowInfo window) {
    if (window.isSelf) return true;
    return _config.isBlockedApp(
      bundleId: window.bundleId,
      appName: window.appName,
      execPath: window.execPath,
    );
  }

  WindowShareLevel shareLevelOf(int windowId) =>
      _shared[windowId]?.level ?? WindowShareLevel.none;

  bool shareWindow(DesktopWindowInfo window, WindowShareLevel level) {
    if (!_config.enabled) return false;
    if (level == WindowShareLevel.none) {
      _shared.remove(window.windowId);
      _syncStopBar();
      notifyListeners();
      return true;
    }
    if (isWindowBlocked(window)) return false;
    _shared[window.windowId] = SharedWindowEntry(window: window, level: level);
    _syncStopBar();
    notifyListeners();
    return true;
  }

  bool setFullScreenShared(bool on) {
    if (!_config.enabled || !_config.allowFullScreen) {
      _fullScreenShared = false;
      _syncStopBar();
      notifyListeners();
      return false;
    }
    _fullScreenShared = on;
    _fullScreenLastAccessed = on ? DateTime.now() : null;
    _syncStopBar();
    notifyListeners();
    return true;
  }

  void markWindowAccessed(int windowId) {
    _shared[windowId]?.touch();
  }

  void markFullScreenAccessed() {
    if (_fullScreenShared) {
      _fullScreenLastAccessed = DateTime.now();
    }
  }

  void stopAllSharing({bool silent = false}) {
    final had = hasActiveShares;
    _shared.clear();
    _fullScreenShared = false;
    _fullScreenLastAccessed = null;
    ComputerUseNative.hideStopBar();
    if (had && !silent) {
      notifyListeners();
    }
  }

  void _checkIdleTimeout() {
    final minutes = _config.idleTimeoutMinutes;
    if (minutes <= 0 || !hasActiveShares) return;
    final cutoff = DateTime.now().subtract(Duration(minutes: minutes));
    var changed = false;
    _shared.removeWhere((_, entry) {
      final expired = entry.lastAccessedAt.isBefore(cutoff);
      if (expired) changed = true;
      return expired;
    });
    if (_fullScreenShared &&
        _fullScreenLastAccessed != null &&
        _fullScreenLastAccessed!.isBefore(cutoff)) {
      _fullScreenShared = false;
      _fullScreenLastAccessed = null;
      changed = true;
    }
    if (changed) {
      _syncStopBar();
      notifyListeners();
    }
  }

  void _syncHotkey() {
    if (!ComputerUseNative.supported) {
      _hotkeyStatus = StopHotkeyStatus.inactive;
      return;
    }
    if (!_config.stopHotkeyEnabled) {
      ComputerUseNative.unregisterStopHotkey();
      _hotkeyStatus = StopHotkeyStatus.disabled;
      return;
    }
    if (!_config.enabled) {
      ComputerUseNative.unregisterStopHotkey();
      _hotkeyStatus = StopHotkeyStatus.inactive;
      return;
    }
    final parsed = ComputerUseConfig.parseMacCarbonHotkey(_config.stopHotkey);
    if (parsed == null) {
      ComputerUseNative.unregisterStopHotkey();
      _hotkeyStatus = StopHotkeyStatus.conflict;
      return;
    }
    final ok = ComputerUseNative.registerStopHotkey(
      parsed.keyCode,
      parsed.modifiers,
    );
    _hotkeyStatus = ok ? StopHotkeyStatus.active : StopHotkeyStatus.conflict;
  }

  void _syncStopBar() {
    if (!ComputerUseNative.supported) return;
    if (!_config.enabled || !_config.floatingStopBar || !hasActiveShares) {
      ComputerUseNative.hideStopBar();
      return;
    }
    final interactiveCount = _shared.values
        .where((e) => e.level == WindowShareLevel.interactive)
        .length;
    final text = _fullScreenShared
        ? 'Ayte 正在共享整个屏幕（可查看与操作）· ${_config.stopHotkey}'
        : interactiveCount > 0
        ? 'Ayte 已共享 ${_shared.length} 个窗口（$interactiveCount 个可操作）· ${_config.stopHotkey}'
        : 'Ayte 已共享 ${_shared.length} 个只读窗口 · ${_config.stopHotkey}';
    ComputerUseNative.showStopBar(text, '停止共享');
  }
}
