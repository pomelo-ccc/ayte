import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    unawaited(
      _process.exitCode.then((code) async {
        await _stdoutSub.cancel();
        await _stderrSub.cancel();
        _live.remove(this);
        _cleanupSettingsFile();
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
        if (!_exited.isCompleted) _exited.complete();
      }),
    );
  }

  static final Set<ClaudeCliTransport> _live = {};

  static Future<void> stopAll() async {
    for (final t in [..._live]) {
      t.close();
    }
  }

  final Process _process;
  final String _executable;
  final String? _settingsFilePath;
  late final StreamSubscription<String> _stdoutSub;
  late final StreamSubscription<String> _stderrSub;
  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();
  final Completer<void> _exited = Completer<void>();
  final List<String> _stderr = [];
  bool _closed = false;

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
    final env = _enrichedPath({...base, ...proxy});
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
        ClaudeSettingsFile.delete(settingsFilePath);
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
    try {
      unawaited(_process.stdin.close());
    } on Object {
      // Ignore.
    }
    _process.kill(ProcessSignal.sigterm);
    _cleanupSettingsFile();
  }

  void _cleanupSettingsFile() {
    try {
      if (_settingsFilePath case final path?) {
        ClaudeSettingsFile.delete(path);
      }
    } on Object {
      // Ignore.
    }
  }

  static Map<String, String> _enrichedPath(Map<String, String> base) {
    final home =
        base['HOME'] ??
        base['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final sep = Platform.isWindows ? ';' : ':';
    final existing = (base['PATH'] ?? Platform.environment['PATH'] ?? '')
        .split(sep)
        .where((s) => s.isNotEmpty)
        .toList();
    final extras = <String>[
      if (home.isNotEmpty && !Platform.isWindows) ...[
        p.join(home, '.local', 'bin'),
        p.join(home, '.hermes', 'node', 'bin'),
        p.join(home, '.claude', 'local'),
        p.join(home, '.bun', 'bin'),
        '/opt/homebrew/bin',
        '/usr/local/bin',
      ],
    ];
    final seen = <String>{};
    final merged = [
      for (final dir in [...extras, ...existing])
        if (seen.add(dir)) dir,
    ];
    return {...base, 'PATH': merged.join(sep)};
  }

  static String? _locateClaude(Map<String, String> env) {
    final sep = Platform.isWindows ? ';' : ':';
    final pathVar = env['PATH'] ?? '';
    final exts = Platform.isWindows
        ? const ['.cmd', '.exe', '.bat', '']
        : const [''];
    for (final dir in pathVar.split(sep)) {
      if (dir.trim().isEmpty) continue;
      for (final ext in exts) {
        final candidate = p.join(dir.trim(), 'claude$ext');
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return null;
  }
}
