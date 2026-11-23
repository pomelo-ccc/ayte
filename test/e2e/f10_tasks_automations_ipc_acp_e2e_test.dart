import 'dart:convert';
import 'dart:io';

import 'package:baocode/acp/acp_agent_service.dart';
import 'package:baocode/acp/ayte_ipc_server.dart';
import 'package:baocode/automations/automation_service.dart';
import 'package:baocode/automations/automations_view.dart';
import 'package:baocode/canvas/canvas_controller.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/settings/pages/general_page.dart';
import 'package:baocode/tasks/task_queue_service.dart';
import 'package:baocode/theme/codicons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
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

const _fakeCodexExecJsonBody = r'''
Future<void> main(List<String> args) async {
  recordEvent({'type': 'launch', 'args': args});
  final env = Map<String, String>.from(Platform.environment);
  final mode = env['FAKE_CODEX_EXEC_MODE'] ?? 'ok';

  if (mode == 'sleep') {
    await Future<void>.delayed(const Duration(seconds: 20));
    exit(0);
  }
  if (mode == 'error_json') {
    stdout.writeln('{broken_json_line');
    stdout.writeln(jsonEncode({
      'type': 'error',
      'message': 'Rate limit hit',
    }));
    await stdout.flush();
    exit(1);
  }

  stdout.writeln(jsonEncode({'type': 'thread.started', 'thread_id': 'th-exec-1'}));
  stdout.writeln(jsonEncode({'type': 'turn.started'}));
  stdout.writeln(jsonEncode({
    'type': 'item.completed',
    'item': {
      'id': 'item-1',
      'type': 'command_execution',
      'command': 'dart test',
      'exit_code': 0,
    },
  }));
  stdout.writeln(jsonEncode({
    'type': 'item.completed',
    'item': {
      'id': 'item-2',
      'type': 'agent_message',
      'text': 'FIXED_BY_CODEX',
    },
  }));
  stdout.writeln(jsonEncode({'type': 'turn.completed'}));
  await stdout.flush();
}
''';

void main() {
  late E2eSandbox sandbox;

  setUp(() {
    sandbox = E2eSandbox.create(realHttp: true);
    TaskQueueService.instance
      ..resetForTest()
      ..storagePathOverride = p.join(sandbox.dataDir.path, 'tasks.json');
    AutomationService.instance.storagePathOverride = p.join(
      sandbox.dataDir.path,
      'automations.json',
    );
    AcpAgentService.instance.headlessRunnerOverride = null;

    sandbox.onDispose(() async {
      AcpAgentService.instance.headlessRunnerOverride = null;
      AutomationService.instance.storagePathOverride = null;
      for (final rule in [...AutomationService.instance.rules]) {
        AutomationService.instance.deleteRule(rule.id);
      }
      await AyteIpcServer.instance.stop();
      await AyteIpcServer.instance.uninstallCli();
      await TaskQueueService.instance.flushForTest();
      TaskQueueService.instance
        ..resetForTest()
        ..storagePathOverride = null;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
  });

  group('F10 Tier 1 — Tasks, Automations, AyteIpcServer & AcpAgentService', () {
    test(
      'F10-T1-01: TaskQueueService worktree run -> diff capture -> clean approveAndMerge with zero systemTemp index leaks',
      () async {
        final repoDir = await initTempGitRepo(sandbox.rootDir);
        final svc = TaskQueueService.instance;

        Set<String> idxFilesInSystemTemp() => Directory.systemTemp
            .listSync()
            .whereType<File>()
            .map((f) => p.basename(f.path))
            .where((n) => n.startsWith('ayte-task-idx-'))
            .toSet();

        final beforeTempIdx = idxFilesInSystemTemp();
        final systemTempIdxEvents = <String>[];
        final tempWatchSub = Directory.systemTemp.watch().listen((event) {
          if (event.path.contains('ayte-task-idx-')) {
            systemTempIdxEvents.add('${event.type}:${event.path}');
          }
        });
        addTearDown(tempWatchSub.cancel);

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
          File(p.join(cwd, 'README.md')).writeAsStringSync('# Updated by Task\n');
          File(p.join(cwd, 'new_file.txt')).writeAsStringSync('created in worktree\n');
          return (ok: true, output: 'Edited files', error: null);
        };

        try {
          final task = svc.enqueue(
            title: 'Edit README and add file',
            prompt: 'Update README.md and create new_file.txt',
            repoPath: repoDir.path,
            agentId: 'codex',
            model: 'm1',
            effort: 'high',
            useWorktree: true,
          );

          await svc.runTask(task.id);
          expect(task.status, WorktreeTaskStatus.review);
          expect(task.model, 'm1');
          expect(task.effort, 'high');
          expect(task.hasDiff, isTrue);
          expect(task.filesChanged, 2);

          final worktreeDir = Directory(task.worktreePath);
          expect(worktreeDir.existsSync(), isTrue);

          final mergeRes = await svc.approveAndMerge(task.id);
          expect(mergeRes.ok, isTrue, reason: mergeRes.message);
          expect(task.status, WorktreeTaskStatus.merged);
          expect(worktreeDir.existsSync(), isFalse);
          expect(
            File(p.join(repoDir.path, 'README.md'))
                .readAsStringSync()
                .replaceAll('\r\n', '\n'),
            '# Updated by Task\n',
          );
          expect(
            File(p.join(repoDir.path, 'new_file.txt')).existsSync(),
            isTrue,
          );
          await Future<void>.delayed(const Duration(milliseconds: 80));
        } finally {
          await tempWatchSub.cancel();
        }
        expect(
          systemTempIdxEvents,
          isEmpty,
          reason: 'Temp GIT_INDEX_FILE must live in cacheDir, not Directory.systemTemp',
        );
        expect(idxFilesInSystemTemp().difference(beforeTempIdx), isEmpty);
      },
    );

    test(
      'F10-T1-02: AcpAgentService codex exec --json arg building & JSONL event parsing',
      () async {
        final cliArgs = AcpAgentService.buildCliArgs(
          agentId: 'codex',
          prompt: 'Fix bug',
          model: 'gpt-5.4',
          effort: 'high',
        );
        expect(cliArgs, containsAllInOrder(['exec', '--json']));
        expect(cliArgs, contains('--full-auto'));
        expect(cliArgs, containsAllInOrder(['-m', 'gpt-5.4']));
        expect(
          cliArgs,
          containsAllInOrder(['-c', 'model_reasoning_effort=high']),
        );

        final fakeBin = Directory(p.join(sandbox.rootDir.path, 'codex_exec_bin'));
        FakeCliExecutable.create(
          fakeBin,
          name: 'codex',
          dartBody: _fakeCodexExecJsonBody,
        );
        sandbox.useClaudeEnvironment(
          _envWithIsolatedPath(sandbox.processEnv, fakeBin.path),
        );

        final chunks = <String>[];
        final res = await AcpAgentService.instance.runHeadlessPrompt(
          agentId: 'codex',
          prompt: 'Fix bug',
          cwd: sandbox.projectDir.path,
          model: 'gpt-5.4',
          effort: 'high',
          onChunk: chunks.add,
        );

        expect(res.ok, isTrue, reason: 'error=${res.error}');
        expect(res.error, isNull);
        expect(res.output, contains('FIXED_BY_CODEX'));
        expect(res.output, isNot(contains('"type":"thread.started"')));
      },
    );

    test(
      'F10-T1-03: AutomationRule model/effort/workflowTemplateId round-trip, create_automation & runNow',
      () async {
        final parsed = AutomationRule.fromJson({
          'id': 'r-json-1',
          'name': 'RoundTrip',
          'prompt': 'Check tests',
          'cwd': sandbox.projectDir.path,
          'cronExpression': '0 2 * * *',
          'agentId': 'codex',
          'model': 'gpt-5.4',
          'effort': 'high',
          'workflowTemplateId': 'wf-1',
        });
        expect(parsed, isNotNull);
        final roundTripped = parsed!.toJson();
        expect(roundTripped['model'], 'gpt-5.4');
        expect(roundTripped['effort'], 'high');
        expect(roundTripped['workflowTemplateId'], 'wf-1');

        final svc = AutomationService.instance;
        svc.registerTools();
        String? capturedModel;
        String? capturedEffort;
        String? capturedAgent;
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
          return (ok: true, output: 'Nightly passed', error: null);
        };

        final toolRes = await ClaudeSdkTools.handle(
          {
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': {
              'name': 'create_automation',
              'arguments': {
                'name': 'Nightly',
                'prompt': 'Check tests',
                'cron': '0 2 * * *',
                'cwd': sandbox.projectDir.path,
                'agentId': 'codex',
                'model': 'gpt-5.4',
                'effort': 'high',
              },
            },
          },
          ClaudeSdkCall(cwd: sandbox.projectDir.path),
        );
        final resultMap = toolRes['result'] as Map<String, Object?>;
        expect(resultMap['isError'], isNot(true));

        final created = svc.rules.firstWhere((r) => r.name == 'Nightly');
        expect(created.agentId, 'codex');
        expect(created.toJson()['model'], 'gpt-5.4');
        expect(created.toJson()['effort'], 'high');

        await svc.runNow(created.id);
        expect(created.history, isNotEmpty);
        expect(created.history.first.ok, isTrue);
        expect(capturedAgent, 'codex');
        expect(capturedModel, 'gpt-5.4');
        expect(capturedEffort, 'high');
      },
    );

    test(
      'F10-T1-04: AyteIpcServer loopback HTTP lifecycle, auth & /health, /agents, /tasks, /tasks/:id/*, /sessions, /automations/run',
      () async {
        final ipc = AyteIpcServer.instance..homeOverride = sandbox.homeDir.path;
        await ipc.start();
        expect(
          ipc.running,
          isTrue,
          reason: 'AyteIpcServer.start() should bind when homeOverride is set',
        );
        expect(File(ipc.ipcInfoPath).existsSync(), isTrue);

        final info =
            jsonDecode(File(ipc.ipcInfoPath).readAsStringSync()) as Map;
        final port = info['port'] as int;
        final token = info['token'] as String;
        final baseUri = Uri.parse('http://127.0.0.1:$port');

        final health = await McpHttpProbe(
          baseUri.replace(path: '/health'),
          bearerToken: token,
        ).requestMethod('GET');
        expect(health.statusCode, 200);
        expect(health.json?['ok'], isTrue);

        final agents = await McpHttpProbe(
          baseUri.replace(path: '/agents'),
          bearerToken: token,
        ).requestMethod('GET');
        expect(agents.statusCode, 200);
        expect(agents.json?['agents'], isA<List>());

        final createTask = await McpHttpProbe(
          baseUri.replace(path: '/tasks'),
          bearerToken: token,
        ).postJsonRpc({
          'title': 'IPC Task',
          'prompt': 'Inspect project',
          'cwd': sandbox.projectDir.path,
          'agent': 'codex',
        });
        expect(createTask.statusCode, 200);
        final taskId = (createTask.json?['task'] as Map)['id'] as String;

        final getTask = await McpHttpProbe(
          baseUri.replace(path: '/tasks/$taskId'),
          bearerToken: token,
        ).requestMethod('GET');
        expect(getTask.statusCode, 200);

        final cancelTask = await McpHttpProbe(
          baseUri.replace(path: '/tasks/$taskId/cancel'),
          bearerToken: token,
        ).postJsonRpc(const {});
        expect(cancelTask.statusCode, 200);

        final sessions = await McpHttpProbe(
          baseUri.replace(path: '/sessions'),
          bearerToken: token,
        ).requestMethod('GET');
        expect(sessions.statusCode, 200);

        final autoRun = await McpHttpProbe(
          baseUri.replace(path: '/automations/run'),
          bearerToken: token,
        ).postJsonRpc({'id': 'missing-id'});
        expect(autoRun.statusCode, 200);

        await ipc.stop();
        expect(ipc.running, isFalse);
        expect(File(ipc.ipcInfoPath).existsSync(), isFalse);
      },
    );

    test(
      'F10-T1-05: KernelRegistry.codex.catalog wired & buildChatHandoff preserves task metadata',
      () async {
        expect(KernelRegistry.codex.catalog, isA<SessionCatalog>());

        final task = TaskQueueService.instance.enqueue(
          title: 'Handoff check',
          prompt: 'Finish Codex task',
          repoPath: sandbox.projectDir.path,
          agentId: 'codex',
          model: 'gpt-5.4',
          effort: 'high',
        );

        final handoff = await TaskQueueService.instance.buildChatHandoff(
          task.id,
          isZh: false,
        );
        expect(handoff, isNotNull);
        expect(handoff!.kernelId, codexKernelId);
        expect(handoff.directory, sandbox.projectDir.path);
        expect(handoff.draftPrompt, contains('Handoff check'));
        expect(handoff.draftPrompt, contains('Finish Codex task'));
        expect((handoff as dynamic).model, 'gpt-5.4');
        expect((handoff as dynamic).effort, 'high');
        expect(task.model, 'gpt-5.4');
        expect(task.effort, 'high');
      },
    );

    testWidgets(
      'F10-T1-06: AutomationsView model/effort/workflow/cwd/edit controls & GeneralSettingsPage ayte-cli UI',
      (tester) async {
        // Keep AutomationService persistence disabled inside testWidgets' FakeAsync
        // zone so unawaited File.writeAsString handles cannot outlive the zone.
        AutomationService.instance.storagePathOverride = null;
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        AyteIpcServer.instance.homeOverride = sandbox.homeDir.path;

        // 1. Validate empty cwd rejection feedback in AutomationsView.
        await tester.pumpWidget(
          const MaterialApp(
            locale: Locale('en'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Scaffold(
              body: SizedBox(
                width: 900,
                height: 700,
                child: AutomationsView(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final emptyCwdFields = find.byType(TextField);
        expect(emptyCwdFields, findsAtLeastNWidgets(3));
        await tester.enterText(emptyCwdFields.at(0), 'No Cwd Auto');
        await tester.enterText(emptyCwdFields.at(2), 'Should fail cwd check');
        await tester.pump();
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();

        expect(
          AutomationService.instance.rules.any((r) => r.name == 'No Cwd Auto'),
          isFalse,
          reason: 'AutomationsView must reject creating a rule with empty cwd',
        );
        expect(
          find.textContaining(
            RegExp(r'cwd|directory|folder|repo|path', caseSensitive: false),
          ),
          findsWidgets,
        );

        // 2. Verify repo/directory picker, workflow/model/effort selectors, rule creation & Edit dialog.
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Scaffold(
              body: SizedBox(
                width: 900,
                height: 700,
                child: AutomationsView(defaultCwd: sandbox.projectDir.path),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final browseControl = find.byWidgetPredicate(
          (w) =>
              (w is Icon &&
                  (w.icon == Codicons.folderOpened ||
                      w.icon == Icons.folder_open)) ||
              (w is Text &&
                  RegExp(
                    r'Browse|Directory|Folder|Repository',
                    caseSensitive: false,
                  ).hasMatch(w.data ?? '')),
        );
        expect(
          browseControl,
          findsWidgets,
          reason: 'AutomationsView must expose a directory/repo picker control',
        );

        final dropdowns = tester
            .widgetList<DropdownButton<String>>(
              find.byType(DropdownButton<String>),
            )
            .toList();
        expect(
          dropdowns.length,
          greaterThanOrEqualTo(2),
          reason: 'AutomationsView must expose agent/workflow and model selectors',
        );

        final workflowIds = CanvasController.instance.runnableWorkflowChoices
            .map((w) => w.id)
            .toSet();
        expect(
          dropdowns.any(
            (dd) => (dd.items ?? const []).any(
              (item) => workflowIds.contains(item.value),
            ),
          ),
          isTrue,
          reason: 'AutomationsView must expose workflow template options',
        );

        final agyModelWithEfforts = AcpAgentService.instance
            .modelsForAgent('agy')
            .firstWhere((m) => m.effortLevels.isNotEmpty);
        final modelDropdownFinder = find.byWidgetPredicate(
          (w) =>
              w is DropdownButton<String> &&
              (w.items ?? const []).any(
                (item) => item.value == agyModelWithEfforts.id,
              ),
        );
        expect(
          modelDropdownFinder,
          findsOneWidget,
          reason: 'AutomationsView must expose a model selector',
        );

        await tester.tap(modelDropdownFinder);
        await tester.pumpAndSettle();
        await tester.tap(find.text(agyModelWithEfforts.label).last);
        await tester.pumpAndSettle();

        final effortDropdowns = tester
            .widgetList<DropdownButton<String>>(
              find.byType(DropdownButton<String>),
            )
            .where(
              (dd) => (dd.items ?? const []).any(
                (item) => agyModelWithEfforts.effortLevels.contains(item.value),
              ),
            );
        expect(
          effortDropdowns,
          isNotEmpty,
          reason: 'AutomationsView must expose effort selector when model supports efforts',
        );

        final textFields = find.byType(TextField);
        expect(textFields, findsAtLeastNWidgets(3));
        await tester.enterText(textFields.at(0), 'Widget Auto');
        await tester.enterText(textFields.at(2), 'Run widget check');
        await tester.pump();
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();

        expect(
          AutomationService.instance.rules.any((r) => r.name == 'Widget Auto'),
          isTrue,
        );

        final ruleEditButton = find.byWidgetPredicate(
          (w) =>
              (w is Icon &&
                  (w.icon == Codicons.edit || w.icon == Icons.edit)) ||
              (w is Tooltip &&
                  RegExp(r'Edit', caseSensitive: false).hasMatch(w.message ?? '')) ||
              (w is Text &&
                  RegExp(r'^Edit$', caseSensitive: false).hasMatch(w.data ?? '')),
        );
        expect(
          ruleEditButton,
          findsWidgets,
          reason: 'AutomationsView rule card must expose an Edit button',
        );
        await tester.tap(ruleEditButton.first);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        final cancelBtn = find.text('Cancel');
        if (cancelBtn.evaluate().isNotEmpty) {
          await tester.tap(cancelBtn.first);
          await tester.pumpAndSettle();
        }

        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const Scaffold(
              body: GeneralSettingsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('ayte-cli'), findsWidgets);
      },
    );
  });

  group('F10 Tier 2 — Guards, Validation, Cancellation & Crash Recovery', () {
    test(
      'F10-T2-01: approveAndMerge rejects dirty main repo without corrupting worktree or uncommitted edits',
      () async {
        final repoDir = await initTempGitRepo(sandbox.rootDir);
        final svc = TaskQueueService.instance;

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
          File(p.join(cwd, 'worktree_only.txt')).writeAsStringSync('from task\n');
          return (ok: true, output: 'ok', error: null);
        };

        final task = svc.enqueue(
          title: 'Dirty guard task',
          prompt: 'Add worktree_only.txt',
          repoPath: repoDir.path,
          useWorktree: true,
        );
        await svc.runTask(task.id);
        expect(task.status, WorktreeTaskStatus.review);

        // Dirty the main repository working tree before merge.
        final mainReadme = File(p.join(repoDir.path, 'README.md'));
        mainReadme.writeAsStringSync('# Uncommitted local work\n');

        final mergeRes = await svc.approveAndMerge(task.id);
        expect(mergeRes.ok, isFalse);
        expect(task.status, WorktreeTaskStatus.review);
        expect(Directory(task.worktreePath).existsSync(), isTrue);
        expect(mainReadme.readAsStringSync(), '# Uncommitted local work\n');

        await svc.discardTask(task.id);
      },
    );

    test(
      'F10-T2-02: AyteIpcServer rejects unauthenticated (401) and invalid POST /tasks (400) requests',
      () async {
        final ipc = AyteIpcServer.instance..homeOverride = sandbox.homeDir.path;
        await ipc.start();
        expect(ipc.running, isTrue);

        final info =
            jsonDecode(File(ipc.ipcInfoPath).readAsStringSync()) as Map;
        final port = info['port'] as int;
        final token = info['token'] as String;
        final baseUri = Uri.parse('http://127.0.0.1:$port');

        final noAuth = await McpHttpProbe(
          baseUri.replace(path: '/tasks'),
        ).requestMethod('GET', omitAuth: true);
        expect(noAuth.statusCode, 401);

        final badAuth = await McpHttpProbe(
          baseUri.replace(path: '/tasks'),
          bearerToken: 'wrong-token',
        ).requestMethod('GET');
        expect(badAuth.statusCode, 401);

        final emptyPrompt = await McpHttpProbe(
          baseUri.replace(path: '/tasks'),
          bearerToken: token,
        ).postJsonRpc({'title': 'T', 'prompt': '', 'cwd': sandbox.projectDir.path});
        expect(emptyPrompt.statusCode, 400);

        final badCwd = await McpHttpProbe(
          baseUri.replace(path: '/tasks'),
          bearerToken: token,
        ).postJsonRpc({
          'title': 'T',
          'prompt': 'Do work',
          'cwd': p.join(sandbox.rootDir.path, 'missing_repo_dir'),
        });
        expect(badCwd.statusCode, 400);
        expect(TaskQueueService.instance.tasks, isEmpty);
      },
    );

    test(
      'F10-T2-03: AutomationService.addRule & create_automation reject invalid cron and nonexistent cwd',
      () async {
        final svc = AutomationService.instance;
        svc.registerTools();
        final beforeCount = svc.rules.length;

        expect(
          () => svc.addRule(
            name: 'Bad Cron',
            prompt: 'hi',
            cwd: sandbox.projectDir.path,
            cronExpression: 'not a cron',
          ),
          throwsArgumentError,
        );
        expect(
          () => svc.addRule(
            name: 'Empty Cwd',
            prompt: 'hi',
            cwd: '',
            cronExpression: '0 9 * * *',
          ),
          throwsArgumentError,
        );
        expect(
          () => svc.addRule(
            name: 'Missing Cwd',
            prompt: 'hi',
            cwd: p.join(sandbox.rootDir.path, 'no_such_dir_e2e'),
            cronExpression: '0 9 * * *',
          ),
          throwsArgumentError,
        );

        final toolRes = await ClaudeSdkTools.handle(
          {
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'tools/call',
            'params': {
              'name': 'create_automation',
              'arguments': {
                'name': 'Bad Tool Cwd',
                'prompt': 'hi',
                'cron': '0 9 * * *',
                'cwd': p.join(sandbox.rootDir.path, 'no_such_dir_e2e'),
              },
            },
          },
          ClaudeSdkCall(cwd: sandbox.projectDir.path),
        );
        final resMap = toolRes['result'] as Map<String, Object?>;
        expect(resMap['isError'], isTrue);
        expect(svc.rules.length, beforeCount);
      },
    );

    test(
      'F10-T2-04: AcpAgentService codex exec --json handles malformed JSON lines & surfaces error events',
      () async {
        final fakeBin = Directory(p.join(sandbox.rootDir.path, 'codex_err_bin'));
        FakeCliExecutable.create(
          fakeBin,
          name: 'codex',
          dartBody: _fakeCodexExecJsonBody,
        );
        sandbox.useClaudeEnvironment({
          ..._envWithIsolatedPath(sandbox.processEnv, fakeBin.path),
          'FAKE_CODEX_EXEC_MODE': 'error_json',
        });

        final res = await AcpAgentService.instance.runHeadlessPrompt(
          agentId: 'codex',
          prompt: 'Trigger error',
          cwd: sandbox.projectDir.path,
        );
        expect(res.ok, isFalse);
        expect('${res.error}\n${res.output}', contains('Rate limit hit'));
      },
    );

    test(
      'F10-T2-05: TaskQueueService.cancelTask kills fake CLI process tree & discardTask cleans worktree and blobs',
      () async {
        final repoDir = await initTempGitRepo(sandbox.rootDir);
        final fakeBin = Directory(p.join(sandbox.rootDir.path, 'cancel_bin'));
        final fakeCodex = FakeCliExecutable.create(
          fakeBin,
          name: 'codex',
          dartBody: _fakeCodexExecJsonBody,
        );
        sandbox.useClaudeEnvironment({
          ..._envWithIsolatedPath(sandbox.processEnv, fakeBin.path),
          'FAKE_CODEX_EXEC_MODE': 'sleep',
        });

        final svc = TaskQueueService.instance;
        final task = svc.enqueue(
          title: 'Cancel sleep task',
          prompt: 'Sleep',
          repoPath: repoDir.path,
          agentId: 'codex',
          useWorktree: true,
        );

        final pidDir = Directory(fakeCodex.pidDirPath);
        Set<int> readRecordedPids() {
          final pids = <int>{};
          if (!pidDir.existsSync()) return pids;
          for (final entity in pidDir.listSync().whereType<File>()) {
            if (!entity.path.endsWith('.pid')) continue;
            for (final line in entity.readAsLinesSync()) {
              final parsed = int.tryParse(line.trim());
              if (parsed != null && parsed > 0) pids.add(parsed);
            }
          }
          return pids;
        }

        final runFuture = svc.runTask(task.id);
        await waitUntil(
          () =>
              fakeCodex.firstLaunchCapture() != null &&
              readRecordedPids().isNotEmpty,
          reason: 'Fake codex child and .pid marker should start',
        );
        final recordedPids = readRecordedPids();

        await svc.cancelTask(task.id);
        await runFuture;
        expect(task.status, WorktreeTaskStatus.cancelled);

        // Verify via OS process check BEFORE discardTask or terminateProcesses()
        // that cancelTask already killed the entire child process tree.
        final pidsToCheck = {...recordedPids, ...readRecordedPids()};
        expect(pidsToCheck, isNotEmpty);
        for (final pid in pidsToCheck) {
          if (Platform.isWindows) {
            final res = await Process.run(
              'tasklist',
              ['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV'],
            );
            expect(
              RegExp('"$pid"').hasMatch('${res.stdout}'),
              isFalse,
              reason: 'PID $pid should already be dead after cancelTask',
            );
          } else {
            final res = await Process.run('kill', ['-0', '$pid']);
            expect(
              res.exitCode,
              isNot(0),
              reason: 'PID $pid should already be dead after cancelTask',
            );
          }
        }

        final worktreePath = task.worktreePath;
        final logPath = svc.logFilePathFor(task.id);
        final diffPath = svc.diffFilePathFor(task.id);

        await svc.discardTask(task.id);
        await fakeCodex.terminateProcesses();
        expect(Directory(worktreePath).existsSync(), isFalse);
        expect(File(logPath).existsSync(), isFalse);
        expect(File(diffPath).existsSync(), isFalse);
        expect(svc.byId(task.id), isNull);
      },
    );

    test(
      'F10-T2-06: TaskQueueService crash recovery resets running->queued & merge conflict aborts cleanly',
      () async {
        final tasksPath = p.join(sandbox.dataDir.path, 'tasks.json');
        File(tasksPath)
          ..createSync(recursive: true)
          ..writeAsStringSync(
            jsonEncode({
              'maxConcurrency': 2,
              'autoDispatch': false,
              'tasks': [
                {
                  'id': 'crashed-1',
                  'title': 'Was running',
                  'prompt': 'Resume me',
                  'repoPath': sandbox.projectDir.path,
                  'status': 'running',
                  'createdAt': '2026-11-22T10:00:00Z',
                },
              ],
            }),
          );

        final svc = TaskQueueService.instance..resetForTest();
        await svc.load();
        final recovered = svc.byId('crashed-1');
        expect(recovered, isNotNull);
        expect(recovered!.status, WorktreeTaskStatus.queued);

        // Merge conflict rollback test
        final repoDir = await initTempGitRepo(sandbox.rootDir);
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
          File(p.join(cwd, 'README.md')).writeAsStringSync('# Worktree version\n');
          return (ok: true, output: 'edited', error: null);
        };

        final conflictTask = svc.enqueue(
          title: 'Conflict task',
          prompt: 'Edit README',
          repoPath: repoDir.path,
          useWorktree: true,
        );
        await svc.runTask(conflictTask.id);
        expect(conflictTask.status, WorktreeTaskStatus.review);

        // Create conflicting commit on main repo branch.
        File(p.join(repoDir.path, 'README.md')).writeAsStringSync('# Main version\n');
        await Process.run('git', ['add', 'README.md'], workingDirectory: repoDir.path);
        await Process.run(
          'git',
          ['commit', '-m', 'Main conflicting change'],
          workingDirectory: repoDir.path,
        );

        final res = await svc.approveAndMerge(conflictTask.id);
        expect(res.ok, isFalse);
        expect(Directory(conflictTask.worktreePath).existsSync(), isTrue);

        final mergeHead = await Process.run(
          'git',
          ['rev-parse', '-q', '--verify', 'MERGE_HEAD'],
          workingDirectory: repoDir.path,
        );
        expect(mergeHead.exitCode, isNot(0));

        await svc.discardTask(conflictTask.id);
      },
    );
  });
}
