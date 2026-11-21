import 'package:flutter/foundation.dart';

/// How the agent delivers clicks, typing, and scroll events when not specified.
enum ComputerUseDeliveryMode {
  background,
  foreground;

  static ComputerUseDeliveryMode parse(Object? raw) =>
      raw == 'foreground' ? foreground : background;
}

/// Share level granted to a single desktop window.
enum WindowShareLevel {
  none,
  readOnly,
  interactive;

  String label({required bool zh}) => switch (this) {
    none => zh ? '未共享' : 'Not Shared',
    readOnly => zh ? '只读' : 'Read Only',
    interactive => zh ? '可操作' : 'Interactive',
  };
}

/// Default macOS apps that must never be shared with an agent.
const List<String> defaultMacNeverShareApps = [
  'com.apple.systempreferences',
  'com.apple.SystemSettings',
  'com.apple.SecurityAgent',
  'com.apple.keychainaccess',
  'com.apple.Passwords',
  'com.1password.1password',
  'com.agilebits.onepassword7',
  'com.bitwarden.desktop',
  'org.keepassxc.keepassxc',
  'com.lastpass.LastPass',
  'in.sinew.Enpass-Desktop',
  'me.proton.pass.electron',
  'com.dashlane.Dashlane',
];

/// Human-readable names for the built-in never-share bundle IDs.
const Map<String, (String zh, String en)> neverShareAppLabels = {
  'com.apple.systempreferences': ('系统设置', 'System Settings'),
  'com.apple.SystemSettings': ('系统设置', 'System Settings'),
  'com.apple.SecurityAgent': ('系统密码与授权弹窗', 'System Auth Dialogs'),
  'com.apple.keychainaccess': ('钥匙串访问', 'Keychain Access'),
  'com.apple.Passwords': ('密码', 'Passwords'),
  'com.1password.1password': ('1Password', '1Password'),
  'com.agilebits.onepassword7': ('1Password 7', '1Password 7'),
  'com.bitwarden.desktop': ('Bitwarden', 'Bitwarden'),
  'org.keepassxc.keepassxc': ('KeePassXC', 'KeePassXC'),
  'com.lastpass.LastPass': ('LastPass', 'LastPass'),
  'in.sinew.Enpass-Desktop': ('Enpass', 'Enpass'),
  'me.proton.pass.electron': ('Proton Pass', 'Proton Pass'),
  'com.dashlane.Dashlane': ('Dashlane', 'Dashlane'),
};

/// Settings persisted under `computerUse.*` in `User/settings.json`.
@immutable
class ComputerUseConfig {
  const ComputerUseConfig({
    this.enabled = false,
    this.agentToolEnabled = false,
    this.idleTimeoutMinutes = 30,
    this.neverShareApps = defaultMacNeverShareApps,
    this.stopHotkeyEnabled = true,
    this.stopHotkey = 'Ctrl+Cmd+Escape',
    this.floatingStopBar = true,
    this.allowBringToFront = true,
    this.defaultDeliveryMode = ComputerUseDeliveryMode.background,
    this.allowLaunchAndMove = false,
    this.allowClipboard = false,
    this.allowFullScreen = false,
  });

  static const enabledKey = 'computerUse.enabled';
  static const agentToolEnabledKey = 'computerUse.agentToolEnabled';
  static const idleTimeoutMinutesKey = 'computerUse.idleTimeoutMinutes';
  static const neverShareAppsKey = 'computerUse.neverShareApps';
  static const stopHotkeyEnabledKey = 'computerUse.stopHotkeyEnabled';
  static const stopHotkeyKey = 'computerUse.stopHotkey';
  static const floatingStopBarKey = 'computerUse.floatingStopBar';
  static const allowBringToFrontKey = 'computerUse.allowBringToFront';
  static const defaultDeliveryModeKey = 'computerUse.defaultDeliveryMode';
  static const allowLaunchAndMoveKey = 'computerUse.allowLaunchAndMove';
  static const allowClipboardKey = 'computerUse.allowClipboard';
  static const allowFullScreenKey = 'computerUse.allowFullScreen';

  static const idleTimeoutOptions = [10, 30, 60, 240, 0];

  final bool enabled;
  final bool agentToolEnabled;
  final int idleTimeoutMinutes;
  final List<String> neverShareApps;
  final bool stopHotkeyEnabled;
  final String stopHotkey;
  final bool floatingStopBar;
  final bool allowBringToFront;
  final ComputerUseDeliveryMode defaultDeliveryMode;
  final bool allowLaunchAndMove;
  final bool allowClipboard;
  final bool allowFullScreen;

  /// Effective delivery mode: locked to background when bring-to-front is off.
  ComputerUseDeliveryMode get effectiveDeliveryMode =>
      allowBringToFront ? defaultDeliveryMode : ComputerUseDeliveryMode.background;

  /// Whether tools should actually be injected into agents.
  bool get toolsActive => enabled && agentToolEnabled;

  factory ComputerUseConfig.fromSettings(Object? Function(String key) read) {
    final rawNever = read(neverShareAppsKey);
    final neverList = rawNever is List
        ? [
            for (final e in rawNever)
              if (e is String && e.trim().isNotEmpty) e.trim(),
          ]
        : defaultMacNeverShareApps;
    final rawTimeout = read(idleTimeoutMinutesKey);
    final timeout = rawTimeout is int && idleTimeoutOptions.contains(rawTimeout)
        ? rawTimeout
        : 30;
    final rawHotkey = read(stopHotkeyKey);
    final hotkey = rawHotkey is String && rawHotkey.trim().isNotEmpty
        ? rawHotkey.trim()
        : 'Ctrl+Cmd+Escape';

    return ComputerUseConfig(
      enabled: read(enabledKey) == true,
      agentToolEnabled: read(agentToolEnabledKey) == true,
      idleTimeoutMinutes: timeout,
      neverShareApps: neverList,
      stopHotkeyEnabled: read(stopHotkeyEnabledKey) != false,
      stopHotkey: hotkey,
      floatingStopBar: read(floatingStopBarKey) != false,
      allowBringToFront: read(allowBringToFrontKey) != false,
      defaultDeliveryMode: ComputerUseDeliveryMode.parse(
        read(defaultDeliveryModeKey),
      ),
      allowLaunchAndMove: read(allowLaunchAndMoveKey) == true,
      allowClipboard: read(allowClipboardKey) == true,
      allowFullScreen: read(allowFullScreenKey) == true,
    );
  }

  Map<String, Object?> toSettingsMap() => {
    enabledKey: enabled ? true : null,
    agentToolEnabledKey: agentToolEnabled ? true : null,
    idleTimeoutMinutesKey: idleTimeoutMinutes == 30 ? null : idleTimeoutMinutes,
    neverShareAppsKey: listEquals(neverShareApps, defaultMacNeverShareApps)
        ? null
        : neverShareApps,
    stopHotkeyEnabledKey: stopHotkeyEnabled ? null : false,
    stopHotkeyKey: stopHotkey == 'Ctrl+Cmd+Escape' ? null : stopHotkey,
    floatingStopBarKey: floatingStopBar ? null : false,
    allowBringToFrontKey: allowBringToFront ? null : false,
    defaultDeliveryModeKey:
        defaultDeliveryMode == ComputerUseDeliveryMode.background
        ? null
        : defaultDeliveryMode.name,
    allowLaunchAndMoveKey: allowLaunchAndMove ? true : null,
    allowClipboardKey: allowClipboard ? true : null,
    allowFullScreenKey: allowFullScreen ? true : null,
  };

  ComputerUseConfig copyWith({
    bool? enabled,
    bool? agentToolEnabled,
    int? idleTimeoutMinutes,
    List<String>? neverShareApps,
    bool? stopHotkeyEnabled,
    String? stopHotkey,
    bool? floatingStopBar,
    bool? allowBringToFront,
    ComputerUseDeliveryMode? defaultDeliveryMode,
    bool? allowLaunchAndMove,
    bool? allowClipboard,
    bool? allowFullScreen,
  }) => ComputerUseConfig(
    enabled: enabled ?? this.enabled,
    agentToolEnabled: agentToolEnabled ?? this.agentToolEnabled,
    idleTimeoutMinutes: idleTimeoutMinutes ?? this.idleTimeoutMinutes,
    neverShareApps: neverShareApps ?? this.neverShareApps,
    stopHotkeyEnabled: stopHotkeyEnabled ?? this.stopHotkeyEnabled,
    stopHotkey: stopHotkey ?? this.stopHotkey,
    floatingStopBar: floatingStopBar ?? this.floatingStopBar,
    allowBringToFront: allowBringToFront ?? this.allowBringToFront,
    defaultDeliveryMode: defaultDeliveryMode ?? this.defaultDeliveryMode,
    allowLaunchAndMove: allowLaunchAndMove ?? this.allowLaunchAndMove,
    allowClipboard: allowClipboard ?? this.allowClipboard,
    allowFullScreen: allowFullScreen ?? this.allowFullScreen,
  );

  /// Whether a window matching [bundleId], [appName], or [execPath] is blocked
  /// by the never-share blacklist.
  bool isBlockedApp({
    required String bundleId,
    required String appName,
    required String execPath,
  }) {
    final b = bundleId.toLowerCase();
    final a = appName.toLowerCase();
    final p = execPath.toLowerCase();
    for (final raw in neverShareApps) {
      final entry = raw.trim().toLowerCase();
      if (entry.isEmpty) continue;
      if (b.isNotEmpty && b == entry) return true;
      if (p.isNotEmpty && (p == entry || p.endsWith('/$entry'))) return true;
      if (a.isNotEmpty && a == entry) return true;
    }
    return false;
  }

  /// Parses a stop-hotkey string like `Ctrl+Cmd+Escape` into macOS Carbon
  /// `(keyCode, modifiers)` if valid; returns null if invalid.
  /// Enforces at least 2 modifiers with at least one Ctrl or Cmd.
  static ({int keyCode, int modifiers})? parseMacCarbonHotkey(String spec) {
    final parts = spec
        .split('+')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.length < 3) return null;

    var modifiers = 0;
    var modCount = 0;
    var hasCtrlOrCmd = false;
    final keyPart = parts.last.toLowerCase();

    for (var i = 0; i < parts.length - 1; i++) {
      switch (parts[i].toLowerCase()) {
        case 'cmd' || 'meta' || 'command' || '⌘':
          modifiers |= 256; // cmdKey
          modCount++;
          hasCtrlOrCmd = true;
        case 'shift' || '⇧':
          modifiers |= 512; // shiftKey
          modCount++;
        case 'alt' || 'option' || 'opt' || '⌥':
          modifiers |= 2048; // optionKey
          modCount++;
        case 'ctrl' || 'control' || '⌃':
          modifiers |= 4096; // controlKey
          modCount++;
          hasCtrlOrCmd = true;
        default:
          return null;
      }
    }
    if (modCount < 2 || !hasCtrlOrCmd) return null;

    final code = _macKeyCodes[keyPart];
    if (code == null) return null;
    return (keyCode: code, modifiers: modifiers);
  }

  static const Map<String, int> _macKeyCodes = {
    'escape': 53,
    'esc': 53,
    'a': 0,
    's': 1,
    'd': 2,
    'f': 3,
    'h': 4,
    'g': 5,
    'z': 6,
    'x': 7,
    'c': 8,
    'v': 9,
    'b': 11,
    'q': 12,
    'w': 13,
    'e': 14,
    'r': 15,
    'y': 16,
    't': 17,
    '1': 18,
    '2': 19,
    '3': 20,
    '4': 21,
    '6': 22,
    '5': 23,
    '9': 25,
    '7': 26,
    '8': 28,
    '0': 29,
    'o': 31,
    'u': 32,
    'i': 34,
    'p': 35,
    'l': 37,
    'j': 38,
    'k': 40,
    'n': 45,
    'm': 46,
    'f1': 122,
    'f2': 120,
    'f3': 99,
    'f4': 118,
    'f5': 96,
    'f6': 97,
    'f7': 98,
    'f8': 100,
    'f9': 101,
    'f10': 109,
    'f11': 103,
    'f12': 111,
  };
}
