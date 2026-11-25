import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../../network/network_proxy_io.dart';
import 'claude_code_transport.dart';
import 'claude_environment.dart';
import 'claude_settings_file.dart';

/// Starts a session on the local Claude Code CLI (`claude -p --input-format
/// stream-json --output-format stream-json ...`).
Future<ClaudeCodeTransport> startClaudeCli(ClaudeLaunch launch) =>
    ClaudeCliTransport.start(launch);

/// Persistent `stream-json` child-process transport for the local Claude Code
/// CLI (`claude`), using the user's local `~/.claude` login and settings.
class ClaudeCliTransport implements ClaudeCodeTransport {
  ClaudeCliTransport._(
    this._process,
    this._executable,
    this._settingsFilePath,
  ) {
    _live.add(this);
    _stdoutSub = _process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_onLine, onError: (Object e) => _stderr.add('$e'));
    _stderrSub = _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          if (_stderr.length >= 40) _stderr.removeAt(0);
          _stderr.add(line);
        });
    unawaited(_process.exitCode.then(_finalizeExit));
  }

  static final Set<ClaudeCliTransport> _live = {};
  static final Set<Future<void>> _pendingStops = {};
  static bool? _installed;

  /// Whether the local `claude` CLI executable is available on PATH.
  static bool installed() =>
      _installed ??= _locateClaude(_enrichedPath(Platform.environment)) != null;

  /// Returns a copy of [base] with common local CLI binary directories added to
  /// `PATH`.
  static Map<String, String> enrichEnvironment(Map<String, String> base) =>
      _enrichedPath(base);

  /// Locates the `claude` CLI executable in [env]'s `PATH`.
  static String? locateExecutable(Map<String, String> env) {
    final found = _locateClaude(env);
    if (found != null) _installed = true;
    return found;
  }

  static Future<void> stopAll() async {
    final live = [..._live];
    for (final t in live) {
      t.close();
    }
    final pendingStops = [..._pendingStops];
    if (live.isEmpty && pendingStops.isEmpty) return;
    await Future.wait([
      for (final t in live)
        t.exited.timeout(const Duration(seconds: 5), onTimeout: () {}),
      for (final stop in pendingStops)
        stop.timeout(const Duration(seconds: 5), onTimeout: () {}),
    ]);
  }

  final Process _process;
  final String _executable;
  String? _settingsFilePath;
  late final StreamSubscription<String> _stdoutSub;
  late final StreamSubscription<String> _stderrSub;
  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();
  final Completer<void> _exited = Completer<void>();
  final List<String> _stderr = [];
  bool _closed = false;
  Future<void>? _terminationFuture;
  Future<void>? _finalizeFuture;

  @visibleForTesting
  String? get settingsFilePathForTesting => _settingsFilePath;

  @visibleForTesting
  static Map<String, String> enrichEnvironmentForTesting(
    Map<String, String> base, {
    bool? forceWindows,
  }) => _enrichedPath(base, forceWindows: forceWindows);

  @visibleForTesting
  static String? locateClaudeForTesting(
    Map<String, String> env, {
    bool? forceWindows,
  }) => _locateClaude(env, forceWindows: forceWindows);

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<void> get exited => _exited.future;

  static Future<ClaudeCodeTransport> start(ClaudeLaunch launch) async {
    if (!Directory(launch.cwd).existsSync()) {
      throw ClaudeFolderGone(launch.cwd);
    }
    final base = await ClaudeEnvironment.of();
    final proxy = await NetworkProxy.instance.environment();
    final combined = <String, String>{...base};
    for (final entry in proxy.entries) {
      if (Platform.isWindows) {
        combined.removeWhere(
          (k, _) => k.toLowerCase() == entry.key.toLowerCase(),
        );
      }
      combined[entry.key] = entry.value;
    }
    final env = _enrichedPath(combined);
    final executable = _locateClaude(env);
    if (executable == null) {
      throw const ClaudeUnavailable(
        '未检测到 Claude Code CLI (claude)',
        detail:
            '请先安装 Claude Code CLI（如 npm install -g @anthropic-ai/claude-code 或官方安装脚本），并确保 claude 在 PATH 中。',
      );
    }
    env.addAll(ClaudeLaunch.environment);

    String? settingsFilePath;
    var effectiveLaunch = launch;
    if (launch.hasSecrets) {
      settingsFilePath = await ClaudeSettingsFile.write(launch.settings);
      effectiveLaunch = launch.withSettingsFile(settingsFilePath);
    }

    try {
      final process = await Process.start(
        executable,
        effectiveLaunch.arguments,
        workingDirectory: launch.cwd,
        environment: env,
        includeParentEnvironment: false,
      );
      return ClaudeCliTransport._(process, executable, settingsFilePath);
    } on Object catch (error) {
      if (settingsFilePath != null) {
        try {
          await ClaudeSettingsFile.delete(settingsFilePath);
        } on Object {
          // Ignore settings cleanup error.
        }
      }
      throw ClaudeUnavailable(
        '无法启动 Claude Code CLI ($executable)',
        detail: '$error',
      );
    }
  }

  void _onLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        if (!_messages.isClosed) {
          _messages.add(decoded.cast<String, Object?>());
        }
      }
    } on Object {
      // Ignore non-JSON preamble/noise lines.
    }
  }

  @override
  void write(Map<String, Object?> message) {
    if (_closed) return;
    try {
      _process.stdin.writeln(jsonEncode(message));
    } on Object {
      // Ignore broken pipe when process exits.
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    if (_exited.isCompleted) {
      _live.remove(this);
      return;
    }
    if (_finalizeFuture case final fin?) {
      _pendingStops.add(fin);
      unawaited(
        fin.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
          _pendingStops.remove(fin);
        }),
      );
      return;
    }
    final stopFuture = _stopAndFinalize();
    _pendingStops.add(stopFuture);
    unawaited(
      stopFuture.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        _pendingStops.remove(stopFuture);
      }),
    );
  }

  Future<void> _stopAndFinalize() async {
    try {
      await _terminateProcessTree();
      final code = await _awaitProcessExitBounded(_process);
      await _finalizeExit(code);
    } finally {
      _live.remove(this);
      if (!_exited.isCompleted) {
        _exited.complete();
      }
    }
  }

  Future<void> _terminateProcessTree() {
    if (_terminationFuture case final existing?) return existing;
    final future = _runTerminateProcessTree();
    _terminationFuture = future;
    return future;
  }

  Future<void> _runTerminateProcessTree() async {
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', ['/pid', '${_process.pid}', '/T', '/F']);
      } on Object {
        try {
          _process.kill();
        } on Object {
          // Ignore if already exited.
        }
      }
      try {
        unawaited(_process.stdin.close().catchError((Object _) {}));
      } on Object {
        // Ignore.
      }
    } else {
      try {
        unawaited(_process.stdin.close().catchError((Object _) {}));
      } on Object {
        // Ignore.
      }
      try {
        _process.kill(ProcessSignal.sigterm);
      } on Object {
        // Ignore if already exited.
      }
    }
  }

  Future<int> _awaitProcessExitBounded(
    Process proc, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      return await proc.exitCode.timeout(
        timeout,
        onTimeout: () {
          try {
            proc.kill(ProcessSignal.sigkill);
          } on Object {
            // Ignore.
          }
          return -1;
        },
      );
    } on Object {
      return -1;
    }
  }

  Future<void> _finalizeExit(int code) =>
      _finalizeFuture ??= _doFinalizeExit(code);

  Future<void> _doFinalizeExit(int code) async {
    try {
      if (_terminationFuture case final term?) {
        await term;
      }
      await _stdoutSub.cancel();
      await _stderrSub.cancel();
      await _cleanupSettingsFile();
      if (!_messages.isClosed) {
        _messages.add(
          ClaudeExit.message(
            code,
            _stderr.join('\n').trim(),
            executable: _executable,
          ),
        );
        await _messages.close();
      }
    } finally {
      _live.remove(this);
      if (!_exited.isCompleted) _exited.complete();
    }
  }

  Future<void> _cleanupSettingsFile() async {
    final path = _settingsFilePath;
    if (path == null) return;
    _settingsFilePath = null;
    try {
      await ClaudeSettingsFile.delete(path);
    } on Object {
      // Ignore.
    }
  }

  static String? _nonEmptyEnv(String? value) =>
      (value != null && value.trim().isNotEmpty) ? value.trim() : null;

  static String? _lookupEnvVar(
    Map<String, String> env,
    String name, {
    required bool win,
  }) {
    final direct = _nonEmptyEnv(env[name]);
    if (direct != null) return direct;
    if (win) {
      final lower = name.toLowerCase();
      for (final entry in env.entries) {
        if (entry.key.toLowerCase() == lower) {
          final value = _nonEmptyEnv(entry.value);
          if (value != null) return value;
        }
      }
      for (final entry in env.entries) {
        if (entry.key.toLowerCase() == lower) {
          return '';
        }
      }
    } else if (env.containsKey(name)) {
      return _nonEmptyEnv(env[name]) ?? '';
    }
    return null;
  }

  static String _resolveHome(
    Map<String, String> base, {
    required bool win,
  }) {
    final baseHome = _lookupEnvVar(base, 'HOME', win: win);
    if (baseHome != null && baseHome.isNotEmpty) return baseHome;
    final baseUserProfile = _lookupEnvVar(base, 'USERPROFILE', win: win);
    if (baseUserProfile != null && baseUserProfile.isNotEmpty) {
      return baseUserProfile;
    }
    if (baseHome != null || baseUserProfile != null) {
      return '';
    }
    final hostHome = _lookupEnvVar(Platform.environment, 'HOME', win: win);
    if (hostHome != null && hostHome.isNotEmpty) return hostHome;
    return _lookupEnvVar(Platform.environment, 'USERPROFILE', win: win) ?? '';
  }

  static Map<String, String> _withPath(
    Map<String, String> base,
    String pathValue, {
    required bool win,
  }) {
    final result = <String, String>{};
    for (final entry in base.entries) {
      if (win && entry.key.toLowerCase() == 'path') continue;
      result[entry.key] = entry.value;
    }
    result['PATH'] = pathValue;
    return result;
  }

  static Map<String, String> _enrichedPath(
    Map<String, String> base, {
    bool? forceWindows,
  }) {
    final win = forceWindows ?? Platform.isWindows;
    final home = _resolveHome(base, win: win);
    final sep = win ? ';' : ':';
    final rawPath =
        _lookupEnvVar(base, 'PATH', win: win) ??
        _lookupEnvVar(Platform.environment, 'PATH', win: win) ??
        '';
    final existing = rawPath
        .split(sep)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final extras = <String>[
      if (home.isNotEmpty && !win) ...[
        p.posix.join(home, '.local', 'bin'),
        p.posix.join(home, '.hermes', 'node', 'bin'),
        p.posix.join(home, '.claude', 'local'),
        p.posix.join(home, '.bun', 'bin'),
        '/opt/homebrew/bin',
        '/usr/local/bin',
      ],
    ];
    final seen = <String>{};
    final merged = <String>[];
    for (final dir in [...existing, ...extras]) {
      final key = win ? dir.toLowerCase() : dir;
      if (seen.add(key)) merged.add(dir);
    }
    return _withPath(base, merged.join(sep), win: win);
  }

  static String? _locateClaude(
    Map<String, String> env, {
    bool? forceWindows,
  }) {
    final win = forceWindows ?? Platform.isWindows;
    final sep = win ? ';' : ':';
    final pathVar = _lookupEnvVar(env, 'PATH', win: win) ?? '';
    final exts = win ? const ['.cmd', '.exe', '.bat', ''] : const [''];
    final join = win ? p.windows.join : p.posix.join;
    for (final dir in pathVar.split(sep)) {
      final trimmed = dir.trim();
      if (trimmed.isEmpty) continue;
      for (final ext in exts) {
        final candidate = join(trimmed, 'claude$ext');
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return null;
  }
}
