import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/antigravity/antigravity_accounts.dart';
import 'package:baocode/kernel/antigravity/antigravity_cli.dart';
import 'package:baocode/kernel/antigravity/antigravity_transport.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_translator.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/claude_code/claude_storage_io.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_account_models.dart' show CodeBuddyRegion;
import 'package:baocode/kernel/codebuddy/codebuddy_cli.dart';
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

const _fakeAgyW1LeadBody = r'''
Map<String, String> _discoverMcp(List<String> args, Map<String, String> env) {
  final sources = <String>[...args];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String? f;
    if (a.startsWith('--mcp-config=')) {
      f = a.substring('--mcp-config='.length);
    } else if (a == '--mcp-config' && i + 1 < args.length) {
      f = args[i + 1];
    } else if (a.startsWith('--settings=')) {
      f = a.substring('--settings='.length);
    } else if (a == '--settings' && i + 1 < args.length) {
      f = args[i + 1];
    } else if (a.startsWith('--add-dir=')) {
      final dir = a.substring('--add-dir='.length);
      f = '$dir${Platform.pathSeparator}.agents${Platform.pathSeparator}mcp_config.json';
    } else if (a == '--add-dir' && i + 1 < args.length) {
      final dir = args[i + 1];
      f = '$dir${Platform.pathSeparator}.agents${Platform.pathSeparator}mcp_config.json';
    }
    if (f != null && File(f).existsSync()) {
      try {
        sources.add(File(f).readAsStringSync());
      } on Object {}
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
  recordEvent({'type': 'launch', 'args': args});
  final mcp = _discoverMcp(args, env);
  String? codexWorkerId;
  String? cbWorkerId;

  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  var turn = 0;
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    turn++;
    recordEvent({'type': 'stdin', 'turn': turn, 'line': line});

    if (turn == 1 && mcp['url'] != null) {
      stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'w1-lead'}));
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

      final r1 = await _rpc(url, tok, {
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {
          'name': 'session_new',
          'arguments': {
            'text': 'Implement lib/feat.dart',
            'kernel': 'codex',
            'worktree': 'feat-w1',
            'title': 'Codex Implementer',
          },
        },
      });
      final t1 = ((((r1['body'] as Map)['result'] as Map)['content'] as List)
          .first as Map)['text'] as String;
      codexWorkerId = RegExp(r'^Started: (\S+)').firstMatch(t1)?[1];

      final r2 = await _rpc(url, tok, {
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {
          'name': 'session_new',
          'arguments': {
            'text': 'Review feat-w1 changes',
            'kernel': 'codebuddy-cli',
            'title': 'CodeBuddy Reviewer',
          },
        },
      });
      final t2 = ((((r2['body'] as Map)['result'] as Map)['content'] as List)
          .first as Map)['text'] as String;
      cbWorkerId = RegExp(r'^Started: (\S+)').firstMatch(t2)?[1];

      final listRes = await _rpc(url, tok, {
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/call',
        'params': {'name': 'session_list', 'arguments': const <String, Object?>{}},
      });
      recordEvent({
        'type': 'w1_spawned',
        'codexWorkerId': codexWorkerId,
        'cbWorkerId': cbWorkerId,
        'list': listRes,
      });

      stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'w1-lead'}));
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 1,
          'step_type': 'tool',
          'state': 'DONE',
          'tool_info': {
            'name': 'baocode:session_new',
            'parameters': {'kernel': jsonEncode('codex')},
            'output': t1,
          },
        },
      }));
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 2,
          'step_type': 'tool',
          'state': 'DONE',
          'tool_info': {
            'name': 'baocode:session_new',
            'parameters': {'kernel': jsonEncode('codebuddy-cli')},
            'output': t2,
          },
        },
      }));
      stdout.writeln(jsonEncode({
        'event': 'result',
        'result': {
          'conversation_id': 'w1-lead',
          'status': 'SUCCESS',
          'response': 'Spawned Codex & CodeBuddy workers',
        },
      }));
      await stdout.flush();
      continue;
    }

    if (mcp['url'] != null && codexWorkerId != null && line.contains('inspect_workers')) {
      final url = mcp['url']!;
      final tok = mcp['token'];
      final readRes = await _rpc(url, tok, {
        'jsonrpc': '2.0',
        'id': 10,
        'method': 'tools/call',
        'params': {
          'name': 'session_read',
          'arguments': {'session': codexWorkerId},
        },
      });
      final changesRes = await _rpc(url, tok, {
        'jsonrpc': '2.0',
        'id': 11,
        'method': 'tools/call',
        'params': {
          'name': 'session_changes',
          'arguments': {'session': codexWorkerId},
        },
      });
      final dupSend1 = await _rpc(url, tok, {
        'jsonrpc': '2.0',
        'id': 12,
        'method': 'tools/call',
        'params': {
          'name': 'session_send',
          'arguments': {'session': cbWorkerId, 'text': 'final check'},
        },
      });
      final dupSend2 = await _rpc(url, tok, {
        'jsonrpc': '2.0',
        'id': 13,
        'method': 'tools/call',
        'params': {
          'name': 'session_send',
          'arguments': {'session': cbWorkerId, 'text': 'final check'},
        },
      });
      recordEvent({
        'type': 'w1_inspected',
        'read': readRes,
        'changes': changesRes,
        'dup1': dupSend1,
        'dup2': dupSend2,
      });
    }

    stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'w1-lead'}));
    stdout.writeln(jsonEncode({
      'event': 'result',
      'result': {
        'conversation_id': 'w1-lead',
        'status': 'SUCCESS',
        'response': 'W1_TURN_$turn',
      },
    }));
    await stdout.flush();
  }
}
''';

const _fakeAgyW2LifecycleBody = r'''
Future<void> main(List<String> args) async {
  final env = Map<String, String>.from(Platform.environment);
  recordEvent({'type': 'launch', 'args': args});
  final editFile = env['FAKE_W2_EDIT_FILE'] ?? '';
  final planFile = env['FAKE_W2_PLAN_FILE'] ?? '';

  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  var turn = 0;
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    turn++;
    recordEvent({'type': 'stdin', 'turn': turn, 'line': line});

    stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'w2-agy-conv'}));
    if (line.contains('Create implementation plan') || args.contains('--mode=plan')) {
      if (planFile.isNotEmpty) {
        stdout.writeln(jsonEncode({
          'event': 'step_update',
          'step_update': {
            'step_index': 1,
            'step_type': 'tool',
            'state': 'DONE',
            'tool_info': {
              'name': 'write_file',
              'parameters': {
                'Path': jsonEncode(planFile),
                'Content': jsonEncode('# W2 Plan\n- Edit lib/app.dart'),
              },
              'output': 'Wrote plan',
            },
          },
        }));
      }
      stdout.writeln(jsonEncode({
        'event': 'result',
        'result': {
          'conversation_id': 'w2-agy-conv',
          'status': 'SUCCESS',
          'response': 'PLAN_READY',
        },
      }));
    } else if (line.contains('Execute plan') || line.contains('started implementing')) {
      if (editFile.isNotEmpty) {
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
                'Target': jsonEncode('int x = 1;'),
                'Replacement': jsonEncode('int x = 2;'),
              },
            },
          },
        }));
        await stdout.flush();
        await Future<void>.delayed(const Duration(milliseconds: 350));
        File(editFile).writeAsStringSync('int x = 2;\n');
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
                'Target': jsonEncode('int x = 1;'),
                'Replacement': jsonEncode('int x = 2;'),
              },
              'output': 'Edited',
            },
          },
        }));
      }
      stdout.writeln(jsonEncode({
        'event': 'result',
        'result': {
          'conversation_id': 'w2-agy-conv',
          'status': 'SUCCESS',
          'response': 'BUILD_COMPLETE',
        },
      }));
    } else {
      stdout.writeln(jsonEncode({
        'event': 'result',
        'result': {
          'conversation_id': 'w2-agy-conv',
          'status': 'SUCCESS',
          'response': 'IMAGE_ANALYZED',
        },
      }));
    }
    await stdout.flush();
  }
}
''';

const _fakeCodexW4Body = r'''
Future<void> main(List<String> args) async {
  recordEvent({'type': 'launch', 'args': args});
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  var turnSeq = 0;
  var awaitingApproval = false;
  String? activeTurnId;

  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    recordEvent({'type': 'stdin', 'line': line});
    final msg = (jsonDecode(line) as Map).cast<String, Object?>();
    final id = msg['id'];
    final method = msg['method'] as String?;

    if (method == null && id == 101 && awaitingApproval) {
      awaitingApproval = false;
      final tid = activeTurnId ?? 'w4-turn-1';
      stdout.writeln(jsonEncode({
        'method': 'item/completed',
        'params': {
          'item': {
            'id': 'msg-$tid',
            'type': 'agentMessage',
            'text': 'W4_PATCH_APPLIED',
          },
        },
      }));
      stdout.writeln(jsonEncode({
        'method': 'turn/completed',
        'params': {'turn': {'id': tid, 'status': 'completed'}},
      }));
      await stdout.flush();
      continue;
    }
    if (method == null && id == 102) {
      recordEvent({'type': 'unknown_rpc_reply', 'msg': msg});
      continue;
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
          'result': {'thread': {'id': 'w4-thread-main'}},
        }));
      case 'turn/start':
        final tid = 'w4-turn-${++turnSeq}';
        activeTurnId = tid;
        awaitingApproval = true;
        stdout.writeln(jsonEncode({'id': id, 'result': {'turn': {'id': tid}}}));
        stdout.writeln(jsonEncode({
          'method': 'turn/started',
          'params': {'turn': {'id': tid}},
        }));
        stdout.writeln(jsonEncode({
          'id': 102,
          'method': 'unknown/customPing',
          'params': const <String, Object?>{},
        }));
        stdout.writeln(jsonEncode({
          'method': 'item/fileChange/patchUpdated',
          'params': {
            'itemId': 'fc-w4',
            'changes': [
              {'path': 'lib/w4.dart', 'diff': '@@ -1,1 +1,1 @@\n-old\n+new'},
            ],
          },
        }));
        stdout.writeln(jsonEncode({
          'id': 101,
          'method': 'item/fileChange/requestApproval',
          'params': {'itemId': 'fc-w4', 'reason': 'Apply W4 patch'},
        }));
      case 'thread/fork':
        stdout.writeln(jsonEncode({
          'id': id,
          'result': {
            'thread': {
              'id': 'w4-forked-1',
              'path': Platform.environment['FAKE_W4_FORK_PATH'] ?? '',
            },
          },
        }));
      case 'thread/name/set':
      case 'thread/rollback':
        stdout.writeln(jsonEncode({'id': id, 'result': <String, Object?>{}}));
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
  group('Tier 4 — Real-World End-to-End Application Workflows (W1–W5)', () {
    test(
      'W1: Multi-Kernel Coordinator Workflow (agy lead + codex worktree implementer + codebuddy reviewer + SessionLinks)',
      () async {
        final sandbox = E2eSandbox.create(realHttp: true);
        SessionToolsSetting.current = () => true;
        final repoDir = await initTempGitRepo(
          sandbox.rootDir,
          name: 'w1_repo',
          files: {'README.md': '# W1 Repo\n'},
        );

        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_w1',
          dartBody: _fakeAgyW1LeadBody,
        );

        late KernelDescriptor agyDesc;
        late KernelDescriptor codexDesc;
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
              environment: sandbox.processEnv,
              launch: launch,
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
            _W1CodexTransport(),
            context: ctx,
            catalog: CodexCatalog(codexHome: p.join(sandbox.homeDir.path, '.codex')),
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
              sessionId: 'w1-cb-reviewer',
              models: const [
                {'value': 'glm-5.0-turbo', 'displayName': 'GLM 5.0 Turbo'},
              ],
              onUserTurn: (tr, _) =>
                  tr.emitSimpleReply('CB_REVIEW_APPROVED', model: 'glm-5.0-turbo'),
            ),
          ),
        );

        final ws = Workspace(
          kernels: [agyDesc, codexDesc, cbDesc],
          projects: [Project('w1_repo', repoDir.path)],
        );
        AgentThread? openedFromLink;
        final links = WorkspaceSessionLinks(
          ws,
          onOpen: (t) => openedFromLink = t,
        );
        SessionTools.register(ws);
        sandbox.onDispose(() {
          SessionTools.unregister();
          links.dispose();
          ws.dispose();
        });

        final lead = ws.startAgent(ws.projects.first, kernel: agyDesc);
        ws.rename(lead, 'Coordinator');
        final handed = links.handedFrom(lead.session);

        lead.session.send(const ComposerMessage(text: 'Coordinate implementation and review'));

        // Wait for both worker auto-reports (<agent-message>) on the agy lead.
        await waitUntil(
          () {
            var gotCodex = false;
            var gotCb = false;
            for (var i = 0; i < lead.session.itemCount; i++) {
              final item = lead.session.itemAt(i);
              if (item is UserMessageItem && item.fromAgent != null) {
                if (item.text.contains('CODEX_WORKTREE_DONE')) gotCodex = true;
                if (item.text.contains('CB_REVIEW_APPROVED')) gotCb = true;
              }
            }
            return gotCodex && gotCb;
          },
          timeout: const Duration(seconds: 20),
          reason: 'Lead must receive <agent-message> reports from both codex and codebuddy workers',
        );

        // Verify git worktree branch feat-w1 was created beside repoDir.
        final wtList = Process.runSync(
          'git',
          ['worktree', 'list'],
          workingDirectory: repoDir.path,
        );
        expect('${wtList.stdout}', contains('feat-w1'));

        await waitUntil(
          () =>
              handed.value.length == 2 &&
              handed.value.every((h) => h.status == HandedStatus.done),
          reason: 'WorkspaceSessionLinks must report both handed workers as done',
        );
        links.open(handed.value.first.id);
        expect(openedFromLink, isNotNull);

        // Turn 2 on lead: inspect session_read, session_changes, and session_send deduplication.
        lead.session.send(const ComposerMessage(text: 'inspect_workers'));
        await waitUntil(
          () => fakeAgy.readCaptures().any((e) => e['type'] == 'w1_inspected'),
          timeout: const Duration(seconds: 15),
        );
        final inspected = fakeAgy.readCaptures().firstWhere(
          (e) => e['type'] == 'w1_inspected',
        );
        expect(jsonEncode(inspected['read']), contains('CODEX_WORKTREE_DONE'));
        final changesText =
            ((((inspected['changes'] as Map)['body'] as Map)['result']
                        as Map)['content']
                    as List)
                .map((e) => (e as Map)['text'] as String)
                .join('\n');
        expect(
          changesText.replaceAll('\\', '/'),
          contains('lib/feat.dart +1 -0'),
        );
        expect(jsonEncode(inspected['dup1']), contains('Sent:'));
        expect(jsonEncode(inspected['dup2']), contains('Not delivered:'));

        // Verify SessionLinks InheritedWidget resolves live host cleanly.
        expect(SessionLinks(host: links, child: const SizedBox.shrink()).host, same(links));
      },
    );

    test(
      'W2: Full agy Coding Turn Lifecycle (image + @ suggestFiles + acceptEdits + EditWatch/ChangeReview + Plan + Usage + zero temp leaks)',
      () async {
        final sandbox = E2eSandbox.create();
        ClaudeCodeKernel.forgetAccount();
        sandbox.onDispose(ClaudeCodeKernel.forgetAccount);
        final repoDir = await initTempGitRepo(
          sandbox.rootDir,
          name: 'w2_repo',
          files: {'lib/app.dart': 'int x = 1;\n'},
        );
        File(p.join(repoDir.path, '.gitignore')).writeAsStringSync('build/\n');
        File(p.join(repoDir.path, 'build', 'ignored.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('const hidden = 1;\n');
        final editFile = File(p.join(repoDir.path, 'lib', 'app.dart'));
        final planFile = File(
          p.join(sandbox.homeDir.path, '.claude', 'plans', 'w2-plan.md'),
        )..createSync(recursive: true);

        Set<String> systemTempFiles() => Directory.systemTemp
            .listSync()
            .whereType<File>()
            .map((f) => p.basename(f.path))
            .where((n) => n.endsWith('.png') || n.contains('ayte_img') || n.contains('baocode'))
            .toSet();
        final beforeTemp = systemTempFiles();

        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_w2',
          dartBody: _fakeAgyW2LifecycleBody,
        );
        final agyDesc = KernelDescriptor(
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
                'FAKE_W2_EDIT_FILE': editFile.path,
                'FAKE_W2_PLAN_FILE': planFile.path,
              },
              launch: launch,
            ),
          ),
        );

        final session = ChatSession(
          kernel: agyDesc,
          kernels: [agyDesc],
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

        // Select acceptEdits permission mode.
        final acceptEdits = session.permissions!.options.firstWhere(
          (o) => o.id == 'acceptEdits',
          orElse: () => session.permissions!.options.first,
        );
        session.permissions!.onSelected(acceptEdits);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Turn 1: send image attachment.
        final pngBytes = Uint8List.fromList([
          137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
        ]);
        session.send(
          ComposerMessage(
            text: 'Inspect UI screenshot [Image #1]',
            images: [
              ImageAttachment(bytes: pngBytes, mediaType: 'image/png', number: 1),
            ],
          ),
        );
        await waitUntil(
          () => !session.isStreaming && session.lastReply == 'IMAGE_ANALYZED',
          timeout: const Duration(seconds: 15),
        );

        final launchArgs =
            (fakeAgy.firstLaunchCapture()!['args'] as List).cast<String>();
        expect(launchArgs, contains('--mode=accept-edits'));
        expect(launchArgs, isNot(contains('--dangerously-skip-permissions')));

        // @ file suggestions must include lib/app.dart and skip build/ignored.dart.
        final suggestions = await session.suggestFiles!('app');
        expect(
          suggestions.map((s) => s.path.replaceAll('\\', '/')),
          contains('lib/app.dart'),
        );
        final ignored = await session.suggestFiles!('ignored');
        expect(
          ignored.map((s) => s.path.replaceAll('\\', '/')),
          isNot(contains('build/ignored.dart')),
        );

        // Turn 2: switch to plan mode, write plan, then startPlan().
        final planMode = session.modes!.options.firstWhere((o) => o.id == 'plan');
        session.modes!.onSelected(planMode);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        session.send(const ComposerMessage(text: 'Create implementation plan'));
        await waitUntil(
          () => !session.isStreaming && session.canStartPlan,
          timeout: const Duration(seconds: 15),
          reason:
              'W2 Turn 2 must exit streaming with canStartPlan '
              '(streaming=${session.isStreaming}, canStartPlan=${session.canStartPlan}, '
              'mode=${session.modes?.selected.id})',
        );

        // Turn 3: startPlan -> startBuilding() + edit_file -> EditWatch + ChangeReview.
        session.startPlan('Execute plan');
        await waitUntil(
          () =>
              !session.isStreaming &&
              session.lastReply == 'BUILD_COMPLETE' &&
              session.fileChanges.isNotEmpty,
          timeout: const Duration(seconds: 15),
          reason:
              'W2 Turn 3 failed (streaming=${session.isStreaming}, '
              'lastReply=${session.lastReply}, '
              'fileChanges=${session.fileChanges.length}, '
              'mode=${session.modes?.selected.id})',
        );
        expect(session.modes?.selected.id, isNot('plan'));
        final lastStdinMsg =
            (jsonDecode(fakeAgy.stdinCaptures().last['line'] as String) as Map)['message']
                as Map;
        expect(
          lastStdinMsg['content'] as String,
          contains(ClaudeTranslator.planStartedNote(planFile.path)),
        );
        expect(editFile.readAsStringSync().replaceAll('\r\n', '\n'), 'int x = 2;\n');

        // Verify AntigravityAccounts usage refresh & non-prefixed UsageLedger.
        final accDir = Directory(
          p.join(sandbox.homeDir.path, '.ayte', 'antigravity_accounts', 'accounts'),
        )..createSync(recursive: true);
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        File(p.join(accDir.path, 'w2-acc.json')).writeAsStringSync(jsonEncode({
          'id': 'w2-acc',
          'email': 'w2@example.com',
          'name': 'W2',
          'token': {'access_token': 'ya29', 'refresh_token': '1//r', 'expires_in': 3600, 'expiry_timestamp': nowSec + 3600},
          'created_at': nowSec,
          'last_used': nowSec,
          'quota': {
            'last_updated': nowSec,
            'subscription_tier': 'PRO',
            'quota_groups': [
              {
                'display_name': 'Gemini',
                'buckets': [
                  {
                    'bucket_id': '5h',
                    'window': '5h',
                    'remaining_fraction': 0.9,
                    'reset_time': DateTime.now().toUtc().add(const Duration(hours: 2)).toIso8601String(),
                    'display_name': '5h',
                  },
                ],
              },
            ],
          },
        }));
        File(p.join(sandbox.homeDir.path, '.ayte', 'antigravity_accounts', 'accounts.json'))
            .writeAsStringSync(jsonEncode({
          'version': '2.0',
          'current_account_id': 'w2-acc',
          'accounts': [{'id': 'w2-acc', 'email': 'w2@example.com'}],
        }));
        final isolatedAccounts = AntigravityAccounts(
          dataDir: p.join(sandbox.homeDir.path, '.ayte', 'antigravity_accounts'),
        );
        sandbox.onDispose(isolatedAccounts.dispose);
        await isolatedAccounts.ensureInitialized();
        expect(isolatedAccounts.currentAccount?.email, 'w2@example.com');

        session.refreshUsage();
        await waitUntil(
          () => session.stats?.limits.isNotEmpty == true,
          timeout: const Duration(seconds: 10),
          reason: 'W2 AntigravityAccounts usage refresh must populate limits',
        );
        expect(session.stats!.limits.first.label, contains('Gemini'));

        session.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          systemTempFiles().difference(beforeTemp),
          isEmpty,
          reason: 'ImageAttachment temp files must not leak in Directory.systemTemp',
        );
      },
    );

    test(
      'W3: CodeBuddy + ExtensionSwitches + Workspace Reload Persistence',
      () async {
        final sandbox = E2eSandbox.create();
        CodeBuddyModels.syncForRegion(CodeBuddyRegion.global);
        sandbox.onDispose(() => CodeBuddyModels.syncForRegion(CodeBuddyRegion.cn));

        final configDir = p.join(sandbox.homeDir.path, '.gemini', 'config');
        File(p.join(configDir, 'skills', 'blocked-cb-skill', 'SKILL.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('---\nname: blocked-cb-skill\n---\nBlocked\n');
        File(p.join(configDir, 'skills', 'allowed-cb-skill', 'SKILL.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('---\nname: allowed-cb-skill\n---\nAllowed\n');
        File(p.join(configDir, 'mcp_config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode({
            'mcpServers': {
              'blocked-cb-mcp': {'command': 'echo', 'args': ['1']},
              'allowed-cb-mcp': {'command': 'echo', 'args': ['2']},
            },
          }));

        ExtensionSwitches.current = () => const ExtensionSwitches(
          disabledSkills: {'blocked-cb-skill'},
          disabledServers: {'blocked-cb-mcp'},
        );

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

        late KernelDescriptor cbDesc;
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
              sessionId: launch.resume ?? 'cb-w3-sess',
              onUserTurn: (tr, _) => tr.emitSimpleReply('W3_CB_OK', model: 'gpt-6-astra'),
            ),
          ),
        );

        final prefs = MemoryPreferenceStore();
        final ws1 = Workspace(
          kernels: [cbDesc],
          preferences: prefs,
          projects: [Project('w3_app', sandbox.projectDir.path)],
        );
        sandbox.onDispose(ws1.dispose);
        await ws1.load();

        final thread = ws1.startAgent(ws1.projects.first, kernel: cbDesc);
        const astraRef = '@$codebuddyBuiltinProviderId/gpt-6-astra';
        thread.session.models?.onSelected(
          thread.session.models!.options.firstWhere((o) => o.id == astraRef),
        );
        final ctxChoice = thread.session
            .modelSettings(astraRef)
            .firstWhere((s) => s.kind == KernelChoiceKind.context);
        ctxChoice.onSelected(ctxChoice.options.firstWhere((o) => o.id == '512000'));
        final effortChoice = thread.session
            .modelSettings(astraRef)
            .firstWhere((s) => s.kind == KernelChoiceKind.effort);
        effortChoice.onSelected(
          effortChoice.options.firstWhere((o) => o.id == 'medium'),
        );

        thread.session.send(const ComposerMessage(text: 'Persist W3 state'));
        await settleAgentTurn(thread);

        File(paths.sessionFile(sandbox.projectDir.path, 'cb-w3-sess'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
            '${jsonEncode({
              'type': 'user',
              'timestamp': DateTime.now().toUtc().toIso8601String(),
              'cwd': sandbox.projectDir.path,
              'sessionId': 'cb-w3-sess',
              'message': {'role': 'user', 'content': 'Persist W3 state'},
            })}\n'
            '${jsonEncode({
              'type': 'assistant',
              'timestamp': DateTime.now().toUtc().toIso8601String(),
              'cwd': sandbox.projectDir.path,
              'sessionId': 'cb-w3-sess',
              'message': {
                'id': 'm-w3',
                'role': 'assistant',
                'model': 'gpt-6-astra',
                'content': [{'type': 'text', 'text': 'W3_CB_OK'}],
              },
            })}\n',
          );

        await waitUntil(() {
          final agents = prefs.preferences['agents'];
          return agents is Map &&
              agents['cb-w3-sess'] is Map &&
              (agents['cb-w3-sess'] as Map)['context'] == '512000' &&
              (agents['cb-w3-sess'] as Map)['effort'] == 'medium';
        });
        ws1.dispose();

        // Reload Workspace #2 and verify kernel, model, context, effort, and ExtensionSwitches.
        final ws2 = Workspace(kernels: [cbDesc], preferences: prefs);
        sandbox.onDispose(ws2.dispose);
        await ws2.load();

        final reloaded = ws2.threads.firstWhere(
          (t) => t.record?.id == 'cb-w3-sess',
        );
        expect(reloaded.kernel.id, codebuddyBuiltinProviderId);
        expect(ws2.keptChoice(reloaded, KernelChoiceKind.model), astraRef);
        expect(ws2.keptChoice(reloaded, KernelChoiceKind.context), '512000');
        expect(ws2.keptChoice(reloaded, KernelChoiceKind.effort), 'medium');

        final store = CustomizationStore(
          configDir: configDir,
          homeDir: sandbox.homeDir.path,
        );
        final skills = await store.list(CustomizationKind.skills);
        final mcps = await store.list(CustomizationKind.mcps);
        expect(
          skills.firstWhere((s) => s.name == 'blocked-cb-skill').enabled,
          isFalse,
        );
        expect(
          skills.firstWhere((s) => s.name == 'allowed-cb-skill').enabled,
          isNot(false),
        );
        expect(
          mcps.firstWhere((m) => m.name == 'blocked-cb-mcp').enabled,
          isFalse,
        );
      },
    );

    test(
      'W4: Codex Multi-Turn Image + Approval + Fork + Multi-Kernel Search (via .cmd shim)',
      () async {
        final sandbox = E2eSandbox.create();
        final codexHome = p.join(sandbox.homeDir.path, '.codex');
        final forkPath = p.join(
          codexHome,
          'sessions',
          '2026',
          '11',
          '22',
          'rollout-2026-11-22T12-00-00-w4-forked-1.jsonl',
        );

        final fakeBin = Directory(p.join(sandbox.rootDir.path, 'w4_cmd_bin'));
        final fakeCodex = FakeCliExecutable.create(
          fakeBin,
          name: 'codex',
          nativeExeOnWindows: false,
          dartBody: _fakeCodexW4Body,
        );
        sandbox.useClaudeEnvironment({
          ..._envWithIsolatedPath(sandbox.processEnv, fakeBin.path),
          'FAKE_W4_FORK_PATH': forkPath,
        });
        sandbox.onDispose(ProcessCodexTransport.stopAll);

        final kernel = CodexKernel(
          KernelRegistry.codex,
          ProcessCodexTransport(cwd: sandbox.projectDir.path),
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: CodexCatalog(codexHome: codexHome),
        );
        sandbox.onDispose(kernel.dispose);

        final healthStates = <KernelHealthStatus>[kernel.health.status];
        final events = <KernelEvent>[];
        final sub = kernel.events.listen((e) {
          events.add(e);
          if (e is KernelInfoChanged) healthStates.add(kernel.health.status);
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));

        kernel.prepare();
        await waitUntil(
          () => kernel.health.status == KernelHealthStatus.ready,
          timeout: const Duration(seconds: 15),
        );
        expect(healthStates, containsAllInOrder([
          KernelHealthStatus.idle,
          KernelHealthStatus.starting,
          KernelHealthStatus.ready,
        ]));

        // Turn 1: send image attachment, handle unknown RPC, approve DiffPreview.
        final pngBytes = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);
        kernel.send(
          KernelTurn(
            id: 'w4-t1',
            text: 'Patch from screenshot',
            images: [
              ImageAttachment(bytes: pngBytes, mediaType: 'image/png', number: 1),
            ],
          ),
        );
        await waitUntil(
          () => events.whereType<InteractionRequested>().any(
            (e) => e.request is ApprovalRequest,
          ),
          timeout: const Duration(seconds: 15),
        );
        final approval = events
            .whereType<InteractionRequested>()
            .lastWhere((e) => e.request is ApprovalRequest)
            .request as ApprovalRequest;
        expect(approval.preview, isA<DiffPreview>());
        expect((approval.preview as DiffPreview).path, 'lib/w4.dart');

        kernel.answer(approval.id, const ApprovalAnswer(ApprovalDecision.allowOnce));
        await waitUntil(
          () => events.whereType<TurnEnded>().any((e) => e.turnId == 'w4-t1'),
          timeout: const Duration(seconds: 15),
        );

        final turnStartLog = fakeCodex
            .stdinCaptures()
            .firstWhere((c) => '${c['line']}'.contains('"turn/start"'));
        expect(
          '${turnStartLog['line']}',
          contains('data:image/png;base64,${base64Encode(pngBytes)}'),
        );

        // Rename & fork session.
        kernel.rename('W4 Main Session');
        final forked = await kernel.fork(title: 'W4 Forked Branch');
        expect(forked, isNotNull);
        expect(forked!.id, 'w4-forked-1');
        expect(forked.title, 'W4 Forked Branch');

        // Multi-kernel ConversationSearch across agy, claude, and codex.
        const token = 'W4_CROSS_KERNEL_TOKEN';
        File(
          p.join(
            sandbox.homeDir.path,
            '.gemini',
            'antigravity-cli',
            'brain',
            'w4-agy',
            '.system_generated',
            'logs',
            'transcript.jsonl',
          ),
        )
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '${jsonEncode({'type': 'USER_INPUT', 'content': '<USER_REQUEST>agy $token</USER_REQUEST>'})}\n',
          );
        File(p.join(sandbox.homeDir.path, '.claude', 'projects', '-w4', 'w4-cc.jsonl'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '${jsonEncode({'type': 'user', 'message': {'role': 'user', 'content': 'claude $token'}})}\n',
          );
        File(forkPath)
          ..createSync(recursive: true)
          ..writeAsStringSync([
            jsonEncode({
              'type': 'session_meta',
              'payload': {'id': 'w4-forked-1', 'cwd': sandbox.projectDir.path},
            }),
            jsonEncode({
              'type': 'event_msg',
              'payload': {'type': 'user_message', 'message': 'codex $token'},
            }),
          ].join('\n'));

        final search = ClaudeConversationSearch(
          configDir: sandbox.processEnv['CLAUDE_CONFIG_DIR'],
          homeDir: sandbox.homeDir.path,
        );
        final hits = await search.search(token);
        expect(
          hits.map((h) => h.sessionId).toSet(),
          containsAll(['w4-agy', 'w4-cc', 'w4-forked-1']),
          reason: 'ConversationSearch must surface agy, claude, and codex sessions (F9)',
        );

        kernel.dispose();
        await kernel.stopped;
      },
    );

    testWidgets(
      'W5: Headless Automation -> Worktree Task -> Workbench Chat Handoff -> Dirty Guard -> Clean Merge & AyteIpcServer CI Loop',
      (tester) async {
        final sandbox = E2eSandbox.create(realHttp: true, autoTearDown: false);
        addTearDown(() => tester.runAsync(sandbox.dispose));
        await tester.binding.setSurfaceSize(const Size(1400, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        TaskQueueService.instance
          ..resetForTest()
          ..storagePathOverride = p.join(sandbox.dataDir.path, 'tasks.json');
        AutomationService.instance.storagePathOverride = p.join(
          sandbox.dataDir.path,
          'automations.json',
        );
        AutomationService.instance.registerTools();

        String? capturedAgent;
        String? capturedModel;
        String? capturedEffort;
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
          capturedAgent = agentId;
          capturedModel = model;
          capturedEffort = effort;
          File(p.join(cwd, 'ci_artifact.txt'))
              .writeAsStringSync('generated by W5 automation\n');
          onChunk?.call('W5_CODEX_COMPLETE\n');
          return (ok: true, output: 'W5_CODEX_COMPLETE', error: null);
        };
        final ipc = AyteIpcServer.instance..homeOverride = sandbox.homeDir.path;

        late Directory repoDir;
        late String createdTaskId;
        late String portStr;
        late String token;

        sandbox.onDispose(() async {
          AcpAgentService.instance.headlessRunnerOverride = null;
          AutomationService.instance.storagePathOverride = null;
          for (final r in [...AutomationService.instance.rules]) {
            AutomationService.instance.deleteRule(r.id);
          }
          await ipc.stop();
          for (final t in [...TaskQueueService.instance.tasks]) {
            if (t.status == WorktreeTaskStatus.running ||
                t.status == WorktreeTaskStatus.queued) {
              await TaskQueueService.instance.cancelTask(t.id);
            }
            await TaskQueueService.instance.discardTask(t.id);
          }
          if (TaskQueueService.instance.tasks.isNotEmpty) {
            await TaskQueueService.instance.flushForTest();
          }
          TaskQueueService.instance
            ..resetForTest()
            ..storagePathOverride = null;
        });

        late Map<String, Object?> toolRes;
        late String ruleId;
        late bool ipcRunning;
        int? unauthStatus;
        int? triggerStatus;
        int? getTaskStatus;
        Map<String, Object?>? getTaskJson;

        await tester.runAsync(() async {
          repoDir = await initTempGitRepo(sandbox.rootDir, name: 'w5_repo');

          toolRes = await ClaudeSdkTools.handle(
            {
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'tools/call',
              'params': {
                'name': 'create_automation',
                'arguments': {
                  'name': 'W5 CI Loop',
                  'prompt': 'Generate CI artifact in worktree',
                  'cron': '0 3 * * *',
                  'cwd': repoDir.path,
                  'agentId': 'codex',
                  'model': 'gpt-5.5',
                  'effort': 'high',
                  'useWorktree': true,
                },
              },
            },
            ClaudeSdkCall(cwd: repoDir.path),
          );
          final rule = AutomationService.instance.rules.firstWhere(
            (r) => r.name == 'W5 CI Loop',
          );
          ruleId = rule.id;

          await ipc.start();
          ipcRunning = ipc.running;
          if (!ipcRunning) return;

          final info = jsonDecode(File(ipc.ipcInfoPath).readAsStringSync()) as Map;
          portStr = '${info['port']}';
          token = info['token'] as String;
          final baseUri = Uri.parse('http://127.0.0.1:$portStr');

          final unauth = await McpHttpProbe(
            baseUri.replace(path: '/automations/run'),
          ).postJsonRpc({'id': ruleId}, omitAuth: true);
          unauthStatus = unauth.statusCode;

          final trigger = await McpHttpProbe(
            baseUri.replace(path: '/automations/run'),
            bearerToken: token,
          ).postJsonRpc({'id': ruleId});
          triggerStatus = trigger.statusCode;
          if (triggerStatus != 200) return;

          await waitUntil(
            () => TaskQueueService.instance.tasks.isNotEmpty,
            timeout: const Duration(seconds: 10),
          );
          final task = TaskQueueService.instance.tasks.first;
          createdTaskId = task.id;
          await waitUntil(
            () => task.status == WorktreeTaskStatus.review,
            timeout: const Duration(seconds: 20),
            reason:
                'Triggered worktree task must reach review status '
                '(status=${task.status}, error=${task.error})',
          );

          final getTask = await McpHttpProbe(
            baseUri.replace(path: '/tasks/${task.id}'),
            bearerToken: token,
          ).requestMethod('GET');
          getTaskStatus = getTask.statusCode;
          getTaskJson = getTask.json;
        });

        expect((toolRes['result'] as Map)['isError'], isNot(true));
        expect(
          ipcRunning,
          isTrue,
          reason: 'AyteIpcServer.start() must bind when homeOverride is set (F10)',
        );
        expect(unauthStatus, 401);
        expect(triggerStatus, 200);
        expect(getTaskStatus, 200);
        expect(getTaskJson?['task'], isA<Map>());
        expect(capturedAgent, 'codex');
        expect(capturedModel, 'gpt-5.5');
        expect(capturedEffort, 'high');

        // Disable file persistence before entering FakeAsync widget interactions.
        await tester.runAsync(() => TaskQueueService.instance.flushForTest());
        TaskQueueService.instance.storagePathOverride = null;
        AutomationService.instance.storagePathOverride = null;

        late KernelDescriptor codexDesc;
        codexDesc = KernelDescriptor(
          id: codexKernelId,
          label: 'Codex',
          icon: Icons.bolt_rounded,
          description: 'Codex',
          create: (ctx) => CodexKernel(
            codexDesc,
            _W5WidgetCodexTransport(),
            context: ctx,
            catalog: CodexCatalog(codexHome: p.join(sandbox.homeDir.path, '.codex')),
          ),
        );
        final prefs = MemoryPreferenceStore({
          'folders': [repoDir.path],
        });
        final ws = Workspace(
          projects: [Project.at(repoDir.path)],
          preferences: prefs,
          kernels: [codexDesc],
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
        final task = TaskQueueService.instance.byId(createdTaskId)!;
        expect(task.hasDiff, isTrue);

        await tester.tap(find.text('Chat').first);
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
        expect(current.session.models?.selected.id, 'gpt-5.5');
        expect(current.session.selected(KernelChoiceKind.effort), 'high');
        expect(ws.sidebarProjects.map((pr) => pr.path).toList(), [repoDir.path]);
        final savedFolders =
            (prefs.preferences['folders'] as List?)?.cast<String>() ?? const [];
        expect(
          savedFolders.any((f) => p.equals(f, task.worktreePath)),
          isFalse,
        );
        expect(
          find.descendant(
            of: find.byType(Sidebar),
            matching: find.text(p.basename(task.worktreePath)),
          ),
          findsNothing,
        );

        // Dirty main repo guard & clean approveAndMerge.
        await tester.runAsync(() async {
          final mainReadme = File(p.join(repoDir.path, 'README.md'));
          final origReadme = mainReadme.readAsStringSync();
          mainReadme.writeAsStringSync('# Dirty local edit\n');

          final blockedMerge = await TaskQueueService.instance.approveAndMerge(task.id);
          expect(blockedMerge.ok, isFalse);
          expect(task.status, WorktreeTaskStatus.review);
          expect(Directory(task.worktreePath).existsSync(), isTrue);
          expect(mainReadme.readAsStringSync(), '# Dirty local edit\n');

          mainReadme.writeAsStringSync(origReadme);
          final cleanMerge = await TaskQueueService.instance.approveAndMerge(task.id);
          expect(cleanMerge.ok, isTrue, reason: cleanMerge.message);
          expect(task.status, WorktreeTaskStatus.merged);
          expect(Directory(task.worktreePath).existsSync(), isFalse);
          expect(File(p.join(repoDir.path, 'ci_artifact.txt')).existsSync(), isTrue);
        });
      },
    );
  });
}

class _W1CodexTransport implements CodexTransport {
  final StreamController<Map<String, Object?>> _messages =
      StreamController<Map<String, Object?>>.broadcast();
  bool _closed = false;
  int _seq = 0;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  void write(Map<String, Object?> message) {
    final id = message['id'];
    switch (message['method']) {
      case 'initialize':
        _emit({'id': id, 'result': const <String, Object?>{}});
      case 'model/list':
        _emit({
          'id': id,
          'result': {
            'data': [
              {
                'id': 'gpt-5.4',
                'displayName': 'GPT-5.4',
                'isDefault': true,
                'supportedReasoningEfforts': [
                  {'reasoningEffort': 'high'},
                ],
                'defaultReasoningEffort': 'high',
              },
            ],
          },
        });
      case 'thread/start':
        _emit({
          'id': id,
          'result': {'thread': {'id': 'w1-codex-thread'}},
        });
      case 'turn/start':
        final tid = 'w1-cdx-turn-${++_seq}';
        _emit({'id': id, 'result': {'turn': {'id': tid}}});
        scheduleMicrotask(() {
          _emit({'method': 'turn/started', 'params': {'turn': {'id': tid}}});
          _emit({
            'method': 'item/completed',
            'params': {
              'item': {
                'id': 'fc-$tid',
                'type': 'fileChange',
                'status': 'completed',
                'changes': [
                  {
                    'path': 'lib/feat.dart',
                    'kind': {'type': 'add'},
                    'diff': '@@ -0,0 +1,1 @@\n+void feat() {}',
                  },
                ],
              },
            },
          });
          _emit({
            'method': 'item/completed',
            'params': {
              'item': {
                'id': 'msg-$tid',
                'type': 'agentMessage',
                'text': 'CODEX_WORKTREE_DONE',
              },
            },
          });
          _emit({
            'method': 'turn/completed',
            'params': {'turn': {'id': tid, 'status': 'completed'}},
          });
        });
      default:
        if (id != null) _emit({'id': id, 'result': const <String, Object?>{}});
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

class _W5WidgetCodexTransport implements CodexTransport {
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
          'result': {'thread': {'id': 'w5-widget-codex'}},
        });
      default:
        if (id != null) _emit({'id': id, 'result': const <String, Object?>{}});
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
