import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/codex/codex_catalog.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_process_transport.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/extension_switches.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/e2e_env.dart';
import 'helpers/e2e_waiters.dart';
import 'helpers/fake_cli_harness.dart';
import 'helpers/mcp_http_probe.dart';

typedef _CodexRpcResponder =
    Map<String, Object?>? Function(
      _ScriptedCodexParityTransport transport,
      Map<String, Object?> msg,
    );

class _ScriptedCodexParityTransport implements CodexTransport {
  _ScriptedCodexParityTransport({
    this.onRequest,
    this.autoCompleteTurns = true,
  });

  final _CodexRpcResponder? onRequest;
  final bool autoCompleteTurns;
  final StreamController<Map<String, Object?>> _messages =
      StreamController<Map<String, Object?>>.broadcast();
  final List<Map<String, Object?>> written = [];
  bool closed = false;
  int _turnSeq = 0;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  void emit(Map<String, Object?> msg) {
    if (!closed && !_messages.isClosed) {
      _messages.add(msg);
    }
  }

  void completeTurn(String turnId, {String text = 'DONE', bool interrupted = false}) {
    if (!interrupted && text.isNotEmpty) {
      emit({
        'method': 'item/completed',
        'params': {
          'item': {
            'id': 'msg-$turnId',
            'type': 'agentMessage',
            'text': text,
          },
        },
      });
    }
    emit({
      'method': 'turn/completed',
      'params': {
        'turn': {
          'id': turnId,
          'status': interrupted ? 'interrupted' : 'completed',
        },
      },
    });
  }

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    final method = message['method'] as String?;
    if (method == null) return; // Client response to server request.
    final id = message['id'];

    final custom = onRequest?.call(this, message);
    if (custom != null) {
      if (custom['__defer'] == true) return;
      if (custom.containsKey('error')) {
        emit({'id': id, 'error': custom['error']});
      } else {
        emit({'id': id, 'result': custom});
      }
      return;
    }

    switch (method) {
      case 'initialize':
        emit({'id': id, 'result': const <String, Object?>{}});
      case 'thread/start':
        emit({
          'id': id,
          'result': {
            'thread': {'id': 'th-main'},
          },
        });
      case 'thread/resume':
        emit({
          'id': id,
          'result': {
            'thread': {'id': (message['params'] as Map?)?['threadId'] ?? 'th-main', 'turns': const []},
          },
        });
      case 'turn/start':
        final turnId = 'srv-turn-${++_turnSeq}';
        emit({
          'id': id,
          'result': {
            'turn': {'id': turnId},
          },
        });
        scheduleMicrotask(() {
          emit({
            'method': 'turn/started',
            'params': {
              'turn': {'id': turnId},
            },
          });
          if (autoCompleteTurns) {
            completeTurn(turnId);
          }
        });
      case 'turn/interrupt':
        emit({'id': id, 'result': const <String, Object?>{}});
      default:
        emit({'id': id, 'result': const <String, Object?>{}});
    }
  }

  @override
  void close() {
    if (closed) return;
    closed = true;
    unawaited(_messages.close());
  }
}

void _writeRolloutFile(
  File file, {
  required String sessionId,
  required String cwd,
  required int turnCount,
  bool includeRichFirstTurn = false,
}) {
  file.parent.createSync(recursive: true);
  final lines = <String>[
    jsonEncode({
      'type': 'session_meta',
      'timestamp': '2026-11-22T08:00:00Z',
      'payload': {'id': sessionId, 'cwd': cwd},
    }),
    jsonEncode({
      'type': 'turn_context',
      'payload': {'model': 'gpt-5.4', 'effort': 'high', 'cwd': cwd},
    }),
  ];
  for (var i = 0; i < turnCount; i++) {
    final ts = DateTime.utc(2026, 11, 22, 8, 1, i).toIso8601String();
    lines.add(
      jsonEncode({
        'type': 'event_msg',
        'timestamp': ts,
        'payload': {'type': 'user_message', 'message': 'Prompt turn $i'},
      }),
    );
    if (includeRichFirstTurn && i == 0) {
      lines.add(
        jsonEncode({
          'type': 'event_msg',
          'timestamp': ts,
          'payload': {'type': 'agent_reasoning', 'text': 'Thinking step 0'},
        }),
      );
      lines.add(
        jsonEncode({
          'type': 'response_item',
          'timestamp': ts,
          'payload': {
            'type': 'local_shell_call',
            'call_id': 'cmd-0',
            'action': {'command': ['echo', 'hi']},
          },
        }),
      );
      lines.add(
        jsonEncode({
          'type': 'response_item',
          'timestamp': ts,
          'payload': {
            'type': 'local_shell_call_output',
            'call_id': 'cmd-0',
            'output': 'hi',
          },
        }),
      );
      lines.add(
        jsonEncode({
          'type': 'event_msg',
          'timestamp': ts,
          'payload': {'type': 'context_compacted'},
        }),
      );
    }
    lines.add(
      jsonEncode({
        'type': 'event_msg',
        'timestamp': ts,
        'payload': {'type': 'agent_message', 'message': 'Answer turn $i'},
      }),
    );
  }
  file.writeAsStringSync('${lines.join('\n')}\n');
}

const _fakeCodexBridgeBody = r'''
Future<void> main(List<String> args) async {
  recordEvent({'type': 'launch', 'args': args});

  String? mcpUrl;
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '-c' && args[i + 1].startsWith('mcp_servers.baocode.url=')) {
      var raw = args[i + 1].substring('mcp_servers.baocode.url='.length);
      if (raw.startsWith('"') && raw.endsWith('"') && raw.length >= 2) {
        raw = raw.substring(1, raw.length - 1);
      }
      mcpUrl = raw;
    }
  }

  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final msg = (jsonDecode(line) as Map).cast<String, Object?>();
    final id = msg['id'];
    final method = msg['method'] as String?;
    if (method == 'initialize') {
      stdout.writeln(jsonEncode({'id': id, 'result': <String, Object?>{}}));
    } else if (method == 'thread/start') {
      stdout.writeln(jsonEncode({
        'id': id,
        'result': {'thread': {'id': 'codex-bridge-thread-1'}},
      }));
    } else if (method == 'turn/start') {
      stdout.writeln(jsonEncode({
        'id': id,
        'result': {'turn': {'id': 't-bridge-1'}},
      }));
      stdout.writeln(jsonEncode({
        'method': 'turn/started',
        'params': {'turn': {'id': 't-bridge-1'}},
      }));
      await stdout.flush();

      if (mcpUrl != null) {
        final client = HttpClient()..findProxy = (_) => 'DIRECT';
        Future<Map<String, Object?>> callRpc(Map<String, Object?> payload) async {
          final req = await client.postUrl(Uri.parse(mcpUrl!));
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(payload));
          final resp = await req.close();
          final body = await utf8.decoder.bind(resp).join();
          return {'status': resp.statusCode, 'body': jsonDecode(body)};
        }

        final initRes = await callRpc({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': {'protocolVersion': '2024-11-05'},
        });
        final toolRes = await callRpc({
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'tools/call',
          'params': {
            'name': 'echo_e2e',
            'arguments': {'msg': 'from-codex'},
          },
        });
        client.close(force: true);
        recordEvent({'type': 'mcp_probe', 'init': initRes, 'tool': toolRes});
      }

      stdout.writeln(jsonEncode({
        'method': 'item/completed',
        'params': {
          'item': {
            'id': 'msg-bridge',
            'type': 'agentMessage',
            'text': 'BRIDGE_OK',
          },
        },
      }));
      stdout.writeln(jsonEncode({
        'method': 'turn/completed',
        'params': {'turn': {'id': 't-bridge-1', 'status': 'completed'}},
      }));
    } else if (id != null) {
      stdout.writeln(jsonEncode({'id': id, 'result': <String, Object?>{}}));
    }
    await stdout.flush();
  }
}
''';

void main() {
  late E2eSandbox sandbox;
  late String codexHome;

  setUp(() {
    sandbox = E2eSandbox.create(realHttp: true);
    codexHome = p.join(sandbox.homeDir.path, '.codex');
    sandbox.onDispose(ProcessCodexTransport.stopAll);
  });

  group('F8 Tier 1 — CodexKernel Catalog, History, Fork, MCP Bridge & Facets', () {
    test(
      'F8-T1-01: CodexKernel sessionId, LoadsHistory pagination & thread/resume fallback',
      () async {
        final rolloutFile = File(
          p.join(
            codexHome,
            'sessions',
            '2026',
            '11',
            '22',
            'rollout-2026-11-22T08-00-00-thread-hist-1.jsonl',
          ),
        );
        _writeRolloutFile(
          rolloutFile,
          sessionId: 'thread-hist-1',
          cwd: sandbox.projectDir.path,
          turnCount: 14,
          includeRichFirstTurn: true,
        );

        final t1 = _ScriptedCodexParityTransport();
        final k1 = CodexKernel(
          KernelRegistry.codex,
          t1,
          context: KernelContext(
            cwd: sandbox.projectDir.path,
            resume: SessionRecord(
              id: 'thread-hist-1',
              title: 'Hist',
              updatedAt: DateTime.utc(2026, 11, 22, 8),
              cwd: sandbox.projectDir.path,
              path: rolloutFile.path,
            ),
          ),
          catalog: CodexCatalog(codexHome: codexHome),
        );
        sandbox.onDispose(k1.dispose);
        expect(k1.sessionId, 'thread-hist-1');

        final events1 = <KernelEvent>[];
        final sub1 = k1.events.listen(events1.add);
        sandbox.onDispose(sub1.cancel);

        await waitUntil(
          () => !k1.loadingHistory && k1.hasEarlierHistory,
          reason: 'Should finish initial 10-turn page load with earlier turns available',
        );
        final initialUsers = events1
            .whereType<ItemUpserted>()
            .map((e) => e.item)
            .whereType<UserMessageItem>()
            .map((u) => u.text)
            .toList();
        expect(initialUsers, hasLength(10));
        expect(initialUsers.first, 'Prompt turn 4');
        expect(initialUsers.last, 'Prompt turn 13');

        await k1.loadEarlier();
        await waitUntil(() => events1.whereType<HistoryPrepended>().isNotEmpty);
        final prepended = events1.whereType<HistoryPrepended>().last;
        final earlierUsers = prepended.items
            .map((e) => e.$2)
            .whereType<UserMessageItem>()
            .map((u) => u.text)
            .toList();
        expect(earlierUsers, [
          'Prompt turn 0',
          'Prompt turn 1',
          'Prompt turn 2',
          'Prompt turn 3',
        ]);
        expect(k1.hasEarlierHistory, isFalse);

        // Fallback to thread/resume RPC when path is null.
        final t2 = _ScriptedCodexParityTransport(
          onRequest: (_, msg) {
            if (msg['method'] == 'thread/resume') {
              return {
                'thread': {
                  'id': 'thread-rpc-1',
                  'turns': [
                    {
                      'items': [
                        {
                          'type': 'userMessage',
                          'id': 'u-rpc-1',
                          'content': [
                            {'type': 'text', 'text': 'From RPC resume'},
                          ],
                        },
                        {
                          'type': 'agentMessage',
                          'id': 'a-rpc-1',
                          'text': 'RPC answer',
                        },
                      ],
                    },
                  ],
                },
              };
            }
            return null;
          },
        );
        final k2 = CodexKernel(
          KernelRegistry.codex,
          t2,
          context: KernelContext(
            cwd: sandbox.projectDir.path,
            resume: SessionRecord(
              id: 'thread-rpc-1',
              title: 'RPC',
              updatedAt: DateTime.utc(2026, 11, 22, 8),
              cwd: sandbox.projectDir.path,
              path: null,
            ),
          ),
          catalog: CodexCatalog(codexHome: codexHome),
        );
        sandbox.onDispose(k2.dispose);
        final events2 = <KernelEvent>[];
        final sub2 = k2.events.listen(events2.add);
        sandbox.onDispose(sub2.cancel);

        await waitUntil(() => !k2.loadingHistory);
        expect(
          events2
              .whereType<ItemUpserted>()
              .map((e) => e.item)
              .whereType<UserMessageItem>()
              .any((u) => u.text == 'From RPC resume'),
          isTrue,
        );
      },
    );

    test(
      'F8-T1-02: ForksConversation & RenamesSession lifecycle including pre-init rename and external update',
      () async {
        final transport = _ScriptedCodexParityTransport(
          onRequest: (_, msg) {
            if (msg['method'] == 'thread/fork') {
              return {
                'thread': {
                  'id': 'th-forked-1',
                  'path': p.join(codexHome, 'sessions', 'rollout-th-forked-1.jsonl'),
                },
              };
            }
            return null;
          },
        );
        final kernel = CodexKernel(
          KernelRegistry.codex,
          transport,
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(codexHome: codexHome),
        );
        sandbox.onDispose(kernel.dispose);

        final events = <KernelEvent>[];
        final sub = kernel.events.listen(events.add);
        sandbox.onDispose(sub.cancel);

        expect(kernel.canFork, isFalse);
        kernel.rename('Renamed Pre-Init');

        kernel.send(const KernelTurn(id: 'u1', text: 'Turn 1'));
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 'u1'),
        );
        kernel.send(const KernelTurn(id: 'u2', text: 'Turn 2'));
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 'u2'),
        );

        expect(kernel.canFork, isTrue);
        expect(
          transport.written.any(
            (m) =>
                m['method'] == 'thread/name/set' &&
                (m['params'] as Map)['name'] == 'Renamed Pre-Init',
          ),
          isTrue,
        );

        final forked = await kernel.fork(before: 'u2', title: 'Branch A');
        expect(forked, isNotNull);
        expect(forked!.id, 'th-forked-1');
        expect(forked.title, 'Branch A');
        expect(
          transport.written.any(
            (m) =>
                m['method'] == 'thread/rollback' &&
                (m['params'] as Map)['threadId'] == 'th-forked-1' &&
                (m['params'] as Map)['numTurns'] == 1,
          ),
          isTrue,
        );
        expect(
          transport.written.any(
            (m) =>
                m['method'] == 'thread/name/set' &&
                (m['params'] as Map)['threadId'] == 'th-forked-1' &&
                (m['params'] as Map)['name'] == 'Branch A',
          ),
          isTrue,
        );

        // Echoed own rename should NOT emit SessionRenamed; external update SHOULD.
        transport.emit({
          'method': 'thread/name/updated',
          'params': {'threadId': 'th-main', 'threadName': 'Renamed Pre-Init'},
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(events.whereType<SessionRenamed>(), isEmpty);

        transport.emit({
          'method': 'thread/name/updated',
          'params': {'threadId': 'th-main', 'threadName': 'External Title'},
        });
        await waitUntil(() => events.whereType<SessionRenamed>().isNotEmpty);
        final renamed = events.whereType<SessionRenamed>().last;
        expect(renamed.title, 'External Title');
      },
    );

    test(
      'F8-T1-03: cwd, settings, KernelWorkspace instructions (ownPrompt vs developerInstructions), permission & mode',
      () async {
        final extraDir = p.join(sandbox.rootDir.path, 'extra_dir');

        final t1 = _ScriptedCodexParityTransport();
        final k1 = CodexKernel(
          KernelRegistry.codex,
          t1,
          context: KernelContext(
            cwd: sandbox.projectDir.path,
            settings: const {
              'permission': 'unless-trusted',
              'mode': 'agent',
              'effort': 'high',
            },
            workspace: () => KernelWorkspace(
              folders: [extraDir],
              instructions: 'BE CONCISE',
              ownPrompt: false,
            ),
          ),
          catalog: CodexCatalog(codexHome: codexHome),
        );
        sandbox.onDispose(k1.dispose);
        final e1 = <KernelEvent>[];
        final s1 = k1.events.listen(e1.add);
        sandbox.onDispose(s1.cancel);

        k1.send(const KernelTurn(id: 't1', text: 'Go'));
        await waitUntil(
          () => e1.whereType<TurnEnded>().any((e) => e.turnId == 't1'),
        );

        final ts1 = t1.written.firstWhere((m) => m['method'] == 'thread/start');
        final p1 = (ts1['params'] as Map).cast<String, Object?>();
        expect(p1['cwd'], sandbox.projectDir.path);
        expect(p1['approvalPolicy'], 'untrusted');
        expect(p1['sandbox'], 'workspace-write');
        expect(p1['developerInstructions'], contains('BE CONCISE'));
        expect(p1['developerInstructions'], contains(extraDir));
        expect(p1['baseInstructions'], isNull);

        final t2 = _ScriptedCodexParityTransport();
        final k2 = CodexKernel(
          KernelRegistry.codex,
          t2,
          context: KernelContext(
            cwd: sandbox.projectDir.path,
            settings: const {'mode': 'ask'},
            workspace: () => const KernelWorkspace(
              folders: [],
              instructions: 'CUSTOM BASE PROMPT',
              ownPrompt: true,
            ),
          ),
          catalog: CodexCatalog(codexHome: codexHome),
        );
        sandbox.onDispose(k2.dispose);
        final e2 = <KernelEvent>[];
        final s2 = k2.events.listen(e2.add);
        sandbox.onDispose(s2.cancel);

        k2.send(const KernelTurn(id: 't2', text: 'Ask'));
        await waitUntil(
          () => e2.whereType<TurnEnded>().any((e) => e.turnId == 't2'),
        );

        final ts2 = t2.written.firstWhere((m) => m['method'] == 'thread/start');
        final p2 = (ts2['params'] as Map).cast<String, Object?>();
        expect(p2['approvalPolicy'], 'never');
        expect(p2['sandbox'], 'read-only');
        expect(p2['baseInstructions'], contains('CUSTOM BASE PROMPT'));
        expect(p2['developerInstructions'], isNull);
      },
    );

    test(
      'F8-T1-04: AyteSdkMcpBridge loopback tool call from fake codex + <agent-message> parsing',
      () async {
        String? capturedCallerSessionId;
        sandbox.registerSdkTool(
          ClaudeSdkTool(
            name: 'echo_e2e',
            description: 'Echoes input and records sessionId',
            kind: ToolKind.other,
            inputSchema: const {
              'type': 'object',
              'properties': {
                'msg': {'type': 'string'},
              },
            },
            summary: (_, _) => 'Echo E2E',
            run: (input, call) async {
              capturedCallerSessionId = call.sessionId;
              return 'ECHO:${input['msg']}';
            },
          ),
        );

        final fakeBin = Directory(p.join(sandbox.rootDir.path, 'bridge_bin'));
        final fakeCodex = FakeCliExecutable.create(
          fakeBin,
          name: 'codex',
          dartBody: _fakeCodexBridgeBody,
        );

        final env = <String, String>{};
        for (final entry in sandbox.processEnv.entries) {
          if (entry.key.toLowerCase() == 'path') continue;
          env[entry.key] = entry.value;
        }
        env['PATH'] = fakeBin.path;
        sandbox.useClaudeEnvironment(env);

        final kernel = CodexKernel(
          KernelRegistry.codex,
          ProcessCodexTransport(cwd: sandbox.projectDir.path),
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(codexHome: codexHome),
          enableSdkMcpBridge: true,
        );
        sandbox.onDispose(kernel.dispose);

        final events = <KernelEvent>[];
        final sub = kernel.events.listen(events.add);
        sandbox.onDispose(sub.cancel);

        kernel.send(
          const KernelTurn(
            id: 't-agent-msg',
            text: '<agent-message from="Lead" thread="lead-1">Check build</agent-message>',
          ),
        );
        await waitUntil(
          () =>
              events.whereType<TurnEnded>().any((e) => e.turnId == 't-agent-msg'),
        );

        final launchArgs =
            (fakeCodex.firstLaunchCapture()!['args'] as List).cast<String>();
        expect(
          launchArgs.any((a) => a.startsWith('mcp_servers.baocode.url=')),
          isTrue,
        );
        expect(launchArgs, contains('mcp_servers.baocode.enabled=true'));
        expect(capturedCallerSessionId, 'codex-bridge-thread-1');

        final probe = fakeCodex.readCaptures().firstWhere(
          (c) => c['type'] == 'mcp_probe',
        );
        expect((probe['tool'] as Map)['status'], 200);
        expect(jsonEncode(probe['tool']), contains('ECHO:from-codex'));

        final userMsg = events
            .whereType<ItemUpserted>()
            .map((e) => e.item)
            .whereType<UserMessageItem>()
            .first;
        expect(userMsg.text, 'Check build');
        expect(userMsg.fromAgent, 'Lead');
        expect(userMsg.fromSession, 'lead-1');

        kernel.dispose();
        await kernel.stopped;
      },
    );

    test(
      'F8-T1-05: DiffPreview on item/fileChange/requestApproval & QuestionRequest on item/tool/requestUserInput',
      () async {
        late _ScriptedCodexParityTransport transport;
        transport = _ScriptedCodexParityTransport(
          autoCompleteTurns: false,
          onRequest: (tr, msg) {
            if (msg['method'] == 'turn/start') {
              final id = msg['id'];
              tr.emit({
                'id': id,
                'result': {
                  'turn': {'id': 't-int-1'},
                },
              });
              scheduleMicrotask(() {
                tr.emit({
                  'method': 'turn/started',
                  'params': {
                    'turn': {'id': 't-int-1'},
                  },
                });
                tr.emit({
                  'method': 'item/fileChange/patchUpdated',
                  'params': {
                    'itemId': 'fc-1',
                    'changes': [
                      {
                        'path': 'lib/app.dart',
                        'diff': '@@ -1,1 +1,1 @@\n-old\n+new',
                      },
                    ],
                  },
                });
                tr.emit({
                  'id': 101,
                  'method': 'item/fileChange/requestApproval',
                  'params': {'itemId': 'fc-1', 'reason': 'Edit app.dart'},
                });
              });
              return {'__defer': true};
            }
            return null;
          },
        );

        final kernel = CodexKernel(
          KernelRegistry.codex,
          transport,
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(codexHome: codexHome),
        );
        sandbox.onDispose(kernel.dispose);

        final events = <KernelEvent>[];
        final sub = kernel.events.listen(events.add);
        sandbox.onDispose(sub.cancel);

        kernel.send(const KernelTurn(id: 't1', text: 'Edit file'));
        await waitUntil(
          () => events
              .whereType<InteractionRequested>()
              .any((e) => e.request is ApprovalRequest),
        );
        final approvalEvt = events.whereType<InteractionRequested>().lastWhere(
          (e) => e.request is ApprovalRequest,
        );
        final approvalReq = approvalEvt.request as ApprovalRequest;
        expect(approvalReq.preview, isA<DiffPreview>());
        final diffPreview = approvalReq.preview as DiffPreview;
        expect(diffPreview.path, 'lib/app.dart');
        expect(diffPreview.lines, isNotEmpty);

        kernel.answer(
          approvalReq.id,
          const ApprovalAnswer(ApprovalDecision.allowAlways),
        );
        expect(
          transport.written.any(
            (m) =>
                m['id'] == 101 &&
                (m['result'] as Map)['decision'] == 'acceptForSession',
          ),
          isTrue,
        );

        transport.emit({
          'id': 102,
          'method': 'item/tool/requestUserInput',
          'params': {
            'questions': [
              {
                'id': 'q1',
                'header': 'Mode',
                'question': 'Pick option',
                'isMultiSelect': true,
                'options': [
                  {'label': 'Opt A', 'description': 'Desc A'},
                ],
              },
              {
                'id': 'q2',
                'header': 'Extra',
                'question': 'Custom note',
                'options': [],
              },
            ],
          },
        });
        await waitUntil(
          () => events
              .whereType<InteractionRequested>()
              .any((e) => e.request is QuestionRequest),
        );
        final questionEvt = events.whereType<InteractionRequested>().lastWhere(
          (e) => e.request is QuestionRequest,
        );
        final qReq = questionEvt.request as QuestionRequest;
        expect(qReq.questions, hasLength(2));
        expect(qReq.questions.first.allowMultiple, isTrue);

        kernel.answer(
          qReq.id,
          const QuestionAnswer([
            ['Opt A'],
            ['Custom'],
          ]),
        );
        final qReply = transport.written.firstWhere((m) => m['id'] == 102);
        expect(qReply['result'], {
          'answers': {
            'q1': {
              'answers': ['Opt A'],
            },
            'q2': {
              'answers': ['Custom'],
            },
          },
        });

        transport.completeTurn('t-int-1');
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 't1'),
        );
      },
    );

    test(
      'F8-T1-06: ManagesMcpServers, ReportsUsage, SuggestsFiles, /compact & /new commands',
      () async {
        final transport = _ScriptedCodexParityTransport(
          onRequest: (_, msg) => switch (msg['method']) {
            'mcpServerStatus/list' => {
              'data': [
                {
                  'name': 's1',
                  'runtimeStatus': 'connected',
                  'tools': ['ping'],
                },
              ],
            },
            'mcpServer/oauth/login' => {
              'authorizationUrl': 'https://example.com/oauth',
            },
            'account/rateLimits/read' => {
              'rateLimits': {
                'primary': {
                  'usedPercent': 25,
                  'windowDurationMins': 300,
                },
                'secondary': {
                  'usedPercent': 10,
                  'windowDurationMins': 10080,
                },
              },
            },
            'fuzzyFileSearch' => {
              'files': [
                {'relativePath': 'lib/main.dart'},
              ],
            },
            _ => null,
          },
        );
        final kernel = CodexKernel(
          KernelRegistry.codex,
          transport,
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(codexHome: codexHome),
        );
        sandbox.onDispose(kernel.dispose);

        final events = <KernelEvent>[];
        final sub = kernel.events.listen(events.add);
        sandbox.onDispose(sub.cancel);

        kernel.refreshMcpServers();
        await waitUntil(
          () => kernel.mcpServers?.any((s) => s.name == 's1') == true,
        );
        expect(kernel.mcpServers!.single.status, McpServerStatus.connected);

        kernel.setMcpServerEnabled('s1', false);
        expect(kernel.mcpServers!.single.status, McpServerStatus.disabled);
        kernel.reconnectMcpServer('s1');
        final oauthUri = await kernel.authenticateMcpServer('s1');
        expect(oauthUri, Uri.parse('https://example.com/oauth'));

        await kernel.refreshUsage();
        await waitUntil(() => events.whereType<StatsReported>().isNotEmpty);
        final stats = events.whereType<StatsReported>().last;
        expect(stats.stats.limits.map((w) => w.label), ['5h', '7d']);
        expect(kernel.accountLimits, hasLength(2));

        final files = await kernel.suggestFiles('main');
        expect(files.map((f) => f.path), ['lib/main.dart']);

        kernel.send(const KernelTurn(id: 't-init', text: 'Start thread'));
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 't-init'),
        );
        expect(kernel.sessionId, 'th-main');

        kernel.send(const KernelTurn(id: 't-cmp', text: '/compact'));
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 't-cmp'),
        );
        expect(
          transport.written.any((m) => m['method'] == 'thread/compact/start'),
          isTrue,
        );
        expect(
          events
              .whereType<ItemUpserted>()
              .map((e) => e.item)
              .whereType<NoticeItem>()
              .any((n) => n.kind == NoticeKind.compaction),
          isTrue,
        );

        kernel.send(const KernelTurn(id: 't-new', text: '/new'));
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 't-new'),
        );
        expect(kernel.sessionId, isNull);
        expect(
          events
              .whereType<ItemUpserted>()
              .map((e) => e.item)
              .whereType<NoticeItem>()
              .any((n) => n.text == 'Started a new chat'),
          isTrue,
        );
      },
    );

    test(
      'F8-T1-07: CodexCatalog projects(), Windows path normalization, sessionsIn(), noteSessionTitle, delete() & id guard',
      () async {
        expect(
          CodexCatalog.normalizeWindowsPath(r'\\?\C:\Work\Repo\'),
          r'C:\Work\Repo',
        );
        expect(
          CodexCatalog.normalizeWindowsPath(r'\\?\UNC\server\share\dir\'),
          r'\\server\share\dir',
        );

        final otherDir = Directory(p.join(sandbox.rootDir.path, 'codex_other_proj'))
          ..createSync(recursive: true);
        final rawPrimaryCwd = Platform.isWindows
            ? '\\\\?\\${sandbox.projectDir.path}\\'
            : sandbox.projectDir.path;

        final rollout1 = File(
          p.join(
            codexHome,
            'sessions',
            '2026',
            '11',
            '22',
            'rollout-2026-11-22T09-00-00-cat-sess-1.jsonl',
          ),
        );
        _writeRolloutFile(
          rollout1,
          sessionId: 'cat-sess-1',
          cwd: rawPrimaryCwd,
          turnCount: 1,
        );

        final rollout2 = File(
          p.join(
            codexHome,
            'sessions',
            '2026',
            '11',
            '22',
            'rollout-2026-11-22T09-05-00-cat-sess-2.jsonl',
          ),
        );
        _writeRolloutFile(
          rollout2,
          sessionId: 'cat-sess-2',
          cwd: otherDir.path,
          turnCount: 1,
        );

        final catalog = CodexCatalog(codexHome: codexHome);
        final projects = await catalog.projects();
        final expectedPrimary = CodexCatalog.normalizeWindowsPath(
          sandbox.projectDir.path,
        );
        final expectedOther = CodexCatalog.normalizeWindowsPath(otherDir.path);
        expect(
          projects.map((pr) => pr.path),
          containsAll([expectedPrimary, expectedOther]),
        );

        final primarySessions = await catalog.sessionsIn(
          Platform.isWindows
              ? '${sandbox.projectDir.path.replaceAll(r'\', '/')}/'
              : sandbox.projectDir.path,
        );
        expect(primarySessions.map((s) => s.id), ['cat-sess-1']);
        expect(primarySessions.single.title, 'Prompt turn 0');

        await catalog.noteSessionTitle('cat-sess-1', 'Custom Codex Title');
        expect(File(p.join(codexHome, 'session_index.jsonl')).existsSync(), isTrue);

        final reloadedSessions = await catalog.sessionsIn(sandbox.projectDir.path);
        expect(reloadedSessions.single.title, 'Custom Codex Title');

        await catalog.delete('cat-sess-1');
        expect(rollout1.existsSync(), isFalse);
        expect(await catalog.sessionsIn(sandbox.projectDir.path), isEmpty);

        await expectLater(
          () => catalog.delete('../escape'),
          throwsArgumentError,
        );
        await expectLater(
          () => catalog.delete('a/b'),
          throwsArgumentError,
        );
      },
    );
  });

  group('F8 Tier 2 — CodexKernel Protocol Safety, Queues, Fallbacks & Boundaries', () {
    test(
      'F8-T2-01: unknown server RPC returns -32601 error & approvesAll auto-approves requests',
      () async {
        final t1 = _ScriptedCodexParityTransport();
        final k1 = CodexKernel(
          KernelRegistry.codex,
          t1,
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(codexHome: codexHome),
        );
        sandbox.onDispose(k1.dispose);

        t1.emit({
          'id': 99,
          'method': 'item/unknown/customPrompt',
          'params': const <String, Object?>{},
        });
        await waitUntil(
          () => t1.written.any((m) => m['id'] == 99),
          reason: 'Should respond to unknown server request without hanging',
        );
        final errReply = t1.written.firstWhere((m) => m['id'] == 99);
        expect((errReply['error'] as Map)['code'], -32601);

        final t2 = _ScriptedCodexParityTransport();
        final k2 = CodexKernel(
          KernelRegistry.codex,
          t2,
          context: KernelContext(
            cwd: sandbox.projectDir.path,
            workspace: () => const KernelWorkspace(
              folders: [],
              approvesAll: true,
            ),
          ),
          catalog: CodexCatalog(codexHome: codexHome),
        );
        sandbox.onDispose(k2.dispose);
        final e2 = <KernelEvent>[];
        final s2 = k2.events.listen(e2.add);
        sandbox.onDispose(s2.cancel);

        t2.emit({
          'id': 201,
          'method': 'item/commandExecution/requestApproval',
          'params': {'command': 'echo hi'},
        });
        t2.emit({
          'id': 202,
          'method': 'item/tool/requestUserInput',
          'params': {
            'questions': [
              {'id': 'q1', 'question': 'Pick'},
            ],
          },
        });
        await waitUntil(
          () =>
              t2.written.any((m) => m['id'] == 201) &&
              t2.written.any((m) => m['id'] == 202),
        );
        expect(e2.whereType<InteractionRequested>(), isEmpty);
        expect(
          (t2.written.firstWhere((m) => m['id'] == 201)['result'] as Map)['decision'],
          'acceptForSession',
        );
        expect(
          t2.written.firstWhere((m) => m['id'] == 202)['result'],
          {'answers': const <String, Object?>{}},
        );
      },
    );

    test(
      'F8-T2-02: QueuesMessages moveQueued, cancelQueued, sendQueuedNow & duplicate turn-id guard',
      () async {
        final transport = _ScriptedCodexParityTransport(autoCompleteTurns: false);
        final kernel = CodexKernel(
          KernelRegistry.codex,
          transport,
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(codexHome: codexHome),
        );
        sandbox.onDispose(kernel.dispose);

        final events = <KernelEvent>[];
        final sub = kernel.events.listen(events.add);
        sandbox.onDispose(sub.cancel);

        kernel.send(const KernelTurn(id: 't1', text: 'First'));
        await waitUntil(
          () => transport.written.any((m) => m['method'] == 'turn/start'),
        );
        kernel.send(const KernelTurn(id: 't2', text: 'Second'));
        kernel.send(const KernelTurn(id: 't3', text: 'Third'));
        kernel.send(const KernelTurn(id: 't4', text: 'Fourth'));
        kernel.send(const KernelTurn(id: 't2', text: 'Duplicate ignored'));

        kernel.moveQueued('t4', 0);
        final reordered = events.whereType<QueueReordered>().last;
        expect(reordered.ids, ['t4', 't2', 't3']);

        expect(await kernel.cancelQueued('t1'), isFalse);
        expect(await kernel.cancelQueued('t3'), isTrue);
        expect(
          events.whereType<ItemRemoved>().any((e) => e.id == 't3'),
          isTrue,
        );

        kernel.sendQueuedNow('t2');
        final afterNow = events.whereType<QueueReordered>().last;
        expect(afterNow.ids, ['t2', 't4']);
        await waitUntil(
          () => events
              .whereType<TurnEnded>()
              .any((e) => e.turnId == 't1' && e.interrupted),
        );

        await waitUntil(
          () =>
              transport.written
                  .where((m) => m['method'] == 'turn/start')
                  .length ==
              2,
        );
        transport.completeTurn('srv-turn-2');
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 't2'),
        );
        transport.completeTurn('srv-turn-3');
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 't4'),
        );
      },
    );

    test(
      'F8-T2-03: pre-thread /compact, blank rename, un-forkable pre-turn & thread/fork RPC error',
      () async {
        final transport = _ScriptedCodexParityTransport(
          onRequest: (_, msg) {
            if (msg['method'] == 'thread/fork') {
              return {
                'error': {'code': -32000, 'message': 'Fork unsupported'},
              };
            }
            return null;
          },
        );
        final kernel = CodexKernel(
          KernelRegistry.codex,
          transport,
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(codexHome: codexHome),
        );
        sandbox.onDispose(kernel.dispose);

        final events = <KernelEvent>[];
        final sub = kernel.events.listen(events.add);
        sandbox.onDispose(sub.cancel);

        expect(await kernel.fork(title: 'Too Early'), isNull);
        kernel.rename('   ');
        kernel.send(const KernelTurn(id: 'c1', text: '/compact'));
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 'c1'),
        );
        expect(
          events
              .whereType<ItemUpserted>()
              .map((e) => e.item)
              .whereType<NoticeItem>()
              .any((n) => n.text == 'Nothing to compact yet.'),
          isTrue,
        );
        expect(transport.written, isEmpty);

        kernel.send(const KernelTurn(id: 't1', text: 'Init thread'));
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 't1'),
        );

        expect(await kernel.fork(title: 'Fail'), isNull);
        expect(
          events
              .whereType<ItemUpserted>()
              .map((e) => e.item)
              .whereType<NoticeItem>()
              .any((n) => n.kind == NoticeKind.error && n.text.contains('Fork unsupported')),
          isTrue,
        );
      },
    );

    test(
      'F8-T2-04: SuggestsFiles falls back to local filesystem walk offline and skips ignored dirs',
      () async {
        File(p.join(sandbox.projectDir.path, 'lib', 'app.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('void main() {}');
        File(p.join(sandbox.projectDir.path, '.git', 'HEAD'))
          ..createSync(recursive: true)
          ..writeAsStringSync('ref: refs/heads/main');
        File(p.join(sandbox.projectDir.path, '.dart_tool', 'cache.txt'))
          ..createSync(recursive: true)
          ..writeAsStringSync('cache');
        File(p.join(sandbox.projectDir.path, 'node_modules', 'pkg', 'index.js'))
          ..createSync(recursive: true)
          ..writeAsStringSync('module.exports = {};');

        final kernel = CodexKernel(
          KernelRegistry.codex,
          _ScriptedCodexParityTransport(),
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(codexHome: codexHome),
        );
        sandbox.onDispose(kernel.dispose);

        final matched = (await kernel.suggestFiles('app'))
            .map((s) => s.path)
            .toList();
        expect(matched, contains('lib/app.dart'));

        final all = (await kernel.suggestFiles('')).map((s) => s.path).toList();
        expect(all.any((s) => s.contains('.git')), isFalse);
        expect(all.any((s) => s.contains('.dart_tool')), isFalse);
        expect(all.any((s) => s.contains('node_modules')), isFalse);
      },
    );

    test(
      'F8-T2-05: ExtensionSwitches dynamically disables baocode tool & server on live bridge',
      () async {
        final switchesNotifier = ValueNotifier<int>(0);
        sandbox.onDispose(switchesNotifier.dispose);
        var currentSwitches = ExtensionSwitches.none;
        ExtensionSwitches.current = () => currentSwitches;
        ExtensionSwitches.changes = switchesNotifier;

        sandbox.registerSdkTool(
          ClaudeSdkTool(
            name: 'echo_e2e',
            description: 'Echo',
            kind: ToolKind.other,
            inputSchema: const {'type': 'object', 'properties': <String, Object?>{}},
            summary: (_, _) => 'Echo',
            run: (_, _) async => 'OK_ECHO',
          ),
        );

        final transport = _ScriptedCodexParityTransport();
        final kernel = CodexKernel(
          KernelRegistry.codex,
          transport,
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(codexHome: codexHome),
          enableSdkMcpBridge: true,
        );
        sandbox.onDispose(kernel.dispose);

        final events = <KernelEvent>[];
        final sub = kernel.events.listen(events.add);
        sandbox.onDispose(sub.cancel);

        kernel.prepare();
        await waitUntil(() => kernel.sdkBridgeForTesting != null);
        final bridge = kernel.sdkBridgeForTesting!;
        final probe = McpHttpProbe(
          Uri.parse('http://127.0.0.1:${bridge.port}/mcp/${bridge.token}'),
        );

        final res1 = await probe.toolsCall('echo_e2e');
        expect(res1.statusCode, 200);
        expect(res1.body, contains('OK_ECHO'));

        currentSwitches = currentSwitches.withTool('baocode', 'echo_e2e', false);
        switchesNotifier.value++;
        final res2 = await probe.toolsCall('echo_e2e');
        expect(
          res2.body.contains('disabled') || res2.body.contains('isError'),
          isTrue,
        );

        kernel.setMcpServerEnabled('baocode', false);
        final listAfterDisable = await probe.toolsList();
        expect(listAfterDisable.statusCode, 200);
        expect(
          (listAfterDisable.json?['result'] as Map)['tools'],
          isEmpty,
        );
        final res3 = await probe.toolsCall('echo_e2e');
        expect(res3.statusCode, 200);
        expect((res3.json?['result'] as Map)['isError'], isTrue);
        expect(res3.body, contains('disabled'));
        await waitUntil(
          () =>
              transport.written.any((m) => m['method'] == 'config/value/write') &&
              transport.written.any(
                (m) => m['method'] == 'config/mcpServer/reload',
              ),
        );
      },
    );

    test(
      'F8-T2-06: loadEarlier() concurrent deduplication & .zst rollout fallback to thread/resume',
      () async {
        final rolloutFile = File(
          p.join(codexHome, 'sessions', 'rollout-th-dedup.jsonl'),
        );
        _writeRolloutFile(
          rolloutFile,
          sessionId: 'th-dedup',
          cwd: sandbox.projectDir.path,
          turnCount: 25,
        );

        final t1 = _ScriptedCodexParityTransport();
        final k1 = CodexKernel(
          KernelRegistry.codex,
          t1,
          context: KernelContext(
            cwd: sandbox.projectDir.path,
            resume: SessionRecord(
              id: 'th-dedup',
              title: 'Dedup',
              updatedAt: DateTime.utc(2026, 11, 22, 8),
              cwd: sandbox.projectDir.path,
              path: rolloutFile.path,
            ),
          ),
          catalog: CodexCatalog(codexHome: codexHome),
        );
        sandbox.onDispose(k1.dispose);
        final e1 = <KernelEvent>[];
        final s1 = k1.events.listen(e1.add);
        sandbox.onDispose(s1.cancel);

        await waitUntil(() => !k1.loadingHistory && k1.hasEarlierHistory);
        await Future.wait([k1.loadEarlier(), k1.loadEarlier()]);
        expect(e1.whereType<HistoryPrepended>(), hasLength(1));

        // .zst compressed rollout path falls back cleanly to thread/resume RPC
        final t2 = _ScriptedCodexParityTransport();
        final k2 = CodexKernel(
          KernelRegistry.codex,
          t2,
          context: KernelContext(
            cwd: sandbox.projectDir.path,
            resume: SessionRecord(
              id: 'th-zst',
              title: 'Compressed',
              updatedAt: DateTime.utc(2026, 11, 22, 8),
              cwd: sandbox.projectDir.path,
              path: p.join(codexHome, 'sessions', 'rollout-th-zst.jsonl.zst'),
            ),
          ),
          catalog: CodexCatalog(codexHome: codexHome),
        );
        sandbox.onDispose(k2.dispose);
        await waitUntil(() => !k2.loadingHistory);
        expect(
          t2.written.any((m) => m['method'] == 'thread/resume'),
          isTrue,
        );
      },
    );
  });
}
