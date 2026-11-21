import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../network/network_proxy_io.dart';
import '../claude_code/claude_environment.dart';
import 'codex_transport.dart';

/// Local stdio JSON-RPC 2.0 transport talking to `codex app-server`.
class ProcessCodexTransport implements CodexTransport {
  ProcessCodexTransport({this.cwd});

  final String? cwd;
  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();
  final List<Map<String, Object?>> _pendingWrites = [];
  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  Future<void>? _starting;
  bool _closed = false;

  static final Set<ProcessCodexTransport> _live = {};

  static Future<void> stopAll() async {
    for (final t in [..._live]) {
      t.close();
    }
  }

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  void write(Map<String, Object?> message) {
    if (_closed) return;
    final proc = _process;
    if (proc != null) {
      _sendNow(proc, message);
      return;
    }
    _pendingWrites.add(message);
    _starting ??= _spawn();
  }

  void _sendNow(Process proc, Map<String, Object?> message) {
    try {
      proc.stdin.writeln(jsonEncode(message));
    } on Object {
      // Ignore write error if process exited.
    }
  }

  Future<void> _spawn() async {
    try {
      final base = await ClaudeEnvironment.of();
      final proxy = await NetworkProxy.instance.environment();
      final env = _enrichedPath({...base, ...proxy});
      final executable = _locateCodex(env);
      if (executable == null) {
        _failPending(
          '未检测到 Codex CLI (codex)。请先安装 @openai/codex 并确保 codex 在 PATH 中。',
        );
        return;
      }
      final workDir = (cwd != null && Directory(cwd!).existsSync())
          ? cwd!
          : Directory.current.path;
      final proc = await Process.start(
        executable,
        const ['app-server'],
        workingDirectory: workDir,
        environment: env,
        includeParentEnvironment: false,
      );
      if (_closed) {
        proc.kill(ProcessSignal.sigterm);
        return;
      }
      _process = proc;
      _live.add(this);
      _stdoutSub = proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(_onLine);
      _stderrSub = proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((_) {});
      unawaited(
        proc.exitCode.then((_) async {
          await _stdoutSub?.cancel();
          await _stderrSub?.cancel();
          _live.remove(this);
          _process = null;
        }),
      );
      final queued = [..._pendingWrites];
      _pendingWrites.clear();
      for (final msg in queued) {
        _sendNow(proc, msg);
      }
    } on Object catch (error) {
      _failPending('启动 Codex app-server 失败: $error');
    }
  }

  void _failPending(String message) {
    final queued = [..._pendingWrites];
    _pendingWrites.clear();
    for (final msg in queued) {
      final id = msg['id'];
      if (id != null && !_messages.isClosed) {
        _messages.add({
          'id': id,
          'error': {'code': -32000, 'message': message},
        });
      }
    }
  }

  void _onLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map && !_messages.isClosed) {
        _messages.add(decoded.cast<String, Object?>());
      }
    } on Object {
      // Ignore non-JSON lines.
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _pendingWrites.clear();
    final proc = _process;
    _process = null;
    if (proc != null) {
      try {
        unawaited(proc.stdin.close());
      } on Object {
        // Ignore.
      }
      proc.kill(ProcessSignal.sigterm);
    }
    _live.remove(this);
    if (!_messages.isClosed) {
      unawaited(_messages.close());
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
        p.join(home, '.hermes', 'node', 'bin'),
        p.join(home, '.local', 'bin'),
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

  static String? _locateCodex(Map<String, String> env) {
    final sep = Platform.isWindows ? ';' : ':';
    final pathVar = env['PATH'] ?? '';
    final exts = Platform.isWindows
        ? const ['.cmd', '.exe', '.bat', '']
        : const [''];
    for (final dir in pathVar.split(sep)) {
      if (dir.trim().isEmpty) continue;
      for (final ext in exts) {
        final candidate = p.join(dir.trim(), 'codex$ext');
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return null;
  }
}
