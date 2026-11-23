import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/codex_catalog.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_process_transport.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/e2e_env.dart';
import 'helpers/e2e_waiters.dart';
import 'helpers/fake_cli_harness.dart';

Map<String, String> _envWithIsolatedPath(
  Map<String, String> base,
  String pathValue,
) {
  final out = <String, String>{};
  for (final entry in base.entries) {
    if (entry.key.toLowerCase() == 'path') continue;
    out[entry.key] = entry.value;
  }
  out['PATH'] = pathValue;
  return out;
}

class _CapturingCodexTransport implements CodexTransport {
  final StreamController<Map<String, Object?>> _messages =
      StreamController<Map<String, Object?>>.broadcast();
  final List<Map<String, Object?>> written = [];
  bool closed = false;
  int _turnSeq = 0;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    final id = message['id'];
    switch (message['method']) {
      case 'initialize':
        _emit({'id': id, 'result': const <String, Object?>{}});
      case 'thread/start':
        _emit({
          'id': id,
          'result': {
            'thread': {'id': 'th-img-1'},
          },
        });
      case 'turn/start':
        final turnId = 'srv-turn-${++_turnSeq}';
        _emit({
          'id': id,
          'result': {
            'turn': {'id': turnId},
          },
        });
        scheduleMicrotask(() {
          _emit({
            'method': 'turn/started',
            'params': {
              'turn': {'id': turnId},
            },
          });
          _emit({
            'method': 'item/completed',
            'params': {
              'item': {
                'id': 'msg-$turnId',
                'type': 'agentMessage',
                'text': 'IMAGE_ACK',
              },
            },
          });
          _emit({
            'method': 'turn/completed',
            'params': {
              'turn': {'id': turnId, 'status': 'completed'},
            },
          });
        });
    }
  }

  void _emit(Map<String, Object?> msg) {
    if (!closed && !_messages.isClosed) {
      _messages.add(msg);
    }
  }

  @override
  void close() {
    if (closed) return;
    closed = true;
    unawaited(_messages.close());
  }
}

const _fakeCodexAppServerBody = r'''
Future<void> main(List<String> args) async {
  final env = Map<String, String>.from(Platform.environment);
  recordEvent({'type': 'launch', 'args': args});

  final modeFile = env['FAKE_CODEX_MODE_FILE'];
  String mode = env['FAKE_CODEX_MODE'] ?? 'normal';
  if (modeFile != null && File(modeFile).existsSync()) {
    mode = File(modeFile).readAsStringSync().trim();
  }

  if (mode == 'fail_login') {
    stderr.writeln('Error: Not logged in. Please run codex login.');
    await stderr.flush();
    exit(1);
  }
  if (mode == 'noisy_crash') {
    for (var i = 1; i <= 80; i++) {
      stderr.writeln('err-${i.toString().padLeft(2, '0')}');
    }
    await stderr.flush();
    exit(42);
  }
  if (mode == 'missing_win32_dep') {
    stderr.writeln(
      'Error: missing optional dependency @openai/codex-win32-x64',
    );
    await stderr.flush();
    exit(1);
  }
  if (mode == 'sleep_startup') {
    await Future<void>.delayed(const Duration(seconds: 10));
    exit(0);
  }

  if (mode == 'banner_garbage') {
    stdout.writeln('Codex CLI v0.0.0 starting up...');
    stdout.writeln('DEBUG: loading profile');
    await stdout.flush();
  }

  final signalFile = env['FAKE_CODEX_SIGNAL_FILE'];
  var turnSeq = 0;

  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    recordEvent({'type': 'stdin', 'line': line});
    final msg = (jsonDecode(line) as Map).cast<String, Object?>();
    final id = msg['id'];
    final method = msg['method'] as String?;
    switch (method) {
      case 'initialize':
        stdout.writeln(jsonEncode({'id': id, 'result': <String, Object?>{}}));
      case 'thread/start':
        stdout.writeln(
          jsonEncode({
            'id': id,
            'result': {
              'thread': {'id': 'fake-codex-thread-1'},
            },
          }),
        );
      case 'turn/start':
        turnSeq++;
        final turnId = 'fake-turn-$turnSeq';
        stdout.writeln(
          jsonEncode({
            'id': id,
            'result': {
              'turn': {'id': turnId},
            },
          }),
        );
        stdout.writeln(
          jsonEncode({
            'method': 'turn/started',
            'params': {
              'turn': {'id': turnId},
            },
          }),
        );
        await stdout.flush();

        if (signalFile != null && signalFile.isNotEmpty) {
          while (!File(signalFile).existsSync()) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }

        final params = (msg['params'] as Map?)?.cast<String, Object?>() ?? const {};
        final input = (params['input'] as List?) ?? const [];
        final firstText = input.isNotEmpty && input.first is Map
            ? '${(input.first as Map)['text'] ?? ''}'
            : '';
        stdout.writeln(
          jsonEncode({
            'method': 'item/completed',
            'params': {
              'item': {
                'id': 'msg-$turnId',
                'type': 'agentMessage',
                'text': 'ECHO:$firstText',
              },
            },
          }),
        );
        stdout.writeln(
          jsonEncode({
            'method': 'turn/completed',
            'params': {
              'turn': {'id': turnId, 'status': 'completed'},
            },
          }),
        );
      default:
        if (id != null) {
          stdout.writeln(jsonEncode({'id': id, 'result': <String, Object?>{}}));
        }
    }
    await stdout.flush();
  }
}
''';

void main() {
  late E2eSandbox sandbox;

  setUp(() {
    sandbox = E2eSandbox.create();
    sandbox.onDispose(ProcessCodexTransport.stopAll);
  });

  group('F7 Tier 1 — Codex Windows Shim, Health Lifecycle & AcceptsImages', () {
    test(
      'F7-T1-01: ProcessCodexTransport locateCodex & resolveLaunch unwrap .cmd and .ps1 npm shims to node.exe',
      () {
        final binDir = Directory(p.join(sandbox.rootDir.path, 'npm_bin'))
          ..createSync(recursive: true);
        final nodeExe = File(p.join(binDir.path, 'node.exe'))
          ..writeAsStringSync('');
        final codexJs = File(
          p.join(
            binDir.path,
            'node_modules',
            '@openai',
            'codex',
            'bin',
            'codex.js',
          ),
        )
          ..createSync(recursive: true)
          ..writeAsStringSync('console.log("codex");');
        final cmdShim = File(p.join(binDir.path, 'codex.cmd'))
          ..writeAsStringSync(
            '@echo off\r\n"%dp0%\\node_modules\\@openai\\codex\\bin\\codex.js" %*\r\n',
          );
        final ps1Shim = File(p.join(binDir.path, 'codex.ps1'))
          ..writeAsStringSync(
            '"\$basedir/node_modules/@openai/codex/bin/codex.js" \$args\n',
          );

        final found = ProcessCodexTransport.locateCodex(
          {'Path': binDir.path},
          forceWindows: true,
        );
        expect(found, cmdShim.path);

        final cmdSpec = ProcessCodexTransport.resolveLaunch(
          cmdShim.path,
          {'Path': binDir.path},
          appServerArgs: const ['app-server', '-c', 'x=1'],
          forceWindows: true,
        );
        expect(p.equals(cmdSpec.executable, nodeExe.path), isTrue);
        expect(cmdSpec.runInShell, isFalse);
        expect(cmdSpec.resolvedBinary, cmdShim.path);
        expect(p.equals(cmdSpec.arguments.first, codexJs.path), isTrue);
        expect(cmdSpec.arguments.skip(1).toList(), ['app-server', '-c', 'x=1']);

        final ps1Spec = ProcessCodexTransport.resolveLaunch(
          ps1Shim.path,
          {'Path': binDir.path},
          forceWindows: true,
        );
        expect(p.equals(ps1Spec.executable, nodeExe.path), isTrue);
        expect(ps1Spec.runInShell, isFalse);
        expect(ps1Spec.resolvedBinary, ps1Shim.path);
        expect(p.equals(ps1Spec.arguments.first, codexJs.path), isTrue);
        expect(ps1Spec.arguments.skip(1).toList(), ['app-server']);
      },
    );

    test(
      'F7-T1-02: locateCodex prefers .exe over .cmd/.ps1 and discovers LOCALAPPDATA OpenAI Codex bin',
      () {
        final binDir = Directory(p.join(sandbox.rootDir.path, 'pref_bin'))
          ..createSync(recursive: true);
        File(p.join(binDir.path, 'codex.cmd')).writeAsStringSync('@echo off\r\n');
        final exeFile = File(p.join(binDir.path, 'codex.exe'))
          ..writeAsStringSync('');

        final preferred = ProcessCodexTransport.locateCodex(
          {'PATH': binDir.path},
          forceWindows: true,
        );
        expect(preferred, exeFile.path);

        final appCodexExe = File(
          p.join(
            sandbox.localAppDataDir.path,
            'OpenAI',
            'Codex',
            'bin',
            'v2',
            'codex.exe',
          ),
        )
          ..createSync(recursive: true)
          ..writeAsStringSync('');

        final discovered = ProcessCodexTransport.locateCodex(
          {
            'Path': '',
            'LOCALAPPDATA': sandbox.localAppDataDir.path,
          },
          forceWindows: true,
        );
        expect(discovered, appCodexExe.path);

        final enriched = ProcessCodexTransport.enrichedPath(
          {
            'Path': binDir.path,
            'USERPROFILE': sandbox.homeDir.path,
            'APPDATA': sandbox.appDataDir.path,
            'LOCALAPPDATA': sandbox.localAppDataDir.path,
          },
          forceWindows: true,
        );
        expect(
          enriched.keys.where((k) => k.toLowerCase() == 'path').length,
          1,
        );
      },
    );

    test(
      'F7-T1-03: real subprocess ProcessCodexTransport launch transitions health idle->starting->ready and runs turn',
      () async {
        final fakeBin = Directory(p.join(sandbox.rootDir.path, 'fake_bin'));
        final fakeCodex = FakeCliExecutable.create(
          fakeBin,
          name: 'codex',
          dartBody: _fakeCodexAppServerBody,
        );
        sandbox.useClaudeEnvironment(
          _envWithIsolatedPath(sandbox.processEnv, fakeBin.path),
        );

        final kernel = CodexKernel(
          KernelRegistry.codex,
          ProcessCodexTransport(cwd: sandbox.projectDir.path),
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(
            codexHome: p.join(sandbox.homeDir.path, '.codex'),
          ),
        );
        sandbox.onDispose(kernel.dispose);

        final healthStates = <KernelHealthStatus>[kernel.health.status];
        final events = <KernelEvent>[];
        final sub = kernel.events.listen((e) {
          events.add(e);
          if (e is KernelInfoChanged) {
            healthStates.add(kernel.health.status);
          }
        });
        sandbox.onDispose(sub.cancel);

        expect(kernel.health.status, KernelHealthStatus.idle);
        kernel.prepare();

        await waitUntil(
          () => kernel.health.status == KernelHealthStatus.ready,
          reason: 'CodexKernel should reach ready state',
        );
        expect(healthStates, containsAllInOrder([
          KernelHealthStatus.idle,
          KernelHealthStatus.starting,
          KernelHealthStatus.ready,
        ]));

        final launch = fakeCodex.firstLaunchCapture();
        expect(launch, isNotNull);
        expect((launch!['args'] as List).first, 'app-server');

        kernel.send(const KernelTurn(id: 't1', text: 'ping'));
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 't1'),
        );

        final reply = events
            .whereType<ItemCompleted>()
            .map((e) => e.item)
            .whereType<AssistantTextItem>()
            .last;
        expect(reply.text, 'ECHO:ping');

        kernel.dispose();
        await kernel.stopped;
      },
    );

    test(
      'F7-T1-04: real .cmd shim fallback spawns cleanly and handles multiline special-char turn',
      () async {
        final fakeBin = Directory(p.join(sandbox.rootDir.path, 'cmd_bin'));
        FakeCliExecutable.create(
          fakeBin,
          name: 'codex',
          nativeExeOnWindows: false,
          dartBody: _fakeCodexAppServerBody,
        );
        sandbox.useClaudeEnvironment(
          _envWithIsolatedPath(sandbox.processEnv, fakeBin.path),
        );

        final kernel = CodexKernel(
          KernelRegistry.codex,
          ProcessCodexTransport(cwd: sandbox.projectDir.path),
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(
            codexHome: p.join(sandbox.homeDir.path, '.codex'),
          ),
        );
        sandbox.onDispose(kernel.dispose);

        final events = <KernelEvent>[];
        final sub = kernel.events.listen(events.add);
        sandbox.onDispose(sub.cancel);

        const payload = 'line1 "quoted" & <tag>\nline2 %PATH% | ok';
        kernel.send(const KernelTurn(id: 't-cmd', text: payload));
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 't-cmd'),
        );

        final reply = events
            .whereType<ItemCompleted>()
            .map((e) => e.item)
            .whereType<AssistantTextItem>()
            .last;
        expect(reply.text, 'ECHO:$payload');

        kernel.dispose();
        await kernel.stopped;
      },
    );

    test(
      'F7-T1-05: CodexKernel.restart() recovers cleanly from KernelHealthStatus.failed',
      () async {
        final modeFile = File(p.join(sandbox.rootDir.path, 'codex_mode.txt'))
          ..writeAsStringSync('fail_login');
        final fakeBin = Directory(p.join(sandbox.rootDir.path, 'restart_bin'));
        FakeCliExecutable.create(
          fakeBin,
          name: 'codex',
          dartBody: _fakeCodexAppServerBody,
        );
        sandbox.useClaudeEnvironment({
          ..._envWithIsolatedPath(sandbox.processEnv, fakeBin.path),
          'FAKE_CODEX_MODE_FILE': modeFile.path,
        });

        final kernel = CodexKernel(
          KernelRegistry.codex,
          ProcessCodexTransport(cwd: sandbox.projectDir.path),
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(
            codexHome: p.join(sandbox.homeDir.path, '.codex'),
          ),
        );
        sandbox.onDispose(kernel.dispose);

        final events = <KernelEvent>[];
        final sub = kernel.events.listen(events.add);
        sandbox.onDispose(sub.cancel);

        kernel.prepare();
        await waitUntil(
          () => kernel.health.status == KernelHealthStatus.failed,
          reason: 'Expected health to become failed on exit code 1',
        );
        expect(kernel.health.message, isNotEmpty);
        expect(kernel.health.detail, contains('Not logged in'));

        modeFile.writeAsStringSync('normal');
        kernel.restart();

        await waitUntil(
          () => kernel.health.status == KernelHealthStatus.ready,
          reason: 'Expected restart() to recover to ready',
        );

        kernel.send(const KernelTurn(id: 't-rec', text: 'recovered'));
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 't-rec'),
        );
        expect(
          events
              .whereType<ItemCompleted>()
              .map((e) => e.item)
              .whereType<AssistantTextItem>()
              .any((a) => a.text == 'ECHO:recovered'),
          isTrue,
        );

        kernel.dispose();
        await kernel.stopped;
      },
    );

    test(
      'F7-T1-06: CodexKernel implements AcceptsImages and serializes turn.images in turn/start',
      () async {
        final transport = _CapturingCodexTransport();
        final kernel = CodexKernel(
          KernelRegistry.codex,
          transport,
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(
            codexHome: p.join(sandbox.homeDir.path, '.codex'),
          ),
        );
        sandbox.onDispose(kernel.dispose);
        expect(kernel, isA<AcceptsImages>());

        final events = <KernelEvent>[];
        final sub = kernel.events.listen(events.add);
        sandbox.onDispose(sub.cancel);

        final bytes1 = Uint8List.fromList([137, 80, 78, 71]);
        final bytes2 = Uint8List.fromList([255, 216, 255, 224]);
        kernel.send(
          KernelTurn(
            id: 't-img',
            text: 'Inspect screenshots',
            images: [
              ImageAttachment(bytes: bytes1, mediaType: 'image/png', number: 1),
              ImageAttachment(bytes: bytes2, mediaType: 'image/jpeg'),
            ],
          ),
        );
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 't-img'),
        );

        final turnStart = transport.written.firstWhere(
          (m) => m['method'] == 'turn/start',
        );
        final input =
            ((turnStart['params'] as Map)['input'] as List).cast<Map>();
        expect(input, [
          {'type': 'text', 'text': 'Inspect screenshots'},
          {'type': 'text', 'text': imageReference(1)},
          {
            'type': 'image',
            'url': 'data:image/png;base64,${base64Encode(bytes1)}',
          },
          {
            'type': 'image',
            'url': 'data:image/jpeg;base64,${base64Encode(bytes2)}',
          },
        ]);
      },
    );
  });

  group('F7 Tier 2 — Codex Transport Errors, BVA & Lifecycle Concurrency', () {
    test(
      'F7-T2-01: missing codex on isolated PATH transitions health to failed with friendly message',
      () async {
        final emptyDir = Directory(p.join(sandbox.rootDir.path, 'empty_bin'))
          ..createSync(recursive: true);
        sandbox.useClaudeEnvironment(
          _envWithIsolatedPath(sandbox.processEnv, emptyDir.path),
        );

        final kernel = CodexKernel(
          KernelRegistry.codex,
          ProcessCodexTransport(cwd: sandbox.projectDir.path),
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(
            codexHome: p.join(sandbox.homeDir.path, '.codex'),
          ),
        );
        sandbox.onDispose(kernel.dispose);

        final events = <KernelEvent>[];
        final sub = kernel.events.listen(events.add);
        sandbox.onDispose(sub.cancel);

        kernel.prepare();
        await waitUntil(
          () => kernel.health.status == KernelHealthStatus.failed,
          reason: 'Missing binary should fail health',
        );
        expect(kernel.health.message, contains('Codex CLI'));

        kernel.send(const KernelTurn(id: 't-miss', text: 'hello'));
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 't-miss'),
        );
        final ended = events.whereType<TurnEnded>().lastWhere(
          (e) => e.turnId == 't-miss',
        );
        expect(ended.interrupted, isTrue);
        expect(
          events
              .whereType<ItemUpserted>()
              .map((e) => e.item)
              .whereType<NoticeItem>()
              .any((n) => n.kind == NoticeKind.error),
          isTrue,
        );

        kernel.dispose();
        await kernel.stopped;
      },
    );

    test(
      'F7-T2-02: stderrTail caps at 50 lines on noisy crash and health.detail keeps last 12 lines',
      () async {
        final fakeBin = Directory(p.join(sandbox.rootDir.path, 'noisy_bin'));
        FakeCliExecutable.create(
          fakeBin,
          name: 'codex',
          dartBody: _fakeCodexAppServerBody,
        );
        sandbox.useClaudeEnvironment({
          ..._envWithIsolatedPath(sandbox.processEnv, fakeBin.path),
          'FAKE_CODEX_MODE': 'noisy_crash',
        });

        final transport = ProcessCodexTransport(cwd: sandbox.projectDir.path);
        final kernel = CodexKernel(
          KernelRegistry.codex,
          transport,
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(
            codexHome: p.join(sandbox.homeDir.path, '.codex'),
          ),
        );
        sandbox.onDispose(kernel.dispose);

        final events = <KernelEvent>[];
        final sub = kernel.events.listen(events.add);
        sandbox.onDispose(sub.cancel);

        kernel.send(const KernelTurn(id: 't-1', text: 'first'));
        kernel.send(const KernelTurn(id: 't-2', text: 'queued'));

        await waitUntil(
          () => kernel.health.status == KernelHealthStatus.failed,
          reason: 'Noisy crash should transition health to failed',
        );
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 't-1'),
        );

        expect(transport.stderrTail.length, 50);
        expect(transport.stderrTail.first, 'err-31');
        expect(transport.stderrTail.last, 'err-80');
        expect(kernel.health.detail, contains('err-69'));
        expect(kernel.health.detail, contains('err-80'));
        expect(kernel.health.detail, contains('Executable:'));
        expect(
          events.whereType<ItemRemoved>().map((e) => e.id),
          contains('t-2'),
        );

        kernel.dispose();
        await kernel.stopped;
      },
    );

    test(
      'F7-T2-03: image-only turn omits empty text block while 0-image empty turn still sends text',
      () async {
        final transport = _CapturingCodexTransport();
        final kernel = CodexKernel(
          KernelRegistry.codex,
          transport,
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(
            codexHome: p.join(sandbox.homeDir.path, '.codex'),
          ),
        );
        sandbox.onDispose(kernel.dispose);

        final events = <KernelEvent>[];
        final sub = kernel.events.listen(events.add);
        sandbox.onDispose(sub.cancel);

        final png = Uint8List.fromList([1, 2, 3, 4]);
        kernel.send(
          KernelTurn(
            id: 't-only-img',
            text: '',
            images: [
              ImageAttachment(bytes: png, mediaType: 'image/png', number: 1),
            ],
          ),
        );
        await waitUntil(
          () =>
              events.whereType<TurnEnded>().any((e) => e.turnId == 't-only-img'),
        );

        kernel.send(const KernelTurn(id: 't-empty', text: ''));
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 't-empty'),
        );

        final starts = transport.written
            .where((m) => m['method'] == 'turn/start')
            .toList();
        expect(starts, hasLength(2));
        final firstInput = ((starts[0]['params'] as Map)['input'] as List);
        expect(firstInput, [
          {'type': 'text', 'text': imageReference(1)},
          {
            'type': 'image',
            'url': 'data:image/png;base64,${base64Encode(png)}',
          },
        ]);
        final secondInput = ((starts[1]['params'] as Map)['input'] as List);
        expect(secondInput, [
          {'type': 'text', 'text': ''},
        ]);
      },
    );

    test(
      'F7-T2-04: release() while busy defers teardown until turn ends; dispose() mid-spawn cleans child',
      () async {
        final signalFile = File(p.join(sandbox.rootDir.path, 'unblock.sig'));
        final fakeBin = Directory(p.join(sandbox.rootDir.path, 'life_bin'));
        final fakeCodex = FakeCliExecutable.create(
          fakeBin,
          name: 'codex',
          dartBody: _fakeCodexAppServerBody,
        );
        sandbox.useClaudeEnvironment({
          ..._envWithIsolatedPath(sandbox.processEnv, fakeBin.path),
          'FAKE_CODEX_SIGNAL_FILE': signalFile.path,
        });

        final kernel = CodexKernel(
          KernelRegistry.codex,
          ProcessCodexTransport(cwd: sandbox.projectDir.path),
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(
            codexHome: p.join(sandbox.homeDir.path, '.codex'),
          ),
        );
        sandbox.onDispose(kernel.dispose);

        final events = <KernelEvent>[];
        final sub = kernel.events.listen(events.add);
        sandbox.onDispose(sub.cancel);

        kernel.send(const KernelTurn(id: 't-busy', text: 'wait'));
        await waitUntil(
          () => fakeCodex.stdinCaptures().any(
            (c) => '${c['line']}'.contains('turn/start'),
          ),
          reason: 'turn/start should reach child process',
        );

        kernel.release();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(kernel.health.status, KernelHealthStatus.ready);

        signalFile.writeAsStringSync('go');
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 't-busy'),
        );
        await waitUntil(
          () => kernel.health.status == KernelHealthStatus.idle,
          reason: 'Deferred release should transition health to idle after turn',
        );
        await kernel.stopped;
        kernel.dispose();

        // Mid-spawn dispose test
        final spawnBin = Directory(p.join(sandbox.rootDir.path, 'spawn_bin'));
        final slowCodex = FakeCliExecutable.create(
          spawnBin,
          name: 'codex',
          dartBody: _fakeCodexAppServerBody,
        );
        sandbox.useClaudeEnvironment({
          ..._envWithIsolatedPath(sandbox.processEnv, spawnBin.path),
          'FAKE_CODEX_MODE': 'sleep_startup',
        });

        final k2 = CodexKernel(
          KernelRegistry.codex,
          ProcessCodexTransport(cwd: sandbox.projectDir.path),
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(
            codexHome: p.join(sandbox.homeDir.path, '.codex'),
          ),
        );
        sandbox.onDispose(k2.dispose);
        k2.prepare();
        await waitUntil(
          () => slowCodex.firstLaunchCapture() != null,
          reason: 'Slow child should launch',
        );
        k2.dispose();
        await k2.stopped;
        await slowCodex.terminateProcesses();
        final pidDir = Directory(slowCodex.pidDirPath);
        final left = pidDir.existsSync()
            ? pidDir.listSync().whereType<File>().length
            : 0;
        expect(left, 0);
      },
    );

    test(
      'F7-T2-05: Windows .cmd/.ps1 shim missing node.exe or target .js falls back safely',
      () {
        final dir = Directory(p.join(sandbox.rootDir.path, 'broken_shim'))
          ..createSync(recursive: true);
        final cmdShim = File(p.join(dir.path, 'codex.cmd'))
          ..writeAsStringSync('"%dp0%\\missing.js" %*\r\n');
        final ps1Shim = File(p.join(dir.path, 'codex.ps1'))
          ..writeAsStringSync('"\$basedir/missing.js" \$args\n');

        final cmdSpec = ProcessCodexTransport.resolveLaunch(
          cmdShim.path,
          const {'PATH': ''},
          forceWindows: true,
        );
        expect(cmdSpec.executable, cmdShim.path);
        expect(cmdSpec.runInShell, isTrue);

        final ps1Spec = ProcessCodexTransport.resolveLaunch(
          ps1Shim.path,
          const {'PATH': ''},
          forceWindows: true,
        );
        expect(ps1Spec.executable, 'powershell.exe');
        expect(ps1Spec.runInShell, isFalse);
        expect(
          ps1Spec.arguments,
          containsAllInOrder([
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            ps1Shim.path,
            'app-server',
          ]),
        );
      },
    );

    test(
      'F7-T2-06: @openai/codex-win32 missing optional dep guidance & non-JSON stdout banner resilience',
      () async {
        final modeFile = File(p.join(sandbox.rootDir.path, 'mode_t6.txt'))
          ..writeAsStringSync('missing_win32_dep');
        final fakeBin = Directory(p.join(sandbox.rootDir.path, 't6_bin'));
        FakeCliExecutable.create(
          fakeBin,
          name: 'codex',
          dartBody: _fakeCodexAppServerBody,
        );
        sandbox.useClaudeEnvironment({
          ..._envWithIsolatedPath(sandbox.processEnv, fakeBin.path),
          'FAKE_CODEX_MODE_FILE': modeFile.path,
        });

        final k1 = CodexKernel(
          KernelRegistry.codex,
          ProcessCodexTransport(cwd: sandbox.projectDir.path),
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(
            codexHome: p.join(sandbox.homeDir.path, '.codex'),
          ),
        );
        sandbox.onDispose(k1.dispose);
        k1.prepare();
        await waitUntil(
          () => k1.health.status == KernelHealthStatus.failed,
          reason: 'Missing win32 dep should transition health to failed',
        );
        expect(k1.health.message, contains('@openai/codex-win32'));
        k1.dispose();
        await k1.stopped;

        modeFile.writeAsStringSync('banner_garbage');
        final k2 = CodexKernel(
          KernelRegistry.codex,
          ProcessCodexTransport(cwd: sandbox.projectDir.path),
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(
            codexHome: p.join(sandbox.homeDir.path, '.codex'),
          ),
        );
        sandbox.onDispose(k2.dispose);
        final events = <KernelEvent>[];
        final sub = k2.events.listen(events.add);
        sandbox.onDispose(sub.cancel);

        k2.prepare();
        await waitUntil(
          () => k2.health.status == KernelHealthStatus.ready,
          reason: 'Non-JSON stdout banner lines should not break initialization',
        );
        k2.send(const KernelTurn(id: 't-ok', text: 'hi'));
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 't-ok'),
        );

        k2.dispose();
        await k2.stopped;
      },
    );
  });
}
