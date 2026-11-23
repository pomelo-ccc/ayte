import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/control_channel.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_account_models.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_accounts.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_cli.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/usage/usage_ledger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/e2e_env.dart';
import 'helpers/e2e_waiters.dart';
import 'helpers/fake_cli_harness.dart';

const _fakeCodeBuddyCliBody = r'''
Future<void> main(List<String> args) async {
  final env = Map<String, String>.from(Platform.environment);
  recordEvent({'type': 'launch', 'args': args, 'env': env});
  final failSubtypes = (env['FAKE_CB_FAIL_SUBTYPES'] ?? '')
      .split(',')
      .where((s) => s.isNotEmpty)
      .toSet();

  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    recordEvent({'type': 'stdin', 'line': line});
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (decoded is! Map) continue;
    final msg = decoded.cast<String, Object?>();
    if (msg['type'] == 'control_request') {
      final reqId = msg['request_id'] as String? ?? '';
      final req = (msg['request'] as Map?)?.cast<String, Object?>() ?? const {};
      final subtype = req['subtype'] as String? ?? '';
      recordEvent({'type': 'control_request', 'subtype': subtype, 'request': req});
      if (failSubtypes.contains(subtype)) {
        stdout.writeln(jsonEncode({
          'type': 'control_response',
          'response': {
            'subtype': 'error',
            'request_id': reqId,
            'error': 'Simulated CLI error for $subtype',
          },
        }));
        await stdout.flush();
        continue;
      }

      final payload = switch (subtype) {
        'initialize' => {
          'commands': const [
            {'name': 'compact', 'description': 'Compact', 'builtin': true},
          ],
          'models': const [],
        },
        'get_available_models' => {'models': const []},
        'mcp_status' => {
          'mcpServers': const [
            {
              'name': 's1',
              'status': 'needs-auth',
              'scope': 'project',
            },
          ],
        },
        'mcp_authenticate' => {'authUrl': 'https://example.com/oauth/cb'},
        'file_suggestions' => {
          'suggestions': const [
            {'path': 'lib/foo.dart'},
          ],
        },
        'get_hooks_listing' => {'hooks': const []},
        _ => const <String, Object?>{},
      };
      stdout.writeln(jsonEncode({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': reqId,
          'response': payload,
        },
      }));
      await stdout.flush();
    } else if (msg['type'] == 'user') {
      final uuid = msg['uuid'] as String? ?? 'u1';
      const sid = 'cb-e2e-session';
      stdout.writeln(jsonEncode({
        'type': 'system',
        'subtype': 'init',
        'session_id': sid,
        'model': 'hy4std',
      }));
      stdout.writeln(jsonEncode({
        'type': 'assistant',
        'session_id': sid,
        'uuid': 'cb-a-$uuid',
        'message': {
          'id': 'cb-m-$uuid',
          'model': 'hy4std',
          'role': 'assistant',
          'content': const [
            {'type': 'text', 'text': 'CB_REPLY'},
          ],
          'usage': const {'input_tokens': 50, 'output_tokens': 12},
        },
      }));
      stdout.writeln(jsonEncode({
        'type': 'result',
        'subtype': 'success',
        'session_id': sid,
        'is_error': false,
        'result': 'CB_REPLY',
        'duration_ms': 10,
      }));
      stdout.writeln(jsonEncode({
        'type': 'system',
        'subtype': 'session_state_changed',
        'session_id': sid,
        'state': 'idle',
      }));
      await stdout.flush();
    }
  }
}
''';

void main() {
  ClaudeCodeKernel createScriptedCodeBuddy({
    required E2eSandbox sandbox,
    Map<String, String> settings = const {},
    List<ScriptedClaudeTransport>? outTransports,
    Map<String, Object?>? account,
  }) {
    return ClaudeCodeKernel(
      KernelRegistry.codebuddy,
      KernelContext(cwd: sandbox.projectDir.path, settings: settings),
      start: (launch) async {
        final t = ScriptedClaudeTransport(
          launch: launch,
          account: account,
          onUserTurn: (tr, _) => tr.emitSimpleReply(
            'cb ok',
            model: 'hy4std',
            inputTokens: 100,
            outputTokens: 20,
          ),
        );
        outTransports?.add(t);
        return t;
      },
    );
  }

  group('F5 Tier 1 — CodeBuddy & ClaudeCodeKernel Feature Parity', () {
    test(
      'F5-T1-01: ClaudeCodeKernel.contextSize supports CodeBuddyModels options, selection and apply_flag_settings',
      () async {
        final sandbox = E2eSandbox.create();
        CodeBuddyModels.syncForRegion(CodeBuddyRegion.global);
        sandbox.onDispose(() => CodeBuddyModels.syncForRegion(CodeBuddyRegion.cn));

        final transports = <ScriptedClaudeTransport>[];
        final kernel = createScriptedCodeBuddy(
          sandbox: sandbox,
          outTransports: transports,
        );
        sandbox.onDispose(kernel.dispose);

        const astraRef = '@$codebuddyBuiltinProviderId/gpt-6-astra';
        const hy4Ref = '@$codebuddyBuiltinProviderId/hy4-preview';

        final astraOptions =
            kernel.contextSize.optionsFor(astraRef).map((o) => o.id).toList();
        expect(
          astraOptions,
          ['256000', '512000', '1000000'],
          reason: 'ClaudeCodeKernel.contextSize must expose CodeBuddyModels windows',
        );
        final hy4Options =
            kernel.contextSize.optionsFor(hy4Ref).map((o) => o.id).toList();
        expect(hy4Options, ['256000', '512000', '960000']);

        final done = Completer<void>();
        final sub = kernel.events.listen((e) {
          if (e is TurnEnded && !done.isCompleted) done.complete();
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));
        kernel.send(const KernelTurn(id: 't1', text: 'boot'));
        await done.future.timeout(const Duration(seconds: 5));

        kernel.contextSize.select(astraRef, '512000');
        expect(kernel.contextSize.selected, '512000');
        expect(kernel.contextWindow, 512000);
        await pumpEventQueue();

        final flagMsg = transports.single.writtenMessages.where(
          (m) =>
              m['type'] == 'control_request' &&
              (m['request'] as Map?)?['subtype'] == 'apply_flag_settings',
        );
        expect(
          flagMsg.any(
            (m) =>
                ((m['request'] as Map)['settings'] as Map)['contextWindow'] ==
                512000,
          ),
          isTrue,
        );
      },
    );

    test(
      'F5-T1-02: ClaudeCodeKernel.effort supports CodeBuddyModels levels including none when allowed',
      () async {
        final sandbox = E2eSandbox.create();
        CodeBuddyModels.syncForRegion(CodeBuddyRegion.global);
        sandbox.onDispose(() => CodeBuddyModels.syncForRegion(CodeBuddyRegion.cn));

        final transports = <ScriptedClaudeTransport>[];
        final kernel = createScriptedCodeBuddy(
          sandbox: sandbox,
          outTransports: transports,
        );
        sandbox.onDispose(kernel.dispose);

        const bunnyRef = '@$codebuddyBuiltinProviderId/space-bunny';
        const flashRef = '@$codebuddyBuiltinProviderId/gemini-3.5-flash';

        expect(
          kernel.effort.optionsFor(bunnyRef).map((o) => o.id).toList(),
          ['low', 'medium', 'high', 'xhigh', 'max'],
        );
        expect(
          kernel.effort.optionsFor(flashRef).map((o) => o.id).toList(),
          contains('none'),
        );

        final done = Completer<void>();
        final sub = kernel.events.listen((e) {
          if (e is TurnEnded && !done.isCompleted) done.complete();
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));
        kernel.send(const KernelTurn(id: 't1', text: 'boot'));
        await done.future.timeout(const Duration(seconds: 5));

        kernel.effort.select(bunnyRef, 'medium');
        expect(kernel.effort.selected, 'medium');
        await pumpEventQueue();

        final flagMsg = transports.single.writtenMessages.where(
          (m) =>
              m['type'] == 'control_request' &&
              (m['request'] as Map?)?['subtype'] == 'apply_flag_settings',
        );
        expect(
          flagMsg.any(
            (m) =>
                ((m['request'] as Map)['settings'] as Map)['effortLevel'] ==
                'medium',
          ),
          isTrue,
        );
      },
    );

    test(
      'F5-T1-03: _lastCatalog is isolated per kernel and codebuddy pre-seeds commands before launch',
      () async {
        final sandbox = E2eSandbox.create();
        final claudeKernel = ClaudeCodeKernel(
          KernelRegistry.claudeCode,
          KernelContext(cwd: sandbox.projectDir.path),
          start: (launch) async => ScriptedClaudeTransport(
            launch: launch,
            commands: const [
              {'name': 'claude-only-cmd', 'description': 'Claude only'},
            ],
            models: const [
              {'value': 'claude-opus-5-5', 'displayName': 'Claude Opus 5.5'},
            ],
            onUserTurn: (tr, _) => tr.emitSimpleReply('ok'),
          ),
        );
        sandbox.onDispose(claudeKernel.dispose);

        final done = Completer<void>();
        final sub = claudeKernel.events.listen((e) {
          if (e is TurnEnded && !done.isCompleted) done.complete();
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));
        claudeKernel.send(const KernelTurn(id: 't1', text: 'init claude'));
        await done.future.timeout(const Duration(seconds: 5));
        expect(
          claudeKernel.commands.any((c) => c.name == 'claude-only-cmd'),
          isTrue,
        );

        // Fresh CodeBuddy kernel BEFORE launch/initialize:
        final cbKernel = createScriptedCodeBuddy(sandbox: sandbox);
        sandbox.onDispose(cbKernel.dispose);
        expect(
          cbKernel.commands.any((c) => c.name == 'claude-only-cmd'),
          isFalse,
          reason:
              'ClaudeCodeKernel _lastCatalog must be isolated per descriptor id',
        );
        expect(
          cbKernel.commands,
          isNotEmpty,
          reason: 'CodeBuddy kernel must seed pre-launch commands before CLI starts',
        );
        expect(
          cbKernel.model.options.any((o) => o.id == 'claude-opus-5-5'),
          isFalse,
        );
      },
    );

    test(
      'F5-T1-04: CodeBuddyTransport forwards mcp_*, file_suggestions, stop_task, background_tasks and get_hooks_listing',
      () async {
        final sandbox = E2eSandbox.create();
        final fakeCb = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_codebuddy_f5_04',
          dartBody: _fakeCodeBuddyCliBody,
        );
        CodeBuddyPathSetting.current = () => fakeCb.executablePath;

        final kernel = ClaudeCodeKernel(
          KernelRegistry.codebuddy,
          KernelContext(cwd: sandbox.projectDir.path),
          start: CodeBuddyTransport.start,
        );
        sandbox.onDispose(kernel.dispose);

        final done = Completer<void>();
        final sub = kernel.events.listen((e) {
          if (e is TurnEnded && !done.isCompleted) done.complete();
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));

        kernel.send(const KernelTurn(id: 't1', text: 'boot codebuddy'));
        await done.future.timeout(const Duration(seconds: 20));
        expect(kernel.health.status, KernelHealthStatus.ready);
        expect(fakeCb.firstLaunchCapture(), isNotNull);

        kernel.refreshMcpServers();
        await waitUntil(
          () => kernel.mcpServers?.any((s) => s.name == 's1') ?? false,
          reason: 'CodeBuddyTransport must forward mcp_status and parse mcpServers',
        );

        kernel.setMcpServerEnabled('s1', false);
        final authUri = await kernel.authenticateMcpServer('s1');
        expect(authUri?.toString(), 'https://example.com/oauth/cb');

        final suggestions = await kernel.suggestFiles('foo');
        expect(suggestions.map((s) => s.path), contains('lib/foo.dart'));

        kernel.stopTask('t1');
        kernel.moveToBackground('u1');
        const expectedSubtypes = [
          'mcp_status',
          'mcp_toggle',
          'mcp_authenticate',
          'file_suggestions',
          'stop_task',
          'background_tasks',
          'get_hooks_listing',
        ];
        await waitUntil(
          () {
            final seen = fakeCb
                .readCaptures()
                .where((e) => e['type'] == 'control_request')
                .map((e) => e['subtype'])
                .toSet();
            return seen.containsAll(expectedSubtypes);
          },
          reason:
              'CodeBuddyTransport did not forward all expected control requests',
        );

        final subtypes = fakeCb
            .readCaptures()
            .where((e) => e['type'] == 'control_request')
            .map((e) => e['subtype'])
            .toSet();
        expect(subtypes, containsAll(expectedSubtypes));
      },
    );

    test(
      'F5-T1-05: CodeBuddyAccounts get_usage and _planName avoid Claude prefix',
      () async {
        final sandbox = E2eSandbox.create();
        ClaudeCodeKernel.forgetAccount();
        sandbox.onDispose(ClaudeCodeKernel.forgetAccount);

        // Seed isolated CodeBuddyAccounts store under sandbox.homeDir.
        final cbDir = Directory(
          p.join(sandbox.homeDir.path, '.cyte', 'codebuddy_accounts', 'accounts'),
        )..createSync(recursive: true);
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final acc = {
          'id': 'cb-e2e-1',
          'uid': 'u-e2e',
          'nickname': 'E2E CB',
          'region': 'cn',
          'endpoint': 'https://copilot.tencent.com',
          'auth': {'kind': 'authToken', 'access_token': 'cb-tok'},
          'quota': {
            'edition': 'pro',
            'total_credits': 1000.0,
            'used_credits': 250.0,
            'remaining_credits': 750.0,
            'reset_time': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 4))
                .toIso8601String(),
            'last_updated': nowSec,
          },
          'created_at': nowSec,
          'last_used': nowSec,
        };
        File(p.join(cbDir.path, 'cb-e2e-1.json')).writeAsStringSync(jsonEncode(acc));
        File(
          p.join(
            sandbox.homeDir.path,
            '.cyte',
            'codebuddy_accounts',
            'accounts.json',
          ),
        ).writeAsStringSync(
          jsonEncode({
            'current_account_id': 'cb-e2e-1',
            'accounts': [
              {'id': 'cb-e2e-1', 'uid': 'u-e2e', 'nickname': 'E2E CB', 'region': 'cn'},
            ],
          }),
        );

        // Verify isolated CodeBuddyAccounts store inside sandbox.homeDir.
        // Note: CodeBuddyTransport.start uses CodeBuddyAccounts.instance
        // (redirecting the singleton to respect sandbox.homeDir is an M3 dependency).
        final isolatedAccounts = CodeBuddyAccounts(
          dataDir: p.join(
            sandbox.homeDir.path,
            '.cyte',
            'codebuddy_accounts',
          ),
        );
        await isolatedAccounts.ensureInitialized();
        expect(isolatedAccounts.dataDirectoryPath, startsWith(sandbox.homeDir.path));
        expect(isolatedAccounts.currentAccount?.id, 'cb-e2e-1');
        expect(isolatedAccounts.currentAccount?.quota?.remainingCredits, 750.0);

        // Verify _planName does not prepend "Claude " to "CodeBuddy (CN · Pro)".
        final planKernel = createScriptedCodeBuddy(
          sandbox: sandbox,
          account: const {'subscriptionType': 'CodeBuddy (CN · Pro)'},
        );
        sandbox.onDispose(planKernel.dispose);
        final done = Completer<void>();
        final sub = planKernel.events.listen((e) {
          if (e is TurnEnded && !done.isCompleted) done.complete();
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));
        planKernel.send(const KernelTurn(id: 't1', text: 'usage'));
        await done.future.timeout(const Duration(seconds: 5));

        UsageLedger.current.flush();
        final days = await UsageLedger.current.storage.days();
        final calls = await UsageLedger.current.storage.read(days);
        expect(calls, isNotEmpty);
        expect(
          calls.first.providerName,
          'CodeBuddy (CN · Pro)',
          reason: 'CodeBuddy subscriptionType must not be prefixed with "Claude "',
        );

        planKernel.dispose();
        await planKernel.stopped;

        // Verify CodeBuddyTransport get_usage populates live quota/limits.
        final fakeCb = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_codebuddy_f5_05',
          dartBody: _fakeCodeBuddyCliBody,
        );
        CodeBuddyPathSetting.current = () => fakeCb.executablePath;
        final kernel = ClaudeCodeKernel(
          KernelRegistry.codebuddy,
          KernelContext(cwd: sandbox.projectDir.path),
          start: CodeBuddyTransport.start,
        );
        sandbox.onDispose(kernel.dispose);

        final tDone = Completer<void>();
        final sub2 = kernel.events.listen((e) {
          if (e is TurnEnded && !tDone.isCompleted) tDone.complete();
        });
        sandbox.onDispose(() => unawaited(sub2.cancel()));
        kernel.send(const KernelTurn(id: 't1', text: 'boot'));
        await tDone.future.timeout(const Duration(seconds: 20));
        expect(kernel.health.status, KernelHealthStatus.ready);
        expect(fakeCb.firstLaunchCapture(), isNotNull);

        await kernel.refreshUsage();
        expect(
          kernel.accountLimits,
          isNotEmpty,
          reason:
              'CodeBuddyTransport get_usage must return account quota limits instead of rate_limits_available: false',
        );
      },
    );
  });

  group('F5 Tier 2 — CodeBuddy Effort Boundaries, Error Paths & Persistence', () {
    test(
      'F5-T2-01: onlyReasoning model rejects none effort and ignores invalid selection',
      () async {
        final sandbox = E2eSandbox.create();
        CodeBuddyModels.syncForRegion(CodeBuddyRegion.cn);
        final transports = <ScriptedClaudeTransport>[];
        final kernel = createScriptedCodeBuddy(
          sandbox: sandbox,
          outTransports: transports,
        );
        sandbox.onDispose(kernel.dispose);

        const glmRef = '@$codebuddyBuiltinProviderId/glm-5.3';
        final options = kernel.effort.optionsFor(glmRef).map((o) => o.id).toList();
        expect(options, containsAll(const ['low', 'high', 'max']));
        expect(options, isNot(contains('none')));
        expect(
          kernel.effort.selectedFor(glmRef),
          isNotNull,
          reason: 'onlyReasoning model glm-5.3 must resolve a non-null initial effort',
        );

        final done = Completer<void>();
        final sub = kernel.events.listen((e) {
          if (e is TurnEnded && !done.isCompleted) done.complete();
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));
        kernel.send(const KernelTurn(id: 't1', text: 'boot'));
        await done.future.timeout(const Duration(seconds: 5));

        kernel.effort.select(glmRef, 'low');
        expect(kernel.effort.selectedFor(glmRef), 'low');
        await pumpEventQueue();
        final sentLow = transports.single.writtenMessages.any(
          (m) =>
              m['type'] == 'control_request' &&
              (m['request'] as Map?)?['subtype'] == 'apply_flag_settings' &&
              ((m['request'] as Map)['settings'] as Map?)?['effortLevel'] ==
                  'low',
        );
        expect(
          sentLow,
          isTrue,
          reason: 'Selecting valid effort "low" must send apply_flag_settings',
        );

        kernel.effort.select(glmRef, 'none');
        expect(kernel.effort.selectedFor(glmRef), 'low');
        await pumpEventQueue();
        final sentNone = transports.single.writtenMessages.any(
          (m) =>
              m['type'] == 'control_request' &&
              (m['request'] as Map?)?['subtype'] == 'apply_flag_settings' &&
              ((m['request'] as Map)['settings'] as Map?)?['effortLevel'] ==
                  'none',
        );
        expect(sentNone, isFalse);
      },
    );

    test(
      'F5-T2-02: fixed-effort and single-context CodeBuddy models behave cleanly',
      () {
        final sandbox = E2eSandbox.create();
        CodeBuddyModels.syncForRegion(CodeBuddyRegion.cn);
        final kernel = createScriptedCodeBuddy(sandbox: sandbox);
        sandbox.onDispose(kernel.dispose);

        const fixedRef = '@$codebuddyBuiltinProviderId/glm-5.2';
        const autoRef = '@$codebuddyBuiltinProviderId/default-model';
        expect(kernel.effort.optionsFor(fixedRef), isEmpty);
        expect(
          kernel.contextSize.optionsFor(fixedRef).map((o) => o.id).toList(),
          ['1000000'],
        );
        expect(
          kernel.contextSize.optionsFor(autoRef).map((o) => o.id).toList(),
          ['200000'],
        );
      },
    );

    test(
      'F5-T2-03: CLI error control_response keeps suggestFiles safe and propagates authenticate error',
      () async {
        final sandbox = E2eSandbox.create();
        sandbox.useClaudeEnvironment({
          ...sandbox.processEnv,
          'FAKE_CB_FAIL_SUBTYPES': 'file_suggestions,mcp_authenticate',
        });
        final fakeCb = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_codebuddy_f5_t2_03',
          dartBody: _fakeCodeBuddyCliBody,
        );
        CodeBuddyPathSetting.current = () => fakeCb.executablePath;

        final kernel = ClaudeCodeKernel(
          KernelRegistry.codebuddy,
          KernelContext(cwd: sandbox.projectDir.path),
          start: CodeBuddyTransport.start,
        );
        sandbox.onDispose(kernel.dispose);

        final done = Completer<void>();
        final sub = kernel.events.listen((e) {
          if (e is TurnEnded && !done.isCompleted) done.complete();
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));
        kernel.send(const KernelTurn(id: 't1', text: 'boot'));
        await done.future.timeout(const Duration(seconds: 20));
        expect(kernel.health.status, KernelHealthStatus.ready);
        expect(fakeCb.firstLaunchCapture(), isNotNull);

        expect(await kernel.suggestFiles('anything'), isEmpty);
        await expectLater(
          kernel.authenticateMcpServer('s1'),
          throwsA(
            isA<ControlError>()
                .having((e) => e.subtype, 'subtype', 'mcp_authenticate')
                .having(
                  (e) => e.message,
                  'message',
                  contains('Simulated CLI error for mcp_authenticate'),
                ),
          ),
          reason:
              'When CodeBuddy CLI returns control error for mcp_authenticate, error must surface instead of silently returning null',
        );

        final controlSubtypes = fakeCb
            .readCaptures()
            .where((e) => e['type'] == 'control_request')
            .map((e) => e['subtype'])
            .toSet();
        expect(
          controlSubtypes,
          containsAll(const ['file_suggestions', 'mcp_authenticate']),
        );
      },
    );

    test(
      'F5-T2-04: missing codebuddy binary transitions kernel to KernelHealthStatus.failed',
      () async {
        final sandbox = E2eSandbox.create();
        final emptyBin = Directory(p.join(sandbox.rootDir.path, 'empty_bin'))
          ..createSync(recursive: true);
        sandbox.useClaudeEnvironment({
          ...sandbox.processEnv,
          'PATH': emptyBin.path,
          'APPDATA': sandbox.appDataDir.path,
        });
        CodeBuddyPathSetting.current = () => p.join(
          emptyBin.path,
          Platform.isWindows ? 'missing.cmd' : 'missing',
        );

        final kernel = ClaudeCodeKernel(
          KernelRegistry.codebuddy,
          KernelContext(cwd: sandbox.projectDir.path),
          start: CodeBuddyTransport.start,
        );
        sandbox.onDispose(kernel.dispose);

        final failedHealth = Completer<KernelHealth>();
        final sub = kernel.events.listen((e) {
          if (e is KernelInfoChanged &&
              kernel.health.status == KernelHealthStatus.failed &&
              !failedHealth.isCompleted) {
            failedHealth.complete(kernel.health);
          }
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));

        kernel.send(const KernelTurn(id: 't1', text: 'hello'));
        final health = await failedHealth.future.timeout(
          const Duration(seconds: 5),
        );
        expect(health.status, KernelHealthStatus.failed);
        expect(health.message, isNotEmpty);
      },
    );

    test(
      'F5-T2-05: per-model effort@ and context@ settings persist across CodeBuddy model switches',
      () {
        final sandbox = E2eSandbox.create();
        CodeBuddyModels.syncForRegion(CodeBuddyRegion.global);
        sandbox.onDispose(() => CodeBuddyModels.syncForRegion(CodeBuddyRegion.cn));

        const astraRef = '@$codebuddyBuiltinProviderId/gpt-6-astra';
        const bunnyRef = '@$codebuddyBuiltinProviderId/space-bunny';

        final kernel = createScriptedCodeBuddy(
          sandbox: sandbox,
          settings: const {
            'model': bunnyRef,
            'effort@$bunnyRef': 'xhigh',
            'context@$astraRef': '512000',
          },
        );
        sandbox.onDispose(kernel.dispose);

        expect(kernel.model.selected, bunnyRef);
        expect(
          kernel.effort.selected,
          'xhigh',
          reason: 'effort@<model> setting must restore xhigh on space-bunny',
        );
        expect(
          kernel.contextSize.selectedFor(astraRef),
          '512000',
          reason: 'context@<model> setting must restore 512000 on gpt-6-astra',
        );

        kernel.model.select(astraRef);
        expect(kernel.contextSize.selected, '512000');

        kernel.model.select(bunnyRef);
        expect(kernel.effort.selected, 'xhigh');
      },
    );
  });
}
