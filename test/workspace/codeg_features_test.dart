import 'dart:io';

import 'package:baocode/acp/acp_agent_service.dart';
import 'package:baocode/automations/cron_parser.dart';
import 'package:baocode/canvas/canvas_controller.dart';
import 'package:baocode/canvas/workflow_celebration_overlay.dart';
import 'package:baocode/chat/widgets/spec_render_block.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_account_models.dart';
import 'package:baocode/kernel/codex/codex_models.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/library/document_preview_service.dart';
import 'package:baocode/sidebar/sidebar_nav_config.dart';
import 'package:baocode/tags/tag_store.dart';
import 'package:baocode/tasks/task_queue_service.dart';
import 'package:baocode/workspace/workspace_hub_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('#1 UI Render (SpecDocument & SpecRenderBlock)', () {
    test('parses RFC 6902 JSONL patch spec with state and repeat', () {
      const raw = '''
{"op":"add","path":"/root","value":"main"}
{"op":"add","path":"/elements/main","value":{"type":"Card","props":{"title":"Release Status"},"children":["list"]}}
{"op":"add","path":"/elements/list","value":{"type":"Stack","props":{"direction":"vertical"},"repeat":{"statePath":"/items","key":"id"},"children":["item"]}}
{"op":"add","path":"/elements/item","value":{"type":"Text","props":{"text":{"\$item":"title"}}}}
{"op":"add","path":"/state/items","value":[]}
{"op":"add","path":"/state/items/0","value":{"id":"1","title":"Build passed"}}
{"op":"add","path":"/state/items/1","value":{"id":"2","title":"Tests passed"}}
''';
      final doc = SpecDocument.parse(raw);
      expect(doc, isNotNull);
      expect(doc!.rootId, 'main');
      expect(doc.elements.keys, containsAll(['main', 'list', 'item']));
      final items = SpecDocument.readPointer(doc.state, '/items') as List;
      expect(items.length, 2);
    });

    testWidgets('renders interactive Card + repeated items', (tester) async {
      const raw = '''
{"op":"add","path":"/root","value":"main"}
{"op":"add","path":"/elements/main","value":{"type":"Card","props":{"title":"Metrics"},"children":["m1"]}}
{"op":"add","path":"/elements/m1","value":{"type":"Metric","props":{"label":"Pass Rate","value":"100%"}}}
''';
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SpecRenderBlock(code: raw))),
      );
      expect(find.text('Metrics'), findsOneWidget);
      expect(find.text('Pass Rate'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
    });
  });

  group('#2 & #3 CronSchedule & TaskQueue', () {
    test('parses 5-field cron and computes next run accurately', () {
      final sched = CronSchedule.tryParse('30 9 * * 1-5');
      expect(sched, isNotNull);
      // 2026-11-21 is Saturday -> next weekday 09:30 is Monday 2026-11-23 09:30.
      final next = sched!.nextAfter(DateTime(2026, 11, 21, 10, 0));
      expect(next, DateTime(2026, 11, 23, 9, 30));
      expect(CronSchedule.tryParse('invalid cron'), isNull);
    });

    test('enqueues tasks and supports concurrency bounds', () async {
      final dir = await Directory.systemTemp.createTemp('ayte-tasks-test');
      addTearDown(() => dir.delete(recursive: true));
      final svc = TaskQueueService.instance
        ..storagePathOverride = p.join(dir.path, 'tasks.json');
      svc.setMaxConcurrency(3);
      expect(svc.maxConcurrency, 3);
      final t = svc.enqueue(
        title: 'Refactor parser',
        prompt: 'Clean up parser helpers',
        repoPath: dir.path,
      );
      expect(t.status, WorktreeTaskStatus.queued);
      await svc.discardTask(t.id);
      svc.storagePathOverride = null;
    });
  });

  group('#4 Library document kind detection', () {
    test('classifies PDF and Office documents properly', () {
      expect(LibraryDocKind.fromPath('/a/report.pdf'), LibraryDocKind.pdf);
      expect(LibraryDocKind.fromPath('/a/spec.docx'), LibraryDocKind.word);
      expect(LibraryDocKind.fromPath('/a/budget.xlsx'), LibraryDocKind.excel);
      expect(
        LibraryDocKind.fromPath('/a/slides.pptx'),
        LibraryDocKind.powerpoint,
      );
      expect(LibraryDocKind.fromPath('/a/spec.docx').isOfficeOrPdf, isTrue);
    });
  });

  group('#5 Grouped Tags', () {
    test('creates tag groups, adds tags, moves tags, and filters', () async {
      final dir = await Directory.systemTemp.createTemp('ayte-tags-test');
      addTearDown(() => dir.delete(recursive: true));
      final store = TagStore.instance
        ..storagePathOverride = p.join(dir.path, 'tags.json');
      final grp = store.addGroup('客户项目', colorValue: 0xFF39C5CF);
      final tag = store.addTag(name: 'PLM', groupId: grp.id);
      expect(store.tagsInGroup(grp.id).any((t) => t.id == tag.id), isTrue);

      store.toggleTagForKey('session-1', tag.id);
      expect(store.tagsOfKey('session-1').map((t) => t.id), contains(tag.id));

      store.deleteGroup(grp.id);
      // Tag is preserved in fallback group rather than silently lost.
      expect(store.tagById(tag.id), isNotNull);
      store.deleteTag(tag.id);
      store.storagePathOverride = null;
    });
  });

  group('#7 Executable Workflow Canvas (DAG)', () {
    test('adds, moves, resizes, connects, and removes nodes & edges', () async {
      final dir = await Directory.systemTemp.createTemp('ayte-canvas-test');
      addTearDown(() => dir.delete(recursive: true));
      final ctrl = CanvasController.instance
        ..storagePathOverride = p.join(dir.path, 'canvas.json');
      ctrl.clearBoard();
      final n = ctrl.addNode(
        kind: CanvasNodeKind.note,
        title: 'Design',
        content: 'Overview',
        x: 100,
        y: 120,
      );
      ctrl.moveNode(n.id, 40, -20);
      ctrl.resizeNode(n.id, 50, 30);
      expect(n.x, 140);
      expect(n.y, 100);
      expect(n.width, 330);
      ctrl.removeNode(n.id);
      ctrl.storagePathOverride = null;
    });

    test(
      'executes DAG with variable interpolation, condition pass/fail branches, and human approval gate',
      () async {
        final dir = await Directory.systemTemp.createTemp('ayte-dag-test');
        addTearDown(() => dir.delete(recursive: true));
        final ctrl = CanvasController.instance
          ..storagePathOverride = p.join(dir.path, 'canvas.json');
        ctrl.clearBoard();

        final t = ctrl.addNode(
          kind: CanvasNodeKind.trigger,
          title: 'Trigger',
          content: 'bugId=BUG-777',
        );
        final cmd = ctrl.addNode(
          kind: CanvasNodeKind.command,
          title: 'Build',
          content: 'echo "BUILD_PASS {{input.bugId}}"',
        );
        final cond = ctrl.addNode(
          kind: CanvasNodeKind.condition,
          title: 'Check',
          conditionExpr: 'contains:BUILD_PASS BUG-777',
        );
        final approve = ctrl.addNode(
          kind: CanvasNodeKind.approval,
          title: 'Human Gate',
          content: 'Confirm {{input.bugId}}',
        );
        final done = ctrl.addNode(
          kind: CanvasNodeKind.command,
          title: 'Close Bug',
          content: 'echo "CLOSED {{input.bugId}} NOTE={{approval.note}}"',
        );
        final failBranch = ctrl.addNode(
          kind: CanvasNodeKind.command,
          title: 'On Fail',
          content: 'echo "FAILED"',
        );

        ctrl.connect(t.id, cmd.id, branch: CanvasEdgeBranch.onPass);
        ctrl.connect(cmd.id, cond.id, branch: CanvasEdgeBranch.onPass);
        ctrl.connect(cond.id, approve.id, branch: CanvasEdgeBranch.onPass);
        ctrl.connect(cond.id, failBranch.id, branch: CanvasEdgeBranch.onFail);
        ctrl.connect(approve.id, done.id, branch: CanvasEdgeBranch.onPass);

        final runFuture = ctrl.runWorkflow(defaultCwd: dir.path);
        // Wait until the workflow pauses at the Human Approval gate.
        for (var i = 0; i < 40 && ctrl.activeApprovalNodeId == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(ctrl.activeApprovalNodeId, approve.id);
        expect(
          ctrl.displayNodeById(approve.id)?.runStatus,
          CanvasNodeRunStatus.waitingApproval,
        );
        // Editor canvas node stays isolated from the running snapshot.
        expect(approve.runStatus, CanvasNodeRunStatus.idle);
        ctrl.approveNode(approve.id, note: '前端改pdm');

        final res = await runFuture;
        expect(res.ok, isTrue);
        final run = ctrl.runById(res.runId!);
        expect(run, isNotNull);
        expect(
          run!.nodeById(done.id)?.runStatus,
          CanvasNodeRunStatus.succeeded,
        );
        expect(
          run.nodeById(done.id)?.output,
          contains('CLOSED BUG-777 NOTE=前端改pdm'),
        );
        expect(
          run.nodeById(failBranch.id)?.runStatus,
          CanvasNodeRunStatus.skipped,
        );

        ctrl.clearAllRunsForTest();
        ctrl.clearBoard();
        ctrl.storagePathOverride = null;
      },
    );

    test('provides 4 built-in engineering workflows and auto-layouts cleanly', () {
      final ctrl = CanvasController.instance;
      final builtins = CanvasController.builtInTemplates();
      expect(builtins.length, 4);
      expect(
        builtins.map((t) => t.id).toList(),
        equals([
          CanvasController.plmLocalRebuildTemplateId,
          CanvasController.refreshModelTemplateId,
          CanvasController.deploy69TemplateId,
          CanvasController.bugVerifyTemplateId,
        ]),
      );

      ctrl.loadBuiltInTemplate(CanvasController.plmLocalRebuildTemplateId);
      expect(ctrl.nodeById('plm_build_lc')?.content, contains('ng-lc-dpp-lib'));
      expect(ctrl.nodeById('plm_tmux_restart')?.content, contains('4201'));

      ctrl.loadBuiltInTemplate(CanvasController.refreshModelTemplateId);
      expect(ctrl.nodes.length, 6);
      expect(
        ctrl.nodeById('rm_trigger')?.content,
        contains('apiUrl=http://172.16.100.69'),
      );
      expect(ctrl.nodeById('rm_scan_gbk')?.content, contains('iconv -f GBK'));
      expect(
        ctrl.nodeById('rm_upload_csv')?.content,
        contains('/api/internal/base/admin/model/'),
      );
      expect(
        ctrl.nodeById('rm_refresh_cache')?.content,
        contains('/api/internal/base/admin/model/refresh'),
      );
      expect(
        ctrl.edges.any(
          (e) =>
              e.fromId == 'rm_refresh_cache' &&
              e.toId == 'rm_fail_diag' &&
              e.branch == CanvasEdgeBranch.onFail,
        ),
        isTrue,
      );

      ctrl.loadBuiltInTemplate(CanvasController.deploy69TemplateId);
      expect(
        ctrl.nodeById('d69_trigger')?.content,
        contains('172.16.100.122:4875'),
      );
      expect(
        ctrl.nodeById('d69_trigger')?.content,
        contains('172.16.100.122:4873'),
      );
      expect(ctrl.nodeById('d69_trigger')?.content, contains('69-sts'));
      expect(ctrl.nodeById('d69_git_push'), isNotNull);
      expect(ctrl.nodeById('d69_build_lc')?.kind, CanvasNodeKind.command);
      expect(ctrl.nodeById('d69_build_lc')?.content, contains('tabbit-cli'));
      expect(ctrl.nodeById('d69_build_lc')?.content, contains('crumbIssuer'));
      expect(ctrl.nodeById('d69_build_bc')?.kind, CanvasNodeKind.command);
      expect(
        ctrl.nodeById('d69_build_bc')?.content,
        contains('BUILD_LC_FIRST=false'),
      );
      expect(ctrl.nodeById('d69_jenkins_run')?.kind, CanvasNodeKind.command);
      expect(
        ctrl.nodeById('d69_jenkins_run')?.content,
        contains('DUPLICATE_DEPLOY_CHECK=false'),
      );
      expect(
        ctrl.edges.any(
          (e) => e.fromId == 'd69_build_lc' && e.toId == 'd69_build_bc',
        ),
        isTrue,
      );
      expect(
        ctrl.edges.any(
          (e) => e.fromId == 'd69_build_bc' && e.toId == 'd69_jenkins_run',
        ),
        isTrue,
      );

      ctrl.loadBuiltInTemplate(CanvasController.bugVerifyTemplateId);
      expect(ctrl.nodes.length, 13);
      expect(ctrl.nodeById('step_trigger')?.content, contains('filterStatus='));
      expect(ctrl.nodeById('step_trigger')?.content, contains('evidenceDir='));
      expect(ctrl.nodeById('step_mark_pr'), isNotNull);
      expect(
        ctrl.nodes.where((n) => n.kind == CanvasNodeKind.approval).length,
        3,
      );
      expect(
        ctrl.edges.any((e) => e.branch == CanvasEdgeBranch.onFail),
        isTrue,
      );
      ctrl.autoLayout();
      final trigger = ctrl.nodeById('step_trigger')!;
      final triage = ctrl.nodeById('step_triage')!;
      final rejectNode = ctrl.nodeById('step_reject_reply')!;
      expect(triage.x, greaterThan(trigger.x));
      expect(rejectNode.y, greaterThan(triage.y));

      final appended = ctrl.addConnectedNode(
        fromId: triage.id,
        branch: CanvasEdgeBranch.onPass,
        kind: CanvasNodeKind.command,
        title: 'Extra Step',
      );
      expect(appended, isNotNull);
      expect(
        ctrl.edges.any((e) => e.fromId == triage.id && e.toId == appended!.id),
        isTrue,
      );

      final dup = ctrl.duplicateNode(triage.id);
      expect(dup, isNotNull);
      expect(dup!.title, contains('副本'));
      ctrl.clearBoard();
    });
  });

  group('#8 Direct 4 Native Kernels & CodeBuddy Accounts', () {
    test('registers all 4 native kernels without ACP', () {
      final descriptors = [
        KernelRegistry.antigravity,
        KernelRegistry.codebuddy,
        KernelRegistry.claudeCode,
        KernelRegistry.codex,
      ];
      expect(
        descriptors.map((k) => k.id).toList(),
        equals(['antigravity-cli', 'codebuddy-cli', 'claude-code', 'codex']),
      );
      expect(
        descriptors.map((k) => k.label).toList(),
        equals(['Antigravity', 'CodeBuddy', 'Claude Code', 'Codex']),
      );
      final headlessIds = AcpAgentService.instance.selectableAgents
          .map((a) => a.id)
          .toList();
      expect(headlessIds, equals(['agy', 'codebuddy', 'claude', 'codex']));
    });

    test('exposes 4 left-sidebar workspace pages and manages nav add/remove/reorder', () {
      expect(WorkspacePage.values.length, 4);
      expect(WorkspacePage.tasks.label(true), '任务队列');
      expect(WorkspacePage.automations.label(true), '自动化');
      expect(WorkspacePage.library.label(true), '资料库');
      expect(WorkspacePage.canvas.label(true), '画布');

      final cfg = SidebarNavConfig.instance..resetDefaults();
      expect(cfg.visibleItems.length, 4);
      expect(cfg.hiddenItems, contains(SidebarNavItem.automations));
      expect(cfg.hiddenItems, contains(SidebarNavItem.library));

      cfg.showItem(SidebarNavItem.library);
      expect(cfg.isVisible(SidebarNavItem.library), isTrue);

      cfg.moveUp(SidebarNavItem.library);
      expect(cfg.visibleItems[3], SidebarNavItem.library);

      cfg.hideItem(SidebarNavItem.stash);
      expect(cfg.isVisible(SidebarNavItem.stash), isFalse);
      expect(cfg.hiddenItems, contains(SidebarNavItem.stash));

      cfg.resetDefaults();
      expect(cfg.visibleItems, SidebarNavConfig.defaultVisible);
    });

    test('formats CodeBuddy balance credits accurately', () {
      expect(formatBalanceCredits(5897.6), '5,897.6');
      expect(formatBalanceCredits(0), '0');
    });

    test('parses Codex local catalog and RPC model/list responses', () {
      final local = CodexModels.parseCatalogJson(
        '{"models":[{"slug":"gpt-5.6-luna","display_name":"gpt-5.6-luna","visibility":"list","default_reasoning_level":"max","supported_reasoning_levels":[{"effort":"low"},{"effort":"max"}]},{"slug":"hidden-one","display_name":"Hidden","visibility":"hide"}]}',
        configuredModel: 'gpt-5.6-luna',
      );
      expect(local.length, 1);
      expect(local.first.id, 'gpt-5.6-luna');
      expect(local.first.isDefault, isTrue);
      expect(local.first.effortLevels, ['low', 'max']);

      final rpc = CodexModels.parseRpcModelList({
        'data': [
          {
            'id': 'gpt-6.2-sol',
            'displayName': 'GPT-6.2-Sol',
            'isDefault': true,
            'defaultReasoningEffort': 'high',
            'supportedReasoningEfforts': [
              {'reasoningEffort': 'low'},
              {'reasoningEffort': 'high'},
              {'reasoningEffort': 'ultra'},
            ],
          },
          {'id': 'secret', 'hidden': true},
        ],
      });
      expect(rpc.length, 1);
      expect(rpc.first.id, 'gpt-6.2-sol');
      expect(rpc.first.label, 'GPT-6.2-Sol');
      expect(rpc.first.effortLevels, ['low', 'high', 'ultra']);
    });

    test('supports workflow default model inheritance and per-node CLI flags', () {
      final ctrl = CanvasController.instance;
      ctrl.clearBoard();
      ctrl.setWorkflowDefaults(
        agentId: 'codex',
        model: 'gpt-5.4',
        effort: 'high',
      );
      final inherited = ctrl.addNode(
        kind: CanvasNodeKind.agent,
        title: '研判节点',
        content: 'hello',
      );
      final overridden = ctrl.addNode(
        kind: CanvasNodeKind.agent,
        title: '修代码节点',
        content: 'fix',
        agentId: 'claude',
        model: 'opus',
        effort: 'max',
      );

      final cfg1 = ctrl.effectiveAgentConfig(inherited);
      expect(cfg1.agentId, 'codex');
      expect(cfg1.model, 'gpt-5.4');
      expect(cfg1.effort, 'high');
      expect(cfg1.inheritedAgent, isTrue);
      expect(cfg1.inheritedModel, isTrue);

      final cfg2 = ctrl.effectiveAgentConfig(overridden);
      expect(cfg2.agentId, 'claude');
      expect(cfg2.model, 'opus');
      expect(cfg2.effort, 'max');
      expect(cfg2.inheritedAgent, isFalse);

      // Verify exact CLI flag positions across all 4 native kernels.
      final agyArgs = AcpAgentService.buildCliArgs(
        agentId: 'agy',
        prompt: 'test',
        model: 'gemini-4-neon',
        effort: 'high',
      );
      expect(agyArgs.indexOf('--model'), lessThan(agyArgs.indexOf('-p')));
      expect(agyArgs.last, 'test');

      final codexArgs = AcpAgentService.buildCliArgs(
        agentId: 'codex',
        prompt: 'test',
        model: 'gpt-5.4',
        effort: 'xhigh',
      );
      expect(codexArgs, containsAllInOrder(['exec', '--full-auto', '-m', 'gpt-5.4']));
      expect(codexArgs, contains('model_reasoning_effort=xhigh'));
      expect(codexArgs.last, 'test');

      final claudeArgs = AcpAgentService.buildCliArgs(
        agentId: 'claude',
        prompt: 'test',
        model: 'opus',
        effort: 'max',
      );
      expect(claudeArgs, containsAllInOrder(['--model', 'opus', '--effort', 'max', '-p', 'test']));

      ctrl.applyWorkflowDefaultsToAllAgents();
      expect(ctrl.effectiveAgentConfig(overridden).agentId, 'codex');
      expect(ctrl.effectiveAgentConfig(overridden).model, 'gpt-5.4');
      ctrl.clearBoard();
    });

    testWidgets(
      'emits WorkflowCompletionEvent and displays fireworks celebration overlay on workflow success',
      (tester) async {
        final ctrl = CanvasController.instance;
        ctrl.clearBoard();
        ctrl.dismissCompletionEvent();

        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh'), Locale('en')],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Scaffold(
              body: WorkflowCelebrationOverlay(
                controller: ctrl,
                child: const Center(child: Text('Workspace Content')),
              ),
            ),
          ),
        );

        expect(find.text('工作流执行完成！'), findsNothing);

        ctrl.addNode(
          kind: CanvasNodeKind.trigger,
          title: '1. 刷新模型',
          content: 'env=69',
        );
        ctrl.replayLastCelebration();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final ev = ctrl.lastCompletionEvent;
        expect(ev, isNotNull);
        expect(ev!.ok, isTrue);
        expect(ev.cancelled, isFalse);
        expect(ev.workflowName, '刷新模型');
        expect(find.text('工作流执行完成！'), findsOneWidget);
        expect(find.text('再放一次'), findsOneWidget);
        expect(find.byType(CustomPaint), findsWidgets);

        // Dismiss the banner cleanly.
        await tester.tap(find.byTooltip('关闭提示'));
        await tester.pumpAndSettle();
        expect(find.text('工作流执行完成！'), findsNothing);

        ctrl.clearBoard();
        ctrl.dismissCompletionEvent();
      },
    );

    test(
      'executes multiple workflows concurrently with isolated state, approval gates, and targeted stop',
      () async {
        final ctrl = CanvasController.instance;
        ctrl.clearAllRunsForTest();
        ctrl.clearBoard();
        ctrl.dismissCompletionEvent();

        // Build Workflow A: Trigger -> Approval Gate -> Shell Echo
        final aTrigger = CanvasNode(
          id: 'a_trig',
          kind: CanvasNodeKind.trigger,
          title: '触发 A',
          x: 0,
          y: 0,
          content: 'tag=ALPHA',
        );
        final aGate = CanvasNode(
          id: 'a_gate',
          kind: CanvasNodeKind.approval,
          title: '审批 A',
          x: 300,
          y: 0,
          content: 'Confirm {{input.tag}}',
        );
        final aCmd = CanvasNode(
          id: 'a_cmd',
          kind: CanvasNodeKind.command,
          title: '执行 A',
          x: 600,
          y: 0,
          content: 'echo "DONE_{{input.tag}}_{{approval.note}}"',
        );
        final aEdges = const [
          CanvasEdge(id: 'ae1', fromId: 'a_trig', toId: 'a_gate'),
          CanvasEdge(id: 'ae2', fromId: 'a_gate', toId: 'a_cmd'),
        ];

        // Build Workflow B: Trigger -> Approval Gate -> Shell Echo
        final bTrigger = CanvasNode(
          id: 'b_trig',
          kind: CanvasNodeKind.trigger,
          title: '触发 B',
          x: 0,
          y: 0,
          content: 'tag=BETA',
        );
        final bGate = CanvasNode(
          id: 'b_gate',
          kind: CanvasNodeKind.approval,
          title: '审批 B',
          x: 300,
          y: 0,
          content: 'Confirm {{input.tag}}',
        );
        final bCmd = CanvasNode(
          id: 'b_cmd',
          kind: CanvasNodeKind.command,
          title: '执行 B',
          x: 600,
          y: 0,
          content: 'echo "DONE_{{input.tag}}"',
        );
        final bEdges = const [
          CanvasEdge(id: 'be1', fromId: 'b_trig', toId: 'b_gate'),
          CanvasEdge(id: 'be2', fromId: 'b_gate', toId: 'b_cmd'),
        ];

        int? runAId;
        int? runBId;
        final futA = ctrl.runWorkflow(
          runName: '并发流 A',
          customNodes: [aTrigger, aGate, aCmd],
          customEdges: aEdges,
          onRunStarted: (id) => runAId = id,
        );
        final futB = ctrl.runWorkflow(
          runName: '并发流 B',
          customNodes: [bTrigger, bGate, bCmd],
          customEdges: bEdges,
          onRunStarted: (id) => runBId = id,
        );

        // Allow both workflows to advance to their approval gates concurrently.
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(runAId, isNotNull);
        expect(runBId, isNotNull);
        expect(runAId, isNot(equals(runBId)));
        expect(ctrl.activeRunCount, 2);
        expect(ctrl.pendingApprovalCount, 2);

        // Clearing editor board must NOT interrupt active background runs.
        ctrl.clearBoard();
        expect(ctrl.activeRunCount, 2);

        // Stop ONLY Workflow B while Workflow A keeps waiting undisturbed.
        ctrl.stopWorkflow(runId: runBId);
        final resB = await futB;
        expect(resB.ok, isFalse);
        expect(resB.runId, runBId);
        expect(ctrl.activeRunCount, 1);
        expect(ctrl.runById(runAId!)!.running, isTrue);

        // Now approve Workflow A with a note and verify it completes cleanly.
        ctrl.approveNode('a_gate', note: 'GO', runId: runAId);
        final resA = await futA;
        expect(resA.ok, isTrue);
        expect(resA.runId, runAId);
        expect(resA.log, contains('DONE_ALPHA_GO'));
        expect(ctrl.activeRunCount, 0);
        expect(ctrl.lastCompletionEvent?.ok, isTrue);
        expect(ctrl.lastCompletionEvent?.workflowRunId, runAId);

        ctrl.clearAllRunsForTest();
        ctrl.clearBoard();
        ctrl.dismissCompletionEvent();
      },
    );

    test(
      'supports breakpoint resume from failed node, run history persistence, and evidence extraction',
      () async {
        final dir = await Directory.systemTemp.createTemp('ayte-resume-test');
        addTearDown(() => dir.delete(recursive: true));
        final flagFile = p.join(dir.path, 'allow_step2.flag');
        final markerFile = p.join(dir.path, 'step1_count.txt');

        final ctrl = CanvasController.instance
          ..storagePathOverride = p.join(dir.path, 'canvas.json');
        ctrl.clearAllRunsForTest();
        ctrl.clearBoard();

        final t = ctrl.addNode(
          kind: CanvasNodeKind.trigger,
          title: '1. 参数',
          content: 'tag=R69\nevidenceDir=${dir.path}',
        );
        final s1 = ctrl.addNode(
          kind: CanvasNodeKind.command,
          title: '2. 上游初始化',
          content: 'echo "x" >> "$markerFile" && echo "UPSTREAM_OK_{{input.tag}}"',
        );
        final s2 = ctrl.addNode(
          kind: CanvasNodeKind.command,
          title: '3. 易失败节点',
          content:
              'test -f "$flagFile" && echo "RESUMED_OK prev={{prev.output}}" || (echo "NEED_FLAG"; exit 1)',
        );
        final s3 = ctrl.addNode(
          kind: CanvasNodeKind.command,
          title: '4. 下游收尾',
          content:
              'echo "FINAL_{{input.tag}} ev=${dir.path}/local-4200-after.png ${dir.path}/trace.md"',
        );
        ctrl.connect(t.id, s1.id);
        ctrl.connect(s1.id, s2.id);
        ctrl.connect(s2.id, s3.id);

        // First run fails at s2 (flag file missing).
        final res1 = await ctrl.runWorkflow(defaultCwd: dir.path);
        expect(res1.ok, isFalse);
        final run1 = ctrl.runById(res1.runId!)!;
        expect(run1.resumableNodeId, s2.id);
        expect(run1.nodeById(s1.id)?.runStatus, CanvasNodeRunStatus.succeeded);
        expect(run1.nodeById(s2.id)?.runStatus, CanvasNodeRunStatus.failed);
        expect(File(markerFile).readAsLinesSync().length, 1);

        // Fix condition & resume from s2 without re-running s1.
        File(flagFile).writeAsStringSync('ok');
        final res2 = await ctrl.resumeWorkflowFromNode(
          run1,
          s2.id,
          defaultCwd: dir.path,
        );
        expect(res2.ok, isTrue);
        final run2 = ctrl.runById(res2.runId!)!;
        // Upstream s1 must NOT have executed a second time.
        expect(File(markerFile).readAsLinesSync().length, 1);
        expect(run2.nodeById(s1.id)?.runStatus, CanvasNodeRunStatus.succeeded);
        expect(run2.nodeById(s2.id)?.runStatus, CanvasNodeRunStatus.succeeded);
        expect(run2.nodeById(s2.id)?.output, contains('UPSTREAM_OK_R69'));
        expect(run2.nodeById(s3.id)?.runStatus, CanvasNodeRunStatus.succeeded);

        // Verify evidence path extraction from node output.
        final evPaths = CanvasController.extractEvidencePaths(
          run2.nodeById(s3.id)!.output,
        );
        expect(evPaths, contains('${dir.path}/local-4200-after.png'));
        expect(evPaths, contains('${dir.path}/trace.md'));

        // Verify persisted run history survives reload and preserves run sequence.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final savedRun2Id = run2.id;
        ctrl.clearAllRunsForTest();
        ctrl.resetLoadedForTest();
        await ctrl.load();
        expect(ctrl.runs.any((r) => r.id == savedRun2Id), isTrue);
        final restored = ctrl.runById(savedRun2Id)!;
        expect(restored.ok, isTrue);
        expect(restored.nodeById(s3.id)?.output, contains('FINAL_R69'));
        expect(restored.capturedVars['input.tag'], 'R69');

        ctrl.clearAllRunsForTest();
        ctrl.clearBoard();
        ctrl.storagePathOverride = null;
      },
    );
  });
}
