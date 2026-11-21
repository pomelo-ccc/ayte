import 'dart:async';

import 'package:flutter/material.dart';

import '../acp/acp_agent_service.dart';
import '../canvas/canvas_controller.dart';
import '../ide/ide_button.dart';
import '../ide/ide_input.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import 'task_queue_service.dart';

/// Kanban-style unattended Task Queue view with isolated Git worktree execution
/// and mandatory Review / Merge approval.
class TaskQueueView extends StatefulWidget {
  const TaskQueueView({super.key, this.defaultRepoPath});

  final String? defaultRepoPath;

  @override
  State<TaskQueueView> createState() => _TaskQueueViewState();
}

class _TaskQueueViewState extends State<TaskQueueView> {
  final _titleController = TextEditingController();
  final _promptController = TextEditingController();
  String _selectedAgent = 'agy';
  String? _selectedWorkflowId;
  bool _useWorktree = true;
  String? _expandedTaskId;
  String? _statusMessage;

  TaskQueueService get _svc => TaskQueueService.instance;

  @override
  void dispose() {
    _titleController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  void _enqueue() {
    final prompt = _promptController.text.trim();
    final title = _titleController.text.trim();
    final repo = widget.defaultRepoPath?.trim() ?? '';
    if ((prompt.isEmpty && title.isEmpty) || repo.isEmpty) return;
    _svc.enqueue(
      title: title,
      prompt: prompt.isEmpty ? title : prompt,
      repoPath: repo,
      agentId: _selectedAgent,
      useWorktree: _useWorktree,
      workflowTemplateId: _selectedWorkflowId,
    );
    _titleController.clear();
    _promptController.clear();
  }

  Future<void> _batchEnqueueDialog(bool isZh) async {
    final repo = widget.defaultRepoPath?.trim() ?? '';
    if (repo.isEmpty) return;
    final batchCtrl = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isZh ? '批量串行加单（每行一个单号或任务）' : 'Batch Enqueue (one per line)'),
        content: SizedBox(
          width: 380,
          child: IdeInputBox(
            controller: batchCtrl,
            minLines: 5,
            maxLines: 10,
            placeholder: isZh
                ? 'BUG-1024\nBUG-1025\nBUG-1026'
                : 'BUG-1024\nBUG-1025',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(batchCtrl.text),
            child: Text(isZh ? '全部加入队列' : 'Enqueue All'),
          ),
        ],
      ),
    );
    batchCtrl.dispose();
    if (raw == null || raw.trim().isEmpty) return;
    var count = 0;
    for (final line in raw.split('\n')) {
      final item = line.trim();
      if (item.isEmpty) continue;
      _svc.enqueue(
        title: item,
        prompt: item,
        repoPath: repo,
        agentId: _selectedAgent,
        useWorktree: _useWorktree,
        workflowTemplateId: _selectedWorkflowId,
      );
      count++;
    }
    if (mounted && count > 0) {
      setState(
        () => _statusMessage = isZh
            ? '已批量加入 $count 条任务到队列'
            : 'Enqueued $count tasks',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final colors = themeColors;
    return ListenableBuilder(
      listenable: Listenable.merge([
        _svc,
        AcpAgentService.instance,
        CanvasController.instance,
      ]),
      builder: (context, _) {
        final tasks = _svc.tasks;
        final agents = AcpAgentService.instance.selectableAgents;
        final workflows = CanvasController.instance.runnableWorkflowChoices;
        if (!agents.any((a) => a.id == _selectedAgent) && agents.isNotEmpty) {
          _selectedAgent = agents.first.id;
        }
        if (_selectedWorkflowId != null &&
            !workflows.any((w) => w.id == _selectedWorkflowId)) {
          _selectedWorkflowId = null;
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header + Concurrency + Dispatch
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: colors['widget.border'].withValues(alpha: 0.4),
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Codicons.checklist, size: 14, color: colors['foreground']),
                      const SizedBox(width: 6),
                      Text(
                        isZh ? '无人值守任务队列 (Worktree)' : 'Unattended Task Queue',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: colors['foreground'],
                        ),
                      ),
                      const Spacer(),
                      // Segmented Concurrency Selector (Serial 1 / 2 / 4)
                      Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: colors['editor.background'],
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: colors['widget.border'].withValues(alpha: 0.45),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final (n, label) in [
                              (1, isZh ? '串行 (1)' : 'Serial'),
                              (2, '2x'),
                              (4, '4x'),
                            ])
                              InkWell(
                                borderRadius: BorderRadius.circular(4),
                                onTap: () => _svc.setMaxConcurrency(n),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _svc.maxConcurrency == n
                                        ? colors['button.background']
                                            .withValues(alpha: 0.2)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    label,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: _svc.maxConcurrency == n
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                      color: _svc.maxConcurrency == n
                                          ? colors['button.background']
                                          : colors['descriptionForeground'],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      IdeButton(
                        label: isZh ? '批量加单' : 'Batch',
                        icon: Codicons.listOrdered,
                        secondary: true,
                        onPressed: () => unawaited(_batchEnqueueDialog(isZh)),
                      ),
                      const SizedBox(width: 6),
                      IdeButton(
                        label: _svc.autoDispatch
                            ? (isZh ? '自动调度: 开' : 'Auto: On')
                            : (isZh ? '自动调度: 关' : 'Auto: Off'),
                        secondary: !_svc.autoDispatch,
                        onPressed: () =>
                            _svc.setAutoDispatch(!_svc.autoDispatch),
                      ),
                      const SizedBox(width: 6),
                      IdeButton(
                        label: isZh ? '开始执行队列' : 'Run Queue',
                        icon: Codicons.play,
                        onPressed: () => unawaited(_svc.dispatchPending()),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: IdeInputBox(
                          controller: _titleController,
                          placeholder: isZh
                              ? '任务标题 / Bug 单号（如 BUG-1024）'
                              : 'Task title / Bug ID',
                        ),
                      ),
                      const SizedBox(width: 6),
                      DropdownButton<String>(
                        value: _selectedWorkflowId ?? '__agent__:$_selectedAgent',
                        isDense: true,
                        underline: const SizedBox.shrink(),
                        dropdownColor: colors['editor.background'],
                        style: TextStyle(
                          fontSize: 12,
                          color: colors['foreground'],
                        ),
                        items: [
                          for (final a in agents)
                            DropdownMenuItem(
                              value: '__agent__:${a.id}',
                              child: Text(a.name),
                            ),
                          for (final wf in workflows)
                            DropdownMenuItem(
                              value: wf.id,
                              child: Text('⚡ ${wf.name}'),
                            ),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            if (v.startsWith('__agent__:')) {
                              _selectedWorkflowId = null;
                              _selectedAgent = v.substring(10);
                            } else {
                              _selectedWorkflowId = v;
                            }
                          });
                        },
                      ),
                      const SizedBox(width: 6),
                      IdeButton(
                        label: _useWorktree
                            ? (isZh ? '隔离 Worktree' : 'Worktree')
                            : (isZh ? '当前工作区直跑' : 'In-Place'),
                        secondary: _useWorktree,
                        onPressed: () =>
                            setState(() => _useWorktree = !_useWorktree),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: IdeInputBox(
                          controller: _promptController,
                          minLines: 1,
                          maxLines: 3,
                          placeholder: isZh
                              ? '描述要后台自动完成的任务（每个任务自动建独立 git worktree）'
                              : 'Describe a task to run unattended in an isolated git worktree...',
                          onSubmitted: (_) => _enqueue(),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IdeButton(
                        label: isZh ? '加入队列' : 'Enqueue',
                        icon: Codicons.add,
                        onPressed: _enqueue,
                      ),
                    ],
                  ),
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      _statusMessage!,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colors['descriptionForeground'],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Task list grouped cleanly
            Expanded(
              child: tasks.isEmpty
                  ? Center(
                      child: Text(
                        isZh
                            ? '暂无队列任务。添加任务后将在独立 Worktree 中后台执行，完成后进入「待审阅」等你合并。'
                            : 'No queued tasks. Tasks run in isolated git worktrees and wait in Review before merging.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors['descriptionForeground'],
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(10),
                      itemCount: tasks.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) => _buildCard(tasks[i], isZh),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCard(WorktreeTask task, bool isZh) {
    final colors = themeColors;
    final expanded = _expandedTaskId == task.id;
    final tone = switch (task.status) {
      WorktreeTaskStatus.queued => const Color(0xFF8B949E),
      WorktreeTaskStatus.running => const Color(0xFF58A6FF),
      WorktreeTaskStatus.review => const Color(0xFFD29922),
      WorktreeTaskStatus.merged => const Color(0xFF3FB950),
      WorktreeTaskStatus.failed => const Color(0xFFE5534B),
      WorktreeTaskStatus.cancelled => const Color(0xFF8B949E),
    };
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors['sideBar.background'].withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: task.status == WorktreeTaskStatus.review
              ? tone.withValues(alpha: 0.7)
              : colors['widget.border'].withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  task.status.label(zh: isZh),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: tone,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  task.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: colors['foreground'],
                  ),
                ),
              ),
              if (task.status == WorktreeTaskStatus.queued ||
                  task.status == WorktreeTaskStatus.failed)
                IdeButton(
                  label: isZh ? '运行' : 'Run',
                  secondary: true,
                  onPressed: () => unawaited(_svc.runTask(task.id)),
                ),
              if (task.status == WorktreeTaskStatus.running)
                IdeButton(
                  label: isZh ? '停止' : 'Stop',
                  secondary: true,
                  onPressed: () => unawaited(_svc.cancelTask(task.id)),
                ),
              if (task.status == WorktreeTaskStatus.review) ...[
                IdeButton(
                  label: isZh ? '审阅并合并' : 'Approve & Merge',
                  icon: Codicons.gitMerge,
                  onPressed: () async {
                    final res = await _svc.approveAndMerge(task.id);
                    if (mounted) {
                      setState(() => _statusMessage = res.message);
                    }
                  },
                ),
                const SizedBox(width: 6),
              ],
              const SizedBox(width: 4),
              InkWell(
                onTap: () => setState(
                  () => _expandedTaskId = expanded ? null : task.id,
                ),
                child: Icon(
                  expanded ? Codicons.chevronUp : Codicons.chevronDown,
                  size: 14,
                  color: colors['descriptionForeground'],
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: () => unawaited(_svc.discardTask(task.id)),
                child: Icon(
                  Codicons.trash,
                  size: 13,
                  color: colors['descriptionForeground'],
                ),
              ),
            ],
          ),
          if (task.branchName.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '${task.branchName} · ${task.agentId}',
              style: TextStyle(
                fontSize: 11,
                fontFamily: AppFonts.mono,
                color: colors['descriptionForeground'],
              ),
            ),
          ],
          if (task.diffStat.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.code,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                task.diffStat,
                maxLines: expanded ? 20 : 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: AppFonts.mono,
                  color: colors['editor.foreground'],
                ),
              ),
            ),
          ],
          if (expanded && task.log.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.code,
                borderRadius: BorderRadius.circular(4),
              ),
              child: SingleChildScrollView(
                reverse: true,
                child: SelectableText(
                  task.log.trim(),
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: AppFonts.mono,
                    color: colors['editor.foreground'],
                  ),
                ),
              ),
            ),
          ],
          if (task.error != null) ...[
            const SizedBox(height: 4),
            Text(
              task.error!,
              style: const TextStyle(fontSize: 11.5, color: Color(0xFFE5534B)),
            ),
          ],
        ],
      ),
    );
  }
}
