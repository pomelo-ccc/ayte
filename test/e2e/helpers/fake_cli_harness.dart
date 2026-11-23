import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:path/path.dart' as p;

/// Resolves the real `dart` / `dart.exe` executable even when running inside
/// `flutter_tester`.
String resolveDartExecutable() {
  final exeName = Platform.isWindows ? 'dart.exe' : 'dart';
  final direct = p.join(p.dirname(Platform.resolvedExecutable), exeName);
  if (File(direct).existsSync()) return direct;

  if (Platform.environment['FLUTTER_ROOT'] case final root?
      when root.isNotEmpty) {
    final sdkDart = p.join(root, 'bin', 'cache', 'dart-sdk', 'bin', exeName);
    if (File(sdkDart).existsSync()) return sdkDart;
  }

  // `flutter_tester.exe` typically lives at:
  // <flutter>/bin/cache/artifacts/engine/<platform>/flutter_tester.exe
  var cursor = Directory(p.dirname(Platform.resolvedExecutable));
  for (var i = 0; i < 6; i++) {
    final sdkDart = p.join(cursor.path, 'dart-sdk', 'bin', exeName);
    if (File(sdkDart).existsSync()) return sdkDart;
    final binCacheDart = p.join(
      cursor.path,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      exeName,
    );
    if (File(binCacheDart).existsSync()) return binCacheDart;
    final parent = cursor.parent;
    if (parent.path == cursor.path) break;
    cursor = parent;
  }

  final sep = Platform.isWindows ? ';' : ':';
  for (final dir in (Platform.environment['PATH'] ?? '').split(sep)) {
    if (dir.trim().isEmpty) continue;
    final candidate = p.join(dir.trim(), exeName);
    if (File(candidate).existsSync()) return candidate;
  }
  return exeName;
}

/// Cross-platform fake CLI executable backed by a real Dart child script.
///
/// On Windows, defaults to a cached native `.exe` trampoline (`[nativeExeOnWindows] = true`)
/// compiled once under `<repoRoot>/.dart_tool/ayte_e2e/` with a Win32 Job Object
/// (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK`),
/// `ProcessStartMode.inheritStdio`, a `<exe>.cfg` sidecar, and `.fake_cli_pids/*.pid`
/// tracking. This preserves multi-line/metacharacter CLI arguments verbatim via
/// `CreateProcessW` (`throughShell: false`) and prevents orphan `dart.exe` processes.
/// On POSIX, generates `<name>` (`chmod +x`) delegating `"$@"` via `exec`.
class FakeCliExecutable {
  FakeCliExecutable._({
    required this.executablePath,
    required this.scriptPath,
    required this.capturePath,
    required this.pidDirPath,
  });

  final String executablePath;
  final String scriptPath;
  final String capturePath;
  final String pidDirPath;

  static final Map<String, String> _trampolineExeCache = {};

  static const String _windowsTrampolineSource = r'''
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

final class _JobObjectBasicLimitInformation extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;
  @Int64()
  external int perJobUserTimeLimit;
  @Uint32()
  external int limitFlags;
  @IntPtr()
  external int minimumWorkingSetSize;
  @IntPtr()
  external int maximumWorkingSetSize;
  @Uint32()
  external int activeProcessLimit;
  @IntPtr()
  external int affinity;
  @Uint32()
  external int priorityClass;
  @Uint32()
  external int schedulingClass;
}

final class _IoCounters extends Struct {
  @Uint64()
  external int readOperationCount;
  @Uint64()
  external int writeOperationCount;
  @Uint64()
  external int otherOperationCount;
  @Uint64()
  external int readTransferCount;
  @Uint64()
  external int writeTransferCount;
  @Uint64()
  external int otherTransferCount;
}

final class _JobObjectExtendedLimitInformation extends Struct {
  external _JobObjectBasicLimitInformation basicLimitInformation;
  external _IoCounters ioInfo;
  @IntPtr()
  external int processMemoryLimit;
  @IntPtr()
  external int jobMemoryLimit;
  @IntPtr()
  external int peakProcessMemoryUsed;
  @IntPtr()
  external int peakJobMemoryUsed;
}

const int _jobObjectExtendedLimitInformationClass = 9;
const int _jobObjectLimitKillOnJobClose = 0x00002000;
const int _jobObjectLimitBreakawayOk = 0x00000800;

int _jobHandle = 0;

void _attachKillOnCloseJob() {
  if (!Platform.isWindows) return;
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final createJobObject = kernel32.lookupFunction<
      IntPtr Function(Pointer<Void>, Pointer<Void>),
      int Function(Pointer<Void>, Pointer<Void>)
    >('CreateJobObjectW');
    final setInformationJobObject = kernel32.lookupFunction<
      Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32),
      int Function(int, int, Pointer<Void>, int)
    >('SetInformationJobObject');
    final getCurrentProcess = kernel32.lookupFunction<
      IntPtr Function(),
      int Function()
    >('GetCurrentProcess');
    final assignProcessToJobObject = kernel32.lookupFunction<
      Int32 Function(IntPtr, IntPtr),
      int Function(int, int)
    >('AssignProcessToJobObject');

    final job = createJobObject(nullptr, nullptr);
    if (job == 0) return;

    final infoSize = sizeOf<_JobObjectExtendedLimitInformation>();
    final callocPtr = kernel32.lookupFunction<
      IntPtr Function(),
      int Function()
    >('GetProcessHeap');
    final heapAlloc = kernel32.lookupFunction<
      Pointer<Void> Function(IntPtr, Uint32, IntPtr),
      Pointer<Void> Function(int, int, int)
    >('HeapAlloc');
    final heapFree = kernel32.lookupFunction<
      Int32 Function(IntPtr, Uint32, Pointer<Void>),
      int Function(int, int, Pointer<Void>)
    >('HeapFree');

    final heap = callocPtr();
    const heapZeroMemory = 0x00000008;
    final rawPtr = heapAlloc(heap, heapZeroMemory, infoSize);
    if (rawPtr == nullptr) return;
    try {
      final info = rawPtr.cast<_JobObjectExtendedLimitInformation>();
      info.ref.basicLimitInformation.limitFlags =
          _jobObjectLimitKillOnJobClose | _jobObjectLimitBreakawayOk;
      setInformationJobObject(
        job,
        _jobObjectExtendedLimitInformationClass,
        rawPtr,
        infoSize,
      );
      assignProcessToJobObject(job, getCurrentProcess());
      // Keep job handle open for the process lifetime so closing it on
      // process exit/kill terminates all child dart.exe processes.
      _jobHandle = job;
    } finally {
      heapFree(heap, 0, rawPtr);
    }
  } on Object {
    // Best-effort Win32 job attachment; .pid tracking handles fallback cleanup.
  }
}

Future<void> main(List<String> args) async {
  _attachKillOnCloseJob();
  final cfgFile = File('${Platform.resolvedExecutable}.cfg');
  final cfg = (jsonDecode(cfgFile.readAsStringSync()) as Map)
      .cast<String, Object?>();
  final dartExe = cfg['dart'] as String;
  final script = cfg['script'] as String;
  final pidDirPath = cfg['pidDir'] as String?;

  final proc = await Process.start(
    dartExe,
    [script, ...args],
    mode: ProcessStartMode.inheritStdio,
  );

  File? pidFile;
  if (pidDirPath != null && pidDirPath.isNotEmpty) {
    try {
      Directory(pidDirPath).createSync(recursive: true);
      pidFile = File('$pidDirPath${Platform.pathSeparator}$pid.pid');
      pidFile.writeAsStringSync('$pid\n${proc.pid}\n', flush: true);
    } on Object {
      pidFile = null;
    }
  }

  final int code;
  try {
    code = await proc.exitCode;
  } finally {
    if (pidFile != null) {
      try {
        if (pidFile.existsSync()) pidFile.deleteSync();
      } on Object {
        // Best-effort pid marker cleanup.
      }
    }
  }
  if (_jobHandle < 0) stderr.writeln('');
  exit(code);
}
''';

  static String _sourceTag(String source) {
    var hash = 0x811c9dc5;
    for (final unit in source.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    final hex = hash.toRadixString(16).padLeft(8, '0');
    return 'v1_${hex}_${source.length}';
  }

  static Directory _resolveShimCacheDir() {
    var cursor = Directory.current;
    for (var i = 0; i < 6; i++) {
      final pubspec = File(p.join(cursor.path, 'pubspec.yaml'));
      final dartTool = Directory(p.join(cursor.path, '.dart_tool'));
      if (pubspec.existsSync() && dartTool.existsSync()) {
        final cache = Directory(p.join(dartTool.path, 'ayte_e2e'));
        if (!cache.existsSync()) cache.createSync(recursive: true);
        return cache;
      }
      final parent = cursor.parent;
      if (parent.path == cursor.path) break;
      cursor = parent;
    }
    final fallback = Directory(
      p.join(Directory.systemTemp.path, 'baocode_e2e_shim_cache'),
    );
    if (!fallback.existsSync()) fallback.createSync(recursive: true);
    return fallback;
  }

  static String _ensureWindowsTrampolineExe(String dartExe) {
    final tag = _sourceTag(_windowsTrampolineSource);
    final memCached = _trampolineExeCache[tag];
    if (memCached != null && File(memCached).existsSync()) {
      return memCached;
    }

    final cacheDir = _resolveShimCacheDir();
    final target = File(
      p.join(cacheDir.path, 'fake_cli_trampoline_$tag.exe'),
    );
    if (target.existsSync()) {
      _trampolineExeCache[tag] = target.path;
      return target.path;
    }

    final lockDir = Directory(p.join(cacheDir.path, 'compile_$tag.lock'));
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      if (target.existsSync()) {
        _trampolineExeCache[tag] = target.path;
        return target.path;
      }

      var locked = false;
      try {
        lockDir.createSync();
        locked = true;
      } on FileSystemException {
        try {
          if (lockDir.existsSync()) {
            final age = DateTime.now().difference(lockDir.statSync().modified);
            if (age > const Duration(seconds: 90)) {
              lockDir.deleteSync(recursive: true);
            }
          }
        } on Object {
          // Another isolate updated/removed the lock concurrently.
        }
        sleep(const Duration(milliseconds: 50));
        continue;
      }

      if (locked) {
        final srcFile = File(
          p.join(cacheDir.path, 'trampoline_${tag}_$pid.dart'),
        );
        final tmpExe = File(
          p.join(cacheDir.path, 'trampoline_${tag}_$pid.tmp.exe'),
        );
        try {
          if (!target.existsSync()) {
            srcFile.writeAsStringSync(_windowsTrampolineSource);
            final res = Process.runSync(dartExe, [
              'compile',
              'exe',
              srcFile.path,
              '-o',
              tmpExe.path,
            ]);
            if (res.exitCode != 0 || !tmpExe.existsSync()) {
              throw StateError(
                'Failed to compile Windows fake CLI trampoline (exit=${res.exitCode}): '
                '${res.stdout}\n${res.stderr}',
              );
            }
            if (!target.existsSync()) {
              tmpExe.renameSync(target.path);
            }
          }
          _trampolineExeCache[tag] = target.path;
          return target.path;
        } finally {
          try {
            if (srcFile.existsSync()) srcFile.deleteSync();
          } on Object {
            // Best-effort temp source cleanup.
          }
          try {
            if (tmpExe.existsSync()) tmpExe.deleteSync();
          } on Object {
            // Best-effort temp exe cleanup.
          }
          try {
            if (lockDir.existsSync()) lockDir.deleteSync(recursive: true);
          } on Object {
            // Best-effort lock directory cleanup.
          }
        }
      }
    }

    if (target.existsSync()) {
      _trampolineExeCache[tag] = target.path;
      return target.path;
    }
    throw StateError(
      'Timed out waiting for compiled Windows fake CLI trampoline at ${target.path}',
    );
  }

  /// Creates a fake CLI executable in [dir] whose Dart body runs when invoked.
  ///
  /// The generated Dart script has `dart:async`, `dart:convert`, and `dart:io`
  /// imported, and defines helper `recordEvent(Map<String, Object?> data)` that
  /// appends JSON lines to [capturePath].
  static FakeCliExecutable create(
    Directory dir, {
    required String name,
    required String dartBody,
    bool nativeExeOnWindows = true,
  }) {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final dartExe = resolveDartExecutable();
    final scriptFile = File(p.join(dir.path, '${name}_impl.dart'));
    final captureFile = File(p.join(dir.path, '${name}_capture.jsonl'));
    final pidDirPath = p.join(dir.path, '.fake_cli_pids');
    final escapedCapture = jsonEncode(captureFile.path);

    scriptFile.writeAsStringSync('''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

final File _captureFile = File($escapedCapture);

void recordEvent(Map<String, Object?> data) {
  _captureFile.writeAsStringSync(
    '\${jsonEncode(data)}\\n',
    mode: FileMode.append,
    flush: true,
  );
}

$dartBody
''');

    final String execPath;
    if (Platform.isWindows && nativeExeOnWindows) {
      final trampolinePath = _ensureWindowsTrampolineExe(dartExe);
      execPath = p.join(dir.path, '$name.exe');
      File(trampolinePath).copySync(execPath);
      File('$execPath.cfg').writeAsStringSync(
        jsonEncode({
          'dart': dartExe,
          'script': scriptFile.path,
          'pidDir': pidDirPath,
        }),
      );
    } else if (Platform.isWindows) {
      execPath = p.join(dir.path, '$name.cmd');
      File(execPath).writeAsStringSync(
        '@echo off\r\n"$dartExe" "${scriptFile.path}" %*\r\n',
      );
    } else {
      execPath = p.join(dir.path, name);
      File(execPath).writeAsStringSync(
        '#!/bin/sh\nexec "$dartExe" "${scriptFile.path}" "\$@"\n',
      );
      Process.runSync('chmod', ['+x', execPath]);
    }

    return FakeCliExecutable._(
      executablePath: execPath,
      scriptPath: scriptFile.path,
      capturePath: captureFile.path,
      pidDirPath: pidDirPath,
    );
  }

  /// Waits briefly for clean exits and terminates any live fake CLI processes
  /// tracked under [rootDir] via `.fake_cli_pids/*.pid`.
  static Future<void> terminateRecordedPids(
    Directory rootDir, {
    Duration grace = const Duration(milliseconds: 300),
  }) async {
    if (!rootDir.existsSync()) return;
    List<File> findPidFiles() {
      if (!rootDir.existsSync()) return const [];
      final out = <File>[];
      try {
        for (final entity in rootDir.listSync(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File &&
              p.basename(entity.parent.path) == '.fake_cli_pids' &&
              entity.path.endsWith('.pid')) {
            out.add(entity);
          }
        }
      } on FileSystemException {
        return const [];
      }
      return out;
    }

    final deadline = DateTime.now().add(grace);
    var pidFiles = findPidFiles();
    while (pidFiles.isNotEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      pidFiles = findPidFiles();
    }
    if (pidFiles.isEmpty) return;

    for (final pidFile in pidFiles) {
      final pids = <int>[];
      try {
        for (final line in pidFile.readAsLinesSync()) {
          final parsed = int.tryParse(line.trim());
          if (parsed != null && parsed > 0 && !pids.contains(parsed)) {
            pids.add(parsed);
          }
        }
      } on Object {
        // File disappeared concurrently.
      }
      // Kill child dart.exe first, then trampoline.
      for (final targetPid in pids.reversed) {
        if (Platform.isWindows) {
          try {
            await Process.run('taskkill', [
              '/PID',
              '$targetPid',
              '/T',
              '/F',
            ]).timeout(
              const Duration(seconds: 3),
              onTimeout: () => ProcessResult(0, 1, '', ''),
            );
          } on Object {
            // Best-effort process cleanup.
          }
        } else {
          try {
            Process.killPid(targetPid, ProcessSignal.sigkill);
          } on Object {
            // Best-effort process cleanup.
          }
        }
      }
      try {
        if (pidFile.existsSync()) pidFile.deleteSync();
      } on Object {
        // Best-effort marker removal.
      }
    }
  }

  /// Terminates any tracked processes launched from this executable's directory.
  Future<void> terminateProcesses({
    Duration grace = const Duration(milliseconds: 300),
  }) => terminateRecordedPids(Directory(pidDirPath), grace: grace);

  /// Reads all captured JSON-lines records written by the fake CLI process.
  List<Map<String, Object?>> readCaptures() {
    final file = File(capturePath);
    if (!file.existsSync()) return const [];
    final out = <Map<String, Object?>>[];
    for (final line in file.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        out.add(decoded.cast<String, Object?>());
      }
    }
    return out;
  }

  /// Finds the first captured launch record (`type == 'launch'`).
  Map<String, Object?>? firstLaunchCapture() {
    for (final entry in readCaptures()) {
      if (entry['type'] == 'launch') return entry;
    }
    return null;
  }

  /// Returns all captured `stdin` payloads (`type == 'stdin'`).
  List<Map<String, Object?>> stdinCaptures() => [
    for (final entry in readCaptures())
      if (entry['type'] == 'stdin') entry,
  ];
}

typedef ControlRequestHandler =
    Map<String, Object?> Function(String subtype, Map<String, Object?> request);

typedef UserTurnHandler =
    void Function(
      ScriptedClaudeTransport transport,
      Map<String, Object?> message,
    );

/// Deterministic in-process [ClaudeCodeTransport] for `ClaudeCodeKernel`,
/// `SessionTools`, and `Workspace` opaque-box tests.
class ScriptedClaudeTransport implements ClaudeCodeTransport {
  ScriptedClaudeTransport({
    required this.launch,
    this.sessionId = 'scripted-session',
    this.account,
    this.commands = const [],
    this.models = const [],
    this.onControlRequest,
    this.onUserTurn,
  });

  final ClaudeLaunch launch;
  final String sessionId;
  final Map<String, Object?>? account;
  final List<Map<String, Object?>> commands;
  final List<Map<String, Object?>> models;
  final ControlRequestHandler? onControlRequest;
  final UserTurnHandler? onUserTurn;

  final StreamController<Map<String, Object?>> _messages =
      StreamController<Map<String, Object?>>.broadcast();
  final Completer<void> _exited = Completer<void>();
  final List<Map<String, Object?>> writtenMessages = [];
  bool _closed = false;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<void> get exited => _exited.future;

  bool get isClosed => _closed;

  /// Emits a raw stream-json message to the kernel.
  void emit(Map<String, Object?> message) {
    if (_closed || _messages.isClosed) return;
    _messages.add({'session_id': sessionId, ...message});
  }

  /// Emits a simple assistant text message followed by a success `result`.
  void emitSimpleReply(
    String text, {
    String messageId = 'msg-1',
    String model = 'default',
    int inputTokens = 10,
    int outputTokens = 5,
    double costUsd = 0.001,
  }) {
    emit({
      'type': 'assistant',
      'uuid': messageId,
      'message': {
        'id': messageId,
        'model': model,
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': text},
        ],
        'usage': {
          'input_tokens': inputTokens,
          'output_tokens': outputTokens,
        },
      },
    });
    emit({
      'type': 'result',
      'subtype': 'success',
      'is_error': false,
      'result': text,
      'duration_ms': 12,
      'total_cost_usd': costUsd,
      'usage': {
        'input_tokens': inputTokens,
        'output_tokens': outputTokens,
      },
    });
  }

  @override
  void write(Map<String, Object?> message) {
    writtenMessages.add(message);
    switch (message['type']) {
      case 'control_request':
        final reqId = message['request_id'] as String? ?? '';
        final request =
            (message['request'] as Map?)?.cast<String, Object?>() ?? const {};
        final subtype = request['subtype'] as String? ?? '';
        final custom = onControlRequest?.call(subtype, request);
        final responsePayload = custom ?? _defaultControlResponse(subtype);
        scheduleMicrotask(() {
          emit({
            'type': 'control_response',
            'response': {
              'subtype': 'success',
              'request_id': reqId,
              'response': responsePayload,
            },
          });
          if (subtype == 'initialize') {
            emit({
              'type': 'system',
              'subtype': 'init',
              'session_id': sessionId,
              'model': launch.model ?? 'default',
            });
          } else if (subtype == 'interrupt') {
            emit({
              'type': 'result',
              'subtype': 'error_during_execution',
              'is_error': false,
              'result': '',
              'duration_ms': 1,
            });
          }
        });
      case 'user':
        if (onUserTurn != null) {
          scheduleMicrotask(() => onUserTurn!(this, message));
        } else {
          scheduleMicrotask(() => emitSimpleReply('ok'));
        }
    }
  }

  Map<String, Object?> _defaultControlResponse(String subtype) =>
      switch (subtype) {
        'initialize' => {
          'commands': commands,
          'models': models,
          if (account != null) 'account': account,
        },
        'get_context_usage' => {
          'maxTokens': launch.autocompact ?? 200000,
          'rawMaxTokens': launch.autocompact ?? 200000,
          'totalTokens': 1000,
          'categories': const [
            {'name': 'Messages', 'tokens': 1000, 'color': 'blue'},
          ],
        },
        'file_suggestions' => {'suggestions': const []},
        'mcp_status' => {'mcpServers': const []},
        'get_usage' => {'rate_limits_available': false},
        _ => const <String, Object?>{},
      };

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    if (!_messages.isClosed) {
      _messages.add(ClaudeExit.message(0, ''));
      unawaited(_messages.close());
    }
    if (!_exited.isCompleted) {
      _exited.complete();
    }
  }
}
