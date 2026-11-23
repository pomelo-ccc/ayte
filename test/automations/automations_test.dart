import 'dart:convert';
import 'dart:io';

import 'package:baocode/acp/acp_agent_service.dart';
import 'package:baocode/automations/automation_service.dart';
import 'package:baocode/automations/automations_view.dart';
import 'package:baocode/canvas/canvas_controller.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/tasks/task_queue_service.dart';
import 'package:baocode/theme/codicons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late Directory repoDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ayte-auto-test-');
    repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync();
    TaskQueueService.instance
      ..resetForTest()
      ..storagePathOverride = p.join(tempDir.path, 'tasks.json');
    AutomationService.instance.storagePathOverride = p.join(
      tempDir.path,
      'automations.json',
    );
    for (final r in [...AutomationService.instance.rules]) {
      AutomationService.instance.deleteRule(r.id);
    }
    AcpAgentService.instance.headlessRunnerOverride = null;
  });

  tearDown(() async {
    AcpAgentService.instance.headlessRunnerOverride = null;
    for (final r in [...AutomationService.instance.rules]) {
      AutomationService.instance.deleteRule(r.id);
    }
    await AutomationService.instance.flushForTest();
    AutomationService.instance.storagePathOverride = null;
    await TaskQueueService.instance.flushForTest();
    TaskQueueService.instance
      ..resetForTest()
      ..storagePathOverride = null;
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('AutomationRule & AutomationService parity', () {
    test('AutomationRule supports legacy JSON, new fields round-trip, and copyWith', () {
      final legacy = AutomationRule.fromJson({
        'id': 'a-legacy',
        'name': 'Legacy',
        'prompt': 'Check',
        'cwd': repoDir.path,
        'cronExpression': '0 9 * * *',
      });
      expect(legacy, isNotNull);
      expect(legacy!.model, isNull);
      expect(legacy.effort, isNull);
      expect(legacy.workflowTemplateId, isNull);

      final updated = legacy.copyWith(
        model: 'gpt-5.4',
        effort: 'high',
        workflowTemplateId: 'wf-1',
      );
      final json = updated.toJson();
      expect(json['model'], 'gpt-5.4');
      expect(json['effort'], 'high');
      expect(json['workflowTemplateId'], 'wf-1');

      final cleared = updated.copyWith(
        clearModel: true,
        clearEffort: true,
        clearWorkflowTemplateId: true,
      );
      expect(cleared.model, isNull);
      expect(cleared.effort, isNull);
      expect(cleared.workflowTemplateId, isNull);
    });

    test('addRule and updateRule validate cwd and cronExpression', () {
      final svc = AutomationService.instance;
      expect(
        () => svc.addRule(
          name: 'Empty cwd',
          prompt: 'hi',
          cwd: '   ',
          cronExpression: '0 9 * * *',
        ),
        throwsArgumentError,
      );
      expect(
        () => svc.addRule(
          name: 'Missing cwd',
          prompt: 'hi',
          cwd: p.join(tempDir.path, 'nope'),
          cronExpression: '0 9 * * *',
        ),
        throwsArgumentError,
      );
      expect(
        () => svc.addRule(
          name: 'Bad cron',
          prompt: 'hi',
          cwd: repoDir.path,
          cronExpression: 'bad',
        ),
        throwsArgumentError,
      );

      final rule = svc.addRule(
        name: 'Valid',
        prompt: 'Run check',
        cwd: repoDir.path,
        cronExpression: '0 9 * * 1-5',
        agentId: 'codex',
        model: 'gpt-5.4',
        effort: 'high',
      );
      expect(rule.model, 'gpt-5.4');
      expect(rule.effort, 'high');

      expect(
        () => svc.updateRule(rule.id, cwd: p.join(tempDir.path, 'missing')),
        throwsArgumentError,
      );
      expect(
        () => svc.updateRule(rule.id, cronExpression: '* *'),
        throwsArgumentError,
      );

      final ok = svc.updateRule(
        rule.id,
        name: 'Updated Valid',
        model: 'gpt-5.4-mini',
        clearEffort: true,
      );
      expect(ok, isTrue);
      expect(rule.name, 'Updated Valid');
      expect(rule.model, 'gpt-5.4-mini');
      expect(rule.effort, isNull);
    });

    test('addRule generates strictly distinct IDs across 20 rapid synchronous calls', () {
      final svc = AutomationService.instance;
      final ids = <String>{};
      for (var i = 0; i < 20; i++) {
        final r = svc.addRule(
          name: 'Rapid-$i',
          prompt: 'Prompt $i',
          cwd: repoDir.path,
          cronExpression: '0 9 * * *',
        );
        expect(ids.add(r.id), isTrue, reason: 'Duplicate ID generated: ${r.id}');
      }
      expect(ids, hasLength(20));
      expect(svc.rules, hasLength(20));
    });

    test('runNow forwards model/effort/workflowTemplateId to worktree queue, workflow, and headless', () async {
      final svc = AutomationService.instance;
      String? seenAgent;
      String? seenModel;
      String? seenEffort;
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
        seenAgent = agentId;
        seenModel = model;
        seenEffort = effort;
        return (ok: true, output: 'Headless OK', error: null);
      };

      // 1) Headless prompt path
      final headlessRule = svc.addRule(
        name: 'Headless',
        prompt: 'Check code',
        cwd: repoDir.path,
        cronExpression: '0 9 * * *',
        agentId: 'codex',
        model: 'gpt-5.4',
        effort: 'medium',
      );
      await svc.runNow(headlessRule.id);
      expect(seenAgent, 'codex');
      expect(seenModel, 'gpt-5.4');
      expect(seenEffort, 'medium');
      expect(headlessRule.history.first.ok, isTrue);

      // 2) Worktree queue path
      final wtRule = svc.addRule(
        name: 'Worktree',
        prompt: 'Fix tests',
        cwd: repoDir.path,
        cronExpression: '0 10 * * *',
        agentId: 'claude',
        model: 'opus',
        effort: 'max',
        workflowTemplateId: 'wf-auto',
        useWorktree: true,
      );
      await svc.runNow(wtRule.id);
      expect(TaskQueueService.instance.tasks, hasLength(1));
      final task = TaskQueueService.instance.tasks.single;
      expect(task.model, 'opus');
      expect(task.effort, 'max');
      expect(task.workflowTemplateId, 'wf-auto');
      await TaskQueueService.instance.discardTask(task.id);

      // 3) Workflow template path (non-worktree)
      final wfRule = svc.addRule(
        name: 'Workflow',
        prompt: 'Run workflow',
        cwd: repoDir.path,
        cronExpression: '0 11 * * *',
        workflowTemplateId: 'missing-wf-id',
        useWorktree: false,
      );
      await svc.runNow(wfRule.id);
      expect(wfRule.history, isNotEmpty);
      expect(wfRule.history.first.ok, isFalse);
      expect(wfRule.history.first.summary, contains('missing-wf-id'));
    });

    test('create_automation MCP tool supports agent/agentId/model/effort/workflowTemplateId & validates cwd', () async {
      final svc = AutomationService.instance;
      svc.registerTools();

      final badRes = await ClaudeSdkTools.handle(
        {
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {
            'name': 'create_automation',
            'arguments': {
              'name': 'Bad',
              'prompt': 'hi',
              'cron': '0 9 * * *',
              'cwd': p.join(tempDir.path, 'does-not-exist'),
            },
          },
        },
        ClaudeSdkCall(cwd: repoDir.path),
      );
      expect((badRes['result'] as Map)['isError'], isTrue);

      final goodRes = await ClaudeSdkTools.handle(
        {
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'tools/call',
          'params': {
            'name': 'create_automation',
            'arguments': {
              'name': 'McpRule',
              'prompt': 'Audit repo',
              'cron': '0 8 * * 1-5',
              'cwd': repoDir.path,
              'agent': 'claude',
              'model': 'sonnet',
              'effort': 'high',
            },
          },
        },
        ClaudeSdkCall(cwd: repoDir.path),
      );
      final map = goodRes['result'] as Map;
      expect(map['isError'], isNot(true));
      final createdJson =
          jsonDecode(((map['content'] as List).single as Map)['text'] as String)
              as Map;
      expect(createdJson['agentId'], 'claude');
      expect(createdJson['model'], 'sonnet');
      expect(createdJson['effort'], 'high');
    });
  });

  group('AutomationsView widget', () {
    testWidgets('validates cwd, picks directory, selects workflow/model/effort, creates & edits rule', (tester) async {
      AutomationService.instance.storagePathOverride = null;
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      AutomationRule? handedOff;

      // 1. Empty cwd validation
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
              width: 960,
              height: 700,
              child: AutomationsView(
                onPickDirectory: () async => repoDir.path,
                onHandOff: (r) async => handedOff = r,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Missing Cwd');
      await tester.enterText(fields.at(2), 'Run something');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(AutomationService.instance.rules, isEmpty);
      expect(
        find.text('Please select a working directory (cwd) first'),
        findsOneWidget,
      );

      // 2. Pick directory via Browse button
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();

      // Select a model with efforts
      final modelOpt = AcpAgentService.instance
          .modelsForAgent('agy')
          .firstWhere((m) => m.effortLevels.isNotEmpty);
      final modelDd = find.byWidgetPredicate(
        (w) =>
            w is DropdownButton<String> &&
            (w.items ?? const []).any((i) => i.value == modelOpt.id),
      );
      await tester.tap(modelDd);
      await tester.pumpAndSettle();
      await tester.tap(find.text(modelOpt.label).last);
      await tester.pumpAndSettle();

      // Verify workflow choices exist
      final wfIds = CanvasController.instance.runnableWorkflowChoices
          .map((w) => w.id)
          .toSet();
      expect(
        tester
            .widgetList<DropdownButton<String>>(
              find.byType(DropdownButton<String>),
            )
            .any((d) => (d.items ?? const []).any((i) => wfIds.contains(i.value))),
        isTrue,
      );

      // Create rule
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(AutomationService.instance.rules, hasLength(1));
      final rule = AutomationService.instance.rules.single;
      expect(rule.cwd, repoDir.path);
      expect(rule.model, modelOpt.id);

      // Hand Off button works
      await tester.tap(find.text('Hand Off'));
      await tester.pumpAndSettle();
      expect(handedOff?.id, rule.id);

      // Edit dialog updates rule
      await tester.tap(find.byIcon(Codicons.edit));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      final dialogFields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(dialogFields.at(0), 'Edited Rule');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(AutomationService.instance.rules.single.name, 'Edited Rule');
    });
  });
}
