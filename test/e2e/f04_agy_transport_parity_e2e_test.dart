import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/antigravity/antigravity_accounts.dart';
import 'package:baocode/kernel/antigravity/antigravity_transport.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_translator.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/queued_messages.dart';
import 'package:baocode/usage/usage_ledger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/e2e_env.dart';
import 'helpers/e2e_waiters.dart';
import 'helpers/fake_cli_harness.dart';

class _RecordingEditWatch implements EditWatch {
  final List<(String phase, String path)> calls = [];

  @override
  Future<void> beforeEdit(String path) async {
    calls.add(('before', path));
  }

  @override
  Future<void> afterEdit(String path) async {
    calls.add(('after', path));
  }
}

const _fakeAgyParityBody = r'''
Future<void> main(List<String> args) async {
  final env = Map<String, String>.from(Platform.environment);
  recordEvent({'type': 'launch', 'args': args, 'env': env});

  final scenario = env['FAKE_AGY_SCENARIO'] ?? 'basic';
  final targetFile = env['FAKE_AGY_EDIT_FILE'] ?? '';
  final planFile = env['FAKE_AGY_PLAN_FILE'] ?? '';
  final signalFile = env['FAKE_AGY_SIGNAL_FILE'] ?? '';
  var turn = 0;

  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    turn++;
    recordEvent({'type': 'stdin', 'turn': turn, 'line': line});

    if (scenario == 'edit_watch') {
      stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-edit-1'}));
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 1,
          'step_type': 'tool',
          'state': 'RUNNING',
          'tool_info': {
            'name': 'edit_file',
            'parameters': {
              'Path': jsonEncode(targetFile),
              'Target': jsonEncode('old'),
              'Replacement': jsonEncode('new'),
            },
          },
        },
      }));
      await stdout.flush();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      stdout.writeln(jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_index': 1,
          'step_type': 'tool',
          'state': 'DONE',
          'tool_info': {
            'name': 'edit_file',
            'parameters': {
              'Path': jsonEncode(targetFile),
              'Target': jsonEncode('old'),
              'Replacement': jsonEncode('new'),
            },
            'output': 'Edited',
          },
        },
      }));
      if (planFile.isNotEmpty) {
        stdout.writeln(jsonEncode({
          'event': 'step_update',
          'step_update': {
            'step_index': 2,
            'step_type': 'tool',
            'state': 'DONE',
            'tool_info': {
              'name': 'write_file',
              'parameters': {
                'Path': jsonEncode(planFile),
                'Content': jsonEncode('# Plan\n1. Step'),
              },
              'output': 'Wrote plan',
            },
          },
        }));
      }
      stdout.writeln(jsonEncode({
        'event': 'result',
        'result': {'conversation_id': 'conv-edit-1', 'status': 'SUCCESS', 'response': 'edited'},
      }));
      await stdout.flush();
      continue;
    }

    if (scenario == 'plan_flow') {
      stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-plan-1'}));
      if (turn == 1) {
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
                'Content': jsonEncode('# Plan\n- Build widget'),
              },
              'output': 'Plan written',
            },
          },
        }));
        stdout.writeln(jsonEncode({
          'event': 'result',
          'result': {
            'conversation_id': 'conv-plan-1',
            'status': 'SUCCESS',
            'response': 'Ready to implement?',
          },
        }));
      } else {
        stdout.writeln(jsonEncode({
          'event': 'result',
          'result': {
            'conversation_id': 'conv-plan-1',
            'status': 'SUCCESS',
            'response': 'Built',
          },
        }));
      }
      await stdout.flush();
      continue;
    }

    if (scenario == 'block_turn_1_on_signal') {
      stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-queue-1'}));
      await stdout.flush();
      if (turn == 1 && signalFile.isNotEmpty) {
        final sig = File(signalFile);
        for (var i = 0; i < 200 && !sig.existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      }
      stdout.writeln(jsonEncode({
        'event': 'result',
        'result': {
          'conversation_id': 'conv-queue-1',
          'status': 'SUCCESS',
          'response': 'turn $turn ok',
        },
      }));
      await stdout.flush();
      continue;
    }

    if (scenario == 'modify_file_turn') {
      stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-rev-1'}));
      if (targetFile.isNotEmpty) {
        File(targetFile).writeAsStringSync('v2');
      }
      stdout.writeln(jsonEncode({
        'event': 'result',
        'result': {
          'conversation_id': 'conv-rev-1',
          'status': 'SUCCESS',
          'response': 'modified',
        },
      }));
      await stdout.flush();
      continue;
    }

    final convId = env['FAKE_AGY_CONV_ID'] ?? 'conv-basic-$turn';
    stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': convId}));
    stdout.writeln(jsonEncode({
      'event': 'result',
      'result': {
        'conversation_id': convId,
        'status': 'SUCCESS',
        'response': 'ok',
      },
    }));
    await stdout.flush();
  }
}
''';

void main() {
  group('F4 Tier 1 — AntigravityTransport Permissions, Edits, Plans, MCP & Usage', () {
    test(
      'F4-T1-01: buildCliArguments maps permissionMode to --mode without unconditional bypass',
      () {
        final acceptEdits = AntigravityTransport.buildCliArguments(
          model: 'gemini-3.8-flash',
          effort: 'high',
          permissionMode: 'acceptEdits',
          maxContextTokens: 256000,
        );
        expect(acceptEdits, contains('--mode=accept-edits'));
        expect(acceptEdits, isNot(contains('--dangerously-skip-permissions')));

        final autoMode = AntigravityTransport.buildCliArguments(
          model: 'gemini-3.8-flash',
          effort: 'high',
          permissionMode: 'auto',
          maxContextTokens: 256000,
        );
        expect(autoMode, contains('--mode=auto'));
        expect(autoMode, isNot(contains('--dangerously-skip-permissions')));

        final planMode = AntigravityTransport.buildCliArguments(
          model: 'gemini-3.8-flash',
          effort: 'high',
          permissionMode: 'plan',
          maxContextTokens: 256000,
        );
        expect(planMode, contains('--mode=plan'));
        expect(planMode, isNot(contains('--dangerously-skip-permissions')));

        final bypassMode = AntigravityTransport.buildCliArguments(
          model: 'gemini-3.8-flash',
          effort: 'high',
          permissionMode: 'bypassPermissions',
          maxContextTokens: 256000,
        );
        expect(bypassMode, contains('--dangerously-skip-permissions'));
      },
    );

    test(
      'F4-T1-02: WatchesEdits invokes beforeEdit then afterEdit for source edits and skips plan files',
      () async {
        final sandbox = E2eSandbox.create();
        final target = File(p.join(sandbox.projectDir.path, 'a.dart'))
          ..writeAsStringSync('old');
        final planFile = File(
          p.join(sandbox.homeDir.path, '.claude', 'plans', 'watch-plan.md'),
        )..createSync(recursive: true);

        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f4_02',
          dartBody: _fakeAgyParityBody,
        );
        final watch = _RecordingEditWatch();
        final kernel = ClaudeCodeKernel(
          KernelRegistry.antigravity,
          KernelContext(cwd: sandbox.projectDir.path),
          start: (launch) async => AntigravityTransport.forTesting(
            executable: fakeAgy.executablePath,
            environment: {
              ...sandbox.processEnv,
              'FAKE_AGY_SCENARIO': 'edit_watch',
              'FAKE_AGY_EDIT_FILE': target.path,
              'FAKE_AGY_PLAN_FILE': planFile.path,
            },
            launch: launch,
          ),
        );
        sandbox.onDispose(kernel.dispose);
        kernel.editWatch = watch;

        final done = Completer<void>();
        final sub = kernel.events.listen((e) {
          if (e is TurnEnded && !done.isCompleted) done.complete();
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));

        kernel.send(const KernelTurn(id: 't1', text: 'edit a.dart'));
        await done.future.timeout(const Duration(seconds: 10));

        expect(
          watch.calls.any((c) => c.$1 == 'before' && p.equals(c.$2, target.path)),
          isTrue,
          reason: 'EditWatch.beforeEdit must be invoked for agy edit_file',
        );
        expect(
          watch.calls.any((c) => c.$1 == 'after' && p.equals(c.$2, target.path)),
          isTrue,
          reason: 'EditWatch.afterEdit must be invoked for agy edit_file',
        );
        final beforeIdx = watch.calls.indexWhere(
          (c) => c.$1 == 'before' && p.equals(c.$2, target.path),
        );
        final afterIdx = watch.calls.indexWhere(
          (c) => c.$1 == 'after' && p.equals(c.$2, target.path),
        );
        expect(beforeIdx, lessThan(afterIdx));
        expect(
          watch.calls.any((c) => p.equals(c.$2, planFile.path)),
          isFalse,
          reason: 'Plan file writes must not trigger EditWatch',
        );
      },
    );

    test(
      'F4-T1-03: StartsPlans surfaces PlanItem in plan mode and startBuilding switches out of plan',
      () async {
        final sandbox = E2eSandbox.create();
        final planFile = File(
          p.join(sandbox.homeDir.path, '.claude', 'plans', 'f4-plan.md'),
        )..createSync(recursive: true);

        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f4_03',
          dartBody: _fakeAgyParityBody,
        );
        final kernel = ClaudeCodeKernel(
          KernelRegistry.antigravity,
          KernelContext(cwd: sandbox.projectDir.path),
          start: (launch) async => AntigravityTransport.forTesting(
            executable: fakeAgy.executablePath,
            environment: {
              ...sandbox.processEnv,
              'FAKE_AGY_SCENARIO': 'plan_flow',
              'FAKE_AGY_PLAN_FILE': planFile.path,
            },
            launch: launch,
          ),
        );
        sandbox.onDispose(kernel.dispose);

        final items = <ChatItem>[];
        var turnsEnded = 0;
        final sub = kernel.events.listen((e) {
          if (e is ItemUpserted) items.add(e.item);
          if (e is TurnEnded) turnsEnded++;
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));

        kernel.mode.select('plan');
        kernel.send(const KernelTurn(id: 't1', text: 'design a plan'));
        await waitUntil(() => turnsEnded >= 1);

        expect(
          items.whereType<PlanItem>().isNotEmpty,
          isTrue,
          reason: 'Writing a plan in plan mode must surface a PlanItem',
        );

        kernel.startBuilding();
        expect(kernel.mode.selected, isNot('plan'));

        kernel.send(const KernelTurn(id: 't2', text: 'go build it'));
        await waitUntil(() => turnsEnded >= 2);
        final lastStdin = fakeAgy.stdinCaptures().last['line'] as String;
        final lastMsg = jsonDecode(lastStdin) as Map<String, Object?>;
        final content = (lastMsg['message'] as Map)['content'] as String;
        expect(
          content,
          contains(ClaudeTranslator.planStartedNote(planFile.path)),
        );
      },
    );

    test(
      'F4-T1-04: suggestFiles respects gitignore and ManagesMcpServers reflects .mcp.json',
      () async {
        final sandbox = E2eSandbox.create();
        final libFile = File(p.join(sandbox.projectDir.path, 'lib', 'hello.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('void hello() {}');
        expect(libFile.existsSync(), isTrue);
        File(p.join(sandbox.projectDir.path, '.gitignore')).writeAsStringSync('build/\n');
        File(p.join(sandbox.projectDir.path, 'build', 'secret.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('const secret = 1;');
        File(p.join(sandbox.projectDir.path, '.mcp.json')).writeAsStringSync(
          jsonEncode({
            'mcpServers': {
              'demo-server': {
                'command': 'echo',
                'args': ['hi'],
              },
            },
          }),
        );

        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f4_04',
          dartBody: _fakeAgyParityBody,
        );
        final kernel = ClaudeCodeKernel(
          KernelRegistry.antigravity,
          KernelContext(cwd: sandbox.projectDir.path),
          start: (launch) async => AntigravityTransport.forTesting(
            executable: fakeAgy.executablePath,
            environment: sandbox.processEnv,
            launch: launch,
          ),
        );
        sandbox.onDispose(kernel.dispose);

        final turnDone = Completer<void>();
        final sub = kernel.events.listen((e) {
          if (e is TurnEnded && !turnDone.isCompleted) turnDone.complete();
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));
        kernel.send(const KernelTurn(id: 't1', text: 'boot'));
        await turnDone.future.timeout(const Duration(seconds: 10));

        final suggestions = await kernel.suggestFiles('hello');
        final paths = suggestions.map((s) => s.path.replaceAll('\\', '/')).toList();
        expect(
          paths,
          contains('lib/hello.dart'),
          reason: 'suggestFiles must discover files in cwd matching query',
        );
        expect(paths, isNot(contains('build/secret.dart')));

        kernel.refreshMcpServers();
        await waitUntil(
          () => kernel.mcpServers?.any((s) => s.name == 'demo-server') ?? false,
          timeout: const Duration(seconds: 10),
          reason: 'refreshMcpServers must populate .mcp.json servers',
        );

        kernel.setMcpServerEnabled('demo-server', false);
        await waitUntil(
          () =>
              kernel.mcpServers
                  ?.where((s) => s.name == 'demo-server')
                  .firstOrNull
                  ?.status ==
              McpServerStatus.disabled,
          timeout: const Duration(seconds: 10),
        );
      },
    );

    test(
      'F4-T1-05: ReportsUsage queries AntigravityAccounts and _planName avoids Claude prefix',
      () async {
        final sandbox = E2eSandbox.create();
        ClaudeCodeKernel.forgetAccount();
        sandbox.onDispose(ClaudeCodeKernel.forgetAccount);

        // Seed isolated AntigravityAccounts store under sandbox.homeDir.
        final accDir = Directory(
          p.join(sandbox.homeDir.path, '.ayte', 'antigravity_accounts', 'accounts'),
        )..createSync(recursive: true);
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final accountJson = {
          'id': 'acc-e2e-1',
          'email': 'e2e@example.com',
          'name': 'E2E User',
          'token': {
            'access_token': 'ya29.test',
            'refresh_token': '1//test',
            'expires_in': 3599,
            'expiry_timestamp': nowSec + 3600,
          },
          'created_at': nowSec,
          'last_used': nowSec,
          'quota': {
            'last_updated': nowSec,
            'subscription_tier': 'PRO',
            'models': [
              {
                'name': 'gemini-3.8-flash',
                'percentage': 80,
                'percentage_known': true,
                'reset_time': DateTime.now()
                    .toUtc()
                    .add(const Duration(hours: 3))
                    .toIso8601String(),
              },
            ],
            'quota_groups': [
              {
                'display_name': 'Gemini Models',
                'buckets': [
                  {
                    'bucket_id': 'gemini-5h',
                    'window': '5h',
                    'remaining_fraction': 0.8,
                    'reset_time': DateTime.now()
                        .toUtc()
                        .add(const Duration(hours: 3))
                        .toIso8601String(),
                    'display_name': '5h limit',
                  },
                  {
                    'bucket_id': 'gemini-weekly',
                    'window': 'weekly',
                    'remaining_fraction': 0.9,
                    'reset_time': DateTime.now()
                        .toUtc()
                        .add(const Duration(days: 5))
                        .toIso8601String(),
                    'display_name': 'Weekly limit',
                  },
                ],
              },
            ],
          },
        };
        File(p.join(accDir.path, 'acc-e2e-1.json'))
            .writeAsStringSync(jsonEncode(accountJson));
        File(
          p.join(
            sandbox.homeDir.path,
            '.ayte',
            'antigravity_accounts',
            'accounts.json',
          ),
        ).writeAsStringSync(
          jsonEncode({
            'version': '2.0',
            'current_account_id': 'acc-e2e-1',
            'accounts': [
              {'id': 'acc-e2e-1', 'email': 'e2e@example.com'},
            ],
          }),
        );

        // Verify isolated AntigravityAccounts store inside sandbox.homeDir.
        // Note: AntigravityTransport.start uses AntigravityAccounts.instance
        // (redirecting the singleton to respect sandbox.homeDir is an M3 dependency).
        final isolatedAccounts = AntigravityAccounts(
          dataDir: p.join(
            sandbox.homeDir.path,
            '.ayte',
            'antigravity_accounts',
          ),
        );
        sandbox.onDispose(isolatedAccounts.dispose);
        await isolatedAccounts.ensureInitialized();
        expect(isolatedAccounts.dataDirectoryPath, startsWith(sandbox.homeDir.path));
        expect(isolatedAccounts.currentAccount?.email, 'e2e@example.com');
        expect(
          isolatedAccounts.currentAccount?.quota?.models.firstOrNull?.percentage,
          80,
        );

        // Verify _planName behavior via UsageLedger on Antigravity CLI subscriptionType.
        late ScriptedClaudeTransport scripted;
        final planKernel = ClaudeCodeKernel(
          KernelRegistry.antigravity,
          KernelContext(cwd: sandbox.projectDir.path),
          start: (launch) async => scripted = ScriptedClaudeTransport(
            launch: launch,
            account: const {'subscriptionType': 'Antigravity CLI'},
            onUserTurn: (tr, _) => tr.emitSimpleReply(
              'ok',
              model: 'gemini-3.8-flash',
              inputTokens: 120,
              outputTokens: 30,
            ),
          ),
        );
        sandbox.onDispose(planKernel.dispose);
        final ended = Completer<void>();
        final sub1 = planKernel.events.listen((e) {
          if (e is TurnEnded && !ended.isCompleted) ended.complete();
        });
        sandbox.onDispose(() => unawaited(sub1.cancel()));
        planKernel.send(const KernelTurn(id: 't1', text: 'hi'));
        await ended.future.timeout(const Duration(seconds: 5));
        expect(scripted.writtenMessages, isNotEmpty);

        UsageLedger.current.flush();
        final days = await UsageLedger.current.storage.days();
        final calls = await UsageLedger.current.storage.read(days);
        expect(calls, isNotEmpty);
        expect(
          calls.first.providerName,
          'Antigravity CLI',
          reason:
              'Antigravity subscriptionType must never be prefixed with "Claude "',
        );
        expect(calls.first.providerName, isNot(startsWith('Claude ')));

        planKernel.dispose();
        await planKernel.stopped;

        // Verify get_usage on AntigravityTransport populates accountLimits.
        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f4_05',
          dartBody: _fakeAgyParityBody,
        );
        final agyKernel = ClaudeCodeKernel(
          KernelRegistry.antigravity,
          KernelContext(cwd: sandbox.projectDir.path),
          start: (launch) async => AntigravityTransport.forTesting(
            executable: fakeAgy.executablePath,
            environment: sandbox.processEnv,
            launch: launch,
          ),
        );
        sandbox.onDispose(agyKernel.dispose);
        StatsReported? lastStats;
        final sub2 = agyKernel.events.listen((e) {
          if (e is StatsReported) lastStats = e;
        });
        sandbox.onDispose(() => unawaited(sub2.cancel()));
        await agyKernel.refreshUsage();
        expect(
          agyKernel.accountLimits,
          isNotEmpty,
          reason:
              'AntigravityTransport get_usage must report quota windows from AntigravityAccounts',
        );
        expect(lastStats?.stats.limitsState, isNot(LimitsState.unavailable));
      },
    );
  });

  group('F4 Tier 2 — Queue Cancellation, Honest Rewind, /clear & Temp Hygiene', () {
    test(
      'F4-T2-01: cancelQueued removes unstarted turn from AntigravityTransport queue',
      () async {
        final sandbox = E2eSandbox.create();
        final signalFile = File(p.join(sandbox.rootDir.path, 'release.sig'));
        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f4_t2_01',
          dartBody: _fakeAgyParityBody,
        );

        final kernel = ClaudeCodeKernel(
          KernelRegistry.antigravity,
          KernelContext(
            cwd: sandbox.projectDir.path,
            workspace: () => KernelWorkspace(
              folders: [sandbox.projectDir.path],
              queuedMessages: QueuedMessages.duringTurn,
            ),
          ),
          start: (launch) async => AntigravityTransport.forTesting(
            executable: fakeAgy.executablePath,
            environment: {
              ...sandbox.processEnv,
              'FAKE_AGY_SCENARIO': 'block_turn_1_on_signal',
              'FAKE_AGY_SIGNAL_FILE': signalFile.path,
            },
            launch: launch,
          ),
        );
        sandbox.onDispose(() {
          if (!signalFile.existsSync()) signalFile.writeAsStringSync('go');
          kernel.dispose();
        });

        final removedIds = <String>[];
        var turnsEnded = 0;
        final sub = kernel.events.listen((e) {
          if (e is ItemRemoved) removedIds.add(e.id);
          if (e is TurnEnded) turnsEnded++;
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));

        kernel.send(const KernelTurn(id: 'turn-1', text: 'FIRST_TURN_PROMPT'));
        await waitUntil(() => fakeAgy.stdinCaptures().isNotEmpty);

        kernel.send(const KernelTurn(id: 'turn-2', text: 'CANCELLED_TURN_2'));
        await pumpEventQueue();

        final cancelled = await kernel.cancelQueued('turn-2');
        expect(cancelled, isTrue);
        expect(removedIds, contains('turn-2'));

        signalFile.writeAsStringSync('go');
        await waitUntil(() => turnsEnded >= 1);
        await Future<void>.delayed(const Duration(milliseconds: 120));

        final stdinText = jsonEncode(fakeAgy.stdinCaptures());
        expect(
          stdinText,
          isNot(contains('CANCELLED_TURN_2')),
          reason:
              'Cancelled queued turn must be removed from AntigravityTransport queue and never sent to agy',
        );
      },
    );

    test(
      'F4-T2-02: cancelQueued returns false for turn already executing',
      () async {
        final sandbox = E2eSandbox.create();
        final signalFile = File(p.join(sandbox.rootDir.path, 'release2.sig'));
        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f4_t2_02',
          dartBody: _fakeAgyParityBody,
        );

        final kernel = ClaudeCodeKernel(
          KernelRegistry.antigravity,
          KernelContext(cwd: sandbox.projectDir.path),
          start: (launch) async => AntigravityTransport.forTesting(
            executable: fakeAgy.executablePath,
            environment: {
              ...sandbox.processEnv,
              'FAKE_AGY_SCENARIO': 'block_turn_1_on_signal',
              'FAKE_AGY_SIGNAL_FILE': signalFile.path,
            },
            launch: launch,
          ),
        );
        sandbox.onDispose(() {
          if (!signalFile.existsSync()) signalFile.writeAsStringSync('go');
          kernel.dispose();
        });

        final done = Completer<void>();
        final sub = kernel.events.listen((e) {
          if (e is TurnEnded && !done.isCompleted) done.complete();
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));

        kernel.send(const KernelTurn(id: 'turn-active', text: 'running'));
        await waitUntil(() => fakeAgy.stdinCaptures().isNotEmpty);

        expect(await kernel.cancelQueued('turn-active'), isFalse);

        signalFile.writeAsStringSync('go');
        await done.future.timeout(const Duration(seconds: 10));
      },
    );

    test(
      'F4-T2-03: revertChanges and rewind never silently fake success without real effect',
      () async {
        final sandbox = E2eSandbox.create();
        final target = File(p.join(sandbox.projectDir.path, 'a.txt'))
          ..writeAsStringSync('v1');
        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f4_t2_03',
          dartBody: _fakeAgyParityBody,
        );

        final kernel = ClaudeCodeKernel(
          KernelRegistry.antigravity,
          KernelContext(cwd: sandbox.projectDir.path),
          start: (launch) async => AntigravityTransport.forTesting(
            executable: fakeAgy.executablePath,
            environment: {
              ...sandbox.processEnv,
              'FAKE_AGY_SCENARIO': 'modify_file_turn',
              'FAKE_AGY_EDIT_FILE': target.path,
            },
            launch: launch,
          ),
        );
        sandbox.onDispose(kernel.dispose);

        final events = <KernelEvent>[];
        final done = Completer<void>();
        final sub = kernel.events.listen((e) {
          events.add(e);
          if (e is TurnEnded && !done.isCompleted) done.complete();
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));

        kernel.send(const KernelTurn(id: 'turn-mod', text: 'modify a.txt'));
        await done.future.timeout(const Duration(seconds: 10));
        expect(target.readAsStringSync(), 'v2');

        kernel.revertChanges(sinceTurn: 'turn-mod');
        await waitUntil(
          () => events.any(
            (e) =>
                e is ChangesReverted ||
                (e is ItemUpserted &&
                    e.item is NoticeItem &&
                    (e.item as NoticeItem).kind == NoticeKind.error),
          ),
          reason:
              'revertChanges must emit ChangesReverted or NoticeKind.error',
        );
        final emittedChangesReverted = events.any((e) => e is ChangesReverted);
        final emittedRevertError = events.any(
          (e) =>
              e is ItemUpserted &&
              e.item is NoticeItem &&
              (e.item as NoticeItem).kind == NoticeKind.error,
        );
        if (emittedChangesReverted) {
          expect(
            target.readAsStringSync(),
            'v1',
            reason:
                'revertChanges must only emit ChangesReverted if the file was actually restored',
          );
        } else {
          expect(
            emittedRevertError,
            isTrue,
            reason:
                'When rewind_files is unsupported, AntigravityTransport must fail honestly (NoticeKind.error) instead of faking ChangesReverted',
          );
        }

        final rewound = await kernel.rewind(
          itemId: 'turn-mod',
          index: 0,
          turns: 1,
        );
        if (rewound) {
          expect(events.any((e) => e is Rewound), isTrue);
        } else {
          expect(rewound, isFalse);
          expect(events.any((e) => e is Rewound), isFalse);
          expect(target.readAsStringSync(), 'v2');
          expect(
            events.any(
              (e) =>
                  e is ItemUpserted &&
                  e.item is NoticeItem &&
                  (e.item as NoticeItem).kind == NoticeKind.error,
            ),
            isTrue,
            reason:
                'When rewind fails or is unsupported, AntigravityTransport must emit NoticeKind.error instead of faking success',
          );
        }
      },
    );

    test(
      'F4-T2-04: /clear resets sessionId and avoids --conversation on subsequent turn',
      () async {
        final sandbox = E2eSandbox.create();
        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f4_t2_04',
          dartBody: _fakeAgyParityBody,
        );
        final kernel = ClaudeCodeKernel(
          KernelRegistry.antigravity,
          KernelContext(cwd: sandbox.projectDir.path),
          start: (launch) async => AntigravityTransport.forTesting(
            executable: fakeAgy.executablePath,
            environment: {
              ...sandbox.processEnv,
              'FAKE_AGY_CONV_ID': 'conv-before-clear',
            },
            launch: launch,
          ),
        );
        sandbox.onDispose(kernel.dispose);

        var turnsEnded = 0;
        final sub = kernel.events.listen((e) {
          if (e is TurnEnded) turnsEnded++;
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));

        kernel.send(const KernelTurn(id: 't1', text: 'first turn'));
        await waitUntil(() => turnsEnded >= 1);
        expect(kernel.sessionId, 'conv-before-clear');

        kernel.send(const KernelTurn(id: 't2', text: '/clear'));
        await waitUntil(() => turnsEnded >= 2);

        kernel.send(const KernelTurn(id: 't3', text: 'after clear'));
        await waitUntil(() => turnsEnded >= 3);

        final launches = fakeAgy
            .readCaptures()
            .where((e) => e['type'] == 'launch')
            .toList();
        expect(launches.length, greaterThanOrEqualTo(2));
        final lastArgs = (launches.last['args'] as List).cast<String>();
        expect(
          lastArgs.any((a) => a.contains('conv-before-clear')),
          isFalse,
          reason:
              'After /clear, subsequent turn must not resume conv-before-clear',
        );
      },
    );

    test(
      'F4-T2-05: image attachment temp files are cleaned up and malformed base64 does not crash',
      () async {
        final sandbox = E2eSandbox.create();
        Set<String> listTempImgFiles() => Directory.systemTemp
            .listSync()
            .whereType<File>()
            .map((f) => p.basename(f.path))
            .where((name) => name.startsWith('ayte_agy_img_'))
            .toSet();

        final before = listTempImgFiles();
        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f4_t2_05',
          dartBody: _fakeAgyParityBody,
        );
        final transport = AntigravityTransport.forTesting(
          executable: fakeAgy.executablePath,
          environment: sandbox.processEnv,
          launch: ClaudeLaunch(cwd: sandbox.projectDir.path),
        );

        final gotResult = Completer<void>();
        final sub = transport.messages.listen((msg) {
          if (msg['type'] == 'result' && !gotResult.isCompleted) {
            gotResult.complete();
          }
        });

        // 1x1 transparent PNG bytes + malformed base64 data block.
        const pngBase64 =
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
        transport.write({
          'type': 'user',
          'uuid': 't-img',
          'message': {
            'role': 'user',
            'content': [
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/png',
                  'data': pngBase64,
                },
              },
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/png',
                  'data': '!!!not-valid-base64!!!',
                },
              },
              {'type': 'text', 'text': 'describe image'},
            ],
          },
        });

        await gotResult.future.timeout(const Duration(seconds: 10));
        transport.close();
        await transport.exited.timeout(const Duration(seconds: 5));
        await sub.cancel();

        final after = listTempImgFiles();
        final leaked = after.difference(before);
        expect(
          leaked,
          isEmpty,
          reason:
              'Temp image files must not leak in Directory.systemTemp after turn/close: $leaked',
        );
      },
    );
  });
}
