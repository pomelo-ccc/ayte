import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:baocode/kernel/claude_code/control_channel.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_account_models.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_accounts.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_cli.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_transport.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String _resolveDartExecutable() {
  final exeName = Platform.isWindows ? 'dart.exe' : 'dart';
  final direct = p.join(p.dirname(Platform.resolvedExecutable), exeName);
  if (File(direct).existsSync()) return direct;
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
  return exeName;
}

Future<({CodeBuddyCli cli, File stdinLog})> _createFakeCodeBuddyCli(
  Directory root, {
  required String dartBody,
  Map<String, String> env = const {},
}) async {
  final dartExe = _resolveDartExecutable();
  final scriptFile = File(p.join(root.path, 'fake_cb.dart'));
  final logFile = File(p.join(root.path, 'stdin.jsonl'));
  await scriptFile.writeAsString('''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

final _log = File(${jsonEncode(logFile.path)});

void recordStdin(Map<String, Object?> msg) {
  _log.writeAsStringSync('\${jsonEncode(msg)}\\n', mode: FileMode.append, flush: true);
}

$dartBody
''');

  if (Platform.isWindows) {
    final cmdFile = File(p.join(root.path, 'fake_cb.cmd'));
    await cmdFile.writeAsString(
      '@echo off\r\n"$dartExe" "${scriptFile.path}" %*\r\n',
    );
    return (
      cli: CodeBuddyCli(
        executable: cmdFile.path,
        environment: env,
        throughShell: true,
      ),
      stdinLog: logFile,
    );
  }

  final shFile = File(p.join(root.path, 'fake_cb.sh'));
  await shFile.writeAsString(
    '#!/bin/sh\nexec "$dartExe" "${scriptFile.path}" "\$@"\n',
  );
  await Process.run('chmod', ['+x', shFile.path]);
  return (
    cli: CodeBuddyCli(
      executable: shFile.path,
      environment: env,
      throughShell: false,
    ),
    stdinLog: logFile,
  );
}

CodeBuddyAccount _makeAccount({
  required String id,
  CodeBuddyQuotaData? quota,
  CodeBuddyRegion region = CodeBuddyRegion.cn,
}) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return CodeBuddyAccount(
    id: id,
    uid: 'uid-$id',
    nickname: 'User $id',
    region: region,
    endpoint: region.defaultEndpoint,
    auth: const CodeBuddyAuthData(
      kind: CodeBuddyAuthKind.authToken,
      accessToken: 'tok-test',
    ),
    quota: quota,
    createdAt: now,
    lastUsed: now,
  );
}

void main() {
  group('CodeBuddyModel & CodeBuddyModels helpers', () {
    test('contextOptionLabel marks single-window models as fixed', () {
      final hy4 = CodeBuddyModels.of('hy4std')!;
      expect(hy4.contextOptionLabel('960K', 960000), '960K（官方固定）');

      CodeBuddyModels.syncForRegion(CodeBuddyRegion.global);
      addTearDown(() => CodeBuddyModels.syncForRegion(CodeBuddyRegion.cn));
      final astra = CodeBuddyModels.of('gpt-6-astra')!;
      expect(astra.contextOptionLabel('256K', 256000), '256K');
      expect(astra.contextOptionLabel('512K', 512000), '512K');
      expect(astra.contextOptionLabel('1M', 1000000), '1M');
    });

    test('bare "default" never matches CodeBuddyModels', () {
      expect(CodeBuddyModels.of('default'), isNull);
      expect(CodeBuddyModels.isCodeBuddyModel('default'), isFalse);
      expect(
        isCodeBuddyLaunch(const ClaudeLaunch(cwd: '.', model: 'default')),
        isFalse,
      );

      expect(CodeBuddyModels.of('@$codebuddyBuiltinProviderId/default'), isNotNull);
      expect(
        CodeBuddyModels.isCodeBuddyModel('@$codebuddyBuiltinProviderId/hy4std'),
        isTrue,
      );
      expect(CodeBuddyModels.isCodeBuddyModel('hy4std'), isTrue);
      expect(
        isCodeBuddyLaunch(
          const ClaudeLaunch(cwd: '.', model: '@$codebuddyBuiltinProviderId/hy4std'),
        ),
        isTrue,
      );
    });

    test('codebuddyBuiltinCommands exposes built-in slash commands', () {
      final names = [for (final c in codebuddyBuiltinCommands) c['name']];
      expect(
        names,
        containsAll(['compact', 'clear', 'plan', 'init', 'review', 'context', 'cost', 'status']),
      );
      for (final cmd in codebuddyBuiltinCommands) {
        expect(cmd['builtin'], isTrue);
        expect(cmd['category'], 'builtin');
      }
    });
  });

  group('CodeBuddyTransport.buildArguments', () {
    test('builds CLI flags for bypassPermissions, effort, autocompact, and prompts', () {
      final args = CodeBuddyTransport.buildArguments(
        launch: const ClaudeLaunch(
          cwd: '.',
          sdkServers: ['baocode'],
          instructions: 'Follow repo style.',
          directories: ['/extra'],
          tools: ['Bash', 'Read'],
        ),
        model: 'hy4std',
        permissionMode: 'bypassPermissions',
        effort: 'high',
        maxContextTokens: 960000,
        resumeSessionId: 'sess-42',
        settingsFilePath: '/tmp/settings.json',
        inlineSettings: const {},
      );

      expect(args, containsAll(['-p', '--input-format', 'stream-json', '--output-format', 'stream-json']));
      expect(args, contains('-y'));
      expect(args, containsAll(['--permission-mode', 'bypassPermissions']));
      expect(args, containsAll(['--model', 'hy4std']));
      expect(args, containsAll(['--effort', 'high']));
      expect(args, containsAll(['--autocompact', '960000']));
      expect(args, containsAll(['--resume', 'sess-42']));
      expect(args, containsAll(['--add-dir', '/extra']));
      expect(args, containsAll(['--settings', '/tmp/settings.json']));
      expect(args, containsAll(['--tools', 'Bash,Read', '--strict-mcp-config']));
      expect(args, contains('--mcp-config'));
      expect(args, containsAll(['--allowedTools', 'mcp__baocode']));
      expect(args, contains('--append-system-prompt'));
    });

    test('omits -y when not bypassPermissions and uses --system-prompt when ownPrompt is true', () {
      final args = CodeBuddyTransport.buildArguments(
        launch: const ClaudeLaunch(
          cwd: '.',
          ownPrompt: true,
          instructions: 'Custom prompt',
          persist: false,
        ),
        model: 'default-model',
        permissionMode: 'plan',
        effort: 'none',
        maxContextTokens: 50000,
        resumeSessionId: null,
        settingsFilePath: null,
        inlineSettings: const {'alwaysThinkingEnabled': false},
      );

      expect(args, isNot(contains('-y')));
      expect(args, isNot(contains('--model')));
      expect(args, isNot(contains('--effort')));
      expect(args, containsAll(['--autocompact', '100000']));
      expect(args, contains('--no-session-persistence'));
      expect(args, containsAll(['--system-prompt', 'Custom prompt']));
    });

    test('set_model before first turn recycles idle process with new --model and never forwards default-model', () async {
      final tmp = Directory.systemTemp.createTempSync('cb_tr_preturn_model_');
      final accDir = Directory(p.join(tmp.path, 'cb_accounts'))
        ..createSync(recursive: true);
      final accounts = CodeBuddyAccounts(dataDir: accDir.path);
      await accounts.ensureInitialized();
      final launchesLog = File(p.join(tmp.path, 'launches.jsonl'));
      final (:cli, stdinLog: _) = await _createFakeCodeBuddyCli(
        tmp,
        dartBody: '''
Future<void> main(List<String> args) async {
  File(${jsonEncode(launchesLog.path)}).writeAsStringSync(
    '\${jsonEncode({"args": args})}\\n',
    mode: FileMode.append,
    flush: true,
  );
  final modelIdx = args.indexOf('--model');
  var currentModel =
      (modelIdx >= 0 && modelIdx + 1 < args.length) ? args[modelIdx + 1] : 'server-default';
  var hasSession = false;
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final msg = (jsonDecode(line) as Map).cast<String, Object?>();
    recordStdin(msg);
    if (msg['type'] == 'control_request') {
      final reqId = msg['request_id'] as String;
      final req = (msg['request'] as Map).cast<String, Object?>();
      final subtype = req['subtype'] as String?;
      if (subtype == 'initialize') {
        stdout.writeln(jsonEncode({
          'type': 'control_response',
          'response': {
            'subtype': 'success',
            'request_id': reqId,
            'response': {'currentModelId': 'hy4std', 'models': const <Object?>[]},
          },
        }));
      } else if (subtype == 'get_available_models') {
        stdout.writeln(jsonEncode({
          'type': 'control_response',
          'response': {
            'subtype': 'success',
            'request_id': reqId,
            'response': {'rawModels': const <Object?>[]},
          },
        }));
      } else if (subtype == 'set_model') {
        final sid = req['session_id'] as String?;
        final next = req['model'] as String? ?? '';
        if (!hasSession && (sid == null || sid.isEmpty)) {
          stdout.writeln(jsonEncode({
            'type': 'control_response',
            'response': {
              'subtype': 'error',
              'request_id': reqId,
              'error': 'Session not found: current',
            },
          }));
        } else {
          currentModel = next;
          stdout.writeln(jsonEncode({
            'type': 'control_response',
            'response': {
              'subtype': 'success',
              'request_id': reqId,
              'response': {'model': next},
            },
          }));
        }
      } else {
        stdout.writeln(jsonEncode({
          'type': 'control_response',
          'response': {
            'subtype': 'success',
            'request_id': reqId,
            'response': const <String, Object?>{},
          },
        }));
      }
      await stdout.flush();
    } else if (msg['type'] == 'user') {
      hasSession = true;
      stdout.writeln(jsonEncode({
        'type': 'system',
        'subtype': 'init',
        'session_id': 'cb-sess-1',
      }));
      stdout.writeln(jsonEncode({
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
        'session_id': 'cb-sess-1',
        'result': 'model=\$currentModel',
      }));
      await stdout.flush();
    }
  }
}
''',
      );

      final transport = CodeBuddyTransport.forTesting(
        cli: CodeBuddyCli(
          executable: cli.executable,
          environment: {'HOME': tmp.path, 'USERPROFILE': tmp.path},
          throughShell: cli.throughShell,
        ),
        launch: ClaudeLaunch(
          cwd: tmp.path,
          model: '@$codebuddyBuiltinProviderId/default-model',
          persist: false,
        ),
        accounts: accounts,
      );
      addTearDown(() async {
        transport.close();
        accounts.dispose();
        await transport.exited.timeout(
          const Duration(seconds: 3),
          onTimeout: () {},
        );
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      final channel = ControlChannel(transport.write);
      final results = <String>[];
      Completer<String>? nextResult;
      final sub = transport.messages.listen((msg) {
        channel.receive(msg);
        if (msg['type'] == 'result') {
          final text = '${msg['result']}';
          results.add(text);
          if (nextResult case final pending? when !pending.isCompleted) {
            pending.complete(text);
          }
        }
      });
      addTearDown(sub.cancel);

      await transport.spawnForTesting();
      await channel.request('initialize', {}, const Duration(seconds: 10));

      // Switch to a concrete model BEFORE the first turn (no session yet).
      await channel.request(
        'set_model',
        {'model': 'deepseek-v4.1-flash'},
        const Duration(seconds: 10),
      );
      nextResult = Completer<String>();
      transport.write({
        'type': 'user',
        'uuid': 'u1',
        'message': {'role': 'user', 'content': 'hello'},
      });
      final turn1 = await nextResult.future.timeout(
        const Duration(seconds: 10),
      );
      expect(turn1, 'model=deepseek-v4.1-flash');

      final launches = [
        for (final line in launchesLog.readAsLinesSync())
          if (line.trim().isNotEmpty)
            (jsonDecode(line) as Map)['args'] as List,
      ];
      expect(launches, hasLength(2));
      expect(launches[0], isNot(contains('--model')));
      expect(launches[1], containsAll(['--model', 'deepseek-v4.1-flash']));

      // Switching back to Auto (default-model) after session start must resolve
      // to the CLI's concrete default (hy4std), never literal default-model.
      await channel.request(
        'set_model',
        {'model': 'default-model'},
        const Duration(seconds: 10),
      );
      nextResult = Completer<String>();
      transport.write({
        'type': 'user',
        'uuid': 'u2',
        'message': {'role': 'user', 'content': 'second'},
      });
      final turn2 = await nextResult.future.timeout(
        const Duration(seconds: 10),
      );
      expect(turn2, 'model=hy4std');
      expect(results, ['model=deepseek-v4.1-flash', 'model=hy4std']);
    });
  });

  group('CodeBuddyTransport.buildUsagePayload', () {
    test('returns rate_limits_available: false when account or quota missing or empty API key', () {
      expect(
        CodeBuddyTransport.buildUsagePayload(null),
        {'rate_limits_available': false},
      );
      expect(
        CodeBuddyTransport.buildUsagePayload(_makeAccount(id: 'no-quota')),
        {'rate_limits_available': false},
      );
      expect(
        CodeBuddyTransport.buildUsagePayload(
          _makeAccount(
            id: 'api-key',
            quota: const CodeBuddyQuotaData(
              edition: CodeBuddyEdition.apiKey,
              lastUpdated: 1000,
            ),
          ),
        ),
        {'rate_limits_available': false},
      );
    });

    test('builds window from total/remaining credits and tolerates malformed resetTime', () {
      final isoPayload = CodeBuddyTransport.buildUsagePayload(
        _makeAccount(
          id: 'pro-1',
          quota: const CodeBuddyQuotaData(
            edition: CodeBuddyEdition.pro,
            subscriptionPackageName: 'Pro 月度包',
            totalCredits: 1000.0,
            usedCredits: 250.0,
            remainingCredits: 750.0,
            resetTime: '2026-12-01T00:00:00Z',
            lastUpdated: 1000,
          ),
        ),
      );
      expect(isoPayload['rate_limits_available'], isTrue);
      final windows =
          ((isoPayload['rate_limits'] as Map)['windows'] as List).cast<Map>();
      expect(windows, hasLength(1));
      expect(windows.single['label'], 'Pro 月度包');
      expect(windows.single['utilization'], closeTo(25.0, 0.001));
      expect(windows.single['resets_at'], '2026-12-01T00:00:00.000Z');

      final badResetPayload = CodeBuddyTransport.buildUsagePayload(
        _makeAccount(
          id: 'bad-reset',
          quota: const CodeBuddyQuotaData(
            edition: CodeBuddyEdition.pro,
            totalCredits: 100.0,
            remainingCredits: 40.0,
            resetTime: 'not-a-timestamp',
            lastUpdated: 1000,
          ),
        ),
      );
      final w2 = ((badResetPayload['rate_limits'] as Map)['windows'] as List)
          .single as Map;
      expect(w2.containsKey('resets_at'), isFalse);
      expect(w2['utilization'], closeTo(60.0, 0.001));
    });

    test('builds windows per active package and handles unlimited and exhausted states', () {
      final pkgPayload = CodeBuddyTransport.buildUsagePayload(
        _makeAccount(
          id: 'pkgs',
          quota: const CodeBuddyQuotaData(
            edition: CodeBuddyEdition.pro,
            packages: [
              CodeBuddyCreditPackage(
                packageCode: 'base',
                packageName: '基础包',
                total: 500.0,
                remain: 100.0,
                used: 400.0,
                expireTime: '2026-11-30 23:59:59',
              ),
              CodeBuddyCreditPackage(
                packageCode: 'zero',
                packageName: '空包',
                total: 0.0,
                remain: 0.0,
                used: 0.0,
              ),
            ],
            lastUpdated: 1000,
          ),
        ),
      );
      final pkgWindows =
          ((pkgPayload['rate_limits'] as Map)['windows'] as List).cast<Map>();
      expect(pkgWindows, hasLength(1));
      expect(pkgWindows.single['label'], '基础包');
      expect(pkgWindows.single['utilization'], closeTo(80.0, 0.001));
      expect(pkgWindows.single['resets_at'], isNotNull);

      final unlim = CodeBuddyTransport.buildUsagePayload(
        _makeAccount(
          id: 'unlim',
          quota: const CodeBuddyQuotaData(
            edition: CodeBuddyEdition.exclusive,
            unlimited: true,
            lastUpdated: 1000,
          ),
        ),
      );
      expect(
        (((unlim['rate_limits'] as Map)['windows'] as List).single
            as Map)['utilization'],
        0.0,
      );

      final exhausted = CodeBuddyTransport.buildUsagePayload(
        _makeAccount(
          id: 'exhausted',
          quota: const CodeBuddyQuotaData(
            edition: CodeBuddyEdition.free,
            totalCredits: 100.0,
            remainingCredits: 0.0,
            quotaExhausted: true,
            lastUpdated: 1000,
          ),
        ),
      );
      expect(
        (((exhausted['rate_limits'] as Map)['windows'] as List).single
            as Map)['utilization'],
        100.0,
      );
    });
  });

  group('CodeBuddyAccounts ClaudeEnvironment isolation', () {
    test('CodeBuddyAccounts.instance reloads when ClaudeEnvironment HOME changes', () async {
      final tmp = Directory.systemTemp.createTempSync('cb_acc_env_');
      addTearDown(() {
        ClaudeEnvironment.use(null);
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      Future<void> seedHome(String homeName, String accId, double remain) async {
        final homeDir = Directory(p.join(tmp.path, homeName));
        final accDir = Directory(
          p.join(homeDir.path, '.cyte', 'codebuddy_accounts', 'accounts'),
        )..createSync(recursive: true);
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        File(p.join(accDir.path, '$accId.json')).writeAsStringSync(
          jsonEncode({
            'id': accId,
            'uid': 'u-$accId',
            'nickname': accId,
            'region': 'cn',
            'endpoint': 'https://copilot.tencent.com',
            'auth': {'kind': 'authToken', 'access_token': 'tok'},
            'quota': {
              'edition': 'pro',
              'total_credits': 1000.0,
              'remaining_credits': remain,
              'used_credits': 1000.0 - remain,
              'last_updated': now,
            },
            'created_at': now,
            'last_used': now,
          }),
        );
        File(
          p.join(homeDir.path, '.cyte', 'codebuddy_accounts', 'accounts.json'),
        ).writeAsStringSync(
          jsonEncode({
            'current_account_id': accId,
            'accounts': [
              {'id': accId, 'uid': 'u-$accId', 'nickname': accId, 'region': 'cn'},
            ],
          }),
        );
      }

      await seedHome('home1', 'acc-1', 700.0);
      await seedHome('home2', 'acc-2', 300.0);

      ClaudeEnvironment.use({
        'HOME': p.join(tmp.path, 'home1'),
        'USERPROFILE': p.join(tmp.path, 'home1'),
      });
      await CodeBuddyAccounts.instance.ensureInitialized();
      expect(CodeBuddyAccounts.instance.currentAccount?.id, 'acc-1');
      expect(
        CodeBuddyAccounts.instance.currentAccount?.quota?.remainingCredits,
        700.0,
      );

      ClaudeEnvironment.use({
        'HOME': p.join(tmp.path, 'home2'),
        'USERPROFILE': p.join(tmp.path, 'home2'),
      });
      await CodeBuddyAccounts.instance.ensureInitialized();
      expect(CodeBuddyAccounts.instance.currentAccount?.id, 'acc-2');
      expect(
        CodeBuddyAccounts.instance.currentAccount?.quota?.remainingCredits,
        300.0,
      );
    });

    testWidgets('Finding 1: upsertAccount / syncFromCliInitializeAccount followed immediately by dispose() does not throw or leak timers', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('cb_acc_dispose_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      await tester.runAsync(() async {
        final accounts1 = CodeBuddyAccounts(
          dataDir: p.join(tmp.path, 'acc1'),
        );
        await accounts1.ensureInitialized();
        await accounts1.upsertAccount(_makeAccount(id: 'dispose-upsert'));
        accounts1.dispose();

        final accounts2 = CodeBuddyAccounts(
          dataDir: p.join(tmp.path, 'acc2'),
        );
        await accounts2.ensureInitialized();
        await accounts2.syncFromCliInitializeAccount({
          'uid': 'cli-u1',
          'accessToken': 'tok-cli-1',
          'domain': 'https://copilot.tencent.com',
        });
        accounts2.dispose();

        // Allow any in-flight unawaited refreshQuota/fetchQuota continuations to settle.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('CodeBuddyTransport live fake CLI control forwarding & fallback', () {
    test('forwards all control subtypes, preserves error responses, seeds init commands, and serves get_usage', () async {
      final tmp = Directory.systemTemp.createTempSync('cb_tr_live_');
      final accDir = Directory(p.join(tmp.path, 'cb_accounts'))
        ..createSync(recursive: true);
      final accounts = CodeBuddyAccounts(dataDir: accDir.path);
      await accounts.ensureInitialized();
      await accounts.upsertAccount(
        _makeAccount(
          id: 'cb-live-1',
          quota: const CodeBuddyQuotaData(
            edition: CodeBuddyEdition.pro,
            subscriptionPackageName: 'Pro Pack',
            totalCredits: 500.0,
            usedCredits: 125.0,
            remainingCredits: 375.0,
            resetTime: '2026-12-10T08:00:00Z',
            lastUpdated: 1000,
          ),
        ),
      );

      const cliBody = r'''
Future<void> main(List<String> args) async {
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final msg = (jsonDecode(line) as Map).cast<String, Object?>();
    recordStdin(msg);
    if (msg['type'] != 'control_request') continue;
    final reqId = msg['request_id'] as String;
    final req = (msg['request'] as Map).cast<String, Object?>();
    final subtype = req['subtype'] as String? ?? '';
    if (subtype == 'mcp_authenticate') {
      stdout.writeln(jsonEncode({
        'type': 'control_response',
        'response': {
          'subtype': 'error',
          'request_id': reqId,
          'error': 'OAuth rejected by server',
        },
      }));
      await stdout.flush();
      continue;
    }
    final payload = switch (subtype) {
      'initialize' => {'commands': const <Object?>[]},
      'get_available_models' => {'rawModels': const <Object?>[]},
      'mcp_status' => {
        'mcpServers': const [
          {'name': 'srv-a', 'status': 'connected', 'scope': 'user'},
        ],
      },
      'file_suggestions' => {
        'suggestions': const [
          {'path': 'lib/main.dart'},
        ],
      },
      'get_hooks_listing' => {
        'hooks': const [
          {
            'event': 'Stop',
            'source': 'sessionHook',
            'type': 'prompt',
            'commandText': 'check',
          },
        ],
      },
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
  }
}
''';

      final (:cli, :stdinLog) = await _createFakeCodeBuddyCli(
        tmp,
        dartBody: cliBody,
      );
      final transport = CodeBuddyTransport.forTesting(
        cli: cli,
        launch: ClaudeLaunch(cwd: tmp.path, persist: false),
        accounts: accounts,
      );
      addTearDown(() async {
        transport.close();
        await transport.exited.timeout(
          const Duration(seconds: 3),
          onTimeout: () {},
        );
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      await transport.spawnForTesting();
      final channel = ControlChannel(transport.write);
      final sub = transport.messages.listen(channel.receive);
      addTearDown(sub.cancel);

      final initResp = await channel.request('initialize', {});
      final seededCmds = (initResp['commands'] as List).cast<Map>();
      expect(
        seededCmds.map((c) => c['name']),
        containsAll(['compact', 'clear', 'plan', 'status']),
      );

      final mcpStatus = await channel.request('mcp_status', {});
      expect((mcpStatus['mcpServers'] as List).first, containsPair('name', 'srv-a'));

      await channel.request('mcp_toggle', {'serverName': 'srv-a', 'enabled': false});
      await channel.request('mcp_reconnect', {'serverName': 'srv-a'});
      await channel.request('reconnect_mcp', {'serverName': 'srv-a'});

      await expectLater(
        channel.request('mcp_authenticate', {'serverName': 'srv-a'}),
        throwsA(
          isA<ControlError>()
              .having((e) => e.subtype, 'subtype', 'mcp_authenticate')
              .having((e) => e.message, 'message', contains('OAuth rejected by server')),
        ),
      );

      final files = await channel.request('file_suggestions', {'query': 'main'});
      expect((files['suggestions'] as List).first, containsPair('path', 'lib/main.dart'));

      await channel.request('stop_task', {'task_id': 't1'});
      await channel.request('background_tasks', {'tool_use_id': 'tu1'});

      final hooks = await channel.request('get_hooks_listing', {});
      expect((hooks['hooks'] as List).first, containsPair('event', 'Stop'));

      final usage = await channel.request('get_usage', {'skip_behaviors': true});
      expect(usage['rate_limits_available'], isTrue);
      final usageWindows =
          ((usage['rate_limits'] as Map)['windows'] as List).cast<Map>();
      expect(usageWindows.single['label'], 'Pro Pack');
      expect(usageWindows.single['utilization'], closeTo(25.0, 0.001));

      expect(transport.pendingControlRequestCountForTesting, 0);

      final loggedSubtypes = [
        for (final line in stdinLog.readAsLinesSync())
          if (line.trim().isNotEmpty)
            ((jsonDecode(line) as Map)['request'] as Map?)?['subtype'],
      ];
      expect(
        loggedSubtypes,
        containsAll([
          'mcp_status',
          'mcp_toggle',
          'mcp_reconnect',
          'reconnect_mcp',
          'mcp_authenticate',
          'file_suggestions',
          'stop_task',
          'background_tasks',
          'get_hooks_listing',
        ]),
      );
    });

    test('timeout fallback resolves unanswered subtypes safely and close cancels pending timers', () async {
      final tmp = Directory.systemTemp.createTempSync('cb_tr_timeout_');
      CodeBuddyTransport.forwardedControlFallbackTimeoutOverride =
          const Duration(milliseconds: 40);
      addTearDown(() {
        CodeBuddyTransport.forwardedControlFallbackTimeoutOverride = null;
      });

      // Silent CLI that never replies to forwarded subtypes.
      const silentBody = r'''
Future<void> main(List<String> args) async {
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final _ in lines) {}
}
''';
      final (:cli, stdinLog: _) = await _createFakeCodeBuddyCli(
        tmp,
        dartBody: silentBody,
      );
      final transport = CodeBuddyTransport.forTesting(
        cli: cli,
        launch: ClaudeLaunch(cwd: tmp.path, persist: false),
      );
      addTearDown(() async {
        transport.close();
        await transport.exited.timeout(
          const Duration(seconds: 3),
          onTimeout: () {},
        );
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      await transport.spawnForTesting();
      final channel = ControlChannel(transport.write);
      final sub = transport.messages.listen(channel.receive);
      addTearDown(sub.cancel);

      expect(await channel.request('mcp_status', {}), {'mcpServers': <Object?>[]});
      expect(await channel.request('file_suggestions', {'query': 'a'}), {
        'suggestions': <Object?>[],
      });
      expect(await channel.request('get_hooks_listing', {}), {'hooks': <Object?>[]});
      expect(await channel.request('mcp_toggle', {'serverName': 's', 'enabled': true}), isEmpty);
      expect(await channel.request('mcp_reconnect', {'serverName': 's'}), isEmpty);
      expect(await channel.request('mcp_authenticate', {'serverName': 's'}), isEmpty);
      expect(await channel.request('stop_task', {'task_id': 't1'}), isEmpty);
      expect(await channel.request('background_tasks', {'tool_use_id': 'tu1'}), isEmpty);
      expect(transport.pendingControlRequestCountForTesting, 0);

      // Verify late exit of a stale/recycled Process does NOT cancel active pending requests.
      CodeBuddyTransport.forwardedControlFallbackTimeoutOverride =
          const Duration(seconds: 10);
      final stalePending = channel.request('mcp_status', {});
      expect(transport.pendingControlRequestCountForTesting, 1);
      final staleProc = await Process.start(_resolveDartExecutable(), ['--version']);
      await staleProc.exitCode;
      transport.simulateProcessExitForTesting(staleProc, 0);
      expect(transport.pendingControlRequestCountForTesting, 1);

      // Verify close() cancels in-flight pending fallback timers cleanly.
      transport.close();
      expect(transport.pendingControlRequestCountForTesting, 0);
      channel.failAll('closed');
      await expectLater(stalePending, throwsA(isA<ControlError>()));
    });

    test('ClaudeCodeKernel(codebuddy) refreshUsage reads CodeBuddyAccounts via CodeBuddyTransport', () async {
      ClaudeCodeKernel.forgetAccount();
      ClaudeCodeKernel.usageRetryDelay = Duration.zero;
      addTearDown(() {
        ClaudeCodeKernel.forgetAccount();
        ClaudeCodeKernel.usageRetryDelay = const Duration(seconds: 3);
      });

      final tmp = Directory.systemTemp.createTempSync('cb_kernel_usage_');
      final accDir = Directory(p.join(tmp.path, 'cb_accounts'))
        ..createSync(recursive: true);
      final accounts = CodeBuddyAccounts(dataDir: accDir.path);
      await accounts.ensureInitialized();
      await accounts.upsertAccount(
        _makeAccount(
          id: 'cb-k-1',
          quota: const CodeBuddyQuotaData(
            edition: CodeBuddyEdition.pro,
            subscriptionPackageName: 'CodeBuddy Pro Credits',
            totalCredits: 200.0,
            usedCredits: 50.0,
            remainingCredits: 150.0,
            lastUpdated: 1000,
          ),
        ),
      );

      const cliBody = r'''
Future<void> main(List<String> args) async {
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final msg = (jsonDecode(line) as Map).cast<String, Object?>();
    if (msg['type'] != 'control_request') continue;
    final reqId = msg['request_id'] as String;
    final req = (msg['request'] as Map).cast<String, Object?>();
    final subtype = req['subtype'] as String? ?? '';
    final payload = switch (subtype) {
      'initialize' => {'commands': const <Object?>[], 'models': const <Object?>[]},
      'get_available_models' => {'rawModels': const <Object?>[]},
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
  }
}
''';

      final (:cli, stdinLog: _) = await _createFakeCodeBuddyCli(
        tmp,
        dartBody: cliBody,
      );
      final kernel = ClaudeCodeKernel(
        KernelRegistry.codebuddy,
        KernelContext(cwd: tmp.path),
        start: (launch) async {
          final transport = CodeBuddyTransport.forTesting(
            cli: cli,
            launch: launch,
            accounts: accounts,
          );
          await transport.spawnForTesting();
          return transport;
        },
      );
      addTearDown(() async {
        kernel.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      await kernel.refreshUsage();
      expect(kernel.accountLimits, hasLength(1));
      expect(kernel.accountLimits.single.label, 'CodeBuddy Pro Credits');
      expect(kernel.accountLimits.single.utilization, closeTo(0.25, 0.001));
    });

    test('close() during mid-spawn aborts Process.start, closes messages, and defers exited until unwind', () async {
      final tmp = Directory.systemTemp.createTempSync('cb_tr_midclose_');
      final accDir = Directory(p.join(tmp.path, 'cb_accounts'))
        ..createSync(recursive: true);
      final accounts = _PausingAccounts(dataDir: accDir.path);
      await accounts.ensureInitialized();
      await accounts.upsertAccount(_makeAccount(id: 'acc-pause'));

      final pidFile = File(p.join(tmp.path, 'spawned.pid'));
      final (:cli, stdinLog: _) = await _createFakeCodeBuddyCli(
        tmp,
        dartBody: '''
Future<void> main(List<String> args) async {
  File(${jsonEncode(pidFile.path)}).writeAsStringSync('\$pid', flush: true);
  await stdin.transform(utf8.decoder).drain<void>();
}
''',
      );
      final transport = CodeBuddyTransport.forTesting(
        cli: CodeBuddyCli(
          executable: cli.executable,
          environment: {'HOME': tmp.path, 'USERPROFILE': tmp.path},
          throughShell: cli.throughShell,
        ),
        launch: ClaudeLaunch(cwd: tmp.path, persist: false),
        accounts: accounts,
      );
      addTearDown(() async {
        transport.close();
        accounts.dispose();
        if (pidFile.existsSync()) {
          final pid = int.tryParse(pidFile.readAsStringSync().trim());
          if (pid != null) {
            if (Platform.isWindows) {
              Process.runSync('taskkill', ['/PID', '$pid', '/T', '/F']);
            } else {
              Process.killPid(pid, ProcessSignal.sigkill);
            }
          }
        }
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      final messagesDone = transport.messages.drain<void>();
      var exitedResolved = false;
      unawaited(transport.exited.then((_) => exitedResolved = true));

      accounts.pauseAccountId = 'acc-pause';
      final spawnFuture = transport.spawnForTesting();
      await accounts.waitUntilPaused();

      transport.close();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(exitedResolved, isFalse);

      accounts.resumePause();
      await Future.wait([
        spawnFuture,
        messagesDone.timeout(const Duration(seconds: 3)),
        transport.exited.timeout(const Duration(seconds: 3)),
      ]);
      expect(exitedResolved, isTrue);
      expect(pidFile.existsSync(), isFalse);
    });

    test('respawn on active account switch kills Windows .cmd grandchild tree without orphans', () async {
      final savedSwitchHandler = CodeBuddyAccounts.onActiveAccountSwitched;
      CodeBuddyAccounts.onActiveAccountSwitched = null;
      addTearDown(
        () => CodeBuddyAccounts.onActiveAccountSwitched = savedSwitchHandler,
      );

      final tmp = Directory.systemTemp.createTempSync('cb_tr_respawn_tree_');
      final accDir = Directory(p.join(tmp.path, 'cb_accounts'))
        ..createSync(recursive: true);
      final accounts = CodeBuddyAccounts(dataDir: accDir.path);
      await accounts.ensureInitialized();
      await accounts.upsertAccount(_makeAccount(id: 'acc-1'), makeActive: true);

      final dartExe = _resolveDartExecutable();
      final sleeperScript = File(p.join(tmp.path, 'sleeper.dart'));
      final grandchildPidFile = File(p.join(tmp.path, 'grandchild.pid'));
      await sleeperScript.writeAsString('''
import 'dart:io';
Future<void> main() async {
  File(${jsonEncode(grandchildPidFile.path)}).writeAsStringSync('\$pid', flush: true);
  await Future<void>.delayed(const Duration(seconds: 30));
}
''');

      final (:cli, stdinLog: _) = await _createFakeCodeBuddyCli(
        tmp,
        dartBody: '''
Future<void> main(List<String> args) async {
  final gcFile = File(${jsonEncode(grandchildPidFile.path)});
  if (!gcFile.existsSync()) {
    await Process.start(${jsonEncode(dartExe)}, [${jsonEncode(sleeperScript.path)}]);
    for (var i = 0; i < 40 && !gcFile.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final msg = (jsonDecode(line) as Map).cast<String, Object?>();
    if (msg['type'] == 'control_request') {
      final reqId = msg['request_id'];
      stdout.writeln(jsonEncode({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': reqId,
          'response': const <String, Object?>{},
        },
      }));
      await stdout.flush();
    } else if (msg['type'] == 'user') {
      final content = ((msg['message'] as Map?)?['content'] ?? '').toString();
      stdout.writeln(jsonEncode({
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
        'result': 'ok:\$content',
      }));
      await stdout.flush();
    }
  }
}
''',
      );

      final transport = CodeBuddyTransport.forTesting(
        cli: CodeBuddyCli(
          executable: cli.executable,
          environment: {'HOME': tmp.path, 'USERPROFILE': tmp.path},
          throughShell: cli.throughShell,
        ),
        launch: ClaudeLaunch(cwd: tmp.path, persist: false),
        accounts: accounts,
      );
      addTearDown(() async {
        transport.close();
        accounts.dispose();
        await transport.exited.timeout(
          const Duration(seconds: 3),
          onTimeout: () {},
        );
        if (grandchildPidFile.existsSync()) {
          final gcPid = int.tryParse(grandchildPidFile.readAsStringSync().trim());
          if (gcPid != null) {
            if (Platform.isWindows) {
              Process.runSync('taskkill', ['/PID', '$gcPid', '/T', '/F']);
            } else {
              Process.killPid(gcPid, ProcessSignal.sigkill);
            }
          }
        }
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      final results = <String>[];
      final sub = transport.messages.listen((msg) {
        if (msg['type'] == 'result') results.add('${msg['result']}');
      });
      addTearDown(sub.cancel);

      await transport.spawnForTesting();
      transport.write({
        'type': 'user',
        'uuid': 'u1',
        'message': {'role': 'user', 'content': 'turn-1'},
      });
      for (var i = 0; i < 80 && results.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(results, ['ok:turn-1']);
      expect(grandchildPidFile.existsSync(), isTrue);
      final gcPid = int.parse(grandchildPidFile.readAsStringSync().trim());
      expect(_isPidAlive(gcPid), isTrue);

      await accounts.upsertAccount(_makeAccount(id: 'acc-2'), makeActive: true);
      transport.write({
        'type': 'user',
        'uuid': 'u2',
        'message': {'role': 'user', 'content': 'turn-2'},
      });
      for (var i = 0; i < 120 && results.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(results, ['ok:turn-1', 'ok:turn-2']);
      expect(
        _isPidAlive(gcPid),
        isFalse,
        reason: 'Grandchild PID $gcPid must be terminated on respawn',
      );
    });

    test('close() followed immediately by stopAll() kills grandchild tree, deletes API-key settings file, and completes exited before stopAll returns', () async {
      final tmp = Directory.systemTemp.createTempSync('cb_tr_close_stopall_');
      final accDir = Directory(p.join(tmp.path, 'cb_accounts'))
        ..createSync(recursive: true);
      final accounts = CodeBuddyAccounts(dataDir: accDir.path);
      await accounts.ensureInitialized();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await accounts.upsertAccount(
        CodeBuddyAccount(
          id: 'acc-apikey',
          uid: 'uid-apikey',
          nickname: 'API Key User',
          region: CodeBuddyRegion.cn,
          endpoint: CodeBuddyRegion.cn.defaultEndpoint,
          auth: const CodeBuddyAuthData(
            kind: CodeBuddyAuthKind.apiKey,
            apiKey: 'cb-secret-key-test',
          ),
          createdAt: now,
          lastUsed: now,
        ),
        makeActive: true,
      );

      final dartExe = _resolveDartExecutable();
      final sleeperScript = File(p.join(tmp.path, 'sleeper.dart'));
      final gcPidFile = File(p.join(tmp.path, 'grandchild.pid'));
      await sleeperScript.writeAsString('''
import 'dart:io';
Future<void> main() async {
  File(${jsonEncode(gcPidFile.path)}).writeAsStringSync('\$pid', flush: true);
  await Future<void>.delayed(const Duration(seconds: 30));
}
''');

      final (:cli, stdinLog: _) = await _createFakeCodeBuddyCli(
        tmp,
        dartBody: '''
Future<void> main(List<String> args) async {
  await Process.start(${jsonEncode(dartExe)}, [${jsonEncode(sleeperScript.path)}]);
  stdout.writeln(jsonEncode({'type': 'system', 'subtype': 'init', 'session_id': 'cb-stopall'}));
  await stdout.flush();
  await stdin.transform(utf8.decoder).drain<void>();
}
''',
      );

      final transport = CodeBuddyTransport.forTesting(
        cli: CodeBuddyCli(
          executable: cli.executable,
          environment: {'HOME': tmp.path, 'USERPROFILE': tmp.path},
          throughShell: cli.throughShell,
        ),
        launch: ClaudeLaunch(cwd: tmp.path, persist: false),
        accounts: accounts,
      );
      addTearDown(() async {
        transport.close();
        await CodeBuddyTransport.stopAll();
        accounts.dispose();
        if (gcPidFile.existsSync()) {
          final gcPid = int.tryParse(gcPidFile.readAsStringSync().trim());
          if (gcPid != null) {
            if (Platform.isWindows) {
              Process.runSync('taskkill', ['/PID', '$gcPid', '/T', '/F']);
            } else {
              Process.killPid(gcPid, ProcessSignal.sigkill);
            }
          }
        }
        if (tmp.existsSync()) {
          for (var i = 0; i < 10; i++) {
            try {
              tmp.deleteSync(recursive: true);
              break;
            } on FileSystemException {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }
        }
      });

      var exitedDone = false;
      unawaited(transport.exited.then((_) => exitedDone = true));

      await transport.spawnForTesting();
      final settingsPath = transport.settingsFilePathForTesting;
      expect(settingsPath, isNotNull);
      expect(File(settingsPath!).existsSync(), isTrue);

      for (var i = 0; i < 80 && !gcPidFile.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(gcPidFile.existsSync(), isTrue);
      final gcPid = int.parse(gcPidFile.readAsStringSync().trim());
      expect(_isPidAlive(gcPid), isTrue);

      transport.close();
      await CodeBuddyTransport.stopAll();

      expect(exitedDone, isTrue);
      expect(_isPidAlive(gcPid), isFalse);
      expect(File(settingsPath).existsSync(), isFalse);
    });

    testWidgets('stopAll() when idle completes inside FakeAsync without pending timers', (tester) async {
      await CodeBuddyTransport.stopAll();
      await tester.pump();
    });
  });

  group('LocalCodeBuddy Windows env & PATH resolution', () {
    test('reads Windows Path/AppData case-insensitively and prioritizes explicit PATH ahead of APPDATA\\npm', () {
      final tmp = Directory.systemTemp.createTempSync('cb_cli_path_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      final explicitBin = Directory(p.join(tmp.path, 'explicit_bin'))
        ..createSync(recursive: true);
      final appDataDir = Directory(p.join(tmp.path, 'roaming'))
        ..createSync(recursive: true);
      final npmDir = Directory(p.join(appDataDir.path, 'npm'))
        ..createSync(recursive: true);
      final emptyHome = Directory(p.join(tmp.path, 'empty_home'))
        ..createSync(recursive: true);

      final explicitCmd = File(p.join(explicitBin.path, 'codebuddy.cmd'))
        ..writeAsStringSync('@echo off\r\n');
      File(p.join(npmDir.path, 'codebuddy.cmd')).writeAsStringSync('@echo off\r\n');

      final enriched = LocalCodeBuddy.enrichedPathEnvironment({
        'Path': explicitBin.path,
        'AppData': appDataDir.path,
        'Home': emptyHome.path,
        'UserProfile': emptyHome.path,
      }, forceWindows: true);

      expect(enriched.containsKey('Path'), isFalse);
      expect(enriched['PATH'], isNotNull);
      final parts = enriched['PATH']!.split(';');
      expect(parts.first, explicitBin.path);
      expect(parts, contains(p.windows.join(appDataDir.path, 'npm')));

      final located = LocalCodeBuddy.locateSyncForTesting({
        'Path': explicitBin.path,
        'AppData': appDataDir.path,
        'Home': emptyHome.path,
        'UserProfile': emptyHome.path,
      }, forceWindows: true);
      expect(located, explicitCmd.path);
    });
  });

  group('CodeBuddyAccounts cross-zone ensureInitialized resilience', () {
    late Directory tmp;
    late CodeBuddyAccounts sharedAcc;

    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('cb_acc_zone_');
      sharedAcc = CodeBuddyAccounts(dataDir: p.join(tmp.path, 'shared'));
    });

    tearDownAll(() {
      sharedAcc.dispose();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    testWidgets('unawaited ensureInitialized inside FakeAsync does not deadlock later callers', (tester) async {
      unawaited(sharedAcc.ensureInitialized());
      await tester.pump();
    });

    test('ensureInitialized completes cleanly in root test zone after FakeAsync', () async {
      await sharedAcc.ensureInitialized().timeout(const Duration(seconds: 3));
      expect(sharedAcc.accounts, isEmpty);
    });

    test('concurrent cross-zone ensureInitialized calls load disk accounts without duplicates', () async {
      final localTmp = Directory.systemTemp.createTempSync('cb_acc_zones_');
      addTearDown(() {
        ClaudeEnvironment.use(null);
        if (localTmp.existsSync()) localTmp.deleteSync(recursive: true);
      });

      void seedCbDir(Directory dataDir, String id) {
        final accountsDir = Directory(p.join(dataDir.path, 'accounts'))
          ..createSync(recursive: true);
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        File(p.join(accountsDir.path, '$id.json')).writeAsStringSync(
          jsonEncode({
            'id': id,
            'uid': 'u-$id',
            'nickname': id,
            'region': 'cn',
            'endpoint': 'https://copilot.tencent.com',
            'auth': {'kind': 'authToken', 'access_token': 'tok-$id'},
            'created_at': now,
            'last_used': now,
          }),
        );
        File(p.join(dataDir.path, 'accounts.json')).writeAsStringSync(
          jsonEncode({
            'current_account_id': id,
            'accounts': [
              {'id': id, 'uid': 'u-$id', 'nickname': id, 'region': 'cn'},
            ],
          }),
        );
      }

      final explicitDir = Directory(p.join(localTmp.path, 'explicit'));
      seedCbDir(explicitDir, 'cb-1');
      final acc = CodeBuddyAccounts(dataDir: explicitDir.path);
      addTearDown(acc.dispose);

      await Future.wait([
        runZoned(() => acc.ensureInitialized()),
        runZoned(() => acc.ensureInitialized()),
        runZoned(() => acc.ensureInitialized()),
      ]);

      expect(acc.accounts.map((a) => a.id).toList(), ['cb-1']);
      expect(acc.currentAccountId, 'cb-1');
      final exported =
          jsonDecode(acc.exportAccountsJson()) as Map<String, Object?>;
      expect(exported['accounts'], hasLength(1));

      final home1 = Directory(p.join(localTmp.path, 'home1'));
      final home2 = Directory(p.join(localTmp.path, 'home2'));
      seedCbDir(
        Directory(p.join(home1.path, '.cyte', 'codebuddy_accounts')),
        'cb-h1',
      );
      seedCbDir(
        Directory(p.join(home2.path, '.cyte', 'codebuddy_accounts')),
        'cb-h2',
      );

      final envAcc = CodeBuddyAccounts();
      addTearDown(envAcc.dispose);
      ClaudeEnvironment.use({'Home': home1.path, 'UserProfile': home1.path});
      await Future.wait([
        runZoned(() => envAcc.ensureInitialized()),
        runZoned(() => envAcc.ensureInitialized()),
      ]);
      expect(envAcc.accounts.map((a) => a.id).toList(), ['cb-h1']);

      ClaudeEnvironment.use({'Home': home2.path, 'UserProfile': home2.path});
      await Future.wait([
        runZoned(() => envAcc.ensureInitialized()),
        runZoned(() => envAcc.ensureInitialized()),
        runZoned(() => envAcc.ensureInitialized()),
      ]);
      expect(envAcc.accounts.map((a) => a.id).toList(), ['cb-h2']);
      expect(envAcc.currentAccountId, 'cb-h2');
    });
  });

  group('CodeBuddyAccounts Windows mixed-case env resolution', () {
    test('ensureInitialized resolves mixed-case Windows Home and UserProfile from ClaudeEnvironment without falling back to host home', () async {
      final tmp = await Directory.systemTemp.createTemp('cb_acc_env_');
      addTearDown(() {
        ClaudeEnvironment.use(null);
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      final isoHome = Directory(p.join(tmp.path, 'iso_home'))
        ..createSync(recursive: true);
      ClaudeEnvironment.use({
        'Home': isoHome.path,
        'UserProfile': isoHome.path,
      });

      final acc = CodeBuddyAccounts();
      addTearDown(acc.dispose);
      await acc.ensureInitialized();

      final expectedDir = p.join(isoHome.path, '.cyte', 'codebuddy_accounts');
      expect(acc.dataDirectoryPath, expectedDir);
      expect(Directory(expectedDir).existsSync(), isTrue);

      ClaudeEnvironment.use({'Home': '', 'UserProfile': ''});
      final blankAcc = CodeBuddyAccounts();
      addTearDown(blankAcc.dispose);
      final savedCwd = Directory.current;
      Directory.current = tmp;
      addTearDown(() => Directory.current = savedCwd);
      await blankAcc.ensureInitialized();
      expect(
        blankAcc.dataDirectoryPath,
        p.join('.cyte', 'codebuddy_accounts'),
      );
    });

    test('ensureInitialized loads disk accounts under FLUTTER_TEST without background HTTP refresh, while explicit refreshAllQuotas still runs', () async {
      final tmp = await Directory.systemTemp.createTemp('cb_acc_flutter_test_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      final dataDir = Directory(p.join(tmp.path, 'cb_accounts'));
      final accountsDir = Directory(p.join(dataDir.path, 'accounts'))
        ..createSync(recursive: true);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await File(p.join(accountsDir.path, 'cb-quiet.json')).writeAsString(
        jsonEncode({
          'id': 'cb-quiet',
          'uid': 'u-quiet',
          'nickname': 'Quiet CB',
          'region': 'cn',
          'endpoint': 'https://copilot.tencent.com',
          'auth': {'kind': 'authToken', 'access_token': 'tok-quiet'},
          'created_at': now,
          'last_used': now,
        }),
      );
      await File(p.join(dataDir.path, 'accounts.json')).writeAsString(
        jsonEncode({
          'current_account_id': 'cb-quiet',
          'accounts': [
            {
              'id': 'cb-quiet',
              'uid': 'u-quiet',
              'nickname': 'Quiet CB',
              'region': 'cn',
            },
          ],
        }),
      );

      var httpOpenCount = 0;
      final savedOverrides = HttpOverrides.current;
      HttpOverrides.global = _CountingHttpOverrides(() => httpOpenCount++);
      addTearDown(() => HttpOverrides.global = savedOverrides);

      final store = CodeBuddyAccounts(dataDir: dataDir.path);
      addTearDown(store.dispose);

      await store.ensureInitialized();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(Platform.environment.containsKey('FLUTTER_TEST'), isTrue);
      expect(store.accounts, hasLength(1));
      expect(store.currentAccountId, 'cb-quiet');
      expect(store.isRefreshingAll, isFalse);
      expect(httpOpenCount, 0);
      expect(store.lastRefreshError, isNull);

      await store.refreshAllQuotas();
      expect(httpOpenCount, greaterThan(0));
    });
  });
}

class _CountingHttpOverrides extends HttpOverrides {
  _CountingHttpOverrides(this.onRequest);

  final void Function() onRequest;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return _CountingHttpClient(onRequest);
  }
}

class _CountingHttpClient implements HttpClient {
  _CountingHttpClient(this.onRequest);

  final void Function() onRequest;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    onRequest();
    return Future<HttpClientRequest>.error(
      const SocketException('blocked in test'),
    );
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

bool _isPidAlive(int pid) {
  if (Platform.isWindows) {
    final res = Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH']);
    return RegExp('(?:^|\\s)$pid(?:\\s|\$)', multiLine: true)
        .hasMatch('${res.stdout}');
  }
  return Process.killPid(pid, ProcessSignal.sigcont);
}

class _PausingAccounts extends CodeBuddyAccounts {
  _PausingAccounts({required super.dataDir});

  String? pauseAccountId;
  Completer<void>? _entered;
  Completer<void>? _release;

  Future<void> waitUntilPaused() => (_entered ??= Completer<void>()).future;

  void resumePause() {
    if (_release != null && !_release!.isCompleted) {
      _release!.complete();
    }
  }

  @override
  Future<CodeBuddyAccount> ensureFreshAccount(CodeBuddyAccount account) async {
    if (account.id == pauseAccountId) {
      pauseAccountId = null;
      _entered ??= Completer<void>();
      if (!_entered!.isCompleted) _entered!.complete();
      _release ??= Completer<void>();
      await _release!.future;
    }
    return account;
  }
}
