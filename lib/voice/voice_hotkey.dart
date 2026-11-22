import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'voice_settings.dart';
import 'voice_stt_service.dart';
import 'voice_tts_service.dart';

class _ComposerRegistration {
  _ComposerRegistration({
    required this.owner,
    required this.onTrigger,
    required this.isFocused,
  });

  final Object owner;
  final VoidCallback onTrigger;
  final bool Function() isFocused;
}

/// Manages the system-wide global hotkey (`baocode/voice`) that brings Ayte to
/// the foreground and toggles voice input in the active chat composer.
class VoiceHotkeyService extends ChangeNotifier {
  VoiceHotkeyService({MethodChannel? channel, VoiceSettingsStore? store})
    : _channel = channel ?? const MethodChannel('baocode/voice'),
      // ignore: prefer_initializing_formals
      _store = store {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static final VoiceHotkeyService instance = VoiceHotkeyService();

  final MethodChannel _channel;
  final VoiceSettingsStore? _store;

  VoiceSettingsStore get _settings => _store ?? VoiceSettingsStore.instance;

  final List<_ComposerRegistration> _composers = [];

  String _appliedHotkey = '';
  bool _paused = false;
  bool? _hotkeyTaken;
  bool _following = false;

  /// Whether the OS accepted the current global hotkey (`false` means another
  /// application already holds it; `null` when empty or unsupported).
  bool? get hotkeyTaken => _hotkeyTaken;

  /// Starts syncing the native global hotkey with [VoiceSettingsStore].
  void follow([VoiceSettingsStore? store]) {
    final target = store ?? _settings;
    if (_following) return;
    _following = true;
    target.addListener(_syncFromSettings);
    VoiceTtsService.instance.onAutoReadCompleted = handleConversationFollowUp;
    _syncFromSettings();
  }

  /// Automatically re-opens the mic in the active composer after an auto-read
  /// AI reply finishes speaking while Conversation Mode is active.
  @visibleForTesting
  void handleConversationFollowUp() {
    final cfg = _settings.config;
    if (!cfg.enabled || !cfg.conversationMode) return;
    if (VoiceSttService.instance.isBusy) return;
    handleHotkeyPressed();
  }

  void _syncFromSettings() {
    if (_paused) return;
    final cfg = _settings.config;
    final desired = cfg.enabled ? cfg.sttHotkey.trim() : '';
    if (desired == _appliedHotkey) return;
    unawaited(_applyHotkey(desired));
  }

  Future<void> _applyHotkey(String spec) async {
    _appliedHotkey = spec;
    final result = await _invokeSetHotkey(spec);
    if (spec != _appliedHotkey) return;
    final nextTaken = spec.isEmpty ? null : result;
    if (nextTaken != _hotkeyTaken) {
      _hotkeyTaken = nextTaken;
      notifyListeners();
    }
  }

  /// Temporarily releases the global hotkey while the user is recording a new
  /// shortcut in Settings.
  Future<void> pause() async {
    if (_paused) return;
    _paused = true;
    if (_appliedHotkey.isNotEmpty) {
      await _invokeSetHotkey('');
    }
  }

  /// Re-registers the configured global hotkey after shortcut recording ends.
  Future<void> resume() async {
    if (!_paused) return;
    _paused = false;
    final cfg = _settings.config;
    final desired = cfg.enabled ? cfg.sttHotkey.trim() : '';
    _appliedHotkey = '';
    await _applyHotkey(desired);
  }

  /// Registers a mounted dock composer so the global hotkey can toggle voice
  /// input on it.
  void registerComposer(
    Object owner, {
    required VoidCallback onTrigger,
    required bool Function() isFocused,
  }) {
    _composers.removeWhere((r) => identical(r.owner, owner));
    _composers.add(
      _ComposerRegistration(
        owner: owner,
        onTrigger: onTrigger,
        isFocused: isFocused,
      ),
    );
  }

  /// Moves [owner] to the top of the recency stack when its composer gains focus.
  void markActive(Object owner) {
    final index = _composers.indexWhere((r) => identical(r.owner, owner));
    if (index == -1 || index == _composers.length - 1) return;
    final entry = _composers.removeAt(index);
    _composers.add(entry);
  }

  void unregisterComposer(Object owner) {
    _composers.removeWhere((r) => identical(r.owner, owner));
  }

  /// Dispatches a global hotkey press to the active composer.
  @visibleForTesting
  void handleHotkeyPressed() {
    if (!_settings.config.enabled) return;
    if (_composers.isEmpty) return;

    // 1. If a composer is already actively listening, toggle it off to finish.
    final activeVoiceOwner = VoiceSttService.instance.activeOwner;
    if (activeVoiceOwner != null) {
      for (final reg in _composers) {
        if (identical(reg.owner, activeVoiceOwner)) {
          reg.onTrigger();
          return;
        }
      }
    }

    // 2. Otherwise prefer whichever composer currently has focus.
    for (var i = _composers.length - 1; i >= 0; i--) {
      if (_composers[i].isFocused()) {
        _composers[i].onTrigger();
        return;
      }
    }

    // 3. Fall back to the most recently active mounted dock composer.
    _composers.last.onTrigger();
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method == 'pressed') {
      handleHotkeyPressed();
    }
    return null;
  }

  /// Triggers Windows 11 native neural Voice Typing (`Win + H`) into the
  /// currently focused composer input.
  Future<bool> triggerWindowsDictation() async {
    try {
      return (await _channel.invokeMethod<bool>('triggerDictation')) == true;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      debugPrint('voice.triggerDictation: $error');
      return false;
    }
  }

  Future<bool?> _invokeSetHotkey(String spec) async {
    try {
      return await _channel.invokeMethod<bool>('setHotkey', spec);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('voice.setHotkey: $error');
      return null;
    }
  }

  /// Formats a persisted hotkey spec (`alt+shift+v`) for display (`Alt+Shift+V`
  /// on Windows/Linux, `⌥⇧V` on macOS).
  static String formatLabel(String hotkey, {required bool mac}) {
    if (hotkey.trim().isEmpty) return '';
    final parts = hotkey.toLowerCase().split('+').map((p) => p.trim()).toList();
    final modifiers = <String>[];
    var key = '';
    for (final part in parts) {
      switch (part) {
        case 'ctrl' || 'control':
          modifiers.add(mac ? '⌃' : 'Ctrl');
        case 'alt' || 'option' || 'opt':
          modifiers.add(mac ? '⌥' : 'Alt');
        case 'shift':
          modifiers.add(mac ? '⇧' : 'Shift');
        case 'cmd' || 'command' || 'meta' || 'win' || 'super':
          modifiers.add(mac ? '⌘' : 'Win');
        case final other when other.isNotEmpty:
          key = _keyLabel(other);
      }
    }
    if (key.isEmpty || modifiers.isEmpty) return '';
    return mac ? '${modifiers.join()}$key' : '${modifiers.join('+')}+$key';
  }

  static String _keyLabel(String key) => switch (key) {
    'space' => 'Space',
    'enter' || 'return' => 'Enter',
    'tab' => 'Tab',
    'escape' || 'esc' => 'Esc',
    'left' => '←',
    'right' => '→',
    'up' => '↑',
    'down' => '↓',
    'backquote' => '`',
    _ => key.toUpperCase(),
  };

  @visibleForTesting
  void resetForTest() {
    _composers.clear();
    _appliedHotkey = '';
    _paused = false;
    _hotkeyTaken = null;
    _following = false;
  }
}
