import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../../network/network_proxy_io.dart';
import '../claude_code/claude_environment.dart';
import 'codex_transport.dart';

/// Resolved command invocation for spawning `codex`.
class CodexLaunchSpec {
  const CodexLaunchSpec({
    required this.executable,
    required this.arguments,
    required this.runInShell,
    this.resolvedBinary,
  });

  final String executable;
  final List<String> arguments;
  final bool runInShell;
  final String? resolvedBinary;
}

/// Local stdio JSON-RPC 2.0 transport talking to `codex app-server`.
class ProcessCodexTransport implements CodexTransport {
  ProcessCodexTransport({
    this.cwd,
    this.extraArgs = const [],
    this.extraArgsBuilder,
  });

  /// Synthetic JSON-RPC notification method emitted onto [messages] when the
  /// underlying process fails to spawn or exits unexpectedly.
  static const transportExitMethod = 'ayte/transportExit';

  static const int _maxStderrLines = 50;

  final String? cwd;
  final List<String> extraArgs;

  /// Optional dynamic CLI argument builder evaluated on each spawn (e.g. for
  /// loopback MCP server `-c mcp_servers.baocode.url=...` overrides).
  List<String> Function()? extraArgsBuilder;

  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();
  final List<Map<String, Object?>> _pendingWrites = [];
  final List<String> _stderrTail = [];

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  Completer<void> _exitedCompleter = Completer<void>()..complete();
  Completer<void> _procExitedCompleter = Completer<void>()..complete();
  Future<void>? _starting;
  final Set<Future<void>> _inFlightSpawns = {};
  final Set<Future<void>> _pendingCleanups = {};
  Future<void>? _closeCleanupFuture;
  int _epoch = 0;
  bool _closed = false;
  bool _stoppingExpected = false;

  static final Set<ProcessCodexTransport> _live = {};
  static final Set<Future<void>> _pendingStops = {};
  static bool? _installed;

  /// Whether the local `codex` CLI executable is available on PATH.
  static bool installed() =>
      _installed ??= locateCodex(enrichedPath(Platform.environment)) != null;

  static Future<void> stopAll() async {
    final live = [..._live];
    for (final t in live) {
      t.close();
    }
    final pendingStops = [..._pendingStops];
    if (live.isEmpty && pendingStops.isEmpty) return;
    await Future.wait([
      for (final t in live)
        t.exited.timeout(const Duration(seconds: 3), onTimeout: () {}),
      for (final stop in pendingStops)
        stop.timeout(const Duration(seconds: 3), onTimeout: () {}),
    ]);
  }

  /// Completes when the currently active (or last started) process exits.
  Future<void> get exited => _exitedCompleter.future;

  /// Recent `stderr` lines captured from the child process.
  List<String> get stderrTail => List.unmodifiable(_stderrTail);

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
    _starting ??= _startSpawn(_epoch);
  }

  Future<void> _trackCleanup(Future<void> future) {
    _pendingCleanups.add(future);
    return future.whenComplete(() {
      _pendingCleanups.remove(future);
    });
  }

  Future<void> _terminateProcess(Process proc) async {
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', ['/pid', '${proc.pid}', '/T', '/F']);
      } on Object {
        try {
          proc.kill(ProcessSignal.sigterm);
        } on Object {
          // Ignore.
        }
      }
      try {
        unawaited(proc.stdin.close().catchError((_) {}));
      } on Object {
        // Ignore.
      }
    } else {
      try {
        unawaited(proc.stdin.close().catchError((_) {}));
      } on Object {
        // Ignore.
      }
      try {
        proc.kill(ProcessSignal.sigterm);
      } on Object {
        // Ignore.
      }
    }
  }

  Future<void> _startSpawn(int epoch) {
    _live.add(this);
    final future = _spawn(epoch);
    _inFlightSpawns.add(future);
    return future.whenComplete(() {
      _inFlightSpawns.remove(future);
      if (_process == null &&
          _inFlightSpawns.isEmpty &&
          _starting == null &&
          _pendingCleanups.isEmpty &&
          !_closed) {
        _live.remove(this);
      }
    });
  }

  void _sendNow(Process proc, Map<String, Object?> message) {
    try {
      proc.stdin.writeln(jsonEncode(message));
    } on Object {
      // Ignore write error if process exited.
    }
  }

  Future<void> _spawn(int epoch) async {
    final exited = Completer<void>();
    final procExited = Completer<void>();
    _exitedCompleter = exited;
    _procExitedCompleter = procExited;
    _stderrTail.clear();
    _stoppingExpected = false;
    var startedProc = false;
    try {
      final base = await ClaudeEnvironment.of();
      if (_closed || epoch != _epoch) {
        if (!procExited.isCompleted) procExited.complete();
        if (!_closed && !exited.isCompleted) exited.complete();
        return;
      }
      final proxy = await NetworkProxy.instance.environment();
      if (_closed || epoch != _epoch) {
        if (!procExited.isCompleted) procExited.complete();
        if (!_closed && !exited.isCompleted) exited.complete();
        return;
      }
      final env = enrichedPath({...base, ...proxy});
      if (Platform.isWindows) {
        for (final key in const ['SystemRoot', 'WINDIR', 'COMSPEC', 'PATHEXT']) {
          final hasKey = env.keys.any((k) => k.toLowerCase() == key.toLowerCase());
          if (!hasKey) {
            final val = Platform.environment[key] ??
                Platform.environment[key.toUpperCase()];
            if (val != null && val.isNotEmpty) env[key] = val;
          }
        }
      }
      final binary = locateCodex(env);
      if (binary == null) {
        if (epoch == _epoch && !_closed) {
          const msg =
              '未检测到 Codex CLI (codex)。请先安装 @openai/codex 或 Codex 桌面端并确保 codex 在 PATH 中。';
          _failPending(msg);
          _emitExit(
            code: -1,
            stderr: '',
            error: msg,
            missingBinary: true,
          );
        }
        return;
      }

      final dynamicArgs = extraArgsBuilder?.call() ?? const <String>[];
      final appServerArgs = <String>[
        'app-server',
        ...extraArgs,
        ...dynamicArgs,
      ];
      final launch = resolveLaunch(
        binary,
        env,
        appServerArgs: appServerArgs,
      );
      final workDir = (cwd != null && Directory(cwd!).existsSync())
          ? cwd!
          : Directory.current.path;

      if (_closed || epoch != _epoch) {
        if (!procExited.isCompleted) procExited.complete();
        if (!_closed && !exited.isCompleted) exited.complete();
        return;
      }
      final proc = await Process.start(
        launch.executable,
        launch.arguments,
        workingDirectory: workDir,
        environment: env,
        includeParentEnvironment: false,
        runInShell: launch.runInShell,
      );
      if (_closed || epoch != _epoch) {
        await _trackCleanup(_terminateProcess(proc));
        await proc.exitCode
            .timeout(
              const Duration(seconds: 2),
              onTimeout: () {
                try {
                  proc.kill(ProcessSignal.sigkill);
                } on Object {
                  // Ignore.
                }
                return -1;
              },
            )
            .catchError((Object _) => -1);
        if (!procExited.isCompleted) procExited.complete();
        if (!_closed && !exited.isCompleted) exited.complete();
        return;
      }

      _process = proc;
      startedProc = true;
      _live.add(this);
      unawaited(proc.stdin.done.catchError((_) {}));

      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();

      final stdoutSub = proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (epoch == _epoch && !_closed) {
                _onLine(line);
              }
            },
            onError: (_) {
              if (!stdoutDone.isCompleted) stdoutDone.complete();
            },
            onDone: () {
              if (!stdoutDone.isCompleted) stdoutDone.complete();
            },
          );
      _stdoutSub = stdoutSub;

      final stderrSub = proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (epoch == _epoch && !_closed) {
                _onStderrLine(line);
              }
            },
            onError: (_) {
              if (!stderrDone.isCompleted) stderrDone.complete();
            },
            onDone: () {
              if (!stderrDone.isCompleted) stderrDone.complete();
            },
          );
      _stderrSub = stderrSub;

      unawaited(
        proc.exitCode.then((code) async {
          await Future.wait([
            stdoutDone.future,
            stderrDone.future,
          ]).timeout(const Duration(milliseconds: 500), onTimeout: () => const []);
          await stdoutSub.cancel();
          await stderrSub.cancel();
          if (identical(_stdoutSub, stdoutSub)) {
            _stdoutSub = null;
          }
          if (identical(_stderrSub, stderrSub)) {
            _stderrSub = null;
          }
          if (identical(_process, proc)) {
            _process = null;
          }
          if (epoch == _epoch) {
            _live.remove(this);
            _starting = null;
          }
          final expectedStop = _stoppingExpected || _closed || epoch != _epoch;
          if (!expectedStop) {
            final tail = _stderrTail.join('\n').trim();
            _failPending(
              tail.isNotEmpty
                  ? 'Codex app-server 异常退出（代码 $code）：$tail'
                  : 'Codex app-server 异常退出（代码 $code）',
            );
            _emitExit(
              code: code,
              stderr: tail,
              executable: launch.resolvedBinary ?? launch.executable,
            );
          }
          if (!procExited.isCompleted) procExited.complete();
          if (!_closed && !exited.isCompleted) exited.complete();
        }),
      );

      final queued = [..._pendingWrites];
      _pendingWrites.clear();
      for (final msg in queued) {
        _sendNow(proc, msg);
      }
    } on Object catch (error) {
      if (epoch == _epoch) {
        _starting = null;
        final tail = _stderrTail.join('\n').trim();
        _failPending('启动 Codex app-server 失败: $error');
        if (!_closed && !_stoppingExpected) {
          _emitExit(code: -1, stderr: tail, error: '$error');
        }
      }
      if (!procExited.isCompleted) procExited.complete();
      if (!_closed && !exited.isCompleted) exited.complete();
    } finally {
      if (!startedProc && !procExited.isCompleted) {
        procExited.complete();
      }
      if (!_closed && !startedProc && !exited.isCompleted) {
        exited.complete();
      }
      if (_process == null && epoch == _epoch) {
        _starting = null;
      }
    }
  }

  void _emitExit({
    required int code,
    required String stderr,
    String? executable,
    String? error,
    bool missingBinary = false,
  }) {
    if (_closed || _messages.isClosed) return;
    _messages.add({
      'method': transportExitMethod,
      'params': <String, Object?>{
        'code': code,
        'stderr': stderr,
        'executable': ?executable,
        'error': ?error,
        if (missingBinary) 'missingBinary': true,
      },
    });
  }

  void _onStderrLine(String line) {
    final trimmed = line.trimRight();
    if (trimmed.isEmpty) return;
    _stderrTail.add(trimmed);
    if (_stderrTail.length > _maxStderrLines) {
      _stderrTail.removeAt(0);
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

  /// Stops any running `codex app-server` child process without closing the
  /// transport stream, allowing subsequent [write] calls (e.g. after `release`
  /// or `restart`) to spawn a fresh process cleanly.
  Future<void> stopProcess() {
    final stopEpoch = ++_epoch;
    _stoppingExpected = true;
    _pendingWrites.clear();
    _starting = null;
    final proc = _process;
    _process = null;
    final procExitedToAwait = _procExitedCompleter;
    final spawnsToAwait = [..._inFlightSpawns];
    final cleanupsToAwait = [..._pendingCleanups];

    if (proc == null && spawnsToAwait.isEmpty && cleanupsToAwait.isEmpty) {
      if (_inFlightSpawns.isEmpty && _starting == null && !_closed) {
        _live.remove(this);
      }
      return Future.value();
    }

    final future = _trackCleanup(
      _runStopProcess(
        stopEpoch: stopEpoch,
        proc: proc,
        procExitedToAwait: procExitedToAwait,
        spawnsToAwait: spawnsToAwait,
        cleanupsToAwait: cleanupsToAwait,
      ),
    );
    _pendingStops.add(future);
    return future.whenComplete(() {
      _pendingStops.remove(future);
    });
  }

  Future<void> _runStopProcess({
    required int stopEpoch,
    required Process? proc,
    required Completer<void> procExitedToAwait,
    required List<Future<void>> spawnsToAwait,
    required List<Future<void>> cleanupsToAwait,
  }) async {
    try {
      if (proc != null) {
        await _terminateProcess(proc);
        await procExitedToAwait.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            try {
              proc.kill(ProcessSignal.sigkill);
            } on Object {
              // Ignore.
            }
          },
        );
      }
      for (final f in spawnsToAwait) {
        try {
          await f;
        } on Object {
          // Ignore spawn failures during stopProcess.
        }
      }
      for (final f in cleanupsToAwait) {
        try {
          await f;
        } on Object {
          // Ignore cleanup failures during stopProcess.
        }
      }
    } finally {
      if (_epoch == stopEpoch &&
          _process == null &&
          _inFlightSpawns.isEmpty &&
          _starting == null &&
          !_closed) {
        _live.remove(this);
      }
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _epoch++;
    _stoppingExpected = true;
    _pendingWrites.clear();
    _starting = null;
    final proc = _process;
    _process = null;
    final hasPendingWork =
        proc != null ||
        _inFlightSpawns.isNotEmpty ||
        _pendingCleanups.isNotEmpty;
    if (!hasPendingWork) {
      _live.remove(this);
      if (!_messages.isClosed) {
        unawaited(_messages.close());
      }
      if (!_exitedCompleter.isCompleted) {
        _exitedCompleter.complete();
      }
      return;
    }
    if (proc != null) {
      unawaited(_trackCleanup(_terminateProcess(proc)));
    }
    _closeCleanupFuture ??= _finalizeClose(proc);
  }

  Future<void> _finalizeClose(Process? initialProc) async {
    while (true) {
      final pending = <Future<void>>[
        ..._inFlightSpawns,
        ..._pendingCleanups,
      ];
      if (pending.isEmpty) break;
      for (final f in pending) {
        try {
          await f;
        } on Object {
          // Ignore spawn/cleanup failures during close; finalization completes.
        }
      }
    }

    if (initialProc != null) {
      try {
        await initialProc.exitCode.timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            try {
              initialProc.kill(ProcessSignal.sigkill);
            } on Object {
              // Ignore.
            }
            return -1;
          },
        );
      } on Object {
        // Proceed to cleanup if exitCode fails.
      }
    }

    _live.remove(this);
    if (!_messages.isClosed) {
      await _messages.close();
    }
    if (!_exitedCompleter.isCompleted) {
      _exitedCompleter.complete();
    }
  }

  static String _readEnvVar(
    Map<String, String> env,
    String name, {
    required bool win,
  }) => _lookupEnvVar(env, name, win: win) ?? '';

  static String? _lookupEnvVar(
    Map<String, String> env,
    String name, {
    required bool win,
  }) {
    if (env[name] case final v? when v.isNotEmpty) return v;
    if (win) {
      final lower = name.toLowerCase();
      for (final entry in env.entries) {
        if (entry.key.toLowerCase() == lower && entry.value.isNotEmpty) {
          return entry.value;
        }
      }
      for (final entry in env.entries) {
        if (entry.key.toLowerCase() == lower) {
          return entry.value;
        }
      }
    } else if (env.containsKey(name)) {
      return env[name];
    }
    return null;
  }

  static String _readEnvWithFallback(
    Map<String, String> base,
    String name, {
    required bool win,
  }) {
    final direct = _lookupEnvVar(base, name, win: win);
    if (direct != null) return direct;
    return _readEnvVar(Platform.environment, name, win: win);
  }

  /// Reads `PATH` case-insensitively on Windows (e.g. `Path` vs `PATH`).
  @visibleForTesting
  static String readPathVar(
    Map<String, String> env, {
    bool? forceWindows,
  }) => _readEnvVar(
    env,
    'PATH',
    win: forceWindows ?? Platform.isWindows,
  );

  /// Returns a copy of [base] with any case-variant `Path` key replaced by
  /// canonical `PATH = pathValue`.
  @visibleForTesting
  static Map<String, String> withPath(
    Map<String, String> base,
    String pathValue, {
    bool? forceWindows,
  }) {
    final win = forceWindows ?? Platform.isWindows;
    final result = <String, String>{};
    for (final entry in base.entries) {
      if (win && entry.key.toLowerCase() == 'path') continue;
      result[entry.key] = entry.value;
    }
    result['PATH'] = pathValue;
    return result;
  }

  /// Enriches `PATH` with common Windows and POSIX tool/runtime locations
  /// (npm, Volta, Bun, Node.js, OpenAI Codex app binary directories) while
  /// preserving case-insensitive `PATH` semantics on Windows.
  static Map<String, String> enrichedPath(
    Map<String, String> base, {
    bool? forceWindows,
  }) {
    final win = forceWindows ?? Platform.isWindows;
    final baseHome = _lookupEnvVar(base, 'HOME', win: win);
    final baseUserProfile = _lookupEnvVar(base, 'USERPROFILE', win: win);
    final home = (baseHome != null && baseHome.isNotEmpty)
        ? baseHome
        : (baseUserProfile != null && baseUserProfile.isNotEmpty)
        ? baseUserProfile
        : (baseHome != null || baseUserProfile != null)
        ? ''
        : switch (_readEnvVar(Platform.environment, 'HOME', win: win)) {
            final h when h.isNotEmpty => h,
            _ => _readEnvVar(Platform.environment, 'USERPROFILE', win: win),
          };
    final sep = win ? ';' : ':';
    final currentPath = readPathVar(base, forceWindows: win);
    final existing = currentPath
        .split(sep)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final extras = <String>[];
    if (win) {
      final appData = _readEnvWithFallback(base, 'APPDATA', win: win);
      final localAppData = _readEnvWithFallback(
        base,
        'LOCALAPPDATA',
        win: win,
      );
      final voltaHome = _readEnvWithFallback(base, 'VOLTA_HOME', win: win);
      final programFiles = _readEnvWithFallback(base, 'ProgramFiles', win: win);

      if (appData.isNotEmpty) {
        extras.add(p.windows.join(appData, 'npm'));
      }
      if (localAppData.isNotEmpty) {
        extras.add(p.windows.join(localAppData, 'Volta', 'bin'));
        extras.addAll(_codexAppBinDirs(localAppData));
      }
      if (voltaHome.isNotEmpty) {
        extras.add(p.windows.join(voltaHome, 'bin'));
      }
      if (programFiles.isNotEmpty) {
        extras.add(p.windows.join(programFiles, 'nodejs'));
      }
      if (home.isNotEmpty) {
        extras.add(p.windows.join(home, '.volta', 'bin'));
        extras.add(p.windows.join(home, '.bun', 'bin'));
        extras.add(p.windows.join(home, '.local', 'bin'));
      }
    } else {
      if (home.isNotEmpty) {
        extras.addAll([
          p.posix.join(home, '.hermes', 'node', 'bin'),
          p.posix.join(home, '.local', 'bin'),
          p.posix.join(home, '.bun', 'bin'),
          p.posix.join(home, '.volta', 'bin'),
        ]);
      }
      extras.addAll(const [
        '/opt/homebrew/bin',
        '/usr/local/bin',
        '/usr/bin',
        '/bin',
      ]);
    }

    final seen = <String>{};
    final merged = <String>[];
    for (final dir in [...existing, ...extras]) {
      final key = win ? dir.toLowerCase() : dir;
      if (seen.add(key)) merged.add(dir);
    }
    return withPath(base, merged.join(sep), forceWindows: win);
  }

  static List<String> _codexAppBinDirs(String localAppData) {
    final baseDir = Directory(p.join(localAppData, 'OpenAI', 'Codex', 'bin'));
    if (!baseDir.existsSync()) return const [];
    final dirs = <String>[];
    try {
      final entries = baseDir.listSync().whereType<Directory>().toList()
        ..sort((a, b) {
          try {
            return b.statSync().modified.compareTo(a.statSync().modified);
          } on Object {
            return b.path.compareTo(a.path);
          }
        });
      for (final sub in entries) {
        if (File(p.join(sub.path, 'codex.exe')).existsSync()) {
          dirs.add(sub.path);
        }
      }
    } on Object {
      // Ignore inaccessible directories.
    }
    if (File(p.join(baseDir.path, 'codex.exe')).existsSync()) {
      dirs.add(baseDir.path);
    }
    return dirs;
  }

  /// Locates `codex` across `env['PATH']` (case-insensitive on Windows) and
  /// `%LOCALAPPDATA%\OpenAI\Codex\bin\*` on Windows, respecting `PATH`
  /// directory order while preferring native `.exe` binaries before
  /// `.cmd`/`.bat`/`.ps1` shims within each directory.
  static String? locateCodex(
    Map<String, String> env, {
    bool? forceWindows,
  }) {
    final win = forceWindows ?? Platform.isWindows;
    final sep = win ? ';' : ':';
    final pathVar = readPathVar(env, forceWindows: win);
    final dirs = [
      for (final dir in pathVar.split(sep))
        if (dir.trim().isNotEmpty) dir.trim(),
    ];
    if (win) {
      final localAppData = _readEnvVar(env, 'LOCALAPPDATA', win: true);
      if (localAppData.isNotEmpty) {
        for (final appDir in _codexAppBinDirs(localAppData)) {
          if (!dirs.any((d) => d.toLowerCase() == appDir.toLowerCase())) {
            dirs.add(appDir);
          }
        }
      }
      const exts = ['.exe', '.cmd', '.bat', '.ps1', ''];
      for (final dir in dirs) {
        for (final ext in exts) {
          final candidate = p.join(dir, 'codex$ext');
          if (File(candidate).existsSync()) return candidate;
        }
      }
      return null;
    }

    for (final dir in dirs) {
      final candidate = p.join(dir, 'codex');
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Resolves the final process executable, arguments, and `runInShell` flag
  /// for launching `codex`, unwrapping Windows npm `.cmd`/`.bat` and
  /// `.ps1` shims directly to `node.exe` + script when possible.
  static CodexLaunchSpec resolveLaunch(
    String executable,
    Map<String, String> env, {
    List<String> appServerArgs = const ['app-server'],
    bool? forceWindows,
  }) {
    final win = forceWindows ?? Platform.isWindows;
    if (!win) {
      return CodexLaunchSpec(
        executable: executable,
        arguments: appServerArgs,
        runInShell: false,
        resolvedBinary: executable,
      );
    }

    final ext = p.extension(executable).toLowerCase();
    if (ext == '.cmd' || ext == '.bat') {
      final unwrapped = _unwrapCmdShim(executable, env, forceWindows: win);
      if (unwrapped != null) {
        return CodexLaunchSpec(
          executable: unwrapped.nodeExe,
          arguments: [unwrapped.scriptPath, ...appServerArgs],
          runInShell: false,
          resolvedBinary: executable,
        );
      }
      return CodexLaunchSpec(
        executable: executable,
        arguments: appServerArgs,
        runInShell: true,
        resolvedBinary: executable,
      );
    }

    if (ext == '.ps1') {
      final unwrapped = _unwrapPs1Shim(executable, env, forceWindows: win);
      if (unwrapped != null) {
        return CodexLaunchSpec(
          executable: unwrapped.nodeExe,
          arguments: [unwrapped.scriptPath, ...appServerArgs],
          runInShell: false,
          resolvedBinary: executable,
        );
      }
      return CodexLaunchSpec(
        executable: 'powershell.exe',
        arguments: [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          executable,
          ...appServerArgs,
        ],
        runInShell: false,
        resolvedBinary: executable,
      );
    }

    return CodexLaunchSpec(
      executable: executable,
      arguments: appServerArgs,
      runInShell: false,
      resolvedBinary: executable,
    );
  }

  static ({String nodeExe, String scriptPath})? _unwrapCmdShim(
    String shimPath,
    Map<String, String> env, {
    required bool forceWindows,
  }) {
    final file = File(shimPath);
    if (!file.existsSync()) return null;
    String content;
    try {
      content = file.readAsStringSync();
    } on Object {
      return null;
    }
    final match = RegExp(
      r'''["']%(?:dp0%|~dp0%?)[/\\]?([^"']+\.(?:c|m)?js)["']''',
      caseSensitive: false,
    ).firstMatch(content);
    if (match == null) return null;
    return _resolveShimTarget(
      p.dirname(shimPath),
      match.group(1)!,
      env,
      forceWindows: forceWindows,
    );
  }

  static ({String nodeExe, String scriptPath})? _unwrapPs1Shim(
    String shimPath,
    Map<String, String> env, {
    required bool forceWindows,
  }) {
    final file = File(shimPath);
    if (!file.existsSync()) return null;
    String content;
    try {
      content = file.readAsStringSync();
    } on Object {
      return null;
    }
    final match = RegExp(
      r'''["']\$basedir[/\\]([^"']+\.(?:c|m)?js)["']''',
      caseSensitive: false,
    ).firstMatch(content);
    if (match == null) return null;
    return _resolveShimTarget(
      p.dirname(shimPath),
      match.group(1)!,
      env,
      forceWindows: forceWindows,
    );
  }

  static ({String nodeExe, String scriptPath})? _resolveShimTarget(
    String shimDir,
    String relativeScript,
    Map<String, String> env, {
    required bool forceWindows,
  }) {
    final normalizedRel = relativeScript.replaceAll('/', p.separator);
    final scriptPath = p.normalize(p.join(shimDir, normalizedRel));
    if (!File(scriptPath).existsSync()) return null;

    final localNode = p.join(shimDir, 'node.exe');
    if (File(localNode).existsSync()) {
      return (nodeExe: localNode, scriptPath: scriptPath);
    }

    final sep = forceWindows ? ';' : ':';
    final pathVar = readPathVar(env, forceWindows: forceWindows);
    final nodeName = forceWindows ? 'node.exe' : 'node';
    for (final dir in pathVar.split(sep)) {
      final trimmed = dir.trim();
      if (trimmed.isEmpty) continue;
      final candidate = p.join(trimmed, nodeName);
      if (File(candidate).existsSync()) {
        return (nodeExe: candidate, scriptPath: scriptPath);
      }
    }
    return null;
  }
}
