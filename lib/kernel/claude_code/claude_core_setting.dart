import 'package:flutter/foundation.dart';

/// Settings → General → Antigravity CLI: what runs an agent session
/// (`ayte.core` in settings.json).
enum ClaudeCore {
  /// The Antigravity CLI (`agy`), run as a persistent local stream-json
  /// process using this machine's Google Antigravity sign-in and setup.
  antigravity,

  /// Ayte's built-in core, written in Dart (`package:bao_agent`): runs on
  /// custom API upstreams configured in Settings → Models.
  builtin;

  static const settingKey = 'ayte.core';

  /// Defaults to Antigravity CLI where `agy` is installed on this machine,
  /// else the built-in core.
  static ClaudeCore get fallback =>
      antigravityInstalled() ? antigravity : builtin;

  /// Whether Antigravity CLI (`agy`) is on this machine; `main()` points it
  /// at `LocalAntigravity.installed`.
  static bool Function() antigravityInstalled = () => false;

  static ClaudeCore parse(Object? setting) =>
      values.where((value) => value.name == setting).firstOrNull ?? fallback;

  /// The setting as it is now, read as each session starts; `main()` points
  /// it at settings.json.
  static ClaudeCore Function() current = () => fallback;

  /// Told as the setting may have changed; `main()` points it at
  /// settings.json.
  static Listenable changes = const _Never();

  /// Why [builtin] has nothing to run on: no upstream turned on.
  static const noModel =
      'No model to run on: Ayte\'s built-in core runs on the custom API '
      'providers of Settings → Models. Add one there, or switch the core to '
      'Antigravity CLI (agy) in Settings → General.';
}

/// Tells nothing: no settings file to follow.
class _Never implements Listenable {
  const _Never();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
