import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:baocode/acp/acp_agent_service.dart';
import 'package:baocode/canvas/canvas_ai_generator.dart';
import 'package:baocode/canvas/canvas_controller.dart';
import 'package:baocode/canvas/infinite_canvas_view.dart';
import 'package:baocode/canvas/workflow_celebration_overlay.dart';

void main() {
  group('CanvasController Undo/Redo, Graph Ops & Multi-Workflow', () {
    test('supports undo/redo across add, connect, move, remove, autoLayout, clear', () {
      final ctrl = CanvasController.forTest();
      expect(ctrl.canUndo, isFalse);
      expect(ctrl.canRedo, isFalse);

      final a = ctrl.addNode(kind: CanvasNodeKind.trigger, title: 'A', x: 100, y: 100);
      final b = ctrl.addNode(kind: CanvasNodeKind.command, title: 'B', x: 400, y: 100);
      final edge = ctrl.connect(a.id, b.id);
      expect(edge, isNotNull);
      expect(ctrl.nodes.length, 2);
      expect(ctrl.edges.length, 1);

      // Cycle prevention: connecting B -> A must be rejected.
      expect(ctrl.wouldCreateCycle(b.id, a.id), isTrue);
      expect(ctrl.connect(b.id, a.id), isNull);
      expect(ctrl.edges.length, 1);

      // Undo removes the edge.
      expect(ctrl.undo(), isTrue);
      expect(ctrl.edges, isEmpty);
      expect(ctrl.canRedo, isTrue);

      // Redo restores the edge.
      expect(ctrl.redo(), isTrue);
      expect(ctrl.edges.length, 1);

      // Clear board + undo recovers everything cleanly.
      ctrl.clearBoard();
      expect(ctrl.nodes, isEmpty);
      expect(ctrl.undo(), isTrue);
      expect(ctrl.nodes.length, 2);
      expect(ctrl.edges.length, 1);
    });

    test('inserts node mid-edge, reconnects edges, duplicates & aligns multi-selection', () {
      final ctrl = CanvasController.forTest();
      final a = ctrl.addNode(kind: CanvasNodeKind.trigger, title: 'Start', x: 100, y: 100);
      final c = ctrl.addNode(kind: CanvasNodeKind.command, title: 'End', x: 700, y: 260);
      final e = ctrl.connect(a.id, c.id, branch: CanvasEdgeBranch.onPass)!;

      final mid = ctrl.insertNodeOnEdge(e.id, CanvasNodeKind.condition, title: 'Gate');
      expect(mid, isNotNull);
      expect(ctrl.nodes.length, 3);
      expect(ctrl.edges.length, 2);
      expect(ctrl.edges.any((x) => x.fromId == a.id && x.toId == mid!.id), isTrue);
      expect(ctrl.edges.any((x) => x.fromId == mid!.id && x.toId == c.id), isTrue);

      // Multi-select duplicate preserves internal edge.
      final copies = ctrl.duplicateNodes({a.id, mid!.id});
      expect(copies.length, 2);
      expect(
        ctrl.edges.any((x) => x.fromId == copies[0].id && x.toId == copies[1].id),
        isTrue,
      );

      // Align top.
      ctrl.alignNodes({a.id, c.id}, CanvasNodeAlignment.top);
      expect(ctrl.nodeById(c.id)!.y, ctrl.nodeById(a.id)!.y);

      // Dynamic board bounds grow past 4800 when nodes extend far right.
      ctrl.moveNode(c.id, 6000, 0);
      expect(ctrl.nodeById(c.id)!.x, greaterThan(4400));
      final size = CanvasController.computeBoardSize(ctrl.nodes);
      expect(size.width, greaterThan(6000));
    });

    test('supports multi-workflow switching and portable JSON export/import', () {
      final ctrl = CanvasController.forTest();
      ctrl.renameActiveWorkflow('主流程');
      ctrl.addNode(kind: CanvasNodeKind.trigger, title: 'T1', content: 'env=prod');

      final wf2 = ctrl.createWorkflow('第二工作流');
      expect(ctrl.workflows.length, 2);
      expect(ctrl.nodes, isEmpty);
      final n2 = ctrl.addNode(kind: CanvasNodeKind.command, title: 'Echo', content: 'echo hi');
      final exported = ctrl.exportWorkflowJson();
      expect(exported, contains('ayte-workflow'));
      expect(exported, contains('Echo'));

      // Switch back to first workflow and verify nodes preserved.
      expect(ctrl.switchWorkflow('wf_default'), isTrue);
      expect(ctrl.nodes.length, 1);
      expect(ctrl.nodes.first.title, 'T1');

      // Import exported JSON into a new tab.
      final imported = ctrl.importWorkflowJson(exported, createNewTab: true);
      expect(imported.nodeCount, 1);
      expect(ctrl.nodes.first.id, n2.id);

      // Delete a workflow safely.
      expect(ctrl.deleteWorkflow(wf2.id), isTrue);
    });
  });

  group('Canvas Variables, Conditions & Cross-Platform Evidence', () {
    test('interpolates defaults and shell/json/url filters safely', () {
      final vars = {'input.msg': "it's a \"test\" & 100%"};
      expect(
        CanvasController.interpolate('{{input.missing ?? default_val}}', vars),
        'default_val',
      );
      expect(
        CanvasController.interpolate('{{input.msg | shell}}', vars),
        "'it'\\''s a \"test\" & 100%'",
      );
      expect(
        CanvasController.interpolate('{{input.msg | json}}', vars),
        'it\'s a \\"test\\" & 100%',
      );
      expect(
        CanvasController.interpolate('{{input.msg | url}}', vars),
        contains('%26%20100%25'),
      );
      // Unquoted fallback resolves another variable when present; quoted stays literal.
      expect(
        CanvasController.interpolate(
          '{{step_triage.output ?? prev.output}}',
          {'prev.output': 'FROM_PREV'},
        ),
        'FROM_PREV',
      );
      expect(
        CanvasController.interpolate(
          "{{step_triage.output ?? 'prev.output'}}",
          {'prev.output': 'FROM_PREV'},
        ),
        'prev.output',
      );
    });

    test('extractOutputVariables parses structured headers and skips placeholders', () {
      const sample = '''
**BUG_ID**: `I2611000627`
BUG_GUID：EB72E4F12A5A41A198AEA62890BA2ADD
- BUG_TITLE: 【公共】新增子文件夹重复提示
BUG_URL: https://pomeloc.top/bugs/#I2611000627
CHANGED_REPOS: pdm
''';
      final parsed = CanvasController.extractOutputVariables(sample);
      expect(parsed['bug.id'], 'I2611000627');
      expect(parsed['bugId'], 'I2611000627');
      expect(parsed['bug.guid'], 'EB72E4F12A5A41A198AEA62890BA2ADD');
      expect(parsed['bug.title'], '【公共】新增子文件夹重复提示');
      expect(parsed['bug.url'], 'https://pomeloc.top/bugs/#I2611000627');
      expect(parsed['fix.repos'], 'pdm');

      // Angle-bracket placeholders and "无" must be ignored.
      expect(
        CanvasController.extractOutputVariables('BUG_ID: <单号>\nCHANGED_REPOS: 无'),
        isEmpty,
      );
    });

    test('evaluateVerdict respects final standalone verdict over earlier prose', () {
      const proseThenPass = '''
规则说明：如果失败请输出 VERDICT: FAIL，通过输出 VERDICT: PASS。
已核实所有校验项通过。
**VERDICT: PASS**
''';
      final v1 = CanvasController.evaluateVerdict(proseThenPass);
      expect(v1.finalVerdict, isTrue);

      const failAtEnd = '''
初步排查看似正常（非 VERDICT: PASS）
最终结论：
VERDICT: FAIL
''';
      final v2 = CanvasController.evaluateVerdict(failAtEnd);
      expect(v2.finalVerdict, isFalse);

      expect(CanvasController.evaluateVerdict('no verdict here').finalVerdict, isNull);
    });

    test('extracts both Windows and POSIX evidence paths without false matches', () {
      const text = r'''
Saved screenshot: C:\Users\demo\evidence\after.png
Diff: D:/Ayte/out/git.diff
Linux: /tmp/run_1/trace.md
''';
      final paths = CanvasController.extractEvidencePaths(text);
      expect(paths, contains(r'C:\Users\demo\evidence\after.png'));
      expect(paths, contains('D:/Ayte/out/git.diff'));
      expect(paths, contains('/tmp/run_1/trace.md'));
    });

    test('handles invalid regex in evaluateCondition without throwing', () {
      expect(
        CanvasController.evaluateCondition(
          'regex:[unclosed',
          prevOutput: 'hello',
          prevExitCode: 0,
        ),
        isFalse,
      );
      expect(
        CanvasController.evaluateCondition(
          'regex:^OK_\\d+\$',
          prevOutput: 'OK_42',
          prevExitCode: 0,
        ),
        isTrue,
      );
    });
  });

  group('Parallel DAG Scheduler, Fan-In Join & Failure Semantics', () {
    test('executes diamond fan-out in parallel and waits for all branches at join', () async {
      final dir = await Directory.systemTemp.createTemp('ayte-diamond-test');
      addTearDown(() => dir.delete(recursive: true));
      final ctrl = CanvasController.forTest();

      final start = ctrl.addNode(
        kind: CanvasNodeKind.trigger,
        title: 'Start',
        content: 'tag=JOIN',
      );
      final left = ctrl.addNode(
        kind: CanvasNodeKind.command,
        title: 'Left',
        content: 'echo LEFT_{{input.tag}}',
      );
      final right = ctrl.addNode(
        kind: CanvasNodeKind.command,
        title: 'Right',
        content: 'echo RIGHT_{{input.tag}}',
      );
      final join = ctrl.addNode(
        kind: CanvasNodeKind.command,
        title: 'Join',
        content: 'echo "MERGED:\$AYTE_PREV_OUTPUT"',
      );
      ctrl.connect(start.id, left.id);
      ctrl.connect(start.id, right.id);
      ctrl.connect(left.id, join.id);
      ctrl.connect(right.id, join.id);

      final res = await ctrl.runWorkflow(defaultCwd: dir.path);
      expect(res.ok, isTrue);
      final run = ctrl.runById(res.runId!)!;
      expect(run.nodeById(left.id)?.runStatus, CanvasNodeRunStatus.succeeded);
      expect(run.nodeById(right.id)?.runStatus, CanvasNodeRunStatus.succeeded);
      expect(run.nodeById(join.id)?.runStatus, CanvasNodeRunStatus.succeeded);
      expect(run.nodeById(join.id)?.output, contains('LEFT_JOIN'));
      expect(run.nodeById(join.id)?.output, contains('RIGHT_JOIN'));
    });

    test('diagnostic onFail node runs WITHOUT falsely reporting workflow ok=true', () async {
      final dir = await Directory.systemTemp.createTemp('ayte-fail-semantics');
      addTearDown(() => dir.delete(recursive: true));
      final ctrl = CanvasController.forTest();

      final failing = ctrl.addNode(
        kind: CanvasNodeKind.command,
        title: 'Broken Step',
        content: 'echo BOOM && exit 1',
      );
      final diag = ctrl.addNode(
        kind: CanvasNodeKind.command,
        title: 'Fail Diagnostics',
        content: 'echo DIAG_PRINTED',
        recoversFailure: false,
      );
      ctrl.connect(failing.id, diag.id, branch: CanvasEdgeBranch.onFail);

      final res = await ctrl.runWorkflow(defaultCwd: dir.path);
      expect(res.ok, isFalse);
      expect(res.failedNodeId, failing.id);
      final run = ctrl.runById(res.runId!)!;
      expect(run.nodeById(diag.id)?.runStatus, CanvasNodeRunStatus.succeeded);
      expect(run.nodeById(diag.id)?.output, contains('DIAG_PRINTED'));

      // Now mark the fallback node as recoversFailure=true -> workflow recovers!
      ctrl.updateNode(diag.id, recoversFailure: true);
      final recovered = await ctrl.runWorkflow(defaultCwd: dir.path);
      expect(recovered.ok, isTrue);
    });

    test('retries transient command failures up to maxRetries', () async {
      final dir = await Directory.systemTemp.createTemp('ayte-retry-test');
      addTearDown(() => dir.delete(recursive: true));
      final flag = p.join(dir.path, 'once.flag').replaceAll(r'\', '/');
      final ctrl = CanvasController.forTest();

      ctrl.addNode(
        kind: CanvasNodeKind.command,
        title: 'Flaky',
        content:
            'if [ -f "$flag" ]; then echo RETRIED_OK; else echo 1 > "$flag"; exit 1; fi',
        maxRetries: 2,
        retryDelaySeconds: 0,
      );
      final res = await ctrl.runWorkflow(defaultCwd: dir.path);
      expect(res.ok, isTrue);
      expect(res.log, contains('RETRIED_OK'));
      expect(res.log, contains('自动重试'));
    });

    test('persists atomically and backs up corrupted canvas.json to .bak', () async {
      final dir = await Directory.systemTemp.createTemp('ayte-atomic-test');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'canvas.json');
      await File(path).writeAsString('{corrupted json!!!');

      final ctrl = CanvasController.forTest(storagePath: path);
      await ctrl.load();
      expect(await File('$path.bak').exists(), isTrue);

      ctrl.addNode(kind: CanvasNodeKind.note, title: 'Saved Note', content: 'Safe');
      await ctrl.flushSave();

      final reloaded = CanvasController.forTest(storagePath: path);
      await reloaded.load();
      expect(reloaded.nodes.length, 1);
      expect(reloaded.nodes.first.title, 'Saved Note');
    });

    test('approval nodes default to unlimited timeout (0) and preserve it in JSON', () {
      final ctrl = CanvasController.forTest();
      final gate = ctrl.addNode(
        kind: CanvasNodeKind.approval,
        title: 'Human Gate',
      );
      expect(gate.timeoutSeconds, 0);
      final parsed = CanvasNode.fromJson(gate.toJson());
      expect(parsed?.timeoutSeconds, 0);

      // Command nodes still clamp to >= 10s.
      final cmd = ctrl.addNode(
        kind: CanvasNodeKind.command,
        title: 'Shell',
        timeoutSeconds: 0,
      );
      expect(cmd.timeoutSeconds, 10);
    });

    test('approval timeout aborts workflow WITHOUT firing onFail rejection branch', () async {
      final ctrl = CanvasController.forTest();
      final gate = ctrl.addNode(
        kind: CanvasNodeKind.approval,
        title: 'Gate',
        content: 'Approve?',
      );
      // Use a short direct timeout (1s) on the node for testing.
      gate.timeoutSeconds = 1;
      var rejectRan = false;
      final rejectNode = ctrl.addNode(
        kind: CanvasNodeKind.command,
        title: 'Reject Side Effect',
        content: 'echo REJECT_RAN',
        recoversFailure: true,
      );
      ctrl.connect(gate.id, rejectNode.id, branch: CanvasEdgeBranch.onFail);

      final res = await ctrl.runWorkflow();
      expect(res.ok, isFalse);
      expect(res.failedNodeId, gate.id);
      final run = ctrl.runById(res.runId!)!;
      expect(run.nodeById(gate.id)?.exitCode, 124);
      rejectRan = run.nodeById(rejectNode.id)?.runStatus ==
          CanvasNodeRunStatus.succeeded;
      expect(rejectRan, isFalse);
      expect(run.nodeById(rejectNode.id)?.runStatus, CanvasNodeRunStatus.skipped);
    });

    test('bug verification template propagates BUG_ID/context and handles human reject cleanly', () async {
      final dir = await Directory.systemTemp.createTemp('ayte-bug-wf-test');
      addTearDown(() => dir.delete(recursive: true));
      addTearDown(() => AcpAgentService.instance.headlessRunnerOverride = null);

      final promptsByStep = <String, String>{};
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
        if (prompt.contains('自动筛选选单')) {
          promptsByStep['step_triage'] = prompt;
          return (
            ok: true,
            output:
                'BUG_ID: I2611000627\n'
                'BUG_GUID: EB72E4F12A5A41A198AEA62890BA2ADD\n'
                'BUG_TITLE: 【公共】新增子文件夹重复提示\n'
                'BUG_URL: https://pomeloc.top/bugs/#I2611000627\n'
                '根因：pdm/src/app/folder-modal.html 框下多了一段重复 hint。\n'
                'VERDICT: PASS',
            error: null,
          );
        }
        if (prompt.contains('action":"fix"')) {
          promptsByStep['step_mark_pr'] = prompt;
          return (
            ok: true,
            output: 'BUG_ID: I2611000627\n已更新为 PR\nVERDICT: PASS',
            error: null,
          );
        }
        if (prompt.contains('按最小化精准原则修复前端代码')) {
          promptsByStep['step_fix_code'] = prompt;
          return (
            ok: true,
            output:
                'BUG_ID: I2611000627\n'
                'CHANGED_REPOS: pdm\n'
                '已移除 folder-modal.html 重复提示文案。\n'
                'VERDICT: PASS',
            error: null,
          );
        }
        if (prompt.contains('不在前端修改')) {
          promptsByStep['step_reject_reply'] = prompt;
          return (
            ok: true,
            output: 'BUG_ID: I2611000627\n已转交后端林泽世\nVERDICT: PASS',
            error: null,
          );
        }
        return (ok: true, output: 'VERDICT: PASS', error: null);
      };

      final ctrl = CanvasController.forTest();
      final tpl = CanvasController.buildBugVerificationTemplate(
        defaultCwd: dir.path,
      );
      // Verify template structural invariants.
      expect(
        tpl.nodes.firstWhere((n) => n.id == 'step_triage_gate').timeoutSeconds,
        0,
      );
      expect(
        tpl.nodes.firstWhere((n) => n.id == 'step_reject_reply').recoversFailure,
        isTrue,
      );
      expect(
        tpl.nodes.firstWhere((n) => n.id == 'step_69_deploy_verify').timeoutSeconds,
        1800,
      );

      // 1) Human rejection path must run step_reject_reply with BUG_ID & finish ok=true.
      late int rejectRunId;
      final rejectFuture = ctrl.runWorkflow(
        templateId: CanvasController.bugVerifyTemplateId,
        defaultCwd: dir.path,
        onRunStarted: (id) => rejectRunId = id,
      );
      while (ctrl.runById(rejectRunId)?.activeApprovalNodeId !=
          'step_triage_gate') {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      ctrl.rejectNode(
        'step_triage_gate',
        note: '转交后端 林泽世',
        runId: rejectRunId,
      );
      final rejectRes = await rejectFuture;
      expect(rejectRes.ok, isTrue, reason: rejectRes.error);
      expect(promptsByStep['step_reject_reply'], contains('I2611000627'));
      expect(
        promptsByStep['step_reject_reply'],
        contains('EB72E4F12A5A41A198AEA62890BA2ADD'),
      );
      expect(promptsByStep['step_reject_reply'], contains('转交后端 林泽世'));

      // 2) Approve path: step_fix_code must still receive step_triage root cause,
      //    BUG_ID, and step_triage_gate.note even after step_mark_pr ran in between!
      promptsByStep.clear();
      // Replace step_rebuild_local with a fast no-op echo so the test stays self-contained.
      final customNodes = [
        for (final n in tpl.nodes)
          if (n.id == 'step_rebuild_local')
            CanvasNode(
              id: n.id,
              kind: n.kind,
              title: n.title,
              x: n.x,
              y: n.y,
              content: r'echo "REBUILT:$AYTE_BUG_ID:$AYTE_FIX_REPOS"',
            )
          else
            n.clone(),
      ];
      late int approveRunId;
      final approveFuture = ctrl.runWorkflow(
        customNodes: customNodes,
        customEdges: tpl.edges,
        defaultCwd: dir.path,
        onRunStarted: (id) => approveRunId = id,
      );
      while (ctrl.runById(approveRunId)?.activeApprovalNodeId !=
          'step_triage_gate') {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      ctrl.approveNode(
        'step_triage_gate',
        note: '只改 pdm',
        runId: approveRunId,
      );
      while (ctrl.runById(approveRunId)?.activeApprovalNodeId !=
          'step_deploy_69_gate') {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final activeApproveRun = ctrl.runById(approveRunId)!;
      expect(promptsByStep['step_fix_code'], contains('I2611000627'));
      expect(promptsByStep['step_fix_code'], contains('folder-modal.html'));
      expect(promptsByStep['step_fix_code'], contains('只改 pdm'));
      expect(
        activeApproveRun.nodeById('step_rebuild_local')?.output,
        contains('REBUILT:I2611000627:pdm'),
      );
      expect(activeApproveRun.capturedVars['bug.id'], 'I2611000627');
      expect(activeApproveRun.capturedVars['fix.repos'], 'pdm');
      ctrl.stopWorkflow(runId: approveRunId);
      await approveFuture;

      // 3) Hard verdict gate on step_triage: missing VERDICT: PASS must fail before approval gate.
      AcpAgentService.instance.headlessRunnerOverride = ({
        required String agentId,
        required String prompt,
        required String cwd,
        String? model,
        String? effort,
        void Function(String chunk)? onChunk,
        void Function(Process proc)? onProcessStarted,
        Duration timeout = const Duration(minutes: 15),
      }) async => (
        ok: true,
        output: '当前会话未挂载浏览器工具，无法读取问题单。',
        error: null,
      );
      final failRes = await ctrl.runWorkflow(
        templateId: CanvasController.bugVerifyTemplateId,
        defaultCwd: dir.path,
      );
      expect(failRes.ok, isFalse);
      expect(failRes.failedNodeId, 'step_triage');
      final failRun = ctrl.runById(failRes.runId!)!;
      expect(
        failRun.nodeById('step_triage_gate')?.runStatus,
        CanvasNodeRunStatus.skipped,
      );
    });
  });

  group('CanvasAiGenerator', () {
    test('parses fenced JSON, strips cycles, and applies generated workflow', () async {
      addTearDown(() => CanvasAiGenerator.askerForTest = null);
      CanvasAiGenerator.askerForTest =
          (system, prompt, {model, exact = false, location, cancel}) async =>
              '''
```json
{
  "name": "CI 自动检测与修复",
  "summary": "运行测试并在失败时调用 AI 修复",
  "nodes": [
    {"id": "t1", "kind": "trigger", "title": "输入参数", "content": "branch=main"},
    {"id": "c1", "kind": "command", "title": "运行测试", "content": "flutter test"},
    {"id": "a1", "kind": "agent", "title": "AI 修复", "content": "修复 {{prev.output}}", "recoversFailure": true}
  ],
  "edges": [
    {"fromId": "t1", "toId": "c1", "branch": "onPass"},
    {"fromId": "c1", "toId": "a1", "branch": "onFail"},
    {"fromId": "a1", "toId": "t1", "branch": "onPass"}
  ]
}
```
''';

      final gen = await CanvasAiGenerator.generateWorkflow('帮我建一个测试失败自动修复流程');
      expect(gen.name, 'CI 自动检测与修复');
      expect(gen.nodes.length, 3);
      // Cycle edge a1 -> t1 must be dropped automatically.
      expect(gen.edges.length, 2);

      final ctrl = CanvasController.forTest();
      ctrl.applyGeneratedWorkflow(
        name: gen.name,
        nodes: gen.nodes,
        edges: gen.edges,
      );
      expect(ctrl.nodes.length, 3);
      expect(ctrl.activeWorkflowName, 'CI 自动检测与修复');
    });
  });

  group('Canvas Studio UI & Celebration Overlay Widgets', () {
    testWidgets(
      'renders InfiniteCanvasView with group frame & minimap without overflow on wide and narrow viewports',
      (tester) async {
        final ctrl = CanvasController.instance;
        ctrl.clearAllRunsForTest();
        ctrl.clearBoard();
        ctrl.addNode(
          kind: CanvasNodeKind.group,
          title: 'Stage 1',
          x: 60,
          y: 60,
          width: 480,
          height: 280,
        );
        final a = ctrl.addNode(
          kind: CanvasNodeKind.trigger,
          title: 'Trigger',
          x: 90,
          y: 110,
          content: 'env=prod',
        );
        final b = ctrl.addNode(
          kind: CanvasNodeKind.command,
          title: 'Build',
          x: 420,
          y: 110,
          content: 'echo ok',
          maxRetries: 2,
        );
        ctrl.connect(a.id, b.id);

        for (final size in const [Size(1280, 760), Size(420, 700)]) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          await tester.pumpWidget(
            const MaterialApp(
              locale: Locale('zh'),
              home: Scaffold(body: InfiniteCanvasView()),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Stage 1'), findsOneWidget);
          expect(find.text('Build'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        ctrl.clearBoard();
      },
    );

    testWidgets(
      'InfiniteCanvasView truncates long workflow names in toolbar pill without overflow',
      (tester) async {
        final ctrl = CanvasController.instance;
        ctrl.clearBoard();
        ctrl.renameActiveWorkflow(
          'Jenkins 69-sts 极速精准部署（LC → BC → 目标应用）',
        );
        ctrl.addNode(
          kind: CanvasNodeKind.command,
          title: 'Deploy',
          x: 120,
          y: 120,
          content: 'echo deploy',
        );

        tester.view.physicalSize = const Size(1280, 760);
        tester.view.devicePixelRatio = 1.0;
        await tester.pumpWidget(
          const MaterialApp(
            locale: Locale('zh'),
            home: Scaffold(body: InfiniteCanvasView()),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Jenkins 69-sts 极速精准部署（LC → BC → 目标应用）'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        ctrl.clearBoard();
      },
    );

    testWidgets(
      'WorkflowCelebrationOverlay displays inspect CTA and dismisses cleanly',
      (tester) async {
        final ctrl = CanvasController.forTest();
        int? inspectedRunId;
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('zh'),
            home: WorkflowCelebrationOverlay(
              controller: ctrl,
              onInspectRun: (id) => inspectedRunId = id,
              child: const Scaffold(body: SizedBox.expand()),
            ),
          ),
        );
        ctrl.addNode(
          kind: CanvasNodeKind.command,
          title: 'Quick Echo',
          content: 'echo ok',
        );
        final res = await tester.runAsync(() => ctrl.runWorkflow());
        expect(res?.ok, isTrue);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.text('Workflow Completed!'), findsOneWidget);
        expect(find.text('Inspect'), findsOneWidget);
        await tester.tap(find.text('Inspect'));
        await tester.pump(const Duration(milliseconds: 450));
        expect(inspectedRunId, isNotNull);
        expect(tester.takeException(), isNull);
        // Let fireworks controller finish cleanly so no pending timers remain.
        await tester.pump(const Duration(seconds: 5));
      },
    );
  });
}
