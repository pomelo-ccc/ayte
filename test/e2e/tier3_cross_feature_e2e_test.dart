import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/bao_agent.dart' show AgentPaths;
import 'package:baocode/acp/acp_agent_service.dart';
import 'package:baocode/acp/ayte_ipc_server.dart';
import 'package:baocode/automations/automation_service.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store_io.dart';
import 'package:baocode/chat/session_links.dart';
import 'package:baocode/customize/customization_store.dart';
import 'package:baocode/customize/customizations.dart';
import 'package:baocode/debug/common/debug_storage.dart';
import 'package:baocode/debug/common/debug_types.dart';
import 'package:baocode/debug/common/repl_model.dart';
import 'package:baocode/debug/service/debug_configuration_manager.dart';
import 'package:baocode/debug/service/debug_host.dart';
import 'package:baocode/debug/service/debug_service.dart';
import 'package:baocode/debug/service/debugger.dart';
import 'package:baocode/debug/session/debug_adapter.dart';
import 'package:baocode/debug/session/debug_session.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/antigravity/antigravity_cli.dart';
import 'package:baocode/kernel/antigravity/antigravity_transport.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/claude_code/claude_storage_io.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_accounts.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_cli.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_transport.dart';
import 'package:baocode/kernel/codex/codex_catalog.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_process_transport.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/extension_switches.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/main.dart';
import 'package:baocode/remote/remote_claude.dart';
import 'package:baocode/search/claude_conversation_search.dart';
import 'package:baocode/settings/app_locale.dart';
import 'package:baocode/sidebar/sidebar.dart';
import 'package:baocode/tasks/task_queue_service.dart';
import 'package:baocode/usage/usage_ledger.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/session_links_host.dart';
import 'package:baocode/workspace/session_tools.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/e2e_env.dart';
import 'helpers/e2e_waiters.dart';
import 'helpers/fake_cli_harness.dart';
import 'helpers/mcp_http_probe.dart';

Map<String, String> _envWithPrependedPath(
  Map<String, String> base,
  String binDir, {
  bool isolated = false,
}) {
  final out = <String, String>{};
  String? existingPath;
  for (final entry in base.entries) {
    if (entry.key.toLowerCase() == 'path') {
      existingPath = entry.value;
    } else {
      out[entry.key] = entry.value;
    }
  }
  final sep = Platform.isWindows ? ';' : ':';
  out['PATH'] = isolated || existingPath == null || existingPath.isEmpty
      ? binDir
      : '$binDir$sep$existingPath';
  return out;
}

const _fakeAgyCrossFeatureBody = r'''
Map<String, String> _discoverMcp(List<String> args, Map<String, String> env) {
  final sources = <String>[...args];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String? candidate;
    if (a.startsWith('--mcp-config=')) {
      candidate = a.substring('--mcp-config='.length);
    } else if (a == '--mcp-config' && i + 1 < args.length) {
      candidate = args[i + 1];
    } else if (a.startsWith('--settings=')) {
      candidate = a.substring('--settings='.length);
    } else if (a == '--settings' && i + 1 < args.length) {
      candidate = args[i + 1];
    } else if (a.startsWith('--add-dir=')) {
      final dir = a.substring('--add-dir='.length);
      candidate =
          '$dir${Platform.pathSeparator}.agents${Platform.pathSeparator}mcp_config.json';
    } else if (a == '--add-dir' && i + 1 < args.length) {
      final dir = args[i + 1];
      candidate =
          '$dir${Platform.pathSeparator}.agents${Platform.pathSeparator}mcp_config.json';
    }
    if (candidate != null && File(candidate).existsSync()) {
      try {
        sources.add(File(candidate).readAsStringSync());
      } on Object {}
    }
  }
  for (final e in env.entries) {
    if (e.key.toUpperCase().contains('MCP') ||
        e.key.toUpperCase().contains('BAOCODE')) {
      sources.add(e.value);
    }
  }
  final urlRe = RegExp("https?://127\\.0\\.0\\.1:\\d+[^\\s\"']+");
  final tokRe = RegExp(r'Bearer\s+([A-Za-z0-9._~+/=-]+)');
  String? url;
  String? token;
  for (final s in sources) {
    url ??= urlRe.firstMatch(s)?[0];
    token ??= tokRe.firstMatch(s)?[1];
  }
  return {if (url != null) 'url': url, if (token != null) 'token': token};
}

Future<Map<String, Object?>> _rpc(
  String url,
  String? token,
  Map<String, Object?> body,
) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..findProxy = (_) => 'DIRECT';
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.headers.set(HttpHeaders.acceptHeader, 'application/json, text/event-stream');
    if (token != null && token.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    req.write(jsonEncode(body));
    final resp = await req.close().timeout(const Duration(seconds: 4));
    final text = await utf8.decoder.bind(resp).join();
    return {
      'status': resp.statusCode,
      'body': text.trim().isEmpty ? null : jsonDecode(text),
    };
  } finally {
    client.close(force: true);
  }
}

Future<void> main(List<String> args) async {
  final env = Map<String, String>.from(Platform.environment);
  recordEvent({'type': 'launch', 'args': args, 'env': env});
  final scenario = env['FAKE_AGY_SCENARIO'] ?? 'session_handoff';
  final editFile = env['FAKE_AGY_EDIT_FILE'] ?? '';
  final mcp = _discoverMcp(args, env);

  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  var turn = 0;
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    turn++;
    recordEvent({'type': 'stdin', 'turn': turn, 'line': line});

    if (scenario == 'session_handoff' && turn == 1 && mcp['url'] != null) {
      stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'agy-lead-conv'}));
      await stdout.flush();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final url = mcp['url']!;
      final tok = mcp['token'];
      await _rpc(url, tok, {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': '2024-11-05'},
      });
      await _rpc(url, tok, {
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
        'params': const <String, Object?>{},
      });
      final callRes = await _rpc(url, tok, {
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {
          'name': 'session_new',
          'arguments': {
            'text': 'Implement helper',
            'kernel': 'codebuddy-cli',
            'project': 'app',
          },
        },
      });
      final badCallRes = await _rpc(url, tok, {
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {
          'name': 'session_new',
          'arguments': {'text': 'Fail', 'kernel': 'unknown-kernel'},
        },
      });
      recordEvent({'type': 'mcp_calls', 'good': callRes, 'bad': badCallRes});
      final body = callRes['body'] as Map;
      final content = ((body['result'] as Map)['content'] as List).first as Map;
      final outText = content['text'] as String? ?? '';

      stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'agy-lead-conv'}));
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 1,
          'step_type': 'tool',
          'state': 'DONE',
          'tool_info': {
            'name': 'baocode:session_new',
            'parameters': {
              'text': jsonEncode('Implement helper'),
              'kernel': jsonEncode('codebuddy-cli'),
              'project': jsonEncode('app'),
            },
            'output': outText,
          },
        },
      }));
      stdout.writeln(jsonEncode({
        'event': 'result',
        'result': {
          'conversation_id': 'agy-lead-conv',
          'status': 'SUCCESS',
          'response': 'Delegated to CodeBuddy',
        },
      }));
      await stdout.flush();
      continue;
    }

    if (scenario == 'switches_probe' && mcp['url'] != null) {
      final url = mcp['url']!;
      final tok = mcp['token'];
      await _rpc(url, tok, {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': '2024-11-05'},
      });
      final listRes = await _rpc(url, tok, {
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/list',
        'params': const <String, Object?>{},
      });
      final blockedRes = await _rpc(url, tok, {
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {'name': 'echo_disabled', 'arguments': {'msg': 'x'}},
      });
      final allowedRes = await _rpc(url, tok, {
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/call',
        'params': {'name': 'echo_allowed', 'arguments': {'msg': 'ok'}},
      });
      recordEvent({
        'type': 'switches_probe',
        'list': listRes,
        'blocked': blockedRes,
        'allowed': allowedRes,
      });
    }

    if (scenario == 'edit_file' && editFile.isNotEmpty) {
      stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'agy-edit-conv'}));
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 1,
          'step_type': 'tool',
          'state': 'RUNNING',
          'tool_info': {
            'name': 'edit_file',
            'parameters': {
              'Path': jsonEncode(editFile),
              'Target': jsonEncode('const v = 1;'),
              'Replacement': jsonEncode('const v = 2;\n// added'),
            },
          },
        },
      }));
      await stdout.flush();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      File(editFile).writeAsStringSync('const v = 2;\n// added\n');
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 1,
          'step_type': 'tool',
          'state': 'DONE',
          'tool_info': {
            'name': 'edit_file',
            'parameters': {
              'Path': jsonEncode(editFile),
              'Target': jsonEncode('const v = 1;'),
              'Replacement': jsonEncode('const v = 2;\n// added'),
            },
            'output': 'Edited $editFile',
          },
        },
      }));
      stdout.writeln(jsonEncode({
        'event': 'result',
        'result': {
          'conversation_id': 'agy-edit-conv',
          'status': 'SUCCESS',
          'response': 'Edited target',
        },
      }));
      await stdout.flush();
      continue;
    }

    stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'agy-conv-$turn'}));
    stdout.writeln(jsonEncode({
      'event': 'result',
      'result': {
        'conversation_id': 'agy-conv-$turn',
        'status': 'SUCCESS',
        'response': 'AGY_REPLY_$turn',
      },
    }));
    await stdout.flush();
  }
}
''';

const _fakeCodexWorkerBody = r'''
Future<void> main(List<String> args) async {
  recordEvent({'type': 'launch', 'args': args});
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  var turnSeq = 0;
  final pendingPings = <int, Completer<void>>{};
  final done = Completer<void>();
  var flushChain = Future<void>.value();
  Future<void> flushStdout() =>
      flushChain = flushChain.then((_) => stdout.flush().catchError((_) {}));

  lines.listen(
    (line) {
      if (line.trim().isEmpty) return;
      recordEvent({'type': 'stdin', 'line': line});
      final msg = (jsonDecode(line) as Map).cast<String, Object?>();
      final id = msg['id'];
      final method = msg['method'] as String?;
      if (method == null && id != null) {
        recordEvent({'type': 'client_response', 'msg': msg});
        if (id is int) {
          pendingPings.remove(id)?.complete();
        }
        return;
      }
      switch (method) {
        case 'initialize':
          stdout.writeln(jsonEncode({'id': id, 'result': <String, Object?>{}}));
        case 'model/list':
          stdout.writeln(jsonEncode({
            'id': id,
            'result': {
              'data': [
                {
                  'id': 'gpt-5.4',
                  'displayName': 'GPT-5.4',
                  'isDefault': true,
                  'supportedReasoningEfforts': [
                    {'reasoningEffort': 'medium'},
                    {'reasoningEffort': 'high'},
                  ],
                  'defaultReasoningEffort': 'high',
                },
              ],
            },
          }));
        case 'thread/start':
          stdout.writeln(jsonEncode({
            'id': id,
            'result': {'thread': {'id': 'codex-worker-thread-1'}},
          }));
        case 'turn/start':
          final seq = ++turnSeq;
          final tid = 'cdx-turn-$seq';
          final pingId = 900 + seq;
          final pingCompleter = Completer<void>();
          pendingPings[pingId] = pingCompleter;
          stdout.writeln(jsonEncode({'id': id, 'result': {'turn': {'id': tid}}}));
          stdout.writeln(jsonEncode({
            'method': 'turn/started',
            'params': {'turn': {'id': tid}},
          }));
          stdout.writeln(jsonEncode({
            'id': pingId,
            'method': 'unknown/serverPing',
            'params': {'ping': 1},
          }));
          unawaited(flushStdout().then((_) async {
            await pingCompleter.future.timeout(
              const Duration(seconds: 15),
              onTimeout: () {
                recordEvent({
                  'type': 'ping_timeout',
                  'pingId': pingId,
                  'turnId': tid,
                });
              },
            );
            pendingPings.remove(pingId);
            stdout.writeln(jsonEncode({
              'method': 'item/completed',
              'params': {
                'item': {
                  'id': 'msg-$tid',
                  'type': 'agentMessage',
                  'text': 'CODEX_TASK_DONE',
                },
              },
            }));
            stdout.writeln(jsonEncode({
              'method': 'turn/completed',
              'params': {'turn': {'id': tid, 'status': 'completed'}},
            }));
            await flushStdout();
          }));
          return;
        default:
          if (id != null) {
            stdout.writeln(jsonEncode({'id': id, 'result': <String, Object?>{}}));
          }
      }
      unawaited(flushStdout());
    },
    onDone: () {
      for (final c in pendingPings.values) {
        if (!c.isCompleted) c.complete();
      }
      pendingPings.clear();
      if (!done.isCompleted) done.complete();
    },
    onError: (_, _) {
      for (final c in pendingPings.values) {
        if (!c.isCompleted) c.complete();
      }
      pendingPings.clear();
      if (!done.isCompleted) done.complete();
    },
  );

  await done.future;
}
''';

const _fakeCodeBuddyUsageBody = r'''
Future<void> main(List<String> args) async {
  recordEvent({'type': 'launch', 'args': args});
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final decoded = jsonDecode(line);
    if (decoded is! Map) continue;
    final msg = decoded.cast<String, Object?>();
    if (msg['type'] == 'control_request') {
      final reqId = msg['request_id'] as String? ?? '';
      final req = (msg['request'] as Map?)?.cast<String, Object?>() ?? const {};
      final subtype = req['subtype'] as String? ?? '';
      final payload = switch (subtype) {
        'initialize' => {'commands': const [], 'models': const []},
        'get_available_models' => {'models': const []},
        _ => const <String, Object?>{},
      };
      stdout.writeln(jsonEncode({
        'type': 'control_response',
        'response': {'subtype': 'success', 'request_id': reqId, 'response': payload},
      }));
      await stdout.flush();
    } else if (msg['type'] == 'user') {
      stdout.writeln(jsonEncode({
        'type': 'assistant',
        'uuid': 'cb-a-1',
        'message': {
          'id': 'cb-m-1',
          'model': 'hy4std',
          'role': 'assistant',
          'content': const [{'type': 'text', 'text': 'CB_DONE'}],
          'usage': const {'input_tokens': 30, 'output_tokens': 10},
        },
      }));
      stdout.writeln(jsonEncode({
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
        'result': 'CB_DONE',
        'duration_ms': 5,
      }));
      await stdout.flush();
    }
  }
}
''';

const _fakeCodexExecWorktreeBody = r'''
Future<void> main(List<String> args) async {
  recordEvent({'type': 'launch', 'args': args, 'cwd': Directory.current.path});
  final mode = Platform.environment['FAKE_CODEX_EXEC_MODE'] ?? 'ok';
  if (mode == 'error_json') {
    stdout.writeln('{corrupt_line');
    stdout.writeln(jsonEncode({'type': 'error', 'message': 'Exec failure'}));
    await stdout.flush();
    exit(1);
  }
  File('${Directory.current.path}${Platform.pathSeparator}README.md')
      .writeAsStringSync('# Modified by codex exec\n');
  stdout.writeln(jsonEncode({'type': 'thread.started', 'thread_id': 'th-exec-t3'}));
  stdout.writeln(jsonEncode({'type': 'turn.started'}));
  stdout.writeln(jsonEncode({
    'type': 'item.completed',
    'item': {
      'id': 'i-1',
      'type': 'agent_message',
      'text': 'CODEX_EXEC_DONE',
    },
  }));
  stdout.writeln(jsonEncode({'type': 'turn.completed'}));
  await stdout.flush();
}
''';

class _ScriptedDapTransportT3 extends EmitterDebugAdapterTransport {
  final List<Json> requests = [];
  int _seq = 1;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {
    fireExit(0);
  }

  void _emit(Json msg) =>
      scheduleMicrotask(() => acceptMessage({'seq': _seq++, ...msg}));

  void _respond(
    Json req, {
    Json? body,
    bool success = true,
    String? message,
  }) => _emit({
    'type': 'response',
    'request_seq': req['seq'],
    'command': req['command'],
    'success': success,
    'message': ?message,
    'body': ?body,
  });

  @override
  void send(Json message) {
    requests.add(message);
    switch (message['command'] as String?) {
      case 'initialize':
        _respond(message, body: const {'supportsConfigurationDoneRequest': true});
        _emit({'type': 'event', 'event': 'initialized'});
      case 'launch':
        _respond(message);
      case 'configurationDone':
        _respond(message);
        _emit({
          'type': 'event',
          'event': 'stopped',
          'body': {'reason': 'entry', 'threadId': 1, 'allThreadsStopped': true},
        });
      case 'threads':
        _respond(message, body: {'threads': [{'id': 1, 'name': 'main'}]});
      case 'stackTrace':
        _respond(message, body: {
          'stackFrames': [
            {
              'id': 10,
              'name': 'main',
              'source': {'name': 'main.dart', 'path': '/app/main.dart'},
              'line': 1,
              'column': 1,
            },
          ],
          'totalFrames': 1,
        });
      case 'scopes':
        _respond(message, body: {'scopes': const []});
      case 'evaluate':
        _respond(message, body: {
          'result': '<lazy>',
          'variablesReference': 77,
          'presentationHint': {'lazy': true},
        });
      case 'variables':
        final ref = (message['arguments'] as Map?)?['variablesReference'];
        _respond(message, body: {
          'variables': ref == 77
              ? [
                  {
                    'name': '',
                    'value': '42 (lazy-loaded)',
                    'variablesReference': 0,
                    'presentationHint': <String, Object?>{},
                  },
                ]
              : const [],
        });
      default:
        _respond(message, body: const {});
    }
  }
}

class _ScriptedDapFactoryT3 implements DebugAdapterFactory {
  _ScriptedDapTransportT3? lastTransport;

  @override
  DebugAdapterTransport createDebugAdapter(DebugSession session) =>
      lastTransport = _ScriptedDapTransportT3();

  @override
  Future<Json> substituteVariables(DebugWorkspaceFolder? folder, Json config) async =>
      config;

  @override
  Future<int?> runInTerminal(Json args, String sessionId) async => null;
}

void main() {
  group('Tier 3 — Cross-Feature Pairwise Integration Matrix', () {
    test(
      'T3-01: agy + SessionTools (session_new -> codebuddy-cli + <agent-message> + SessionLinks + mapTool)',
      () async {
        final sandbox = E2eSandbox.create(realHttp: true);
        SessionToolsSetting.current = () => true;

        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_t3_01',
          dartBody: _fakeAgyCrossFeatureBody,
        );

        late KernelDescriptor agyDesc;
        late KernelDescriptor cbDesc;
        agyDesc = KernelDescriptor(
          id: antigravityBuiltinProviderId,
          label: 'Antigravity',
          icon: Icons.rocket_launch_rounded,
          description: 'Antigravity',
          create: (ctx) => ClaudeCodeKernel(
            agyDesc,
            ctx,
            start: (launch) async => AntigravityTransport.forTesting(
              executable: fakeAgy.executablePath,
              environment: {
                ...sandbox.processEnv,
                'FAKE_AGY_SCENARIO': 'session_handoff',
              },
              launch: launch,
            ),
          ),
        );
        cbDesc = KernelDescriptor(
          id: codebuddyBuiltinProviderId,
          label: 'CodeBuddy',
          icon: Icons.auto_awesome_rounded,
          description: 'CodeBuddy',
          create: (ctx) => ClaudeCodeKernel(
            cbDesc,
            ctx,
            start: (launch) async => ScriptedClaudeTransport(
              launch: launch,
              sessionId: 'cb-worker-t3-01',
              models: const [
                {'value': 'glm-5.0-turbo', 'displayName': 'GLM 5.0 Turbo'},
              ],
              onUserTurn: (tr, _) => tr.emitSimpleReply(
                'CB_REVIEW_DONE',
                model: 'glm-5.0-turbo',
              ),
            ),
          ),
        );

        final ws = Workspace(
          kernels: [agyDesc, cbDesc],
          projects: [Project('app', sandbox.projectDir.path)],
        );
        final links = WorkspaceSessionLinks(ws, onOpen: (_) {});
        SessionTools.register(ws);
        sandbox.onDispose(() {
          SessionTools.unregister();
          links.dispose();
          ws.dispose();
        });

        final lead = ws.startAgent(ws.projectAt(sandbox.projectDir.path));
        ws.rename(lead, 'AgyLead');
        final handed = links.handedFrom(lead.session);

        lead.session.send(const ComposerMessage(text: 'Delegate to CodeBuddy'));
        try {
          await waitUntil(
            () {
              for (var i = 0; i < lead.session.itemCount; i++) {
                final item = lead.session.itemAt(i);
                if (item is UserMessageItem &&
                    item.fromAgent != null &&
                    item.text.contains('CB_REVIEW_DONE')) {
                  return true;
                }
              }
              return false;
            },
            timeout: const Duration(seconds: 15),
          );
        } catch (err) {
          final itemsDesc = [
            for (var i = 0; i < lead.session.itemCount; i++)
              lead.session.itemAt(i).runtimeType.toString(),
          ];
          fail(
            'Lead must receive <agent-message> auto-report from CodeBuddy worker '
            '(err=$err, threads=${ws.threads.length}, '
            'threadIds=${ws.threads.map((t) => '${t.id}/${SessionTools.idOf(t)}').toList()}, '
            'leadItems=$itemsDesc, captures=${jsonEncode(fakeAgy.readCaptures())})',
          );
        }

        final calls = fakeAgy.readCaptures().firstWhere(
          (e) => e['type'] == 'mcp_calls',
        );
        expect(((calls['bad'] as Map)['body'] as Map)['result']?['isError'], isTrue);
        expect(ws.threads, hasLength(2));

        final toolItems = [
          for (var i = 0; i < lead.session.itemCount; i++)
            if (lead.session.itemAt(i) case ToolCallItem item) item,
        ];
        expect(
          toolItems.any((t) => t.tool == 'session_new' && isSessionTool(t.tool)),
          isTrue,
        );

        await waitUntil(
          () => handed.value.any((h) => h.status == HandedStatus.done),
          reason: 'WorkspaceSessionLinks must transition handed worker to done',
        );
        expect(handed.value.single.model, isNotNull);
        expect(links.statusOf(handed.value.single.id), HandedStatus.done);
      },
    );

    test(
      'T3-02: agy + ExtensionSwitches + CustomizationStore (skills, MCP & loopback tool filtering)',
      () async {
        final sandbox = E2eSandbox.create(realHttp: true);
        final configDir = p.join(sandbox.homeDir.path, '.gemini', 'config');

        File(p.join(configDir, 'config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode({'disabledPlugins': ['bad-kit']}));
        File(p.join(configDir, 'plugins', 'my-kit', 'plugin.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode({'name': 'my-kit'}));
        final pluginSkill = File(
          p.join(configDir, 'plugins', 'my-kit', 'skills', 'lint-fix', 'SKILL.md'),
        )
          ..createSync(recursive: true)
          ..writeAsStringSync('---\nname: lint-fix\n---\n# Lint Fix\n');
        File(p.join(configDir, 'plugins', 'bad-kit', 'plugin.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode({'name': 'bad-kit'}));
        File(p.join(configDir, 'plugins', 'bad-kit', 'skills', 'hidden', 'SKILL.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('---\nname: hidden\n---\n# Hidden\n');
        File(p.join(configDir, 'skills', 'active-skill', 'SKILL.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('---\nname: active-skill\n---\nActive\n');
        File(p.join(configDir, 'skills', 'blocked-skill', 'SKILL.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('---\nname: blocked-skill\n---\nBlocked\n');
        File(p.join(configDir, 'mcp_config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode({
            'mcpServers': {
              'blocked-mcp': {'command': 'echo', 'args': ['1']},
              'active-mcp': {'command': 'echo', 'args': ['2']},
            },
          }));

        ExtensionSwitches.current = () => const ExtensionSwitches(
          disabledSkills: {'blocked-skill'},
          disabledServers: {'blocked-mcp'},
          disabledTools: {ClaudeSdkTools.server: {'echo_disabled'}},
        );

        sandbox.registerSdkTool(
          ClaudeSdkTool(
            name: 'echo_disabled',
            description: 'Disabled tool',
            kind: ToolKind.other,
            inputSchema: const {'type': 'object'},
            summary: (_, _) => 'disabled',
            run: (_, _) async => 'SHOULD_NOT_RUN',
          ),
        );
        sandbox.registerSdkTool(
          ClaudeSdkTool(
            name: 'echo_allowed',
            description: 'Allowed tool',
            kind: ToolKind.other,
            inputSchema: const {'type': 'object'},
            summary: (_, _) => 'allowed',
            run: (input, _) async => 'ALLOWED:${input['msg']}',
          ),
        );

        final store = CustomizationStore(
          configDir: configDir,
          homeDir: sandbox.homeDir.path,
        );
        expect(await store.commandFile('lint-fix'), pluginSkill.path);
        expect(await store.commandFile('my-kit:lint-fix'), pluginSkill.path);
        expect(await store.commandFile('hidden'), isNull);
        expect(await store.commandFile('../secret'), isNull);

        final skills = await store.list(CustomizationKind.skills);
        final mcps = await store.list(CustomizationKind.mcps);
        expect(
          skills.firstWhere((s) => s.name == 'blocked-skill').enabled,
          isFalse,
        );
        expect(
          skills.firstWhere((s) => s.name == 'active-skill').enabled,
          isNot(false),
        );
        expect(
          mcps.firstWhere((m) => m.name == 'blocked-mcp').enabled,
          isFalse,
        );
        expect(
          mcps.firstWhere((m) => m.name == 'active-mcp').enabled,
          isNot(false),
        );

        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_t3_02',
          dartBody: _fakeAgyCrossFeatureBody,
        );
        final kernel = ClaudeCodeKernel(
          KernelRegistry.antigravity,
          KernelContext(cwd: sandbox.projectDir.path),
          start: (launch) async => AntigravityTransport.forTesting(
            executable: fakeAgy.executablePath,
            environment: {
              ...sandbox.processEnv,
              'FAKE_AGY_SCENARIO': 'switches_probe',
            },
            launch: launch,
          ),
        );
        sandbox.onDispose(kernel.dispose);

        final done = Completer<void>();
        final sub = kernel.events.listen((e) {
          if (e is TurnEnded && !done.isCompleted) done.complete();
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));
        kernel.send(const KernelTurn(id: 't1', text: 'probe switches'));
        await done.future.timeout(const Duration(seconds: 15));

        final probe = fakeAgy.readCaptures().firstWhere(
          (e) => e['type'] == 'switches_probe',
        );
        final listTools =
            ((((probe['list'] as Map)['body'] as Map)['result'] as Map)['tools']
                    as List)
                .cast<Map>()
                .map((t) => t['name'])
                .toList();
        expect(listTools, contains('echo_allowed'));
        expect(listTools, isNot(contains('echo_disabled')));
        expect(jsonEncode(probe['allowed']), contains('ALLOWED:ok'));
        expect(
          jsonEncode(probe['blocked']),
          isNot(contains('SHOULD_NOT_RUN')),
        );
      },
    );

    test(
      'T3-03: codebuddy + Workspace reload attribution + CodeBuddyAccounts quota',
      () async {
        final sandbox = E2eSandbox.create();
        final claudeConfigDir = sandbox.processEnv['CLAUDE_CONFIG_DIR']!;
        final paths = AgentPaths(
          home: sandbox.homeDir.path,
          configDir: claudeConfigDir,
        );
        final catalog = ClaudeCatalog(
          local: ClaudeStorage(
            configDir: claudeConfigDir,
            cacheFile: p.join(sandbox.dataDir.path, 'claude-sessions.json'),
          ),
        );

        // Seed isolated CodeBuddyAccounts store and verify quota refresh.
        final cbAccDir = Directory(
          p.join(sandbox.homeDir.path, '.cyte', 'codebuddy_accounts', 'accounts'),
        )..createSync(recursive: true);
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        File(p.join(cbAccDir.path, 'cb-t3.json')).writeAsStringSync(jsonEncode({
          'id': 'cb-t3',
          'uid': 'u-t3',
          'nickname': 'T3 CB',
          'region': 'cn',
          'endpoint': 'https://copilot.tencent.com',
          'auth': {'kind': 'authToken', 'access_token': 'tok-t3'},
          'quota': {
            'edition': 'pro',
            'total_credits': 500.0,
            'used_credits': 100.0,
            'remaining_credits': 400.0,
            'reset_time': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 2))
                .toIso8601String(),
            'last_updated': nowSec,
          },
          'created_at': nowSec,
          'last_used': nowSec,
        }));
        File(
          p.join(sandbox.homeDir.path, '.cyte', 'codebuddy_accounts', 'accounts.json'),
        ).writeAsStringSync(jsonEncode({
          'current_account_id': 'cb-t3',
          'accounts': [
            {'id': 'cb-t3', 'uid': 'u-t3', 'nickname': 'T3 CB', 'region': 'cn'},
          ],
        }));

        final fakeCb = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_cb_t3_03',
          dartBody: _fakeCodeBuddyUsageBody,
        );
        CodeBuddyPathSetting.current = () => fakeCb.executablePath;
        final accounts = CodeBuddyAccounts(
          dataDir: p.join(sandbox.homeDir.path, '.cyte', 'codebuddy_accounts'),
        );
        sandbox.onDispose(accounts.dispose);
        await accounts.ensureInitialized();
        expect(accounts.currentAccount?.quota?.remainingCredits, 400.0);

        final cbKernelDirect = ClaudeCodeKernel(
          KernelRegistry.codebuddy,
          KernelContext(cwd: sandbox.projectDir.path),
          start: (launch) async {
            final tr = CodeBuddyTransport.forTesting(
              cli: CodeBuddyCli(
                executable: fakeCb.executablePath,
                environment: sandbox.processEnv,
              ),
              launch: launch,
              accounts: accounts,
            );
            await tr.spawnForTesting();
            return tr;
          },
        );
        sandbox.onDispose(cbKernelDirect.dispose);
        final doneDirect = Completer<void>();
        final subDirect = cbKernelDirect.events.listen((e) {
          if (e is TurnEnded && !doneDirect.isCompleted) doneDirect.complete();
        });
        sandbox.onDispose(() => unawaited(subDirect.cancel()));
        cbKernelDirect.send(const KernelTurn(id: 't1', text: 'boot'));
        await doneDirect.future.timeout(const Duration(seconds: 15));
        await cbKernelDirect.refreshUsage();
        expect(cbKernelDirect.accountLimits, isNotEmpty);

        // Now verify Workspace kernelId persistence across dispose + reload.
        late KernelDescriptor cbDesc;
        late KernelDescriptor ccDesc;
        cbDesc = KernelDescriptor(
          id: codebuddyBuiltinProviderId,
          label: 'CodeBuddy',
          icon: Icons.auto_awesome_rounded,
          description: 'CodeBuddy',
          catalog: catalog,
          create: (ctx) => ClaudeCodeKernel(
            cbDesc,
            ctx,
            start: (launch) async => ScriptedClaudeTransport(
              launch: launch,
              sessionId: launch.resume ?? 'cb-reload-1',
              onUserTurn: (tr, _) => tr.emitSimpleReply('CB_RELOADED'),
            ),
          ),
        );
        ccDesc = KernelDescriptor(
          id: claudeCodeKernelId,
          label: 'Claude Code',
          icon: Icons.terminal_rounded,
          description: 'Claude Code',
          catalog: catalog,
          create: (ctx) => ClaudeCodeKernel(
            ccDesc,
            ctx,
            start: (launch) async => ScriptedClaudeTransport(
              launch: launch,
              sessionId: launch.resume ?? 'cc-reload-1',
            ),
          ),
        );

        final prefs = MemoryPreferenceStore();
        final ws1 = Workspace(
          kernels: [ccDesc, cbDesc],
          preferences: prefs,
          projects: [Project('proj', sandbox.projectDir.path)],
        );
        sandbox.onDispose(ws1.dispose);
        await ws1.load();

        final thread = ws1.startAgent(ws1.projects.first, kernel: cbDesc);
        thread.session.send(const ComposerMessage(text: 'Persist me'));
        await settleAgentTurn(thread);
        final perms = thread.session.permissions!;
        final acceptEdits = perms.options.firstWhere(
          (o) => o.id == 'acceptEdits',
          orElse: () => perms.options.last,
        );
        perms.onSelected(acceptEdits);

        final jsonl = File(paths.sessionFile(sandbox.projectDir.path, 'cb-reload-1'))
          ..parent.createSync(recursive: true);
        jsonl.writeAsStringSync(
          '${jsonEncode({
            'type': 'user',
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            'cwd': sandbox.projectDir.path,
            'sessionId': 'cb-reload-1',
            'message': {'role': 'user', 'content': 'Persist me'},
          })}\n'
          '${jsonEncode({
            'type': 'assistant',
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            'cwd': sandbox.projectDir.path,
            'sessionId': 'cb-reload-1',
            'message': {
              'id': 'm1',
              'role': 'assistant',
              'model': 'claude-sonnet-4-6',
              'content': [{'type': 'text', 'text': 'CB_RELOADED'}],
            },
          })}\n',
        );

        await waitUntil(() {
          final agents = prefs.preferences['agents'];
          return agents is Map &&
              agents['cb-reload-1'] is Map &&
              (agents['cb-reload-1'] as Map)['permission'] == acceptEdits.id;
        });
        ws1.dispose();

        final ws2 = Workspace(kernels: [ccDesc, cbDesc], preferences: prefs);
        sandbox.onDispose(ws2.dispose);
        await ws2.load();

        final reloaded = ws2.threads.firstWhere(
          (t) => t.record?.id == 'cb-reload-1',
        );
        expect(reloaded.kernel.id, codebuddyBuiltinProviderId);
        expect(ws2.keptChoice(reloaded, KernelChoiceKind.permission), acceptEdits.id);
      },
    );

    test(
      'T3-04: codex + SessionTools (session_new(kernel: codex) + <agent-message> + ProcessCodexTransport)',
      () async {
        final sandbox = E2eSandbox.create(realHttp: true);
        SessionToolsSetting.current = () => true;
        sandbox.onDispose(ProcessCodexTransport.stopAll);

        final fakeBin = Directory(p.join(sandbox.rootDir.path, 'codex_bin'));
        final fakeCodex = FakeCliExecutable.create(
          fakeBin,
          name: 'codex',
          dartBody: _fakeCodexWorkerBody,
        );
        sandbox.useClaudeEnvironment(
          _envWithPrependedPath(sandbox.processEnv, fakeBin.path, isolated: true),
        );

        late KernelDescriptor agyDesc;
        late KernelDescriptor codexDesc;
        agyDesc = KernelDescriptor(
          id: antigravityBuiltinProviderId,
          label: 'Antigravity',
          icon: Icons.rocket_launch_rounded,
          description: 'Antigravity',
          create: (ctx) => ClaudeCodeKernel(
            agyDesc,
            ctx,
            start: (launch) async => ScriptedClaudeTransport(
              launch: launch,
              sessionId: 'agy-lead-t3-04',
              onUserTurn: (tr, _) => tr.emitSimpleReply('AGY_LEAD_READY'),
            ),
          ),
        );
        codexDesc = KernelDescriptor(
          id: codexKernelId,
          label: 'Codex',
          icon: Icons.bolt_rounded,
          description: 'Codex',
          create: (ctx) => CodexKernel(
            codexDesc,
            ProcessCodexTransport(cwd: ctx.cwd ?? sandbox.projectDir.path),
            context: ctx,
            catalog: CodexCatalog(codexHome: p.join(sandbox.homeDir.path, '.codex')),
            enableSdkMcpBridge: true,
          ),
        );

        final ws = Workspace(
          kernels: [agyDesc, codexDesc],
          projects: [Project('app', sandbox.projectDir.path)],
        );
        SessionTools.register(ws);
        sandbox.onDispose(() {
          SessionTools.unregister();
          ws.dispose();
        });

        final lead = ws.startAgent(ws.projects.first, kernel: agyDesc);
        ws.rename(lead, 'Lead');
        lead.session.send(const ComposerMessage(text: 'boot'));
        await settleAgentTurn(lead);
        final leadId = SessionTools.idOf(lead);

        final res = await ClaudeSdkTools.handle(
          {
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': {
              'name': 'session_new',
              'arguments': {'text': 'Run codex worker', 'kernel': codexKernelId},
            },
          },
          ClaudeSdkCall(cwd: sandbox.projectDir.path, sessionId: leadId),
        );
        final resultMap = res['result'] as Map<String, Object?>;
        expect(resultMap['isError'], isNot(true));

        await waitUntil(
          () {
            for (var i = 0; i < lead.session.itemCount; i++) {
              final item = lead.session.itemAt(i);
              if (item is UserMessageItem && item.text.contains('CODEX_TASK_DONE')) {
                return true;
              }
            }
            return false;
          },
          timeout: const Duration(seconds: 15),
          reason: 'Lead must receive CODEX_TASK_DONE auto-report from real ProcessCodexTransport worker',
        );

        final launchArgs =
            (fakeCodex.firstLaunchCapture()!['args'] as List).cast<String>();
        expect(launchArgs.any((a) => a.startsWith('mcp_servers.baocode.url=')), isTrue);
        await waitUntil(
          () => fakeCodex.readCaptures().any(
            (c) =>
                c['type'] == 'client_response' &&
                ((c['msg'] as Map)['error'] as Map?)?['code'] == -32601,
          ),
          timeout: const Duration(seconds: 15),
          reason:
              'Unknown server RPC request must receive -32601 without stalling turn',
        );
        final rpcReplies = fakeCodex
            .readCaptures()
            .where((c) => c['type'] == 'client_response')
            .toList();
        expect(
          rpcReplies.any((r) => ((r['msg'] as Map)['error'] as Map?)?['code'] == -32601),
          isTrue,
          reason: 'Unknown server RPC request must receive -32601 without stalling turn',
        );

        // Also send structured <agent-message> directly into the Codex worker.
        final codexWorker = ws.threads.firstWhere((t) => t.kernel.id == codexKernelId);
        await ClaudeSdkTools.handle(
          {
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'tools/call',
            'params': {
              'name': 'session_send',
              'arguments': {
                'session': SessionTools.idOf(codexWorker),
                'text': 'Second pass',
              },
            },
          },
          ClaudeSdkCall(cwd: sandbox.projectDir.path, sessionId: leadId),
        );
        await waitUntil(() {
          for (var i = 0; i < codexWorker.session.itemCount; i++) {
            final item = codexWorker.session.itemAt(i);
            if (item is UserMessageItem &&
                item.fromAgent == 'Lead' &&
                item.text == 'Second pass') {
              return true;
            }
          }
          return false;
        }, timeout: const Duration(seconds: 15));
      },
    );

    test(
      'T3-05: codex + ConversationSearch + CodexCatalog rollout indexing & search',
      () async {
        final sandbox = E2eSandbox.create();
        sandbox.useClaudeEnvironment(sandbox.processEnv);
        final codexHome = p.join(sandbox.homeDir.path, '.codex');
        const needle = 'CODEX_CATALOG_SEARCH_NEEDLE_T305';

        final rollout = File(
          p.join(
            codexHome,
            'sessions',
            '2026',
            '11',
            '22',
            'rollout-2026-11-22T09-00-00-cdx-t305.jsonl',
          ),
        )..createSync(recursive: true);
        rollout.writeAsStringSync([
          jsonEncode({
            'type': 'session_meta',
            'timestamp': '2026-11-22T09:00:00Z',
            'payload': {'id': 'cdx-t305', 'cwd': sandbox.projectDir.path},
          }),
          jsonEncode({
            'type': 'turn_context',
            'payload': {'model': 'gpt-5.4', 'effort': 'high', 'cwd': sandbox.projectDir.path},
          }),
          jsonEncode({
            'type': 'event_msg',
            'timestamp': '2026-11-22T09:00:01Z',
            'payload': {'type': 'user_message', 'message': 'Investigate $needle'},
          }),
          jsonEncode({
            'type': 'event_msg',
            'timestamp': '2026-11-22T09:00:02Z',
            'payload': {'type': 'agent_message', 'message': 'Resolved $needle'},
          }),
        ].join('\n'));

        // Write a malformed rollout alongside it to verify resilience.
        File(
          p.join(codexHome, 'sessions', '2026', '11', '22', 'rollout-corrupt.jsonl'),
        )
          ..createSync(recursive: true)
          ..writeAsBytesSync([0xff, 0xfe, ...utf8.encode('\n{bad_json\n')]);

        final catalog = CodexCatalog(codexHome: codexHome);
        await catalog.noteSessionTitle('cdx-t305', 'Investigate $needle');
        final sessions = await catalog.sessionsIn(sandbox.projectDir.path);
        expect(sessions.map((s) => s.id), contains('cdx-t305'));

        final search = ClaudeConversationSearch(
          configDir: sandbox.processEnv['CLAUDE_CONFIG_DIR'],
          homeDir: sandbox.homeDir.path,
        );
        final hits = await search.search(needle);
        expect(
          hits.map((h) => h.sessionId),
          contains('cdx-t305'),
          reason: 'ConversationSearch must index ~/.codex/sessions rollout files (F9)',
        );
      },
    );

    test(
      'T3-06: agy + EditWatch + ChangeReview + SessionTools (session_changes & undo)',
      () async {
        final sandbox = E2eSandbox.create();
        SessionToolsSetting.current = () => true;
        final repoDir = await initTempGitRepo(
          sandbox.rootDir,
          files: {'lib/target.dart': 'const v = 1;\n'},
        );
        final targetFile = File(p.join(repoDir.path, 'lib', 'target.dart'));

        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_t3_06',
          dartBody: _fakeAgyCrossFeatureBody,
        );

        // 1. Verify ChatSession + BlobReviewStore ChangeReview + EditWatch undo.
        final reviewDesc = KernelDescriptor(
          id: antigravityBuiltinProviderId,
          label: 'Antigravity',
          icon: Icons.rocket_launch_rounded,
          description: 'Antigravity',
          create: (ctx) => ClaudeCodeKernel(
            KernelRegistry.antigravity,
            ctx,
            start: (launch) async => AntigravityTransport.forTesting(
              executable: fakeAgy.executablePath,
              environment: {
                ...sandbox.processEnv,
                'FAKE_AGY_SCENARIO': 'edit_file',
                'FAKE_AGY_EDIT_FILE': targetFile.path,
              },
              launch: launch,
            ),
          ),
        );
        final session = ChatSession(
          kernel: reviewDesc,
          kernels: [reviewDesc],
          kernelContext: KernelContext(cwd: repoDir.path),
          historyCount: 0,
          openReview: (root, {session}) async => ChangeReview(
            BlobReviewStore.open(p.join(sandbox.dataDir.path, 'checkpoints')),
            root: root,
          ),
        );
        session.attach();
        sandbox.onDispose(session.dispose);
        await waitUntil(() => session.health.status == KernelHealthStatus.ready);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        session.send(const ComposerMessage(text: 'edit target'));
        await waitUntil(
          () => !session.isStreaming && session.fileChanges.isNotEmpty,
          timeout: const Duration(seconds: 15),
          reason: 'EditWatch + ChangeReview must capture lib/target.dart edit',
        );
        expect(
          session.fileChanges.any(
            (c) => c.path.replaceAll('\\', '/').endsWith('lib/target.dart'),
          ),
          isTrue,
        );
        expect(targetFile.readAsStringSync().replaceAll('\r\n', '\n'), 'const v = 2;\n// added\n');

        expect(session.undoChanges, isNotNull);
        session.undoChanges!(session.fileChanges);
        await waitUntil(
          () => targetFile.readAsStringSync().replaceAll('\r\n', '\n') == 'const v = 1;\n',
          reason: 'ChangeReview.undo must restore original file content',
        );

        // 2. Verify SessionTools session_changes across Workspace threads.
        final ws = Workspace(
          kernels: [reviewDesc],
          projects: [Project('repo', repoDir.path)],
        );
        SessionTools.register(ws);
        sandbox.onDispose(() {
          SessionTools.unregister();
          ws.dispose();
        });

        final lead = ws.startAgent(ws.projects.first);
        ws.rename(lead, 'Coordinator');
        final worker = ws.startAgent(ws.projects.first);
        ws.rename(worker, 'Editor');
        worker.session.send(const ComposerMessage(text: 'apply edit'));
        await settleAgentTurn(worker, timeout: const Duration(seconds: 15));

        final changesRes = await ClaudeSdkTools.handle(
          {
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': {
              'name': 'session_changes',
              'arguments': {'session': SessionTools.idOf(worker)},
            },
          },
          ClaudeSdkCall(cwd: repoDir.path, sessionId: SessionTools.idOf(lead)),
        );
        final changesResult = changesRes['result'] as Map<String, Object?>;
        expect(
          changesResult['isError'],
          isNot(true),
          reason: 'session_changes failed: ${jsonEncode(changesResult)}',
        );
        final text =
            ((changesResult['content'] as List).single as Map)['text'] as String;
        expect(text, contains('target.dart'));
        expect(text, contains(repoDir.path));

        final selfErr = await ClaudeSdkTools.handle(
          {
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'tools/call',
            'params': {
              'name': 'session_changes',
              'arguments': {'session': SessionTools.idOf(lead)},
            },
          },
          ClaudeSdkCall(cwd: repoDir.path, sessionId: SessionTools.idOf(lead)),
        );
        expect((selfErr['result'] as Map)['isError'], isTrue);
      },
    );

    test(
      'T3-07: TaskQueueService + Workspace buildChatHandoff preserves model/effort without polluting sidebar',
      () async {
        final sandbox = E2eSandbox.create();
        final repoDir = await initTempGitRepo(sandbox.rootDir);
        final svc = TaskQueueService.instance
          ..resetForTest()
          ..storagePathOverride = p.join(sandbox.dataDir.path, 'tasks.json');
        sandbox.onDispose(() async {
          AcpAgentService.instance.headlessRunnerOverride = null;
          await svc.flushForTest();
          svc
            ..resetForTest()
            ..storagePathOverride = null;
        });

        AcpAgentService.instance.headlessRunnerOverride = ({
          required String agentId,
          required String prompt,
          required String cwd,
          String? model,
          String? effort,
          void Function(String chunk)? onChunk,
          void Function(Process proc)? onProcessStarted,
          Duration timeout = const Duration(minutes: 15),
        }) async {
          File(p.join(cwd, 'wt_edit.txt')).writeAsStringSync('changed\n');
          return (ok: true, output: 'Done', error: null);
        };

        final task = svc.enqueue(
          title: 'T3-07 Handoff',
          prompt: 'Refactor module',
          repoPath: repoDir.path,
          agentId: 'codex',
          model: 'gpt-5.4',
          effort: 'high',
          useWorktree: true,
        );
        await svc.runTask(task.id);
        expect(task.status, WorktreeTaskStatus.review);

        final prefs = MemoryPreferenceStore({
          'folders': [repoDir.path],
        });
        final ws = Workspace(
          projects: [Project.at(repoDir.path)],
          preferences: prefs,
        );
        sandbox.onDispose(ws.dispose);
        await ws.load();

        final handoff = await svc.buildChatHandoff(task.id, isZh: false);
        expect(handoff, isNotNull);
        expect(handoff!.directory, task.worktreePath);
        expect(handoff.kernelId, codexKernelId);
        expect(handoff.draftPrompt, contains('T3-07 Handoff'));
        expect((handoff as dynamic).model, 'gpt-5.4');
        expect((handoff as dynamic).effort, 'high');
        expect(ws.sidebarProjects.map((pr) => pr.path).toList(), [repoDir.path]);

        expect(await svc.buildChatHandoff('nonexistent-id', isZh: false), isNull);
        await svc.discardTask(task.id);
      },
    );

    test(
      'T3-08: AutomationService + AyteIpcServer (/automations/run + cwd validation + model/effort)',
      () async {
        final sandbox = E2eSandbox.create(realHttp: true);
        AutomationService.instance.storagePathOverride = p.join(
          sandbox.dataDir.path,
          'automations.json',
        );
        final ipc = AyteIpcServer.instance..homeOverride = sandbox.homeDir.path;
        sandbox.onDispose(() async {
          AcpAgentService.instance.headlessRunnerOverride = null;
          AutomationService.instance.storagePathOverride = null;
          for (final r in [...AutomationService.instance.rules]) {
            AutomationService.instance.deleteRule(r.id);
          }
          await ipc.stop();
        });

        final svc = AutomationService.instance..registerTools();
        String? gotAgent;
        String? gotModel;
        String? gotEffort;
        String? gotCwd;
        AcpAgentService.instance.headlessRunnerOverride = ({
          required String agentId,
          required String prompt,
          required String cwd,
          String? model,
          String? effort,
          void Function(String chunk)? onChunk,
          void Function(Process proc)? onProcessStarted,
          Duration timeout = const Duration(minutes: 15),
        }) async {
          gotAgent = agentId;
          gotModel = model;
          gotEffort = effort;
          gotCwd = cwd;
          return (ok: true, output: 'AUTO_IPC_OK', error: null);
        };

        // Invalid cwd must be rejected cleanly.
        final badTool = await ClaudeSdkTools.handle(
          {
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': {
              'name': 'create_automation',
              'arguments': {
                'name': 'BadCwd',
                'prompt': 'hi',
                'cron': '0 4 * * *',
                'cwd': p.join(sandbox.rootDir.path, 'does_not_exist'),
              },
            },
          },
          ClaudeSdkCall(cwd: sandbox.projectDir.path),
        );
        expect((badTool['result'] as Map)['isError'], isTrue);

        final goodTool = await ClaudeSdkTools.handle(
          {
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'tools/call',
            'params': {
              'name': 'create_automation',
              'arguments': {
                'name': 'IpcAuto',
                'prompt': 'Run CI check',
                'cron': '0 4 * * *',
                'cwd': sandbox.projectDir.path,
                'agentId': 'codex',
                'model': 'gpt-5.4',
                'effort': 'high',
              },
            },
          },
          ClaudeSdkCall(cwd: sandbox.projectDir.path),
        );
        expect((goodTool['result'] as Map)['isError'], isNot(true));
        final rule = svc.rules.firstWhere((r) => r.name == 'IpcAuto');

        await ipc.start();
        final info = jsonDecode(File(ipc.ipcInfoPath).readAsStringSync()) as Map;
        final baseUri = Uri.parse('http://127.0.0.1:${info['port']}');
        final token = info['token'] as String;

        final unauth = await McpHttpProbe(
          baseUri.replace(path: '/automations/run'),
        ).postJsonRpc({'id': rule.id}, omitAuth: true);
        expect(unauth.statusCode, 401);

        final runRes = await McpHttpProbe(
          baseUri.replace(path: '/automations/run'),
          bearerToken: token,
        ).postJsonRpc({'id': rule.id});
        expect(runRes.statusCode, 200);

        await waitUntil(() => rule.history.isNotEmpty);
        expect(rule.history.first.ok, isTrue);
        expect(gotAgent, 'codex');
        expect(gotModel, 'gpt-5.4');
        expect(gotEffort, 'high');
        expect(gotCwd, sandbox.projectDir.path);
      },
    );

    test(
      'T3-09: AcpAgentService (codex exec --json) + TaskQueueService worktree diff & merge',
      () async {
        final sandbox = E2eSandbox.create();
        final repoDir = await initTempGitRepo(sandbox.rootDir);
        final fakeBin = Directory(p.join(sandbox.rootDir.path, 'codex_exec_t3'));
        final fakeCodex = FakeCliExecutable.create(
          fakeBin,
          name: 'codex',
          dartBody: _fakeCodexExecWorktreeBody,
        );
        sandbox.useClaudeEnvironment(
          _envWithPrependedPath(sandbox.processEnv, fakeBin.path, isolated: true),
        );

        final svc = TaskQueueService.instance
          ..resetForTest()
          ..storagePathOverride = p.join(sandbox.dataDir.path, 'tasks.json');
        AcpAgentService.instance.headlessRunnerOverride = null;
        sandbox.onDispose(() async {
          AcpAgentService.instance.headlessRunnerOverride = null;
          await svc.flushForTest();
          svc
            ..resetForTest()
            ..storagePathOverride = null;
        });

        final task = svc.enqueue(
          title: 'Real codex exec worktree',
          prompt: 'Update README',
          repoPath: repoDir.path,
          agentId: 'codex',
          model: 'gpt-5.4',
          effort: 'high',
          useWorktree: true,
        );

        await svc.runTask(task.id);
        expect(task.status, WorktreeTaskStatus.review);
        expect(task.hasDiff, isTrue);
        expect(task.log, contains('CODEX_EXEC_DONE'));

        final launch = fakeCodex.firstLaunchCapture()!;
        final args = (launch['args'] as List).cast<String>();
        expect(args, containsAllInOrder(['exec', '--json']));
        expect(args, containsAllInOrder(['-m', 'gpt-5.4']));
        expect(args, containsAllInOrder(['-c', 'model_reasoning_effort=high']));

        final mergeRes = await svc.approveAndMerge(task.id);
        expect(mergeRes.ok, isTrue, reason: mergeRes.message);
        expect(task.status, WorktreeTaskStatus.merged);
        expect(
          File(p.join(repoDir.path, 'README.md'))
              .readAsStringSync()
              .replaceAll('\r\n', '\n'),
          '# Modified by codex exec\n',
        );

        // Verify no ayte-task-idx-* files leaked in Directory.systemTemp.
        final leakedIdx = Directory.systemTemp
            .listSync()
            .whereType<File>()
            .where((f) => p.basename(f.path).startsWith('ayte-task-idx-'))
            .toList();
        expect(leakedIdx, isEmpty);

        // Error JSON mode transitions task to failed cleanly.
        sandbox.useClaudeEnvironment({
          ..._envWithPrependedPath(sandbox.processEnv, fakeBin.path, isolated: true),
          'FAKE_CODEX_EXEC_MODE': 'error_json',
        });
        final errTask = svc.enqueue(
          title: 'Failing codex exec',
          prompt: 'Fail',
          repoPath: repoDir.path,
          agentId: 'codex',
          useWorktree: true,
        );
        await svc.runTask(errTask.id);
        expect(errTask.status, WorktreeTaskStatus.failed);
        expect(errTask.error, contains('Exec failure'));
        await svc.discardTask(errTask.id);
      },
    );

    test(
      'T3-10: ClaudeCodeKernel (claude-code vs antigravity-cli vs codebuddy-cli) catalog & UsageLedger isolation',
      () async {
        final sandbox = E2eSandbox.create();
        ClaudeCodeKernel.forgetCatalogCache();
        sandbox.onDispose(ClaudeCodeKernel.forgetCatalogCache);

        final cc = ClaudeCodeKernel(
          KernelRegistry.claudeCode,
          KernelContext(cwd: sandbox.projectDir.path),
          start: (launch) async => ScriptedClaudeTransport(
            launch: launch,
            sessionId: 'iso-cc-1',
            account: const {'subscriptionType': 'Max'},
            commands: const [
              {'name': 'cc-cmd', 'description': 'Claude cmd'},
            ],
            models: const [
              {'value': 'claude-opus-4-6', 'displayName': 'Claude Opus 4.6'},
            ],
            onUserTurn: (tr, _) => tr.emitSimpleReply(
              'cc',
              model: 'claude-opus-4-6',
              inputTokens: 10,
              outputTokens: 5,
            ),
          ),
        );
        final agy = ClaudeCodeKernel(
          KernelRegistry.antigravity,
          KernelContext(cwd: sandbox.projectDir.path),
          start: (launch) async => ScriptedClaudeTransport(
            launch: launch,
            sessionId: 'iso-agy-1',
            account: const {'subscriptionType': 'Antigravity CLI'},
            commands: const [
              {'name': 'agy-cmd', 'description': 'Agy cmd'},
            ],
            models: const [
              {'value': 'gemini-3.8-flash', 'displayName': 'Gemini 3.8 Flash'},
            ],
            onUserTurn: (tr, _) => tr.emitSimpleReply(
              'agy',
              model: 'gemini-3.8-flash',
              inputTokens: 20,
              outputTokens: 7,
            ),
          ),
        );
        final cb = ClaudeCodeKernel(
          KernelRegistry.codebuddy,
          KernelContext(cwd: sandbox.projectDir.path),
          start: (launch) async => ScriptedClaudeTransport(
            launch: launch,
            sessionId: 'iso-cb-1',
            account: const {'subscriptionType': 'CodeBuddy (CN · Pro)'},
            commands: const [
              {'name': 'cb-cmd', 'description': 'CodeBuddy cmd'},
            ],
            models: const [
              {'value': 'glm-5.0-turbo', 'displayName': 'GLM 5.0 Turbo'},
            ],
            onUserTurn: (tr, _) => tr.emitSimpleReply(
              'cb',
              model: 'glm-5.0-turbo',
              inputTokens: 30,
              outputTokens: 9,
            ),
          ),
        );
        sandbox.onDispose(() {
          cc.dispose();
          agy.dispose();
          cb.dispose();
        });

        var endedCount = 0;
        for (final k in [cc, agy, cb]) {
          final sub = k.events.listen((e) {
            if (e is TurnEnded) endedCount++;
          });
          sandbox.onDispose(() => unawaited(sub.cancel()));
        }

        cc.send(const KernelTurn(id: 't1', text: '1'));
        agy.send(const KernelTurn(id: 't2', text: '2'));
        cb.send(const KernelTurn(id: 't3', text: '3'));
        await waitUntil(() => endedCount == 3);

        expect(cc.commands.map((c) => c.name), contains('cc-cmd'));
        expect(cc.commands.map((c) => c.name), isNot(contains('agy-cmd')));
        expect(agy.commands.map((c) => c.name), contains('agy-cmd'));
        expect(agy.commands.map((c) => c.name), isNot(contains('cb-cmd')));
        expect(cb.commands.map((c) => c.name), contains('cb-cmd'));
        expect(cb.commands.map((c) => c.name), isNot(contains('cc-cmd')));

        // Unstarted sibling CodeBuddy kernel must inherit only CodeBuddy catalog.
        final freshCb = ClaudeCodeKernel(
          KernelRegistry.codebuddy,
          KernelContext(cwd: sandbox.projectDir.path),
          start: (launch) async => ScriptedClaudeTransport(launch: launch),
        );
        sandbox.onDispose(freshCb.dispose);
        expect(freshCb.commands.map((c) => c.name), contains('cb-cmd'));
        expect(freshCb.commands.map((c) => c.name), isNot(contains('cc-cmd')));
        expect(freshCb.commands.map((c) => c.name), isNot(contains('agy-cmd')));

        UsageLedger.current.flush();
        final days = await UsageLedger.current.storage.days();
        final calls = await UsageLedger.current.storage.read(days);
        expect(calls, hasLength(3));
        final agyCall = calls.firstWhere((c) => c.session == 'iso-agy-1');
        final cbCall = calls.firstWhere((c) => c.session == 'iso-cb-1');
        expect(agyCall.provider, antigravityBuiltinProviderId);
        expect(agyCall.providerName, isNot(startsWith('Claude ')));
        expect(cbCall.provider, codebuddyBuiltinProviderId);
        expect(cbCall.providerName, 'CodeBuddy (CN · Pro)');
      },
    );

    testWidgets(
      'T3-11: Workbench + TaskQueueView + Workspace _handOffTaskToChat applies model/effort without polluting Sidebar',
      (tester) async {
        final sandbox = E2eSandbox.create(autoTearDown: false);
        addTearDown(() => tester.runAsync(sandbox.dispose));
        await tester.binding.setSurfaceSize(const Size(1400, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        AutomationService.instance.storagePathOverride = null;
        TaskQueueService.instance
          ..resetForTest()
          ..storagePathOverride = null;

        late Directory repoDir;
        late WorktreeTask task;
        await tester.runAsync(() async {
          repoDir = await initTempGitRepo(sandbox.rootDir);
          AcpAgentService.instance.headlessRunnerOverride = ({
            required String agentId,
            required String prompt,
            required String cwd,
            String? model,
            String? effort,
            void Function(String chunk)? onChunk,
            void Function(Process proc)? onProcessStarted,
            Duration timeout = const Duration(minutes: 15),
          }) async {
            File(p.join(cwd, 'feature.txt')).writeAsStringSync('worktree change\n');
            return (ok: true, output: 'Worktree ready', error: null);
          };
          task = TaskQueueService.instance.enqueue(
            title: 'UI Handoff Task',
            prompt: 'Polish worktree feature',
            repoPath: repoDir.path,
            agentId: 'codex',
            model: 'gpt-5.5',
            effort: 'high',
            useWorktree: true,
          );
          await TaskQueueService.instance.runTask(task.id);
        });
        expect(task.status, WorktreeTaskStatus.review);
        expect(task.worktreePath, isNotEmpty);
        expect(p.equals(task.worktreePath, repoDir.path), isFalse);

        sandbox.onDispose(() async {
          AcpAgentService.instance.headlessRunnerOverride = null;
          await TaskQueueService.instance.discardTask(task.id);
          TaskQueueService.instance.resetForTest();
        });

        late KernelDescriptor codexDesc;
        codexDesc = KernelDescriptor(
          id: codexKernelId,
          label: 'Codex',
          icon: Icons.bolt_rounded,
          description: 'Codex',
          create: (ctx) => CodexKernel(
            codexDesc,
            _HandoffCodexTransport(),
            context: ctx,
            catalog: CodexCatalog(codexHome: p.join(sandbox.homeDir.path, '.codex')),
          ),
        );
        late KernelDescriptor agyDesc;
        agyDesc = KernelDescriptor(
          id: antigravityBuiltinProviderId,
          label: 'Antigravity',
          icon: Icons.rocket_launch_rounded,
          description: 'Antigravity',
          create: (ctx) => ClaudeCodeKernel(
            agyDesc,
            ctx,
            start: (launch) async => ScriptedClaudeTransport(launch: launch),
          ),
        );

        final prefs = MemoryPreferenceStore({
          'folders': [repoDir.path],
        });
        final ws = Workspace(
          projects: [Project.at(repoDir.path)],
          preferences: prefs,
          kernels: [agyDesc, codexDesc],
        );
        await tester.runAsync(ws.load);
        sandbox.onDispose(ws.dispose);

        await tester.pumpWidget(
          BaoCodeApp(
            workspace: ws,
            appLocale: AppLocale(storage: MemoryLocaleStorage(AppLocale.english)),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Tasks').first);
        await tester.pumpAndSettle();

        final chatBtn = find.text('Chat');
        expect(chatBtn, findsAtLeastNWidgets(1));
        await tester.tap(chatBtn.first);
        final handoffDeadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(handoffDeadline)) {
          final draft =
              ws.current?.session.draft.pendingMessage?.text ??
              ws.current?.session.draft.content ??
              '';
          if (ws.current != null && draft.contains(task.worktreePath)) {
            break;
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();

        final current = ws.current;
        expect(current, isNotNull);
        expect(
          p.equals(current!.session.kernelContext.cwd ?? '', repoDir.path),
          isTrue,
          reason:
              'Handed-off chat session must anchor on task.repoPath '
              'so Sidebar stays unpolluted',
        );
        expect(current.session.kernel.id, codexKernelId);
        final draftText =
            current.session.draft.pendingMessage?.text ??
            current.session.draft.content ??
            '';
        expect(draftText, contains(task.worktreePath));
        expect(draftText, contains(task.title));
        expect(draftText, contains(task.prompt));

        expect(
          current.session.models?.selected.id,
          'gpt-5.5',
          reason: 'Handed-off chat session must apply task.model',
        );
        expect(
          current.session.selected(KernelChoiceKind.effort),
          'high',
          reason: 'Handed-off chat session must apply task.effort',
        );

        expect(
          ws.sidebarProjects.map((pr) => pr.path).toList(),
          [repoDir.path],
          reason: 'Task handoff must NOT pollute Workspace.sidebarProjects with worktreePath',
        );
        final savedFolders =
            (prefs.preferences['folders'] as List?)?.cast<String>() ?? const [];
        expect(
          savedFolders.any((f) => p.equals(f, task.worktreePath)),
          isFalse,
          reason: 'Task handoff must NOT persist worktreePath into folders preferences',
        );
        expect(
          find.descendant(
            of: find.byType(Sidebar),
            matching: find.text(p.basename(task.worktreePath)),
          ),
          findsNothing,
          reason: 'Sidebar must NOT render ephemeral worktree folder as a project',
        );
      },
    );

    test(
      'T3-12: F1 static analysis gate + multi-kernel KernelRegistry & ClaudeCore public contract',
      () async {
        final e2eAnalyze = await AnalyzeHelper.runFlutterAnalyze(
          targets: const ['test/e2e'],
        );
        expect(e2eAnalyze.exitCode, 0, reason: e2eAnalyze.stdout);
        expect(e2eAnalyze.stdout, contains('No issues found!'));

        final repoAnalyze = await AnalyzeHelper.runFlutterAnalyze();
        expect(repoAnalyze.exitCode, 0, reason: repoAnalyze.stdout);
        expect(repoAnalyze.stdout, contains('No issues found!'));

        expect(ClaudeCore.values, [ClaudeCore.antigravity, ClaudeCore.builtin]);
        final sandbox = E2eSandbox.create();
        ClaudeCore.antigravityInstalled = () => false;
        expect(ClaudeCore.parse('cli'), ClaudeCore.builtin);
        expect(sandbox.rootDir.existsSync(), isTrue);

        expect(KernelRegistry.antigravity.catalog, isA<SessionCatalog>());
        expect(KernelRegistry.codebuddy.catalog, isA<SessionCatalog>());
        expect(KernelRegistry.claudeCode.catalog, isA<SessionCatalog>());
        expect(
          KernelRegistry.codex.catalog,
          isA<SessionCatalog>(),
          reason: 'KernelRegistry.codex must wire CodexCatalog (F10)',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'T3-13: F9 Debug REPL evaluateLazy + ConversationSearch + CustomizationStore integration',
      () async {
        final sandbox = E2eSandbox.create();
        sandbox.useClaudeEnvironment(sandbox.processEnv);
        const debugNeedle = 'lazy_debug_symbol_t3_13';

        final factory = _ScriptedDapFactoryT3();
        final dbg = DebugService(
          host: DebugServiceHost(),
          storage: MemoryDebugStorageBackend(),
          fileStore: MemoryLaunchFileStore(),
        );
        dbg.registry.setExtensions([
          const DebuggerExtension(
            id: 'test.t3',
            debuggers: [
              {'type': 'fake', 'label': 'Fake'},
            ],
          ),
        ]);
        dbg.registry.registerDebugAdapterFactory(['fake'], factory);
        await dbg.configurationManager.initialize();
        sandbox.onDispose(() async {
          await dbg.stopSession(null);
          dbg.dispose();
        });

        expect(
          await dbg.startDebugging(null, {
            'type': 'fake',
            'request': 'launch',
            'name': 'T3',
          }),
          isTrue,
        );
        await waitUntil(() => dbg.viewModel.focusedStackFrame != null);
        final session = dbg.model.getSessions().single;
        final frame = dbg.viewModel.focusedStackFrame!;

        final evalResult = ReplEvaluationResult(debugNeedle);
        expect(
          await evalResult.evaluateExpression(
            debugNeedle,
            session,
            frame,
            'repl',
            keepLazyVars: true,
          ),
          isTrue,
        );
        expect(evalResult.value, '<lazy>');
        await evalResult.evaluateLazy();
        expect(evalResult.value, '42 (lazy-loaded)');

        // Null/zero reference boundary on RawObjectReplElement.
        final raw = RawObjectReplElement('r-0', 'empty', const {});
        await expectLater(raw.evaluateLazy(), completes);

        // Pair with multi-kernel ConversationSearch & CustomizationStore switches.
        File(
          p.join(
            sandbox.homeDir.path,
            '.codex',
            'sessions',
            '2026',
            '11',
            '22',
            'rollout-2026-11-22T11-00-00-dbg-1.jsonl',
          ),
        )
          ..createSync(recursive: true)
          ..writeAsStringSync([
            jsonEncode({
              'type': 'session_meta',
              'payload': {'id': 'dbg-1', 'cwd': sandbox.projectDir.path},
            }),
            jsonEncode({
              'type': 'event_msg',
              'payload': {
                'type': 'user_message',
                'message': 'Inspect $debugNeedle in REPL',
              },
            }),
          ].join('\n'));

        final configDir = p.join(sandbox.homeDir.path, '.gemini', 'config');
        File(p.join(configDir, 'skills', 'dbg-skill', 'SKILL.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('---\nname: dbg-skill\n---\nDebug\n');
        ExtensionSwitches.current = () => const ExtensionSwitches(
          disabledSkills: {'dbg-skill'},
        );

        final store = CustomizationStore(
          configDir: configDir,
          homeDir: sandbox.homeDir.path,
        );
        final skills = await store.list(CustomizationKind.skills);
        expect(skills.firstWhere((s) => s.name == 'dbg-skill').enabled, isFalse);

        final search = ClaudeConversationSearch(
          configDir: sandbox.processEnv['CLAUDE_CONFIG_DIR'],
          homeDir: sandbox.homeDir.path,
        );
        final hits = await search.search(debugNeedle);
        expect(hits.map((h) => h.sessionId), contains('dbg-1'));
      },
    );
  });
}

class _HandoffCodexTransport implements CodexTransport {
  final StreamController<Map<String, Object?>> _messages =
      StreamController<Map<String, Object?>>.broadcast();
  bool _closed = false;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  void write(Map<String, Object?> message) {
    final id = message['id'];
    switch (message['method']) {
      case 'initialize':
        _emit({'id': id, 'result': const <String, Object?>{}});
      case 'thread/start':
        _emit({
          'id': id,
          'result': {'thread': {'id': 'th-handoff-1'}},
        });
      default:
        if (id != null) {
          _emit({'id': id, 'result': const <String, Object?>{}});
        }
    }
  }

  void _emit(Map<String, Object?> msg) {
    if (!_closed && !_messages.isClosed) _messages.add(msg);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_messages.close());
  }
}
