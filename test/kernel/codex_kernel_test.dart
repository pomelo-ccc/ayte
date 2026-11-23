import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_process_transport.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/codex/mock_codex_transport.dart';
import 'package:baocode/kernel/extension_switches.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _RealHttpOverrides extends HttpOverrides {
  HttpClient newRealClient() => super.createHttpClient(null);
}

class _TestCodexTransport implements CodexTransport {
  _TestCodexTransport({this.onWrite});

  final void Function(_TestCodexTransport t, Map<String, Object?> msg)? onWrite;
  final StreamController<Map<String, Object?>> _out =
      StreamController.broadcast(sync: true);
  final List<Map<String, Object?>> written = [];
  bool closed = false;

  @override
  Stream<Map<String, Object?>> get messages => _out.stream;

  void push(Map<String, Object?> msg) {
    if (!closed && !_out.isClosed) _out.add(msg);
  }

  void respond(Object? id, Map<String, Object?> result) =>
      push({'id': id, 'result': result});

  void respondError(Object? id, int code, String message) => push({
    'id': id,
    'error': {'code': code, 'message': message},
  });

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    if (onWrite != null) {
      onWrite!(this, message);
      return;
    }
    if (message['method'] == null) return;
    final id = message['id'];
    final result = switch (message['method']) {
      'thread/start' => {
        'thread': {'id': 'thr-1'},
      },
      'thread/resume' => {
        'thread': {'id': (message['params'] as Map)['threadId'] ?? 'thr-1', 'turns': const []},
      },
      'thread/fork' => {
        'thread': {'id': 'thr-fork-1'},
      },
      'turn/start' => {
        'turn': {'id': 'srv-turn-1'},
      },
      _ => <String, Object?>{},
    };
    respond(id, result);
  }

  @override
  void close() {
    if (closed) return;
    closed = true;
    unawaited(_out.close());
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('codex_kernel_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('F7 Health lifecycle, release, restart, and AcceptsImages', () {
    test('health transitions idle -> starting -> ready -> failed and recovers on restart()', () async {
      var failInit = true;
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          if (msg['method'] == 'initialize') {
            if (failInit) {
              tr.push({
                'method': ProcessCodexTransport.transportExitMethod,
                'params': {
                  'code': 1,
                  'stderr':
                      'Error: Missing optional dependency @openai/codex-win32-x64. Reinstall Codex',
                  'executable': r'C:\npm\codex.cmd',
                },
              });
            } else {
              tr.respond(msg['id'], {'userAgent': 'codex'});
            }
          } else if (msg['method'] != null) {
            tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(
        MockKernels.codex,
        t,
        loadLocalCatalog: true,
      );
      addTearDown(kernel.dispose);

      expect(kernel.health.status, KernelHealthStatus.idle);
      final statuses = <KernelHealthStatus>[];
      final sub = kernel.events.listen((e) {
        if (e is KernelInfoChanged) statuses.add(kernel.health.status);
      });
      addTearDown(sub.cancel);

      kernel.prepare();
      await pumpEventQueue();
      expect(kernel.health.status, KernelHealthStatus.failed);
      expect(kernel.health.message, contains('@openai/codex-win32-x64'));
      expect(kernel.health.detail, contains('codex.cmd'));
      expect(statuses, contains(KernelHealthStatus.starting));
      expect(statuses.last, KernelHealthStatus.failed);

      failInit = false;
      kernel.restart();
      await pumpEventQueue();
      expect(kernel.health.status, KernelHealthStatus.ready);
      await expectLater(kernel.stopped, completes);
    });

    test('CodexKernel.restart() on live ProcessCodexTransport recovers cleanly to ready', () async {
      if (!Platform.isWindows) return;
      String? nodeExe;
      try {
        final res = await Process.run('where', ['node.exe']);
        if (res.exitCode == 0) {
          for (final line in '${res.stdout}'.split(RegExp(r'\r?\n'))) {
            final trimmed = line.trim();
            if (trimmed.isNotEmpty && File(trimmed).existsSync()) {
              nodeExe = trimmed;
              break;
            }
          }
        }
      } on Object {
        // Ignore.
      }
      if (nodeExe == null) return;

      final npmDir = Directory(p.join(tempDir.path, 'npm_live'))..createSync();
      final pkgDir = Directory(
        p.join(npmDir.path, 'node_modules', '@openai', 'codex', 'bin'),
      )..createSync(recursive: true);
      final scriptFile = File(p.join(pkgDir.path, 'codex.js'));
      scriptFile.writeAsStringSync('''
const readline = require('readline');
process.on('SIGTERM', () => setTimeout(() => process.exit(0), 120));
const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', (line) => {
  if (!line.trim()) return;
  const msg = JSON.parse(line);
  if (msg.method === 'initialize') {
    process.stdout.write(JSON.stringify({ id: msg.id, result: { userAgent: 'codex' } }) + '\\n');
  } else if (msg.method === 'model/list') {
    process.stdout.write(JSON.stringify({ id: msg.id, result: { data: [] } }) + '\\n');
  } else if (msg.id != null) {
    process.stdout.write(JSON.stringify({ id: msg.id, result: {} }) + '\\n');
  }
});
rl.on('close', () => setTimeout(() => process.exit(0), 120));
''');
      File(p.join(npmDir.path, 'codex.cmd')).writeAsStringSync(
        '@ECHO off\r\n"%~dp0\\node_modules\\@openai\\codex\\bin\\codex.js" %*\r\n',
      );

      ClaudeEnvironment.use({
        'PATH': '${npmDir.path};${p.dirname(nodeExe)}',
        'APPDATA': npmDir.path,
        'LOCALAPPDATA': npmDir.path,
        'USERPROFILE': tempDir.path,
        'SystemRoot': ?Platform.environment['SystemRoot'],
      });
      addTearDown(() => ClaudeEnvironment.use(null));

      final transport = ProcessCodexTransport(cwd: tempDir.path);
      final kernel = CodexKernel(
        MockKernels.codex,
        transport,
        context: KernelContext(cwd: tempDir.path),
        enableSdkMcpBridge: true,
      );
      addTearDown(() async {
        kernel.dispose();
        await kernel.stopped;
      });

      kernel.prepare();
      for (var i = 0; i < 200 && kernel.health.status != KernelHealthStatus.ready; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(kernel.health.status, KernelHealthStatus.ready);

      kernel.restart();
      // Wait for restart to settle past old process's 120ms exit delay.
      for (var i = 0; i < 200 && kernel.health.status != KernelHealthStatus.ready; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(kernel.health.status, KernelHealthStatus.ready);
    });

    test('restart() during in-flight initialize preserves new sdkBridgeForTesting and health.ready', () async {
      final toolName = 'codex_m4_restart_probe';
      ClaudeSdkTools.register(
        ClaudeSdkTool(
          name: toolName,
          description: 'Restart probe',
          inputSchema: const {'type': 'object'},
          run: (_, _) async => 'ok',
        ),
      );
      addTearDown(() => ClaudeSdkTools.unregister(toolName));

      final initIds = <Object?>[];
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          if (msg['method'] == 'initialize') {
            initIds.add(msg['id']);
            // Hold initialize #1 pending; respond only to initialize #2.
            if (initIds.length >= 2) {
              tr.respond(msg['id'], {'userAgent': 'codex'});
            }
          } else if (msg['method'] != null) {
            tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(
        MockKernels.codex,
        t,
        context: KernelContext(cwd: tempDir.path),
        enableSdkMcpBridge: true,
      );
      addTearDown(kernel.dispose);

      kernel.prepare();
      for (var i = 0; i < 100 && initIds.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(initIds, hasLength(1));
      final firstBridge = kernel.sdkBridgeForTesting;
      expect(firstBridge, isNotNull);

      // Restart while initialize #1 is still in flight.
      kernel.restart();
      for (var i = 0; i < 100 && kernel.health.status != KernelHealthStatus.ready; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await pumpEventQueue();

      expect(initIds, hasLength(2));
      expect(kernel.health.status, KernelHealthStatus.ready);
      final secondBridge = kernel.sdkBridgeForTesting;
      expect(secondBridge, isNotNull);
      expect(secondBridge, isNot(same(firstBridge)));

      // Verify secondBridge is still open and serving HTTP.
      final client = _RealHttpOverrides().newRealClient();
      addTearDown(() => client.close(force: true));
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${secondBridge!.port}/mcp/${secondBridge.token}'),
      );
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}));
      final resp = await req.close();
      expect(resp.statusCode, 200);
    });

    test('release() resets idle kernel while preserving sessionId and defers while busy', () async {
      final t = _TestCodexTransport();
      final kernel = CodexKernel(MockKernels.codex, t, loadLocalCatalog: true);
      addTearDown(kernel.dispose);

      kernel.send(const KernelTurn(id: 't1', text: 'hello'));
      await pumpEventQueue();
      expect(kernel.sessionId, 'thr-1');
      expect(kernel.health.status, KernelHealthStatus.ready);

      // Busy: release() is deferred until turn completes.
      kernel.release();
      expect(kernel.health.status, KernelHealthStatus.ready);

      t.push({
        'method': 'turn/completed',
        'params': {
          'turn': {'id': 'srv-turn-1', 'status': 'completed'},
        },
      });
      await pumpEventQueue();
      expect(kernel.health.status, KernelHealthStatus.idle);
      expect(kernel.sessionId, 'thr-1');
    });

    test('serializes turn.images into turn/start input and MockCodexTransport handles image-only turns', () async {
      final t = _TestCodexTransport();
      final kernel = CodexKernel(MockKernels.codex, t);
      addTearDown(kernel.dispose);

      final pngBytes = Uint8List.fromList([137, 80, 78, 71]);
      kernel.send(
        KernelTurn(
          id: 't-img',
          text: 'check screenshot',
          images: [
            ImageAttachment(bytes: pngBytes, mediaType: 'image/png', number: 2),
          ],
        ),
      );
      await pumpEventQueue();

      final turnStart = t.written.firstWhere((m) => m['method'] == 'turn/start');
      final input = (turnStart['params'] as Map)['input'] as List;
      expect(input, [
        {'type': 'text', 'text': 'check screenshot'},
        {'type': 'text', 'text': '[Image #2]'},
        {
          'type': 'image',
          'url': 'data:image/png;base64,${base64Encode(pngBytes)}',
        },
      ]);

      // MockCodexTransport must also handle image-only / image-first input without throwing.
      final mock = MockCodexTransport();
      final mockKernel = CodexKernel(MockKernels.codex, mock);
      addTearDown(mockKernel.dispose);
      final events = <KernelEvent>[];
      final sub = mockKernel.events.listen(events.add);
      addTearDown(sub.cancel);
      mockKernel.send(
        KernelTurn(
          id: 't-mock-img',
          text: '',
          images: [ImageAttachment(bytes: pngBytes, mediaType: 'image/png')],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        events.whereType<ItemUpserted>().any(
          (e) =>
              e.item is NoticeItem &&
              (e.item as NoticeItem).kind == NoticeKind.error,
        ),
        isFalse,
      );
    });

    test('HUNT A2: restart() with active turn, queued turn, loadLocalCatalog, and async initialize sends initialize before thread/resume', () async {
      final methods = <String>[];
      final pendingInitIds = <Object?>[];
      var turnStartCount = 0;
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          final method = msg['method'] as String?;
          if (method == null) return;
          methods.add(method);
          switch (method) {
            case 'initialize':
              if (pendingInitIds.isEmpty) {
                pendingInitIds.add(msg['id']);
                tr.respond(msg['id'], {'userAgent': 'codex'});
              } else {
                // Hold the post-restart initialize async.
                pendingInitIds.add(msg['id']);
              }
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-a2'},
              });
            case 'thread/resume':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-a2', 'turns': const []},
              });
            case 'turn/start':
              // Leave t1's turn/start pending before restart; respond to t2 after restart.
              if (++turnStartCount >= 2) {
                tr.respond(msg['id'], {
                  'turn': {'id': 'srv-a2'},
                });
              }
            default:
              tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(
        MockKernels.codex,
        t,
        context: KernelContext(cwd: tempDir.path),
        loadLocalCatalog: true,
      );
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't1', text: 'first'));
      await pumpEventQueue();
      expect(kernel.sessionId, 'thr-a2');

      kernel.send(const KernelTurn(id: 't2', text: 'queued'));
      methods.clear();

      kernel.restart();
      await pumpEventQueue();

      // Post-restart initialize is still pending; thread/resume and turn/start must NOT have been sent yet.
      expect(pendingInitIds, hasLength(2));
      expect(methods, ['initialize']);

      // Complete post-restart initialize.
      t.respond(pendingInitIds[1], {'userAgent': 'codex'});
      await pumpEventQueue();

      expect(methods.first, 'initialize');
      expect(
        methods.indexOf('initialize'),
        lessThan(methods.indexOf('thread/resume')),
      );
      expect(
        methods.indexOf('thread/resume'),
        lessThan(methods.indexOf('turn/start')),
      );

      t.push({
        'method': 'turn/completed',
        'params': {
          'threadId': 'thr-a2',
          'turn': {'id': 'srv-a2', 'status': 'completed'},
        },
      });
      await pumpEventQueue();
      final t2Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 't2').toList();
      expect(t2Ended, hasLength(1));
      expect(t2Ended.single.interrupted, isFalse);
    });
  });

  group('F8 Catalog, History, Fork, Rename, and Context', () {
    test('LoadsHistory from rollout file with loadEarlier() and issues thread/resume on first send()', () async {
      final rollout = File(
        p.join(tempDir.path, 'sessions', 'rollout-2026-11-22T09-00-00-thr-hist.jsonl'),
      )..parent.createSync(recursive: true);
      final lines = <String>[
        jsonEncode({
          'type': 'session_meta',
          'payload': {'id': 'thr-hist', 'cwd': tempDir.path},
        }),
        for (var i = 1; i <= 12; i++) ...[
          jsonEncode({
            'type': 'event_msg',
            'payload': {'type': 'user_message', 'message': 'user turn $i'},
          }),
          jsonEncode({
            'type': 'event_msg',
            'payload': {'type': 'agent_message', 'message': 'assistant turn $i'},
          }),
        ],
      ];
      rollout.writeAsStringSync('${lines.join('\n')}\n');

      final t = _TestCodexTransport();
      final kernel = CodexKernel(
        MockKernels.codex,
        t,
        context: KernelContext(
          cwd: tempDir.path,
          resume: SessionRecord(
            id: 'thr-hist',
            title: 'History Test',
            updatedAt: DateTime.now(),
            cwd: tempDir.path,
            path: rollout.path,
          ),
          workspace: () => KernelWorkspace(
            folders: [tempDir.path, p.join(tempDir.path, 'extra')],
            instructions: 'Always verify invariants.',
          ),
        ),
      );
      addTearDown(kernel.dispose);

      expect(kernel.sessionId, 'thr-hist');
      expect(kernel.loadingHistory, isTrue);

      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      for (var i = 0; i < 100 && kernel.loadingHistory; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(kernel.loadingHistory, isFalse);
      expect(kernel.hasEarlierHistory, isTrue);
      // Replay must NOT emit FileEdited.
      expect(events.whereType<FileEdited>(), isEmpty);
      expect(
        events
            .whereType<ItemUpserted>()
            .map((e) => e.item)
            .whereType<UserMessageItem>()
            .map((u) => u.text),
        contains('user turn 12'),
      );

      await kernel.loadEarlier();
      final prepended = events.whereType<HistoryPrepended>().single;
      expect(
        prepended.items.map((e) => e.$2).whereType<UserMessageItem>().map((u) => u.text),
        ['user turn 1', 'user turn 2'],
      );
      expect(kernel.hasEarlierHistory, isFalse);

      // First send() must resume thread on server with workspace instructions.
      kernel.send(const KernelTurn(id: 't-new', text: 'continue'));
      await pumpEventQueue();
      final resumeCall = t.written.firstWhere((m) => m['method'] == 'thread/resume');
      final resumeParams = resumeCall['params'] as Map;
      expect(resumeParams['threadId'], 'thr-hist');
      expect(resumeParams['cwd'], tempDir.path);
      expect(
        resumeParams['developerInstructions'],
        contains('Always verify invariants.'),
      );
    });

    test('ForksConversation & RenamesSession handle fork, before-rollback, pending titles, and external renames', () async {
      final t = _TestCodexTransport();
      final kernel = CodexKernel(
        MockKernels.codex,
        t,
        context: KernelContext(cwd: tempDir.path),
      );
      addTearDown(kernel.dispose);

      expect(kernel.canFork, isFalse);
      // Queue rename before threadId exists.
      kernel.rename('Queued Title');
      kernel.send(const KernelTurn(id: 't1', text: 'first'));
      await pumpEventQueue();
      expect(kernel.canFork, isTrue);

      // Queued rename flushed after thread/start.
      expect(
        t.written.any(
          (m) =>
              m['method'] == 'thread/name/set' &&
              (m['params'] as Map)['name'] == 'Queued Title',
        ),
        isTrue,
      );

      // Echo from server for our own sent title does NOT emit SessionRenamed.
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);
      t.push({
        'method': 'thread/name/updated',
        'params': {'threadId': 'thr-1', 'threadName': 'Queued Title'},
      });
      expect(events.whereType<SessionRenamed>(), isEmpty);

      // External rename emits SessionRenamed.
      t.push({
        'method': 'thread/name/updated',
        'params': {'threadId': 'thr-1', 'threadName': 'Server Renamed'},
      });
      expect(events.whereType<SessionRenamed>().single.title, 'Server Renamed');

      // Complete turn 1 so _completedTurnCount == 1, then fork before t1.
      t.push({
        'method': 'turn/completed',
        'params': {
          'turn': {'id': 'srv-turn-1', 'status': 'completed'},
        },
      });
      final forked = await kernel.fork(before: 't1', title: 'Branch Fork');
      expect(forked, isNotNull);
      expect(forked!.id, 'thr-fork-1');
      expect(forked.title, 'Branch Fork');
      expect(
        t.written.any(
          (m) =>
              m['method'] == 'thread/rollback' &&
              (m['params'] as Map)['threadId'] == 'thr-fork-1' &&
              (m['params'] as Map)['numTurns'] == 1,
        ),
        isTrue,
      );
    });
  });

  group('F8 AyteSdkMcpBridge, parseAgentMessage, and Facets', () {
    test('AyteSdkMcpBridge exposes ClaudeSdkTools over loopback HTTP and renders mcpToolCall', () async {
      final toolName = 'codex_m4_probe_tool';
      ClaudeSdkTools.register(
        ClaudeSdkTool(
          name: toolName,
          description: 'M4 probe tool',
          inputSchema: const {'type': 'object'},
          kind: ToolKind.search,
          summary: (input, _) => 'Probe ${input['q']}',
          run: (input, call) async {
            return 'ok:${call.sessionId}:${call.turnId}:${input['q']}';
          },
        ),
      );
      addTearDown(() => ClaudeSdkTools.unregister(toolName));

      final t = _TestCodexTransport();
      final kernel = CodexKernel(
        MockKernels.codex,
        t,
        context: KernelContext(
          cwd: tempDir.path,
          workspace: () => KernelWorkspace(
            folders: [tempDir.path],
            ownPrompt: true,
            instructions: 'Custom persona prompt',
          ),
        ),
        enableSdkMcpBridge: true,
      );
      addTearDown(kernel.dispose);

      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(
        const KernelTurn(
          id: 't-mcp',
          text: '<agent-message from="Lead" session="s-0">Run probe</agent-message>',
        ),
      );
      for (var i = 0; i < 100 && kernel.sdkBridgeForTesting == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await pumpEventQueue();

      final bridge = kernel.sdkBridgeForTesting!;
      final userItem = events
          .whereType<ItemUpserted>()
          .map((e) => e.item)
          .whereType<UserMessageItem>()
          .first;
      expect(userItem.fromAgent, 'Lead');
      expect(userItem.fromSession, 's-0');
      expect(userItem.text, 'Run probe');

      final threadStart = t.written.firstWhere((m) => m['method'] == 'thread/start');
      expect(
        (threadStart['params'] as Map)['baseInstructions'],
        contains('Custom persona prompt'),
      );

      // Call bridge via /mcp/<token> endpoint (as codex app-server does via -c url).
      final client = _RealHttpOverrides().newRealClient();
      addTearDown(() => client.close(force: true));
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${bridge.port}/mcp/${bridge.token}'),
      );
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 77,
          'method': 'tools/call',
          'params': {
            'name': toolName,
            'arguments': {'q': 'abc'},
          },
        }),
      );
      final resp = await req.close();
      expect(resp.statusCode, 200);
      final body = jsonDecode(await utf8.decodeStream(resp)) as Map;
      final content = ((body['result'] as Map)['content'] as List).single as Map;
      expect(content['text'], 'ok:thr-1:t-mcp:abc');

      // Also verify mcpToolCall translation via ClaudeSdkTools.called.
      t.push({
        'method': 'item/completed',
        'params': {
          'item': {
            'type': 'mcpToolCall',
            'id': 'mcp-1',
            'server': ClaudeSdkTools.server,
            'tool': toolName,
            'arguments': {'q': 'abc'},
            'status': 'completed',
            'result': {
              'content': [
                {'type': 'text', 'text': 'done'},
              ],
            },
          },
        },
      });
      final toolItem =
          events
                  .whereType<ItemUpserted>()
                  .lastWhere((e) => e.id == 'mcp-1')
                  .item
              as ToolCallItem;
      expect(toolItem.kind, ToolKind.search);
      expect(toolItem.target, 'Probe abc');
      expect(toolItem.status, ToolStatus.succeeded);
    });

    test('QueuesMessages, SelectsPermission, DiffPreview, QuestionRequest, unknown RPC fallback, /compact, and /new', () async {
      final t = _TestCodexTransport();
      final kernel = CodexKernel(
        MockKernels.codex,
        t,
        context: KernelContext(
          cwd: tempDir.path,
          settings: {KernelChoiceKind.permission.name: 'never'},
        ),
      );
      addTearDown(kernel.dispose);

      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      expect(kernel.permission.selected, 'never');
      kernel.permission.select('full-access');
      expect(kernel.permission.selected, 'full-access');

      // Start turn 1 and queue turn 2 & 3.
      kernel.send(const KernelTurn(id: 't1', text: 'first'));
      await pumpEventQueue();
      final t1Start = t.written.lastWhere((m) => m['method'] == 'turn/start');
      expect(
        (t1Start['params'] as Map)['sandboxPolicy'],
        {'type': 'dangerFullAccess'},
      );

      kernel.send(const KernelTurn(id: 't2', text: 'second'));
      kernel.send(const KernelTurn(id: 't3', text: 'third'));
      kernel.moveQueued('t3', 0);
      expect(
        events.whereType<QueueReordered>().last.ids,
        ['t3', 't2'],
      );
      expect(await kernel.cancelQueued('t2'), isTrue);
      expect(events.whereType<ItemRemoved>().last.id, 't2');

      // Unknown server request -> JSON-RPC -32601 error response.
      t.push({'id': 901, 'method': 'unknown/customMethod', 'params': const {}});
      final errReply = t.written.firstWhere((m) => m['id'] == 901);
      expect((errReply['error'] as Map)['code'], -32601);

      // DiffPreview from cached patchUpdated + fileChange/requestApproval.
      t.push({
        'method': 'item/fileChange/patchUpdated',
        'params': {
          'itemId': 'fc-1',
          'changes': [
            {'path': 'lib/main.dart', 'diff': '@@ -1 +1 @@\n-old\n+new'},
          ],
        },
      });
      t.push({
        'id': 902,
        'method': 'item/fileChange/requestApproval',
        'params': {'itemId': 'fc-1', 'reason': 'Update main'},
      });
      final approvalReq =
          events
                  .whereType<InteractionRequested>()
                  .lastWhere((e) => e.request.id == 'approval:902')
                  .request
              as ApprovalRequest;
      expect(approvalReq.preview, isA<DiffPreview>());
      final diffPreview = approvalReq.preview as DiffPreview;
      expect(diffPreview.path, 'lib/main.dart');
      expect(diffPreview.lines.map((l) => l.type), [
        DiffLineType.removed,
        DiffLineType.added,
      ]);
      kernel.answer('approval:902', const ApprovalAnswer(ApprovalDecision.allowOnce));

      // item/tool/requestUserInput -> QuestionRequest / QuestionAnswer.
      t.push({
        'id': 903,
        'method': 'item/tool/requestUserInput',
        'params': {
          'questions': [
            {
              'id': 'env',
              'header': 'Target',
              'question': 'Which environment?',
              'options': [
                {'label': 'staging', 'description': 'Staging'},
                {'label': 'prod', 'description': 'Prod'},
              ],
            },
          ],
        },
      });
      final qReq =
          events
                  .whereType<InteractionRequested>()
                  .lastWhere((e) => e.request.id == 'question:903')
                  .request
              as QuestionRequest;
      expect(qReq.questions.single.prompt, 'Which environment?');
      kernel.answer('question:903', const QuestionAnswer([['staging']]));
      final qReply = t.written.firstWhere((m) => m['id'] == 903);
      expect(qReply['result'], {
        'answers': {
          'env': {
            'answers': ['staging'],
          },
        },
      });

      // Turn tokenUsage -> TurnEnded.usage
      t.push({
        'method': 'thread/tokenUsage/updated',
        'params': {
          'tokenUsage': {
            'last': {'inputTokens': 120, 'outputTokens': 45, 'totalTokens': 165},
            'modelContextWindow': 272000,
          },
        },
      });

      // Complete turn 1 -> auto-dequeues t3.
      t.push({
        'method': 'turn/completed',
        'params': {
          'turn': {'id': 'srv-turn-1', 'status': 'completed'},
        },
      });
      await pumpEventQueue();
      final ended1 = events.whereType<TurnEnded>().first;
      expect(ended1.usage?.inputTokens, 120);
      expect(ended1.usage?.outputTokens, 45);
      expect(
        t.written.where((m) => m['method'] == 'turn/start'),
        hasLength(2),
      );

      // Complete t3.
      t.push({
        'method': 'turn/completed',
        'params': {
          'turn': {'id': 'srv-turn-1', 'status': 'completed'},
        },
      });
      await pumpEventQueue();

      // /compact
      kernel.send(const KernelTurn(id: 't-compact', text: '/compact'));
      await pumpEventQueue();
      expect(
        t.written.any((m) => m['method'] == 'thread/compact/start'),
        isTrue,
      );
      expect(
        events.whereType<ItemUpserted>().any(
          (e) =>
              e.item is NoticeItem &&
              (e.item as NoticeItem).kind == NoticeKind.compaction,
        ),
        isTrue,
      );

      // /new resets sessionId
      kernel.send(const KernelTurn(id: 't-new-chat', text: '/new'));
      await pumpEventQueue();
      expect(kernel.sessionId, isNull);
    });

    test('ManagesMcpServers, ReportsUsage, and SuggestsFiles (RPC + local fallback)', () async {
      File(p.join(tempDir.path, 'lib', 'alpha.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('// a');
      var useRpcSearch = false;
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          final id = msg['id'];
          switch (msg['method']) {
            case 'mcpServerStatus/list':
              tr.respond(id, {
                'data': [
                  {
                    'name': 'docs',
                    'runtimeStatus': 'connected',
                    'tools': {'search': const <String, Object?>{}},
                  },
                  {
                    'name': 'github',
                    'runtimeStatus': 'authenticationRequired',
                  },
                ],
              });
            case 'mcpServer/oauth/login':
              tr.respond(id, {'authorizationUrl': 'https://example.com/oauth'});
            case 'account/rateLimits/read':
              tr.respond(id, {
                'rateLimits': {
                  'primary': {
                    'usedPercent': 25,
                    'windowDurationMins': 300,
                    'resetsAt': 1800000000,
                  },
                },
              });
            case 'fuzzyFileSearch':
              if (useRpcSearch) {
                tr.respond(id, {
                  'files': [
                    {'path': 'src/beta.dart'},
                  ],
                });
              } else {
                tr.respondError(id, -32601, 'not supported');
              }
            default:
              if (msg['method'] != null) tr.respond(id, {});
          }
        },
      );

      final kernel = CodexKernel(
        MockKernels.codex,
        t,
        context: KernelContext(cwd: tempDir.path),
      );
      addTearDown(kernel.dispose);

      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      // Uninitialized SuggestsFiles uses local fallback.
      final localFiles = await kernel.suggestFiles('alpha');
      expect(localFiles.map((f) => f.path), contains('lib/alpha.dart'));

      kernel.refreshMcpServers();
      await pumpEventQueue();
      expect(kernel.mcpServers?.map((s) => (s.name, s.status)), [
        ('docs', McpServerStatus.connected),
        ('github', McpServerStatus.needsAuth),
      ]);
      expect(kernel.mcpServers!.first.tools, ['search']);

      kernel.setMcpServerEnabled('docs', false);
      await pumpEventQueue();
      expect(
        t.written.any(
          (m) =>
              m['method'] == 'config/value/write' &&
              (m['params'] as Map)['keyPath'] == 'mcp_servers.docs.enabled' &&
              (m['params'] as Map)['value'] == false,
        ),
        isTrue,
      );

      final authUri = await kernel.authenticateMcpServer('github');
      expect(authUri?.toString(), 'https://example.com/oauth');

      await kernel.refreshUsage();
      expect(kernel.accountLimits.single.label, '5h');
      expect(kernel.accountLimits.single.utilization, closeTo(0.25, 0.001));
      expect(events.whereType<StatsReported>(), isNotEmpty);

      useRpcSearch = true;
      final rpcFiles = await kernel.suggestFiles('beta');
      expect(rpcFiles.map((f) => f.path), ['src/beta.dart']);
    });

    test('handles sendQueuedNow without stale turn/completed race, transportExit queue clearing, serverRequest/resolved, and RPC history fallback', () async {
      File(p.join(tempDir.path, '.git', 'HEAD'))
        ..createSync(recursive: true)
        ..writeAsStringSync('ref: refs/heads/main');
      File(p.join(tempDir.path, 'lib', 'real.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('// real');

      var turnSeq = 0;
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          final id = msg['id'];
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(id, {
                'thread': {'id': 'thr-race'},
              });
            case 'thread/resume':
              tr.respond(id, {
                'thread': {
                  'id': 'thr-race',
                  'turns': [
                    {
                      'items': [
                        {
                          'type': 'userMessage',
                          'id': 'u-old',
                          'content': [
                            {'type': 'text', 'text': 'old question'},
                          ],
                        },
                        {
                          'type': 'agentMessage',
                          'id': 'a-old',
                          'text': 'old answer',
                        },
                      ],
                    },
                  ],
                },
              });
            case 'turn/start':
              tr.respond(id, {
                'turn': {'id': 'srv-${++turnSeq}'},
              });
            default:
              if (msg['method'] != null) tr.respond(id, {});
          }
        },
      );

      final kernel = CodexKernel(
        MockKernels.codex,
        t,
        context: KernelContext(
          cwd: tempDir.path,
          resume: SessionRecord(
            id: 'thr-race',
            title: 'RPC History',
            updatedAt: DateTime.now(),
            cwd: tempDir.path,
          ),
        ),
      );
      addTearDown(kernel.dispose);

      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      for (var i = 0; i < 100 && kernel.loadingHistory; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        events
            .whereType<ItemUpserted>()
            .map((e) => e.item)
            .whereType<UserMessageItem>()
            .map((u) => u.text),
        contains('old question'),
      );

      // Local suggestFiles skips .git directory cleanly.
      final suggested = await kernel.suggestFiles('');
      expect(suggested.map((f) => f.path), isNot(contains('.git/HEAD')));
      expect(suggested.map((f) => f.path), contains('lib/real.dart'));

      // sendQueuedNow cancels t1 and promotes t3; late srv-1 turn/completed must NOT kill t3!
      kernel.send(const KernelTurn(id: 't1', text: 'first'));
      await pumpEventQueue();
      kernel.send(const KernelTurn(id: 't2', text: 'second'));
      kernel.send(const KernelTurn(id: 't3', text: 'third'));
      kernel.sendQueuedNow('t3');
      // Late completion for srv-1 arrives before or after srv-2 starts.
      t.push({
        'method': 'turn/completed',
        'params': {
          'turn': {'id': 'srv-1', 'status': 'interrupted'},
        },
      });
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 't3'), isEmpty);

      // serverRequest/resolved cleans up pending approval.
      t.push({
        'id': 500,
        'method': 'item/commandExecution/requestApproval',
        'params': {'command': 'ls'},
      });
      expect(
        events.whereType<InteractionRequested>().any((e) => e.request.id == 'approval:500'),
        isTrue,
      );
      t.push({
        'method': 'serverRequest/resolved',
        'params': {'requestId': 500},
      });
      expect(
        events.whereType<InteractionResolved>().any((e) => e.requestId == 'approval:500'),
        isTrue,
      );

      // transportExit clears remaining queued t2 BEFORE ending active t3.
      final turnStartsBeforeCrash = t.written.where((m) => m['method'] == 'turn/start').length;
      t.push({
        'method': ProcessCodexTransport.transportExitMethod,
        'params': {'code': 1, 'stderr': 'not logged in'},
      });
      await pumpEventQueue();
      expect(kernel.health.status, KernelHealthStatus.failed);
      expect(kernel.health.message, contains('not logged in'));
      expect(events.whereType<ItemRemoved>().any((e) => e.id == 't2'), isTrue);
      expect(
        t.written.where((m) => m['method'] == 'turn/start').length,
        turnStartsBeforeCrash,
      );
    });

    test('pre-turn/start cancellation via sendQueuedNow does not send ghost turn/start', () async {
      Object? pendingThreadStartId;
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          final id = msg['id'];
          switch (msg['method']) {
            case 'thread/start':
              if (pendingThreadStartId == null) {
                pendingThreadStartId = id;
                // Hold first thread/start pending.
              } else {
                tr.respond(id, {
                  'thread': {'id': 'thr-2'},
                });
              }
            case 'turn/start':
              tr.respond(id, {
                'turn': {'id': 'srv-turn'},
              });
            default:
              if (msg['method'] != null) tr.respond(id, {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);

      kernel.send(const KernelTurn(id: 't1', text: 'first'));
      for (var i = 0; i < 50 && pendingThreadStartId == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(pendingThreadStartId, isNotNull);

      kernel.send(const KernelTurn(id: 't2', text: 'urgent'));
      kernel.sendQueuedNow('t2');
      await pumpEventQueue();

      // Now resolve t1's delayed thread/start.
      t.respond(pendingThreadStartId, {
        'thread': {'id': 'thr-1'},
      });
      await pumpEventQueue();

      final turnStarts = t.written.where((m) => m['method'] == 'turn/start').toList();
      expect(turnStarts, hasLength(1));
      final input = (turnStarts.single['params'] as Map)['input'] as List;
      expect((input.first as Map)['text'], 'urgent');
    });

    test('/new during async _loadHistory and loadEarlier prevents stale items and pagination leak', () async {
      // Case A: /new while _loadHistory is awaiting RPC thread/resume.
      Object? resumeRpcId;
      final t1 = _TestCodexTransport(
        onWrite: (tr, msg) {
          if (msg['method'] == 'thread/resume') {
            resumeRpcId = msg['id'];
          } else if (msg['method'] != null) {
            tr.respond(msg['id'], {});
          }
        },
      );
      final k1 = CodexKernel(
        MockKernels.codex,
        t1,
        context: KernelContext(
          cwd: tempDir.path,
          resume: SessionRecord(
            id: 'thr-slow',
            title: 'Slow',
            updatedAt: DateTime.now(),
            cwd: tempDir.path,
          ),
        ),
      );
      addTearDown(k1.dispose);
      final k1Events = <KernelEvent>[];
      final k1Sub = k1.events.listen(k1Events.add);
      addTearDown(k1Sub.cancel);

      for (var i = 0; i < 50 && resumeRpcId == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(resumeRpcId, isNotNull);

      k1.send(const KernelTurn(id: 't-new-a', text: '/new'));
      t1.respond(resumeRpcId, {
        'thread': {
          'id': 'thr-slow',
          'turns': [
            {
              'items': [
                {
                  'type': 'userMessage',
                  'id': 'stale-u1',
                  'content': [
                    {'type': 'text', 'text': 'stale question'},
                  ],
                },
              ],
            },
          ],
        },
      });
      await pumpEventQueue();
      expect(k1.sessionId, isNull);
      expect(k1.loadingHistory, isFalse);
      expect(k1.hasEarlierHistory, isFalse);
      expect(
        k1Events
            .whereType<ItemUpserted>()
            .map((e) => e.item)
            .whereType<UserMessageItem>()
            .where((u) => u.text == 'stale question'),
        isEmpty,
      );

      // Case B: /new while loadEarlier() is awaiting rollout read.
      final rollout = File(
        p.join(tempDir.path, 'sessions', 'rollout-2026-11-22T10-00-00-thr-page.jsonl'),
      )..parent.createSync(recursive: true);
      final lines = <String>[
        jsonEncode({
          'type': 'session_meta',
          'payload': {'id': 'thr-page', 'cwd': tempDir.path},
        }),
        for (var i = 1; i <= 15; i++) ...[
          jsonEncode({
            'type': 'event_msg',
            'payload': {'type': 'user_message', 'message': 'hist turn $i'},
          }),
          jsonEncode({
            'type': 'event_msg',
            'payload': {'type': 'agent_message', 'message': 'hist reply $i'},
          }),
        ],
      ];
      rollout.writeAsStringSync('${lines.join('\n')}\n');

      final t2 = _TestCodexTransport();
      final k2 = CodexKernel(
        MockKernels.codex,
        t2,
        context: KernelContext(
          cwd: tempDir.path,
          resume: SessionRecord(
            id: 'thr-page',
            title: 'Paginated',
            updatedAt: DateTime.now(),
            cwd: tempDir.path,
            path: rollout.path,
          ),
        ),
      );
      addTearDown(k2.dispose);
      for (var i = 0; i < 100 && k2.loadingHistory; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(k2.hasEarlierHistory, isTrue);

      final k2Events = <KernelEvent>[];
      final k2Sub = k2.events.listen(k2Events.add);
      addTearDown(k2Sub.cancel);

      final earlierFuture = k2.loadEarlier();
      k2.send(const KernelTurn(id: 't-new-b', text: '/new'));
      await earlierFuture;
      await pumpEventQueue();

      expect(k2.sessionId, isNull);
      expect(k2.hasEarlierHistory, isFalse);
      expect(k2.loadingEarlier, isFalse);
      expect(k2Events.whereType<HistoryPrepended>(), isEmpty);
    });

    test('_parseDiffLines handles overflowing hunk line numbers without FormatException and rewind updates fork turn count', () async {
      final t = _TestCodexTransport();
      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);

      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      t.push({
        'id': 950,
        'method': 'item/fileChange/requestApproval',
        'params': {
          'path': 'lib/big.dart',
          'diff': '@@ -9999999999999999999999999 +1 @@\n-old\n+new',
        },
      });
      final req =
          events
                  .whereType<InteractionRequested>()
                  .lastWhere((e) => e.request.id == 'approval:950')
                  .request
              as ApprovalRequest;
      expect(req.preview, isA<DiffPreview>());
      expect((req.preview as DiffPreview).lines, hasLength(2));
      kernel.answer('approval:950', const ApprovalAnswer(ApprovalDecision.deny));

      // Run 2 completed turns, rewind 1 turn, then fork before turn 1 -> dropTurns == 0.
      kernel.send(const KernelTurn(id: 'rt1', text: 'turn 1'));
      await pumpEventQueue();
      t.push({
        'method': 'turn/completed',
        'params': {
          'turn': {'id': 'srv-turn-1', 'status': 'completed'},
        },
      });
      await pumpEventQueue();

      kernel.send(const KernelTurn(id: 'rt2', text: 'turn 2'));
      await pumpEventQueue();
      t.push({
        'method': 'turn/completed',
        'params': {
          'turn': {'id': 'srv-turn-1', 'status': 'completed'},
        },
      });
      await pumpEventQueue();

      await kernel.rewind(itemId: 'rt2', index: 1, turns: 1);
      final rollbacksBeforeFork =
          t.written.where((m) => m['method'] == 'thread/rollback').length;
      final forked = await kernel.fork(before: 'rt1', title: 'After Rewind');
      expect(forked, isNotNull);
      // With _completedTurnCount decremented from 2 -> 1, and rt1 at turnIndex 0:
      // dropTurns == 1 (instead of 2).
      final forkRollback = t.written
          .where((m) => m['method'] == 'thread/rollback')
          .skip(rollbacksBeforeFork)
          .single;
      expect((forkRollback['params'] as Map)['numTurns'], 1);
    });

    test('late turn/started and turn/completed from cancelled in-flight turn/start do not hijack or kill promoted turn', () async {
      // Case A: t1 turn/started('srv-1') + t1 turn/start response('srv-1') +
      // turn/completed('srv-1') before t2 completes.
      final pendingTurnStartIds = <Object?>[];
      final tA = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-a'},
              });
            case 'turn/start':
              pendingTurnStartIds.add(msg['id']);
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );
      final kA = CodexKernel(MockKernels.codex, tA, context: KernelContext(cwd: tempDir.path));
      addTearDown(kA.dispose);
      final eventsA = <KernelEvent>[];
      final subA = kA.events.listen(eventsA.add);
      addTearDown(subA.cancel);

      kA.send(const KernelTurn(id: 't1', text: 'first'));
      for (var i = 0; i < 50 && pendingTurnStartIds.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(pendingTurnStartIds, hasLength(1));

      kA.send(const KernelTurn(id: 't2', text: 'urgent'));
      kA.sendQueuedNow('t2');
      await pumpEventQueue();
      expect(pendingTurnStartIds, hasLength(2));

      // Late turn/started for t1 arrives before t1's turn/start RPC response.
      tA.push({
        'method': 'turn/started',
        'params': {
          'turn': {'id': 'srv-1'},
        },
      });
      // Resolve t1's turn/start response -> should mark srv-1 ignored and interrupt it.
      tA.respond(pendingTurnStartIds[0], {
        'turn': {'id': 'srv-1'},
      });
      await pumpEventQueue();

      final interruptsA = tA.written.where((m) => m['method'] == 'turn/interrupt').toList();
      expect(interruptsA, hasLength(1));
      expect((interruptsA.single['params'] as Map)['turnId'], 'srv-1');

      // Now t1's turn/completed arrives -> must NOT kill t2.
      tA.push({
        'method': 'turn/completed',
        'params': {
          'turn': {'id': 'srv-1', 'status': 'interrupted'},
        },
      });
      await pumpEventQueue();
      expect(eventsA.whereType<TurnEnded>().where((e) => e.turnId == 't2'), isEmpty);

      // Now t2 starts and completes normally on srv-2.
      tA.respond(pendingTurnStartIds[1], {
        'turn': {'id': 'srv-2'},
      });
      tA.push({
        'method': 'turn/started',
        'params': {
          'turn': {'id': 'srv-2'},
        },
      });
      tA.push({
        'method': 'turn/completed',
        'params': {
          'turn': {'id': 'srv-2', 'status': 'completed'},
        },
      });
      await pumpEventQueue();
      final t2EndedA = eventsA.whereType<TurnEnded>().where((e) => e.turnId == 't2').toList();
      expect(t2EndedA, hasLength(1));
      expect(t2EndedA.single.interrupted, isFalse);

      // Case B: t1 turn/started('srv-1') AND turn/completed('srv-1') arrive
      // BEFORE t1's turn/start response resolves (including t2 resolving first).
      final pendingTurnStartIdsB = <Object?>[];
      final tB = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-b'},
              });
            case 'turn/start':
              pendingTurnStartIdsB.add(msg['id']);
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );
      final kB = CodexKernel(MockKernels.codex, tB, context: KernelContext(cwd: tempDir.path));
      addTearDown(kB.dispose);
      final eventsB = <KernelEvent>[];
      final subB = kB.events.listen(eventsB.add);
      addTearDown(subB.cancel);

      kB.send(const KernelTurn(id: 'b1', text: 'first'));
      for (var i = 0; i < 50 && pendingTurnStartIdsB.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      kB.send(const KernelTurn(id: 'b2', text: 'urgent'));
      kB.sendQueuedNow('b2');
      await pumpEventQueue();
      expect(pendingTurnStartIdsB, hasLength(2));

      // Server emits b1's turn/started + turn/completed BEFORE b1's turn/start RPC responds.
      tB.push({
        'method': 'turn/started',
        'params': {
          'turn': {'id': 'srv-b1'},
        },
      });
      tB.push({
        'method': 'turn/completed',
        'params': {
          'turn': {'id': 'srv-b1', 'status': 'interrupted'},
        },
      });
      await pumpEventQueue();
      expect(eventsB.whereType<TurnEnded>().where((e) => e.turnId == 'b2'), isEmpty);

      // Even if b2's turn/start resolves before b1's turn/start resolves, b2 stays intact.
      tB.respond(pendingTurnStartIdsB[1], {
        'turn': {'id': 'srv-b2'},
      });
      await pumpEventQueue();
      expect(eventsB.whereType<TurnEnded>().where((e) => e.turnId == 'b2'), isEmpty);

      // Now b1's turn/start resolves, followed by b2 completing normally.
      tB.respond(pendingTurnStartIdsB[0], {
        'turn': {'id': 'srv-b1'},
      });
      await pumpEventQueue();
      expect(eventsB.whereType<TurnEnded>().where((e) => e.turnId == 'b2'), isEmpty);

      tB.push({
        'method': 'turn/completed',
        'params': {
          'turn': {'id': 'srv-b2', 'status': 'completed'},
        },
      });
      await pumpEventQueue();
      final b2Ended = eventsB.whereType<TurnEnded>().where((e) => e.turnId == 'b2').toList();
      expect(b2Ended, hasLength(1));
      expect(b2Ended.single.interrupted, isFalse);
    });

    test('/new while turn/start is in flight still sends turn/interrupt on captured old threadId', () async {
      var threadCount = 0;
      final pendingTurnStartIds = <Object?>[];
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': ++threadCount == 1 ? 'thr-old' : 'thr-new'},
              });
            case 'turn/start':
              pendingTurnStartIds.add(msg['id']);
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );
      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't1', text: 'slow turn'));
      for (var i = 0; i < 50 && pendingTurnStartIds.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(pendingTurnStartIds, hasLength(1));
      expect(kernel.sessionId, 'thr-old');

      // /new with now: true cancels t1 and clears _threadId while t1's turn/start is in flight.
      kernel.send(const KernelTurn(id: 't2', text: '/new', now: true));
      await pumpEventQueue();
      expect(kernel.sessionId, isNull);

      // Now t1's turn/start resolves -> must still emit turn/interrupt for srv-1 on thr-old.
      t.respond(pendingTurnStartIds[0], {
        'turn': {'id': 'srv-1'},
      });
      await pumpEventQueue();

      final interrupts = t.written.where((m) => m['method'] == 'turn/interrupt').toList();
      expect(interrupts, hasLength(1));
      expect(interrupts.single['params'], {
        'threadId': 'thr-old',
        'turnId': 'srv-1',
      });

      // Subsequent turn on thr-new must not be affected by late srv-1 notifications.
      kernel.send(const KernelTurn(id: 't3', text: 'fresh thread'));
      for (var i = 0; i < 50 && pendingTurnStartIds.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(kernel.sessionId, 'thr-new');
      t.push({
        'method': 'turn/started',
        'params': {
          'turn': {'id': 'srv-1'},
        },
      });
      t.push({
        'method': 'turn/completed',
        'params': {
          'turn': {'id': 'srv-1', 'status': 'interrupted'},
        },
      });
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 't3'), isEmpty);

      t.respond(pendingTurnStartIds[1], {
        'turn': {'id': 'srv-2'},
      });
      t.push({
        'method': 'turn/completed',
        'params': {
          'turn': {'id': 'srv-2', 'status': 'completed'},
        },
      });
      await pumpEventQueue();
      final t3Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 't3').toList();
      expect(t3Ended, hasLength(1));
      expect(t3Ended.single.interrupted, isFalse);
    });

    test('HUNT B1: /new while turn-1 on thr-old is ignored does not swallow early turn/completed for reused turn-1 on thr-new', () async {
      var threadCount = 0;
      final pendingTurnStarts = <Object?>[];
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': ++threadCount == 1 ? 'thr-old' : 'thr-new'},
              });
            case 'turn/start':
              pendingTurnStarts.add(msg['id']);
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't1', text: 'old turn'));
      await pumpEventQueue();
      expect(kernel.sessionId, 'thr-old');

      // /new while t1's turn/start is in flight, then t1's turn/start resolves with turn-1 on thr-old
      // -> ('thr-old', 'turn-1') enters _ignoredServerTurns.
      kernel.send(const KernelTurn(id: 't-new', text: '/new', now: true));
      await pumpEventQueue();
      t.respond(pendingTurnStarts[0], {
        'turn': {'id': 'turn-1'},
      });
      await pumpEventQueue();

      // Start t2 on thr-new; thr-new reuses per-thread turn ID 'turn-1' and finishes before turn/start resolves.
      kernel.send(const KernelTurn(id: 't2', text: 'new thread turn'));
      await pumpEventQueue();
      expect(kernel.sessionId, 'thr-new');
      expect(pendingTurnStarts, hasLength(2));

      t.push({
        'method': 'turn/started',
        'params': {
          'threadId': 'thr-new',
          'turn': {'id': 'turn-1'},
        },
      });
      t.push({
        'method': 'turn/completed',
        'params': {
          'threadId': 'thr-new',
          'turn': {'id': 'turn-1', 'status': 'completed'},
        },
      });
      t.respond(pendingTurnStarts[1], {
        'turn': {'id': 'turn-1'},
      });
      await pumpEventQueue();

      final t2Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 't2').toList();
      expect(t2Ended, hasLength(1));
      expect(t2Ended.single.interrupted, isFalse);
    });

    test('HUNT B2: late turn/completed from thr-old with matching per-thread turnId does not kill active turn on thr-new', () async {
      var threadCount = 0;
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': ++threadCount == 1 ? 'thr-old' : 'thr-new'},
              });
            case 'turn/start':
              tr.respond(msg['id'], {
                'turn': {'id': 'turn-1'},
              });
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't1', text: 'old turn'));
      await pumpEventQueue();
      kernel.send(const KernelTurn(id: 't-new', text: '/new', now: true));
      await pumpEventQueue();

      kernel.send(const KernelTurn(id: 't2', text: 'new turn'));
      await pumpEventQueue();
      expect(kernel.sessionId, 'thr-new');

      // Late turn/completed from thr-old with turn-1 must NOT kill active t2 on thr-new!
      t.push({
        'method': 'turn/completed',
        'params': {
          'threadId': 'thr-old',
          'turn': {'id': 'turn-1', 'status': 'interrupted'},
        },
      });
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 't2'), isEmpty);

      // Actual thr-new completion ends t2 cleanly.
      t.push({
        'method': 'turn/completed',
        'params': {
          'threadId': 'thr-new',
          'turn': {'id': 'turn-1', 'status': 'completed'},
        },
      });
      await pumpEventQueue();
      final t2Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 't2').toList();
      expect(t2Ended, hasLength(1));
      expect(t2Ended.single.interrupted, isFalse);
    });

    test('HUNT C: cancel() between early turn/started and turn/completed before turn/start response emits single turn/interrupt', () async {
      final pendingTurnStarts = <Object?>[];
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-c'},
              });
            case 'turn/start':
              pendingTurnStarts.add(msg['id']);
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't1', text: 'turn 1'));
      await pumpEventQueue();
      expect(pendingTurnStarts, hasLength(1));

      // Early turn/started arrives before turn/start response.
      t.push({
        'method': 'turn/started',
        'params': {
          'threadId': 'thr-c',
          'turn': {'id': 'srv-1'},
        },
      });
      kernel.cancel();
      await pumpEventQueue();

      // Early turn/completed arrives before turn/start response.
      t.push({
        'method': 'turn/completed',
        'params': {
          'threadId': 'thr-c',
          'turn': {'id': 'srv-1', 'status': 'interrupted'},
        },
      });
      // Now turn/start response arrives.
      t.respond(pendingTurnStarts[0], {
        'turn': {'id': 'srv-1'},
      });
      await pumpEventQueue();

      final interrupts = t.written.where((m) => m['method'] == 'turn/interrupt').toList();
      expect(interrupts, hasLength(1));

      // Verify no stale _ignoredServerTurns leak blocks a subsequent turn reusing 'srv-1'.
      kernel.send(const KernelTurn(id: 't2', text: 'turn 2'));
      await pumpEventQueue();
      t.push({
        'method': 'turn/started',
        'params': {
          'threadId': 'thr-c',
          'turn': {'id': 'srv-1'},
        },
      });
      t.respond(pendingTurnStarts[1], {
        'turn': {'id': 'srv-1'},
      });
      t.push({
        'method': 'turn/completed',
        'params': {
          'threadId': 'thr-c',
          'turn': {'id': 'srv-1', 'status': 'completed'},
        },
      });
      await pumpEventQueue();
      final t2Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 't2').toList();
      expect(t2Ended, hasLength(1));
      expect(t2Ended.single.interrupted, isFalse);
    });

    test('HUNT D: /compact while orphaned turn/start is in flight awaits turn/completed instead of ending prematurely', () async {
      Object? pendingTurnStartId;
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-d'},
              });
            case 'turn/start':
              pendingTurnStartId = msg['id'];
            case 'thread/compact/start':
              tr.respond(msg['id'], {});
              tr.push({
                'method': 'turn/started',
                'params': {
                  'threadId': 'thr-d',
                  'turn': {'id': 'srv-compact'},
                },
              });
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't1', text: 'long turn'));
      await pumpEventQueue();
      expect(pendingTurnStartId, isNotNull);

      // Cancel t1 while turn/start is still in flight, then send /compact.
      kernel.send(const KernelTurn(id: 't-compact', text: '/compact', now: true));
      await pumpEventQueue();

      // /compact must NOT have ended yet while srv-compact is running.
      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 't-compact'), isEmpty);

      // Even if orphaned t1 turn/start resolves and completes now, /compact stays alive.
      t.respond(pendingTurnStartId, {
        'turn': {'id': 'srv-1'},
      });
      t.push({
        'method': 'turn/completed',
        'params': {
          'threadId': 'thr-d',
          'turn': {'id': 'srv-1', 'status': 'interrupted'},
        },
      });
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 't-compact'), isEmpty);

      // Now srv-compact completes -> /compact ends cleanly.
      t.push({
        'method': 'turn/completed',
        'params': {
          'threadId': 'thr-d',
          'turn': {'id': 'srv-compact', 'status': 'completed'},
        },
      });
      await pumpEventQueue();
      final compactEnded =
          events.whereType<TurnEnded>().where((e) => e.turnId == 't-compact').toList();
      expect(compactEnded, hasLength(1));
      expect(compactEnded.single.interrupted, isFalse);
    });

    test('T2.2a: turn/started and turn/completed with notifThreadId == null after /new while thr-old turn-1 is ignored', () async {
      var threadCount = 0;
      final pendingTurnStarts = <Object?>[];
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': ++threadCount == 1 ? 'thr-old' : 'thr-new'},
              });
            case 'turn/start':
              pendingTurnStarts.add(msg['id']);
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't1', text: 'old turn'));
      await pumpEventQueue();
      expect(kernel.sessionId, 'thr-old');

      // /new while t1's turn/start is in flight, then t1 resolves with 'turn-1' on thr-old
      // -> ('thr-old', 'turn-1') enters _ignoredServerTurns.
      kernel.send(const KernelTurn(id: 't-new', text: '/new', now: true));
      await pumpEventQueue();
      t.respond(pendingTurnStarts[0], {
        'turn': {'id': 'turn-1'},
      });
      await pumpEventQueue();

      // Start t2 on thr-new; transport omits threadId on turn/started and turn/completed
      // before t2's turn/start resolves with reused 'turn-1'.
      kernel.send(const KernelTurn(id: 't2', text: 'new thread turn'));
      await pumpEventQueue();
      expect(kernel.sessionId, 'thr-new');
      expect(pendingTurnStarts, hasLength(2));

      t.push({
        'method': 'turn/started',
        'params': {
          'turn': {'id': 'turn-1'},
        },
      });
      t.push({
        'method': 'turn/completed',
        'params': {
          'turn': {'id': 'turn-1', 'status': 'completed'},
        },
      });
      t.respond(pendingTurnStarts[1], {
        'turn': {'id': 'turn-1'},
      });
      await pumpEventQueue();

      final t2Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 't2').toList();
      expect(t2Ended, hasLength(1));
      expect(t2Ended.single.interrupted, isFalse);
    });

    test('T2.2b: turn/completed with notifThreadId == null before t2 turn/start response after t2 turn/started(thr-new)', () async {
      var threadCount = 0;
      final pendingTurnStarts = <Object?>[];
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': ++threadCount == 1 ? 'thr-old' : 'thr-new'},
              });
            case 'turn/start':
              pendingTurnStarts.add(msg['id']);
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't1', text: 'old turn'));
      await pumpEventQueue();
      kernel.send(const KernelTurn(id: 't-new', text: '/new', now: true));
      await pumpEventQueue();
      t.respond(pendingTurnStarts[0], {
        'turn': {'id': 'turn-1'},
      });
      await pumpEventQueue();

      kernel.send(const KernelTurn(id: 't2', text: 'new turn'));
      await pumpEventQueue();
      t.push({
        'method': 'turn/started',
        'params': {
          'threadId': 'thr-new',
          'turn': {'id': 'turn-1'},
        },
      });
      t.push({
        'method': 'turn/completed',
        'params': {
          'turn': {'id': 'turn-1', 'status': 'completed'},
        },
      });
      t.respond(pendingTurnStarts[1], {
        'turn': {'id': 'turn-1'},
      });
      await pumpEventQueue();

      final t2Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 't2').toList();
      expect(t2Ended, hasLength(1));
      expect(t2Ended.single.interrupted, isFalse);
      final interrupts = t.written.where((m) => m['method'] == 'turn/interrupt').toList();
      expect(interrupts, hasLength(1)); // Only t1's interrupt
    });

    test('T2.3b: /compact while orphaned t1 turn/start is in flight ignores orphaned t1 turn/started arriving during thread/compact/start', () async {
      Object? pendingTurnStartId;
      Object? pendingCompactId;
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-23b'},
              });
            case 'turn/start':
              pendingTurnStartId = msg['id'];
            case 'thread/compact/start':
              pendingCompactId = msg['id'];
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't1', text: 'long turn'));
      await pumpEventQueue();
      expect(pendingTurnStartId, isNotNull);

      kernel.send(const KernelTurn(id: 't-compact', text: '/compact', now: true));
      await pumpEventQueue();
      expect(pendingCompactId, isNotNull);

      // Orphaned t1 turn/started('srv-1') arrives WHILE thread/compact/start is still awaiting!
      t.push({
        'method': 'turn/started',
        'params': {
          'threadId': 'thr-23b',
          'turn': {'id': 'srv-1'},
        },
      });
      t.push({
        'method': 'turn/completed',
        'params': {
          'threadId': 'thr-23b',
          'turn': {'id': 'srv-1', 'status': 'interrupted'},
        },
      });
      await pumpEventQueue();

      // /compact must NOT have ended prematurely!
      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 't-compact'), isEmpty);

      // Now thread/compact/start resolves with {} and emits srv-compact turn/started.
      t.respond(pendingCompactId, {});
      t.push({
        'method': 'turn/started',
        'params': {
          'threadId': 'thr-23b',
          'turn': {'id': 'srv-compact'},
        },
      });
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 't-compact'), isEmpty);

      // Orphaned t1 turn/start resolves later; srv-compact completes normally.
      t.respond(pendingTurnStartId, {
        'turn': {'id': 'srv-1'},
      });
      t.push({
        'method': 'turn/completed',
        'params': {
          'threadId': 'thr-23b',
          'turn': {'id': 'srv-compact', 'status': 'completed'},
        },
      });
      await pumpEventQueue();
      final compactEnded =
          events.whereType<TurnEnded>().where((e) => e.turnId == 't-compact').toList();
      expect(compactEnded, hasLength(1));
      expect(compactEnded.single.interrupted, isFalse);
    });

    test('T2.3c: delayed srv-compact turn/started past Duration.zero while promoted t3 turn/start is in flight does not hijack t3', () async {
      final pendingTurnStarts = <Object?>[];
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-23c'},
              });
            case 'turn/start':
              pendingTurnStarts.add(msg['id']);
            case 'thread/compact/start':
              tr.respond(msg['id'], {});
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      // Establish thread first.
      kernel.send(const KernelTurn(id: 't0', text: 'init'));
      await pumpEventQueue();
      t.respond(pendingTurnStarts[0], {
        'turn': {'id': 'srv-0'},
      });
      t.push({
        'method': 'turn/completed',
        'params': {
          'threadId': 'thr-23c',
          'turn': {'id': 'srv-0', 'status': 'completed'},
        },
      });
      await pumpEventQueue();

      // Send /compact and queue t3 behind it.
      kernel.send(const KernelTurn(id: 't-compact', text: '/compact'));
      kernel.send(const KernelTurn(id: 't3', text: 'after compact'));
      await pumpEventQueue();

      // /compact ended after Duration.zero and promoted t3, whose turn/start is in flight.
      expect(
        events.whereType<TurnEnded>().where((e) => e.turnId == 't-compact'),
        hasLength(1),
      );
      expect(pendingTurnStarts, hasLength(2));

      // Delayed srv-compact notifications arrive while t3's turn/start is still in flight.
      t.push({
        'method': 'turn/started',
        'params': {
          'threadId': 'thr-23c',
          'turn': {'id': 'srv-compact'},
        },
      });
      t.push({
        'method': 'turn/completed',
        'params': {
          'threadId': 'thr-23c',
          'turn': {'id': 'srv-compact', 'status': 'completed'},
        },
      });
      await pumpEventQueue();

      // t3 MUST NOT be killed by delayed srv-compact!
      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 't3'), isEmpty);

      // Now t3 resolves and completes normally.
      t.respond(pendingTurnStarts[1], {
        'turn': {'id': 'srv-3'},
      });
      t.push({
        'method': 'turn/completed',
        'params': {
          'threadId': 'thr-23c',
          'turn': {'id': 'srv-3', 'status': 'completed'},
        },
      });
      await pumpEventQueue();
      final t3Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 't3').toList();
      expect(t3Ended, hasLength(1));
      expect(t3Ended.single.interrupted, isFalse);
    });

    test('/compact returning explicit turn id in thread/compact/start binds exact server turn despite orphaned turn/start', () async {
      Object? pendingTurnStartId;
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-compact-id'},
              });
            case 'turn/start':
              pendingTurnStartId = msg['id'];
            case 'thread/compact/start':
              tr.respond(msg['id'], {
                'turn': {'id': 'srv-compact-explicit'},
              });
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't1', text: 'slow'));
      await pumpEventQueue();
      expect(pendingTurnStartId, isNotNull);

      kernel.send(const KernelTurn(id: 't-compact', text: '/compact', now: true));
      await pumpEventQueue();

      // Orphaned t1 completes: must NOT end /compact.
      t.respond(pendingTurnStartId, {
        'turn': {'id': 'srv-1'},
      });
      t.push({
        'method': 'turn/completed',
        'params': {
          'threadId': 'thr-compact-id',
          'turn': {'id': 'srv-1', 'status': 'interrupted'},
        },
      });
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 't-compact'), isEmpty);

      // Explicit compact turn completes: /compact ends cleanly.
      t.push({
        'method': 'turn/completed',
        'params': {
          'threadId': 'thr-compact-id',
          'turn': {'id': 'srv-compact-explicit', 'status': 'completed'},
        },
      });
      await pumpEventQueue();
      final compactEnded =
          events.whereType<TurnEnded>().where((e) => e.turnId == 't-compact').toList();
      expect(compactEnded, hasLength(1));
      expect(compactEnded.single.interrupted, isFalse);
    });

    test('EDGE 1: /compact cancelled via now:true while thread/compact/start ({}) is in flight prevents srv-compact from killing t2', () async {
      final pendingTurnStarts = <Object?>[];
      Object? pendingCompactId;
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-e1'},
              });
            case 'turn/start':
              pendingTurnStarts.add(msg['id']);
            case 'thread/compact/start':
              pendingCompactId = msg['id'];
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't0', text: 'init'));
      await pumpEventQueue();
      t.respond(pendingTurnStarts[0], {'turn': {'id': 'srv-0'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-e1', 'turn': {'id': 'srv-0', 'status': 'completed'}},
      });
      await pumpEventQueue();

      kernel.send(const KernelTurn(id: 'c1', text: '/compact'));
      await pumpEventQueue();
      expect(pendingCompactId, isNotNull);

      // Cancel c1 via now:true t2 while thread/compact/start ({}) is still in flight.
      kernel.send(const KernelTurn(id: 't2', text: 'follow up', now: true));
      await pumpEventQueue();
      expect(pendingTurnStarts, hasLength(2));

      // thread/compact/start resolves {} and srv-compact notifications arrive synchronously
      // while t2's turn/start is in flight.
      t.respond(pendingCompactId, {});
      t.push({
        'method': 'turn/started',
        'params': {'threadId': 'thr-e1', 'turn': {'id': 'srv-compact'}},
      });
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-e1', 'turn': {'id': 'srv-compact', 'status': 'completed'}},
      });
      await pumpEventQueue();

      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 't2'), isEmpty);

      t.respond(pendingTurnStarts[1], {'turn': {'id': 'srv-2'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-e1', 'turn': {'id': 'srv-2', 'status': 'completed'}},
      });
      await pumpEventQueue();
      final t2Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 't2').toList();
      expect(t2Ended, hasLength(1));
      expect(t2Ended.single.interrupted, isFalse);
    });

    test('EDGE 1b: /compact cancelled via cancel() while thread/compact/start ({}) is in flight prevents srv-compact from killing subsequent t2', () async {
      final pendingTurnStarts = <Object?>[];
      Object? pendingCompactId;
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-e1b'},
              });
            case 'turn/start':
              pendingTurnStarts.add(msg['id']);
            case 'thread/compact/start':
              pendingCompactId = msg['id'];
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't0', text: 'init'));
      await pumpEventQueue();
      t.respond(pendingTurnStarts[0], {'turn': {'id': 'srv-0'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-e1b', 'turn': {'id': 'srv-0', 'status': 'completed'}},
      });
      await pumpEventQueue();

      kernel.send(const KernelTurn(id: 'c1', text: '/compact'));
      await pumpEventQueue();
      expect(pendingCompactId, isNotNull);

      kernel.cancel();
      await pumpEventQueue();
      t.respond(pendingCompactId, {});
      await pumpEventQueue();

      // Now t2 starts while srv-compact notifications arrive mid-turn/start.
      kernel.send(const KernelTurn(id: 't2', text: 'after cancel'));
      await pumpEventQueue();
      expect(pendingTurnStarts, hasLength(2));

      t.push({
        'method': 'turn/started',
        'params': {'threadId': 'thr-e1b', 'turn': {'id': 'srv-compact'}},
      });
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-e1b', 'turn': {'id': 'srv-compact', 'status': 'completed'}},
      });
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 't2'), isEmpty);

      t.respond(pendingTurnStarts[1], {'turn': {'id': 'srv-2'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-e1b', 'turn': {'id': 'srv-2', 'status': 'completed'}},
      });
      await pumpEventQueue();
      final t2Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 't2').toList();
      expect(t2Ended, hasLength(1));
      expect(t2Ended.single.interrupted, isFalse);
    });

    test('EDGE 2: /compact cancelled during Duration.zero wait after thread/compact/start ({}) prevents srv-compact from killing t2', () async {
      final pendingTurnStarts = <Object?>[];
      var compactStarts = 0;
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-e2'},
              });
            case 'turn/start':
              pendingTurnStarts.add(msg['id']);
            case 'thread/compact/start':
              compactStarts++;
              tr.respond(msg['id'], {});
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't0', text: 'init'));
      await pumpEventQueue();
      t.respond(pendingTurnStarts[0], {'turn': {'id': 'srv-0'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-e2', 'turn': {'id': 'srv-0', 'status': 'completed'}},
      });
      await pumpEventQueue();

      // Send /compact and advance microtasks until it enters Future.delayed(Duration.zero).
      kernel.send(const KernelTurn(id: 'c1', text: '/compact'));
      while (compactStarts < 1) {
        await Future<void>.microtask(() {});
      }
      await Future<void>.microtask(() {});
      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 'c1'), isEmpty);

      // Cancel via now:true before Duration.zero fires.
      kernel.send(const KernelTurn(id: 't2', text: 'preempt', now: true));
      await pumpEventQueue();
      expect(pendingTurnStarts, hasLength(2));

      t.push({
        'method': 'turn/started',
        'params': {'threadId': 'thr-e2', 'turn': {'id': 'srv-compact'}},
      });
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-e2', 'turn': {'id': 'srv-compact', 'status': 'completed'}},
      });
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 't2'), isEmpty);

      t.respond(pendingTurnStarts[1], {'turn': {'id': 'srv-2'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-e2', 'turn': {'id': 'srv-2', 'status': 'completed'}},
      });
      await pumpEventQueue();
      final t2Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 't2').toList();
      expect(t2Ended, hasLength(1));
      expect(t2Ended.single.interrupted, isFalse);

      // Subcase: if srv-compact bound turn/started during Duration.zero before cancel(),
      // cancel() ignores srv-compact and t3 completes normally.
      kernel.send(const KernelTurn(id: 'c2', text: '/compact'));
      while (compactStarts < 2) {
        await Future<void>.microtask(() {});
      }
      await Future<void>.microtask(() {});
      t.push({
        'method': 'turn/started',
        'params': {'threadId': 'thr-e2', 'turn': {'id': 'srv-compact-2'}},
      });
      kernel.send(const KernelTurn(id: 't3', text: 'after bound cancel', now: true));
      await pumpEventQueue();
      expect(pendingTurnStarts, hasLength(3));
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-e2', 'turn': {'id': 'srv-compact-2', 'status': 'interrupted'}},
      });
      t.respond(pendingTurnStarts[2], {'turn': {'id': 'srv-3'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-e2', 'turn': {'id': 'srv-3', 'status': 'completed'}},
      });
      await pumpEventQueue();
      final t3Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 't3').toList();
      expect(t3Ended, hasLength(1));
      expect(t3Ended.single.interrupted, isFalse);
    });

    test('EDGE 3: sync transport + explicit compact turnId with synchronous turn/started + turn/completed before await resumes (with queued t2) does not poison _ignoredServerTurns for t3', () async {
      final pendingTurnStarts = <Object?>[];
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-e3'},
              });
            case 'turn/start':
              pendingTurnStarts.add(msg['id']);
            case 'thread/compact/start':
              tr.respond(msg['id'], {
                'turn': {'id': 'turn-1'},
              });
              tr.push({
                'method': 'turn/started',
                'params': {'threadId': 'thr-e3', 'turn': {'id': 'turn-1'}},
              });
              tr.push({
                'method': 'turn/completed',
                'params': {'threadId': 'thr-e3', 'turn': {'id': 'turn-1', 'status': 'completed'}},
              });
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't0', text: 'init'));
      await pumpEventQueue();
      t.respond(pendingTurnStarts[0], {'turn': {'id': 'srv-0'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-e3', 'turn': {'id': 'srv-0', 'status': 'completed'}},
      });
      await pumpEventQueue();

      kernel.send(const KernelTurn(id: 'c1', text: '/compact'));
      kernel.send(const KernelTurn(id: 't2', text: 'queued'));
      await pumpEventQueue();
      expect(pendingTurnStarts, hasLength(2));
      t.respond(pendingTurnStarts[1], {'turn': {'id': 'turn-2'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-e3', 'turn': {'id': 'turn-2', 'status': 'completed'}},
      });
      await pumpEventQueue();

      // t3 reuses 'turn-1' with early turn/started + turn/completed before turn/start response.
      kernel.send(const KernelTurn(id: 't3', text: 'reuses turn-1'));
      await pumpEventQueue();
      expect(pendingTurnStarts, hasLength(3));
      t.push({
        'method': 'turn/started',
        'params': {'threadId': 'thr-e3', 'turn': {'id': 'turn-1'}},
      });
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-e3', 'turn': {'id': 'turn-1', 'status': 'completed'}},
      });
      t.respond(pendingTurnStarts[2], {'turn': {'id': 'turn-1'}});
      await pumpEventQueue();

      final t3Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 't3').toList();
      expect(t3Ended, hasLength(1));
      expect(t3Ended.single.interrupted, isFalse);
    });

    test('EDGE 3b: sync transport + explicit compact turnId without queued turn does not poison _ignoredServerTurns for subsequent t3', () async {
      final pendingTurnStarts = <Object?>[];
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-e3b'},
              });
            case 'turn/start':
              pendingTurnStarts.add(msg['id']);
            case 'thread/compact/start':
              tr.respond(msg['id'], {'turnId': 'turn-1'});
              tr.push({
                'method': 'turn/started',
                'params': {'threadId': 'thr-e3b', 'turn': {'id': 'turn-1'}},
              });
              tr.push({
                'method': 'turn/completed',
                'params': {'threadId': 'thr-e3b', 'turn': {'id': 'turn-1', 'status': 'completed'}},
              });
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't0', text: 'init'));
      await pumpEventQueue();
      t.respond(pendingTurnStarts[0], {'turn': {'id': 'srv-0'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-e3b', 'turn': {'id': 'srv-0', 'status': 'completed'}},
      });
      await pumpEventQueue();

      kernel.send(const KernelTurn(id: 'c1', text: '/compact'));
      await pumpEventQueue();

      kernel.send(const KernelTurn(id: 't3', text: 'reuses turn-1'));
      await pumpEventQueue();
      expect(pendingTurnStarts, hasLength(2));
      t.push({
        'method': 'turn/started',
        'params': {'threadId': 'thr-e3b', 'turn': {'id': 'turn-1'}},
      });
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-e3b', 'turn': {'id': 'turn-1', 'status': 'completed'}},
      });
      t.respond(pendingTurnStarts[1], {'turn': {'id': 'turn-1'}});
      await pumpEventQueue();

      final t3Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 't3').toList();
      expect(t3Ended, hasLength(1));
      expect(t3Ended.single.interrupted, isFalse);
    });

    test('STRESS 3 (COMPACT-POISON-1): explicit compact turnId + sync turn/started + cancel() + sync turn/completed before await resumes does not poison _ignoredServerTurns for t3', () async {
      final pendingTurnStarts = <Object?>[];
      late CodexKernel kernel;
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-cp1'},
              });
            case 'turn/start':
              pendingTurnStarts.add(msg['id']);
            case 'thread/compact/start':
              tr.respond(msg['id'], {
                'turn': {'id': 'turn-1'},
              });
              tr.push({
                'method': 'turn/started',
                'params': {'threadId': 'thr-cp1', 'turn': {'id': 'turn-1'}},
              });
              kernel.cancel();
              tr.push({
                'method': 'turn/completed',
                'params': {
                  'threadId': 'thr-cp1',
                  'turn': {'id': 'turn-1', 'status': 'interrupted'},
                },
              });
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't0', text: 'init'));
      await pumpEventQueue();
      t.respond(pendingTurnStarts[0], {'turn': {'id': 'srv-0'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-cp1', 'turn': {'id': 'srv-0', 'status': 'completed'}},
      });
      await pumpEventQueue();

      kernel.send(const KernelTurn(id: 'c1', text: '/compact'));
      await pumpEventQueue();
      final c1Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 'c1').toList();
      expect(c1Ended, hasLength(1));
      expect(c1Ended.single.interrupted, isTrue);

      // Subsequent t3 reusing 'turn-1' with early turn/started + turn/completed before turn/start response.
      kernel.send(const KernelTurn(id: 't3', text: 'reuses turn-1'));
      await pumpEventQueue();
      expect(pendingTurnStarts, hasLength(2));
      t.push({
        'method': 'turn/started',
        'params': {'threadId': 'thr-cp1', 'turn': {'id': 'turn-1'}},
      });
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-cp1', 'turn': {'id': 'turn-1', 'status': 'completed'}},
      });
      t.respond(pendingTurnStarts[1], {'turn': {'id': 'turn-1'}});
      await pumpEventQueue();

      final t3Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 't3').toList();
      expect(t3Ended, hasLength(1));
      expect(t3Ended.single.interrupted, isFalse);
    });

    test('STRESS 4 (COMPACT-ORPHAN-1): c1 cancelled by c2 (/compact now:true); c1 resolves explicit cmp-1 + sync turn/started + turn/completed while c2 is in flight does not hijack c2', () async {
      final pendingTurnStarts = <Object?>[];
      final pendingCompactStarts = <Object?>[];
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-co1'},
              });
            case 'turn/start':
              pendingTurnStarts.add(msg['id']);
            case 'thread/compact/start':
              pendingCompactStarts.add(msg['id']);
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't0', text: 'init'));
      await pumpEventQueue();
      t.respond(pendingTurnStarts[0], {'turn': {'id': 'srv-0'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-co1', 'turn': {'id': 'srv-0', 'status': 'completed'}},
      });
      await pumpEventQueue();

      kernel.send(const KernelTurn(id: 'c1', text: '/compact'));
      await pumpEventQueue();
      expect(pendingCompactStarts, hasLength(1));

      // Cancel c1 with c2 (/compact now:true) while c1's thread/compact/start is in flight.
      kernel.send(const KernelTurn(id: 'c2', text: '/compact', now: true));
      await pumpEventQueue();
      expect(pendingCompactStarts, hasLength(2));

      // Case A: c2 resolves {} first (setting _compactingTurnClientId = 'c2'), then
      // cancelled c1 resolves explicit cmp-1 + sync turn/started + turn/completed
      // before c2 receives its own srv-compact-2 turn/started.
      t.respond(pendingCompactStarts[1], {});
      t.respond(pendingCompactStarts[0], {'turn': {'id': 'cmp-1'}});
      t.push({
        'method': 'turn/started',
        'params': {'threadId': 'thr-co1', 'turn': {'id': 'cmp-1'}},
      });
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-co1', 'turn': {'id': 'cmp-1', 'status': 'completed'}},
      });

      // c2 must NOT be hijacked/killed by c1's cmp-1!
      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 'c2'), isEmpty);

      // Now c2 binds its own srv-compact-2 before Duration.zero fires.
      t.push({
        'method': 'turn/started',
        'params': {'threadId': 'thr-co1', 'turn': {'id': 'srv-compact-2'}},
      });
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 'c2'), isEmpty);

      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-co1', 'turn': {'id': 'srv-compact-2', 'status': 'completed'}},
      });
      await pumpEventQueue();

      final c2Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 'c2').toList();
      expect(c2Ended, hasLength(1));
      expect(c2Ended.single.interrupted, isFalse);
    });

    test('STRESS 4b (COMPACT-ORPHAN-1): c1 resolves explicit cmp-1 + sync turn/started + turn/completed while c2 is awaiting thread/compact/start', () async {
      final pendingTurnStarts = <Object?>[];
      final pendingCompactStarts = <Object?>[];
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-co1b'},
              });
            case 'turn/start':
              pendingTurnStarts.add(msg['id']);
            case 'thread/compact/start':
              pendingCompactStarts.add(msg['id']);
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't0', text: 'init'));
      await pumpEventQueue();
      t.respond(pendingTurnStarts[0], {'turn': {'id': 'srv-0'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-co1b', 'turn': {'id': 'srv-0', 'status': 'completed'}},
      });
      await pumpEventQueue();

      kernel.send(const KernelTurn(id: 'c1', text: '/compact'));
      await pumpEventQueue();
      expect(pendingCompactStarts, hasLength(1));

      kernel.send(const KernelTurn(id: 'c2', text: '/compact', now: true));
      await pumpEventQueue();
      expect(pendingCompactStarts, hasLength(2));

      // c1 resolves explicit cmp-1 + sync turn/started + turn/completed while c2 is still awaiting RPC.
      t.respond(pendingCompactStarts[0], {'turn': {'id': 'cmp-1'}});
      t.push({
        'method': 'turn/started',
        'params': {'threadId': 'thr-co1b', 'turn': {'id': 'cmp-1'}},
      });
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-co1b', 'turn': {'id': 'cmp-1', 'status': 'completed'}},
      });
      await pumpEventQueue();

      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 'c2'), isEmpty);

      t.respond(pendingCompactStarts[1], {'turn': {'id': 'cmp-2'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-co1b', 'turn': {'id': 'cmp-2', 'status': 'completed'}},
      });
      await pumpEventQueue();

      final c2Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 'c2').toList();
      expect(c2Ended, hasLength(1));
      expect(c2Ended.single.interrupted, isFalse);
    });

    test('STRESS 5 (COMPACT-ORPHAN-1): c1 (/compact) cancelled via t2 (now:true) with sync explicit cmp-1 while t2 is awaiting _ensureInitialized before _inFlightTurnStarts', () async {
      final pendingTurnStarts = <Object?>[];
      Object? pendingCompactId;
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-co2'},
              });
            case 'turn/start':
              pendingTurnStarts.add(msg['id']);
            case 'thread/compact/start':
              pendingCompactId = msg['id'];
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't0', text: 'init'));
      await pumpEventQueue();
      t.respond(pendingTurnStarts[0], {'turn': {'id': 'srv-0'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-co2', 'turn': {'id': 'srv-0', 'status': 'completed'}},
      });
      await pumpEventQueue();

      kernel.send(const KernelTurn(id: 'c1', text: '/compact'));
      await pumpEventQueue();
      expect(pendingCompactId, isNotNull);

      // Cancel c1 via t2 (now:true); t2 is suspended at `await _ensureInitialized`
      // before reaching `_inFlightTurnStarts.add('t2')`.
      kernel.send(const KernelTurn(id: 't2', text: 'follow up', now: true));
      expect(pendingTurnStarts, hasLength(1));

      // Synchronously resolve c1 with explicit cmp-1 and push turn/started + turn/completed.
      t.respond(pendingCompactId, {'turn': {'id': 'cmp-1'}});
      t.push({
        'method': 'turn/started',
        'params': {'threadId': 'thr-co2', 'turn': {'id': 'cmp-1'}},
      });
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-co2', 'turn': {'id': 'cmp-1', 'status': 'completed'}},
      });
      await pumpEventQueue();

      // t2 must NOT have been killed by c1's cmp-1!
      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 't2'), isEmpty);
      expect(pendingTurnStarts, hasLength(2));

      t.respond(pendingTurnStarts[1], {'turn': {'id': 'srv-2'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-co2', 'turn': {'id': 'srv-2', 'status': 'completed'}},
      });
      await pumpEventQueue();

      final t2Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 't2').toList();
      expect(t2Ended, hasLength(1));
      expect(t2Ended.single.interrupted, isFalse);
    });

    test('NEW-PROBE C (COMPACT-RESTART-1): restart() mid-flight after cancelled c1 resolves explicit cmp-1 does not poison new epoch', () async {
      final pendingTurnStarts = <Object?>[];
      final pendingCompactStarts = <Object?>[];
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-cr1'},
              });
            case 'turn/start':
              pendingTurnStarts.add(msg['id']);
            case 'thread/compact/start':
              pendingCompactStarts.add(msg['id']);
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't0', text: 'init'));
      await pumpEventQueue();
      t.respond(pendingTurnStarts[0], {'turn': {'id': 'srv-0'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-cr1', 'turn': {'id': 'srv-0', 'status': 'completed'}},
      });
      await pumpEventQueue();

      kernel.send(const KernelTurn(id: 'c1', text: '/compact'));
      await pumpEventQueue();
      expect(pendingCompactStarts, hasLength(1));

      // Cancel c1, resolve c1 synchronously with explicit cmp-1, then immediately restart()
      // in the same synchronous turn before c1's await compactCompleter.future resumes.
      kernel.cancel();
      t.respond(pendingCompactStarts[0], {'turn': {'id': 'cmp-1'}});
      kernel.restart();
      await pumpEventQueue();

      // New epoch compact reusing cmp-1 must complete cleanly without hanging.
      kernel.send(const KernelTurn(id: 'c2', text: '/compact'));
      await pumpEventQueue();
      expect(pendingCompactStarts, hasLength(2));
      t.respond(pendingCompactStarts[1], {'turn': {'id': 'cmp-1'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-cr1', 'turn': {'id': 'cmp-1', 'status': 'completed'}},
      });
      await pumpEventQueue();

      final c2Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 'c2').toList();
      expect(c2Ended, hasLength(1));
      expect(c2Ended.single.interrupted, isFalse);
    });

    test('NEW-PROBE C2 (COMPACT-RESTART-1): non-cancelled c1 resolves explicit cmp-1 right before restart() without poisoning new epoch', () async {
      final pendingTurnStarts = <Object?>[];
      final pendingCompactStarts = <Object?>[];
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-cr2'},
              });
            case 'turn/start':
              pendingTurnStarts.add(msg['id']);
            case 'thread/compact/start':
              pendingCompactStarts.add(msg['id']);
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't0', text: 'init'));
      await pumpEventQueue();
      t.respond(pendingTurnStarts[0], {'turn': {'id': 'srv-0'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-cr2', 'turn': {'id': 'srv-0', 'status': 'completed'}},
      });
      await pumpEventQueue();

      kernel.send(const KernelTurn(id: 'c1', text: '/compact'));
      await pumpEventQueue();
      expect(pendingCompactStarts, hasLength(1));

      // Non-cancelled c1 resolves explicit cmp-1 right before synchronous restart().
      t.respond(pendingCompactStarts[0], {'turn': {'id': 'cmp-1'}});
      kernel.restart();
      await pumpEventQueue();

      // New epoch compact reusing cmp-1 must NOT be poisoned by stale c1 microtask.
      kernel.send(const KernelTurn(id: 'c2', text: '/compact'));
      await pumpEventQueue();
      expect(pendingCompactStarts, hasLength(2));
      t.respond(pendingCompactStarts[1], {'turn': {'id': 'cmp-1'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-cr2', 'turn': {'id': 'cmp-1', 'status': 'completed'}},
      });
      await pumpEventQueue();

      final c2Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 'c2').toList();
      expect(c2Ended, hasLength(1));
      expect(c2Ended.single.interrupted, isFalse);
    });

    test('COMPACT-RESTART-1 (_start): t1 resolves turn/start right before restart() without poisoning or interrupting new epoch', () async {
      final pendingTurnStarts = <Object?>[];
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': 'thr-sr1'},
              });
            case 'turn/start':
              pendingTurnStarts.add(msg['id']);
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      kernel.send(const KernelTurn(id: 't0', text: 'init'));
      await pumpEventQueue();
      t.respond(pendingTurnStarts[0], {'turn': {'id': 'srv-0'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-sr1', 'turn': {'id': 'srv-0', 'status': 'completed'}},
      });
      await pumpEventQueue();

      kernel.send(const KernelTurn(id: 't1', text: 'in flight'));
      await pumpEventQueue();
      expect(pendingTurnStarts, hasLength(2));

      // t1 resolves turn-1 synchronously right before restart().
      t.respond(pendingTurnStarts[1], {'turn': {'id': 'turn-1'}});
      kernel.restart();
      await pumpEventQueue();

      // Must NOT have sent turn/interrupt for stale turn-1 on the new epoch.
      expect(t.written.where((m) => m['method'] == 'turn/interrupt'), isEmpty);

      // New epoch turn reusing turn-1 completes cleanly.
      kernel.send(const KernelTurn(id: 't2', text: 'reuses turn-1'));
      await pumpEventQueue();
      expect(pendingTurnStarts, hasLength(3));
      t.respond(pendingTurnStarts[2], {'turn': {'id': 'turn-1'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-sr1', 'turn': {'id': 'turn-1', 'status': 'completed'}},
      });
      await pumpEventQueue();

      final t2Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 't2').toList();
      expect(t2Ended, hasLength(1));
      expect(t2Ended.single.interrupted, isFalse);
    });

    test('NEW-PROBE B (COMPACT-THREADLESS-ORPHAN-1): c1 (/compact) cancelled by /new -> t2 creates thr-2 -> c2 (/compact) resolves {} -> c1 resolves cmp-1 with notifThreadId==null does not hijack c2', () async {
      var threadCount = 0;
      final pendingTurnStarts = <Object?>[];
      final pendingCompactStarts = <Object?>[];
      final t = _TestCodexTransport(
        onWrite: (tr, msg) {
          switch (msg['method']) {
            case 'thread/start':
              tr.respond(msg['id'], {
                'thread': {'id': ++threadCount == 1 ? 'thr-1' : 'thr-2'},
              });
            case 'turn/start':
              pendingTurnStarts.add(msg['id']);
            case 'thread/compact/start':
              pendingCompactStarts.add(msg['id']);
            default:
              if (msg['method'] != null) tr.respond(msg['id'], {});
          }
        },
      );

      final kernel = CodexKernel(MockKernels.codex, t, context: KernelContext(cwd: tempDir.path));
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      final sub = kernel.events.listen(events.add);
      addTearDown(sub.cancel);

      // Establish thr-1.
      kernel.send(const KernelTurn(id: 't0', text: 'init'));
      await pumpEventQueue();
      t.respond(pendingTurnStarts[0], {'turn': {'id': 'srv-0'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-1', 'turn': {'id': 'srv-0', 'status': 'completed'}},
      });
      await pumpEventQueue();

      // Start c1 (/compact on thr-1), then cancel via /new (now: true).
      kernel.send(const KernelTurn(id: 'c1', text: '/compact'));
      await pumpEventQueue();
      expect(pendingCompactStarts, hasLength(1));

      kernel.send(const KernelTurn(id: 't-new', text: '/new', now: true));
      await pumpEventQueue();
      expect(kernel.sessionId, isNull);

      // t2 creates thr-2 and completes.
      kernel.send(const KernelTurn(id: 't2', text: 'new thread'));
      await pumpEventQueue();
      expect(kernel.sessionId, 'thr-2');
      t.respond(pendingTurnStarts[1], {'turn': {'id': 'srv-2'}});
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-2', 'turn': {'id': 'srv-2', 'status': 'completed'}},
      });
      await pumpEventQueue();

      // Start c2 (/compact on thr-2), which resolves {} and enters Duration.zero.
      kernel.send(const KernelTurn(id: 'c2', text: '/compact'));
      await pumpEventQueue();
      expect(pendingCompactStarts, hasLength(2));
      t.respond(pendingCompactStarts[1], {});
      // Let c2's compactCompleter.future resume and set _compactingTurnClientId = 'c2',
      // before Duration.zero fires.
      await Future<void>.value();

      // Old-thread c1 resolves explicit cmp-1 and pushes threadless turn/started + turn/completed.
      t.respond(pendingCompactStarts[0], {'turn': {'id': 'cmp-1'}});
      t.push({
        'method': 'turn/started',
        'params': {'turn': {'id': 'cmp-1'}},
      });
      t.push({
        'method': 'turn/completed',
        'params': {'turn': {'id': 'cmp-1', 'status': 'completed'}},
      });

      // c2 must NOT have been hijacked by c1's threadless cmp-1!
      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 'c2'), isEmpty);

      // c2 binds its own srv-compact-2 and finishes cleanly.
      t.push({
        'method': 'turn/started',
        'params': {'threadId': 'thr-2', 'turn': {'id': 'srv-compact-2'}},
      });
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 'c2'), isEmpty);

      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-2', 'turn': {'id': 'srv-compact-2', 'status': 'completed'}},
      });
      await pumpEventQueue();
      final c2Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 'c2').toList();
      expect(c2Ended, hasLength(1));
      expect(c2Ended.single.interrupted, isFalse);

      // Verify thr-2 subsequent turn t3 reusing 'cmp-1' is not poisoned in _earlyCompletedServerTurns.
      kernel.send(const KernelTurn(id: 't3', text: 'reuses cmp-1'));
      await pumpEventQueue();
      expect(pendingTurnStarts, hasLength(3));
      t.respond(pendingTurnStarts[2], {'turn': {'id': 'cmp-1'}});
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>().where((e) => e.turnId == 't3'), isEmpty);
      t.push({
        'method': 'turn/completed',
        'params': {'threadId': 'thr-2', 'turn': {'id': 'cmp-1', 'status': 'completed'}},
      });
      await pumpEventQueue();
      final t3Ended = events.whereType<TurnEnded>().where((e) => e.turnId == 't3').toList();
      expect(t3Ended, hasLength(1));
      expect(t3Ended.single.interrupted, isFalse);
    });
  });

  group('CodexKernel dynamic ExtensionSwitches and AyteSdkMcpBridge parity', () {
    test(
      'dynamic ExtensionSwitches.changes disables raw and normalized non-alphanumeric tools on sdkBridgeForTesting',
      () async {
        const dottedTool = 'cdx_probe.dotted-tool';
        var dottedRuns = 0;
        ClaudeSdkTools.register(
          ClaudeSdkTool(
            name: dottedTool,
            description: 'Codex dotted probe tool',
            inputSchema: const {'type': 'object'},
            run: (input, call) async {
              dottedRuns++;
              return 'cdx-dotted-ok';
            },
          ),
        );
        addTearDown(() => ClaudeSdkTools.unregister(dottedTool));

        final prevCurrent = ExtensionSwitches.current;
        final prevChanges = ExtensionSwitches.changes;
        var currentSwitches = ExtensionSwitches.none;
        final changes = ChangeNotifier();
        ExtensionSwitches.current = () => currentSwitches;
        ExtensionSwitches.changes = changes;
        addTearDown(() {
          ExtensionSwitches.current = prevCurrent;
          ExtensionSwitches.changes = prevChanges;
          changes.dispose();
        });

        final t = _TestCodexTransport();
        final kernel = CodexKernel(
          MockKernels.codex,
          t,
          context: KernelContext(cwd: tempDir.path),
          enableSdkMcpBridge: true,
        );
        addTearDown(kernel.dispose);

        kernel.prepare();
        for (var i = 0; i < 100 && kernel.health.status != KernelHealthStatus.ready; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(kernel.health.status, KernelHealthStatus.ready);
        final bridge = kernel.sdkBridgeForTesting!;

        final client = _RealHttpOverrides().newRealClient();
        addTearDown(() => client.close(force: true));

        Future<List<String>> listTools() async {
          final req = await client.postUrl(bridge.endpointUri);
          req.headers.set('Authorization', 'Bearer ${bridge.token}');
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}));
          final res = await req.close();
          final body = jsonDecode(await utf8.decoder.bind(res).join()) as Map;
          return (((body['result'] as Map)['tools'] as List).cast<Map>())
              .map((m) => m['name'] as String)
              .toList();
        }

        Future<Map<String, Object?>> callDotted() async {
          final req = await client.postUrl(bridge.endpointUri);
          req.headers.set('Authorization', 'Bearer ${bridge.token}');
          req.headers.contentType = ContentType.json;
          req.write(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 2,
              'method': 'tools/call',
              'params': {'name': dottedTool, 'arguments': const <String, Object?>{}},
            }),
          );
          final res = await req.close();
          return (jsonDecode(await utf8.decoder.bind(res).join()) as Map)
              .cast<String, Object?>();
        }

        // Enabled initially.
        expect(await listTools(), contains(dottedTool));
        expect(((await callDotted())['result'] as Map)['isError'], isNot(isTrue));
        expect(dottedRuns, 1);

        // Disable by raw name via ExtensionSwitches.changes.
        currentSwitches = const ExtensionSwitches(
          disabledTools: {ClaudeSdkTools.server: {dottedTool}},
        );
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        changes.notifyListeners();
        expect(await listTools(), isNot(contains(dottedTool)));
        expect(((await callDotted())['result'] as Map)['isError'], isTrue);
        expect(dottedRuns, 1);

        // Re-enable.
        currentSwitches = ExtensionSwitches.none;
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        changes.notifyListeners();
        expect(await listTools(), contains(dottedTool));
        expect(((await callDotted())['result'] as Map)['isError'], isNot(isTrue));
        expect(dottedRuns, 2);

        // Disable by normalized name (e.g. UsageBreakdown) via ExtensionSwitches.changes.
        currentSwitches = const ExtensionSwitches(
          disabledTools: {ClaudeSdkTools.server: {'cdx_probe_dotted-tool'}},
        );
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        changes.notifyListeners();
        expect(await listTools(), isNot(contains(dottedTool)));
        expect(((await callDotted())['result'] as Map)['isError'], isTrue);
        expect(dottedRuns, 2);
      },
    );

    test(
      'dynamic baocode server flip while initialized emits config/value/write + reload, and setMcpServerEnabled persists via save',
      () async {
        const probeTool = 'cdx_server_flip_probe_tool';
        ClaudeSdkTools.register(
          ClaudeSdkTool(
            name: probeTool,
            description: 'Server flip probe tool',
            inputSchema: const {'type': 'object'},
            run: (input, call) async => 'ok',
          ),
        );
        addTearDown(() => ClaudeSdkTools.unregister(probeTool));

        final prevCurrent = ExtensionSwitches.current;
        final prevChanges = ExtensionSwitches.changes;
        final prevSave = ExtensionSwitches.save;
        var currentSwitches = const ExtensionSwitches(
          disabledServers: {ClaudeSdkTools.server},
        );
        final changes = ChangeNotifier();
        final savedHistory = <ExtensionSwitches>[];
        ExtensionSwitches.current = () => currentSwitches;
        ExtensionSwitches.changes = changes;
        ExtensionSwitches.save = (sw) async {
          savedHistory.add(sw);
          currentSwitches = sw;
        };
        addTearDown(() {
          ExtensionSwitches.current = prevCurrent;
          ExtensionSwitches.changes = prevChanges;
          ExtensionSwitches.save = prevSave;
          changes.dispose();
        });

        final t = _TestCodexTransport();
        final kernel = CodexKernel(
          MockKernels.codex,
          t,
          context: KernelContext(cwd: tempDir.path),
          enableSdkMcpBridge: true,
        );
        addTearDown(kernel.dispose);

        kernel.prepare();
        for (var i = 0; i < 100 && kernel.health.status != KernelHealthStatus.ready; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(kernel.health.status, KernelHealthStatus.ready);
        final bridge = kernel.sdkBridgeForTesting!;

        final client = _RealHttpOverrides().newRealClient();
        addTearDown(() => client.close(force: true));

        Future<List<Object?>> listTools() async {
          final req = await client.postUrl(bridge.endpointUri);
          req.headers.set('Authorization', 'Bearer ${bridge.token}');
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}));
          final res = await req.close();
          final body = jsonDecode(await utf8.decoder.bind(res).join()) as Map;
          return (body['result'] as Map)['tools'] as List;
        }

        expect(await listTools(), isEmpty);

        // Flip baocode server to enabled dynamically while initialized.
        t.written.clear();
        currentSwitches = ExtensionSwitches.none;
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        changes.notifyListeners();
        await pumpEventQueue();

        final methods = t.written.map((m) => m['method']).toList();
        expect(methods, containsAllInOrder([
          'config/value/write',
          'config/mcpServer/reload',
          'mcpServerStatus/list',
        ]));
        final writeMsg = t.written.firstWhere((m) => m['method'] == 'config/value/write');
        expect((writeMsg['params'] as Map)['keyPath'], 'mcp_servers.baocode.enabled');
        expect((writeMsg['params'] as Map)['value'], isTrue);
        expect(await listTools(), isNotEmpty);

        // setMcpServerEnabled('baocode', false) persists via ExtensionSwitches.save so
        // later unrelated ExtensionSwitches.changes does not re-enable baocode.
        t.written.clear();
        kernel.setMcpServerEnabled(ClaudeSdkTools.server, false);
        await pumpEventQueue();
        expect(savedHistory, isNotEmpty);
        expect(savedHistory.last.serverEnabled(ClaudeSdkTools.server), isFalse);
        expect(await listTools(), isEmpty);

        t.written.clear();
        currentSwitches = currentSwitches.withSkills(const {'unrelated-skill'}, false);
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        changes.notifyListeners();
        await pumpEventQueue();
        expect(await listTools(), isEmpty);
        expect(
          t.written.where((m) => m['method'] == 'config/value/write'),
          isEmpty,
        );
      },
    );

    test(
      'ExtensionSwitches.changes firing while prepare() / AyteSdkMcpBridge.start is in flight syncs onto newly bound bridge',
      () async {
        const probeTool = 'cdx_bridge_race_probe_tool';
        ClaudeSdkTools.register(
          ClaudeSdkTool(
            name: probeTool,
            description: 'Bridge race probe tool',
            inputSchema: const {'type': 'object'},
            run: (input, call) async => 'ok',
          ),
        );
        addTearDown(() => ClaudeSdkTools.unregister(probeTool));

        final prevCurrent = ExtensionSwitches.current;
        final prevChanges = ExtensionSwitches.changes;
        var currentSwitches = ExtensionSwitches.none;
        final changes = ChangeNotifier();
        ExtensionSwitches.current = () => currentSwitches;
        ExtensionSwitches.changes = changes;
        addTearDown(() {
          ExtensionSwitches.current = prevCurrent;
          ExtensionSwitches.changes = prevChanges;
          changes.dispose();
        });

        final t = _TestCodexTransport();
        final kernel = CodexKernel(
          MockKernels.codex,
          t,
          context: KernelContext(cwd: tempDir.path),
          enableSdkMcpBridge: true,
        );
        addTearDown(kernel.dispose);

        kernel.prepare();
        // Notify synchronously while AyteSdkMcpBridge.start is still awaiting bind.
        currentSwitches = const ExtensionSwitches(
          disabledServers: {ClaudeSdkTools.server},
        );
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        changes.notifyListeners();

        for (var i = 0; i < 100 && kernel.health.status != KernelHealthStatus.ready; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(kernel.health.status, KernelHealthStatus.ready);
        final bridge = kernel.sdkBridgeForTesting!;

        final client = _RealHttpOverrides().newRealClient();
        addTearDown(() => client.close(force: true));
        final req = await client.postUrl(bridge.endpointUri);
        req.headers.set('Authorization', 'Bearer ${bridge.token}');
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}));
        final res = await req.close();
        final body = jsonDecode(await utf8.decoder.bind(res).join()) as Map;
        expect((body['result'] as Map)['tools'], isEmpty);
      },
    );

    test(
      '_buildProcessArgs wires codexMcpOverrides for non-baocode servers with TOML key quoting',
      () async {
        final prevCurrent = ExtensionSwitches.current;
        ExtensionSwitches.current = () => const ExtensionSwitches(
          disabledServers: {'docs', 'claude.ai Docs', ClaudeSdkTools.server},
        );
        addTearDown(() => ExtensionSwitches.current = prevCurrent);

        final pt = ProcessCodexTransport(cwd: tempDir.path);
        final kernel = CodexKernel(
          MockKernels.codex,
          pt,
          context: KernelContext(cwd: tempDir.path),
          enableSdkMcpBridge: true,
        );
        addTearDown(() async {
          kernel.dispose();
          await kernel.stopped;
        });

        final args = pt.extraArgsBuilder!();
        expect(
          args,
          containsAllInOrder([
            '-c',
            'mcp_servers."claude.ai Docs".enabled=false',
            '-c',
            'mcp_servers.docs.enabled=false',
          ]),
        );
        expect(
          args.where((a) => a.startsWith('mcp_servers.baocode.enabled=')),
          isEmpty,
        );
      },
    );
  });
}
