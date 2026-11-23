import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../acp/acp_agent_service.dart';
import '../canvas/canvas_controller.dart';
import '../ide/ide_button.dart';
import '../ide/ide_input.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import '../workspace/window_controls.dart';
import 'task_diff_parser.dart';
import 'task_queue_service.dart';

enum _TaskFilter { all, queued, running, review, merged, failed }

enum _TaskDetailTab { diff, log, info }

enum _StatusTone { info, success, error }

/// Unattended Task Queue view with isolated Git worktree execution, repo &
/// model/effort selection, unified/side-by-side Diff review, and one-click
/// handoff into an interactive chat session.
class TaskQueueView extends StatefulWidget {
  const TaskQueueView({
    super.key,
    this.defaultRepoPath,
    this.availableRepos = const [],
    this.onPickDirectory,
    this.onHandOffTask,
  });

  final String? defaultRepoPath;
  final List<String> availableRepos;
  final Future<String?> Function()? onPickDirectory;
  final Future<void> Function(WorktreeTask task)? onHandOffTask;

  @override
  State<TaskQueueView> createState() => _TaskQueueViewState();
}

class _TaskQueueViewState extends State<TaskQueueView> {
  final _titleController = TextEditingController();
  final _promptController = TextEditingController();
  String _selectedRepo = '';
  final List<String> _customRepos = [];
  String _selectedAgent = 'agy';
  String _selectedModel = '';
  String _selectedEffort = '';
  String? _selectedWorkflowId;
  bool _useWorktree = true;
  _TaskFilter _filter = _TaskFilter.all;
  String? _expandedTaskId;
  _TaskDetailTab _detailTab = _TaskDetailTab.diff;
  String? _statusMessage;
  _StatusTone _statusTone = _StatusTone.info;
  Timer? _elapsedTicker;

  TaskQueueService get _svc => TaskQueueService.instance;

  @override
  void initState() {
    super.initState();
    _initSelectedRepo();
    _svc.addListener(_syncElapsedTicker);
    _syncElapsedTicker();
  }

  void _syncElapsedTicker() {
    if (_svc.runningCount > 0) {
      _elapsedTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _svc.runningCount == 0) {
          _elapsedTicker?.cancel();
          _elapsedTicker = null;
          return;
        }
        setState(() {});
      });
    } else {
      _elapsedTicker?.cancel();
      _elapsedTicker = null;
    }
  }

  @override
  void didUpdateWidget(TaskQueueView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selectedRepo.isEmpty) {
      _initSelectedRepo();
    }
  }

  void _initSelectedRepo() {
    final def = widget.defaultRepoPath?.trim() ?? '';
    if (def.isNotEmpty) {
      _selectedRepo = def;
    } else if (widget.availableRepos.isNotEmpty) {
      _selectedRepo = widget.availableRepos.first;
    }
  }

  List<String> _allRepoChoices() {
    final seen = <String>{};
    final out = <String>[];
    void addPath(String? raw) {
      final v = raw?.trim() ?? '';
      if (v.isNotEmpty && seen.add(v)) out.add(v);
    }

    addPath(widget.defaultRepoPath);
    for (final r in widget.availableRepos) {
      addPath(r);
    }
    for (final r in _customRepos) {
      addPath(r);
    }
    addPath(_selectedRepo);
    return out;
  }

  @override
  void dispose() {
    _svc.removeListener(_syncElapsedTicker);
    _elapsedTicker?.cancel();
    _titleController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  void _showStatus(String message, {_StatusTone tone = _StatusTone.info}) {
    if (!mounted) return;
    setState(() {
      _statusMessage = message;
      _statusTone = tone;
    });
  }

  Future<void> _pickRepoFolder(bool isZh) async {
    final picker = widget.onPickDirectory ?? WindowControls.pickDirectory;
    final picked = await picker();
    if (!mounted || picked == null || picked.trim().isEmpty) return;
    final clean = picked.trim();
    setState(() {
      if (!_customRepos.contains(clean)) _customRepos.add(clean);
      _selectedRepo = clean;
      _statusMessage = null;
    });
  }

  void _enqueue(bool isZh) {
    final prompt = _promptController.text.trim();
    final title = _titleController.text.trim();
    final repo = _selectedRepo.trim();
    if (repo.isEmpty) {
      _showStatus(
        isZh
            ? '请先选择目标代码仓库目录，再加入任务队列。'
            : 'Please select a target repository folder first.',
        tone: _StatusTone.error,
      );
      return;
    }
    if (prompt.isEmpty && title.isEmpty) {
      _showStatus(
        isZh ? '请输入任务标题或任务描述。' : 'Enter a task title or prompt.',
        tone: _StatusTone.error,
      );
      return;
    }
    final isWorkflow = _selectedWorkflowId != null;
    final task = _svc.enqueue(
      title: title,
      prompt: prompt.isEmpty ? title : prompt,
      repoPath: repo,
      agentId: _selectedAgent,
      model: isWorkflow || _selectedModel.isEmpty ? null : _selectedModel,
      effort: isWorkflow || _selectedEffort.isEmpty ? null : _selectedEffort,
      useWorktree: _useWorktree,
      workflowTemplateId: _selectedWorkflowId,
    );
    _titleController.clear();
    _promptController.clear();
    _showStatus(
      isZh ? '已加入队列：${task.title}' : 'Enqueued: ${task.title}',
      tone: _StatusTone.success,
    );
  }

  Future<void> _batchEnqueueDialog(bool isZh) async {
    final repo = _selectedRepo.trim();
    if (repo.isEmpty) {
      _showStatus(
        isZh
            ? '请先选择目标代码仓库目录，再批量加单。'
            : 'Please select a target repository folder before batch enqueue.',
        tone: _StatusTone.error,
      );
      return;
    }
    final batchCtrl = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          isZh ? '批量加单（每行一个单号或任务）' : 'Batch Enqueue (one per line)',
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                isZh
                    ? '目标仓库：$repo'
                    : 'Target repo: $repo',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: themeColors['descriptionForeground'],
                ),
              ),
              const SizedBox(height: 8),
              IdeInputBox(
                controller: batchCtrl,
                minLines: 5,
                maxLines: 10,
                placeholder: isZh
                    ? 'BUG-1024\nBUG-1025\nBUG-1026'
                    : 'BUG-1024\nBUG-1025',
              ),
            ],
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
    final isWorkflow = _selectedWorkflowId != null;
    var count = 0;
    for (final line in raw.split('\n')) {
      final item = line.trim();
      if (item.isEmpty) continue;
      _svc.enqueue(
        title: item,
        prompt: item,
        repoPath: repo,
        agentId: _selectedAgent,
        model: isWorkflow || _selectedModel.isEmpty ? null : _selectedModel,
        effort: isWorkflow || _selectedEffort.isEmpty ? null : _selectedEffort,
        useWorktree: _useWorktree,
        workflowTemplateId: _selectedWorkflowId,
      );
      count++;
    }
    if (count > 0) {
      _showStatus(
        isZh ? '已批量加入 $count 条任务到队列' : 'Enqueued $count tasks',
        tone: _StatusTone.success,
      );
    }
  }

  Future<void> _editTaskDialog(WorktreeTask task, bool isZh) async {
    final titleCtrl = TextEditingController(text: task.title);
    final promptCtrl = TextEditingController(text: task.prompt);
    var agent = task.agentId;
    var model = task.model ?? '';
    var effort = task.effort ?? '';
    var useWorktree = task.useWorktree;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final colors = themeColors;
          final agents = AcpAgentService.instance.selectableAgents;
          final models = AcpAgentService.instance.modelsForAgent(agent);
          if (model.isNotEmpty && !models.any((m) => m.id == model)) {
            model = '';
          }
          final modelObj = models.where((m) => m.id == model).firstOrNull;
          final efforts = modelObj?.effortLevels ?? const <String>[];
          if (effort.isNotEmpty && !efforts.contains(effort)) {
            effort = '';
          }
          return AlertDialog(
            title: Text(isZh ? '编辑任务' : 'Edit Task'),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  IdeInputBox(
                    controller: titleCtrl,
                    placeholder: isZh ? '任务标题' : 'Task title',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      DropdownButton<String>(
                        value: agent,
                        isDense: true,
                        underline: const SizedBox.shrink(),
                        dropdownColor: colors['editor.background'],
                        style: TextStyle(
                          fontSize: 12,
                          color: colors['foreground'],
                        ),
                        items: [
                          for (final a in agents)
                            DropdownMenuItem(value: a.id, child: Text(a.name)),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setDialogState(() {
                            agent = v;
                            model = '';
                            effort = '';
                          });
                        },
                      ),
                      DropdownButton<String>(
                        value: model,
                        isDense: true,
                        underline: const SizedBox.shrink(),
                        dropdownColor: colors['editor.background'],
                        style: TextStyle(
                          fontSize: 12,
                          color: colors['foreground'],
                        ),
                        items: [
                          DropdownMenuItem(
                            value: '',
                            child: Text(isZh ? '默认模型' : 'Default model'),
                          ),
                          for (final m in models)
                            DropdownMenuItem(value: m.id, child: Text(m.label)),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setDialogState(() {
                            model = v;
                            effort = '';
                          });
                        },
                      ),
                      if (efforts.isNotEmpty)
                        DropdownButton<String>(
                          value: effort,
                          isDense: true,
                          underline: const SizedBox.shrink(),
                          dropdownColor: colors['editor.background'],
                          style: TextStyle(
                            fontSize: 12,
                            color: colors['foreground'],
                          ),
                          items: [
                            DropdownMenuItem(
                              value: '',
                              child: Text(isZh ? '默认强度' : 'Default effort'),
                            ),
                            for (final e in efforts)
                              DropdownMenuItem(value: e, child: Text(e)),
                          ],
                          onChanged: (v) {
                            if (v != null) setDialogState(() => effort = v);
                          },
                        ),
                      IdeButton(
                        label: useWorktree
                            ? (isZh ? '隔离 Worktree' : 'Worktree')
                            : (isZh ? '当前工作区直跑' : 'In-Place'),
                        secondary: useWorktree,
                        onPressed: () =>
                            setDialogState(() => useWorktree = !useWorktree),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  IdeInputBox(
                    controller: promptCtrl,
                    minLines: 4,
                    maxLines: 10,
                    placeholder: isZh ? '任务提示词' : 'Task prompt',
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(isZh ? '取消' : 'Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(isZh ? '保存' : 'Save'),
              ),
            ],
          );
        },
      ),
    );
    if (saved == true) {
      _svc.updateTask(
        task.id,
        title: titleCtrl.text,
        prompt: promptCtrl.text,
        agentId: agent,
        model: model,
        clearModel: model.isEmpty,
        effort: effort,
        clearEffort: effort.isEmpty,
        useWorktree: useWorktree,
      );
      _showStatus(
        isZh ? '已更新任务：${task.title}' : 'Updated task: ${task.title}',
        tone: _StatusTone.success,
      );
    }
    titleCtrl.dispose();
    promptCtrl.dispose();
  }

  Future<void> _openDiffReview(WorktreeTask task, bool isZh) async {
    await _svc.ensureTaskDetailsLoaded(task.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _TaskDiffReviewDialog(
        taskId: task.id,
        isZh: isZh,
        onApproveAndMerge: () async {
          final res = await _svc.approveAndMerge(task.id);
          if (mounted) {
            _showStatus(
              res.message,
              tone: res.ok ? _StatusTone.success : _StatusTone.error,
            );
          }
          return res;
        },
        onHandOff: widget.onHandOffTask == null
            ? null
            : () async {
                Navigator.of(ctx).pop();
                await widget.onHandOffTask!(task);
              },
      ),
    );
  }

  Future<void> _confirmAndDiscard(WorktreeTask task, bool isZh) async {
    final hasLiveWorktree = task.worktreePath.isNotEmpty;
    final hasUnmergedChanges =
        task.status == WorktreeTaskStatus.review ||
        (task.status == WorktreeTaskStatus.failed &&
            (task.hasDiff || task.diffText.isNotEmpty || task.filesChanged > 0));
    if (hasLiveWorktree && hasUnmergedChanges) {
      final isFailed = task.status == WorktreeTaskStatus.failed;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            isFailed
                ? (isZh ? '丢弃包含改动的失败任务？' : 'Discard Failed Task with Changes?')
                : (isZh ? '丢弃待审阅任务？' : 'Discard Unmerged Task?'),
          ),
          content: Text(
            isFailed
                ? (isZh
                      ? '失败任务「${task.title}」在 Worktree 中留有部分代码改动，丢弃将永久删除其 Worktree 与分支 ${task.branchName}。'
                      : 'Failed task "${task.title}" has partial changes in its worktree. Discarding will permanently delete the worktree and branch ${task.branchName}.')
                : (isZh
                      ? '任务「${task.title}」在 Worktree 中有尚未合并的变更，丢弃将永久删除其 Worktree 与分支 ${task.branchName}。'
                      : 'Task "${task.title}" has unmerged changes in its worktree. Discarding will permanently delete the worktree and branch ${task.branchName}.'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(isZh ? '取消' : 'Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFE5534B),
              ),
              child: Text(isZh ? '确认丢弃' : 'Discard'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await _svc.discardTask(task.id);
    if (_expandedTaskId == task.id && mounted) {
      setState(() => _expandedTaskId = null);
    }
  }

  Future<void> _confirmAndClearFailed(
    bool isZh,
    List<WorktreeTask> allTasks,
  ) async {
    final failedTasks = allTasks
        .where((t) => t.status == WorktreeTaskStatus.failed)
        .toList();
    if (failedTasks.isEmpty) return;
    final withDiffCount = failedTasks
        .where(
          (t) =>
              t.worktreePath.isNotEmpty &&
              (t.hasDiff || t.diffText.isNotEmpty || t.filesChanged > 0),
        )
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          isZh
              ? '清理 ${failedTasks.length} 条失败任务？'
              : 'Clear ${failedTasks.length} Failed Tasks?',
        ),
        content: Text(
          withDiffCount > 0
              ? (isZh
                    ? '将清理 ${failedTasks.length} 条失败任务，其中 $withDiffCount 条在 Worktree 中留有未合并改动（将永久删除对应 Worktree 与分支）。是否继续？'
                    : 'This will remove ${failedTasks.length} failed task(s), including $withDiffCount with uncommitted/unmerged changes in their worktrees. Continue?')
              : (isZh
                    ? '将移除 ${failedTasks.length} 条失败任务并清理其日志与残留 Worktree。'
                    : 'This will remove ${failedTasks.length} failed task(s) and clean up their logs and any remaining worktrees.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFE5534B),
            ),
            child: Text(isZh ? '确认清理' : 'Clear Failed'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final removed = await _svc.clearFinishedTasks(includeFailed: true);
    if (removed > 0) {
      _showStatus(
        isZh ? '已清理 $removed 条已完成/失败任务' : 'Cleared $removed task(s)',
        tone: _StatusTone.info,
      );
    }
  }

  List<WorktreeTask> _applyFilter(List<WorktreeTask> tasks) => switch (_filter) {
    _TaskFilter.all => tasks,
    _TaskFilter.queued =>
      tasks.where((t) => t.status == WorktreeTaskStatus.queued).toList(),
    _TaskFilter.running =>
      tasks.where((t) => t.status == WorktreeTaskStatus.running).toList(),
    _TaskFilter.review =>
      tasks.where((t) => t.status == WorktreeTaskStatus.review).toList(),
    _TaskFilter.merged =>
      tasks.where((t) => t.status == WorktreeTaskStatus.merged).toList(),
    _TaskFilter.failed =>
      tasks
          .where(
            (t) =>
                t.status == WorktreeTaskStatus.failed ||
                t.status == WorktreeTaskStatus.cancelled,
          )
          .toList(),
  };

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
        final allTasks = _svc.tasks;
        final filteredTasks = _applyFilter(allTasks);
        final agents = AcpAgentService.instance.selectableAgents;
        final workflows = CanvasController.instance.runnableWorkflowChoices;
        if (!agents.any((a) => a.id == _selectedAgent) && agents.isNotEmpty) {
          _selectedAgent = agents.first.id;
        }
        if (_selectedWorkflowId != null &&
            !workflows.any((w) => w.id == _selectedWorkflowId)) {
          _selectedWorkflowId = null;
        }
        final models = AcpAgentService.instance.modelsForAgent(_selectedAgent);
        if (_selectedModel.isNotEmpty &&
            !models.any((m) => m.id == _selectedModel)) {
          _selectedModel = '';
        }
        final selectedModelObj = models
            .where((m) => m.id == _selectedModel)
            .firstOrNull;
        final effortLevels = selectedModelObj?.effortLevels ?? const <String>[];
        if (_selectedEffort.isNotEmpty &&
            !effortLevels.contains(_selectedEffort)) {
          _selectedEffort = '';
        }
        final repoChoices = _allRepoChoices();
        final finishedCount = allTasks
            .where(
              (t) =>
                  t.status == WorktreeTaskStatus.merged ||
                  t.status == WorktreeTaskStatus.cancelled,
            )
            .length;
        final failedCount = allTasks
            .where((t) => t.status == WorktreeTaskStatus.failed)
            .length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header + Enqueue composer
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
                  // Row 1: Title, concurrency, dispatch controls
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Codicons.checklist,
                            size: 14,
                            color: colors['foreground'],
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isZh
                                ? '无人值守任务队列 (Worktree)'
                                : 'Unattended Task Queue',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: colors['foreground'],
                            ),
                          ),
                          if (_svc.runningCount > 0 || _svc.reviewCount > 0) ...[
                            const SizedBox(width: 8),
                            _SmallBadge(
                              text: isZh
                                  ? '运行 ${_svc.runningCount} · 待审 ${_svc.reviewCount}'
                                  : '${_svc.runningCount} running · ${_svc.reviewCount} review',
                              color: _svc.reviewCount > 0
                                  ? const Color(0xFFD29922)
                                  : const Color(0xFF58A6FF),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(width: 8),
                      // Segmented Concurrency Selector (Serial 1 / 2 / 4)
                      Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: colors['editor.background'],
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: colors['widget.border'].withValues(
                              alpha: 0.45,
                            ),
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
                      IdeButton(
                        label: isZh ? '批量加单' : 'Batch',
                        icon: Codicons.listOrdered,
                        secondary: true,
                        onPressed: () => unawaited(_batchEnqueueDialog(isZh)),
                      ),
                      IdeButton(
                        label: _svc.autoDispatch
                            ? (isZh ? '自动调度: 开' : 'Auto: On')
                            : (isZh ? '自动调度: 关' : 'Auto: Off'),
                        secondary: !_svc.autoDispatch,
                        onPressed: () =>
                            _svc.setAutoDispatch(!_svc.autoDispatch),
                      ),
                      IdeButton(
                        label: isZh ? '开始执行队列' : 'Run Queue',
                        icon: Codicons.play,
                        onPressed: () => unawaited(_svc.dispatchPending()),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Row 2: Target repository selector + browse + execution mode
                  Row(
                    children: [
                      Icon(
                        Codicons.folderOpened,
                        size: 14,
                        color: _selectedRepo.isEmpty
                            ? const Color(0xFFD29922)
                            : colors['descriptionForeground'],
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: colors['input.background'],
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: _selectedRepo.isEmpty
                                  ? const Color(
                                      0xFFD29922,
                                    ).withValues(alpha: 0.65)
                                  : colors['input.border'],
                            ),
                          ),
                          child: repoChoices.isEmpty
                              ? Text(
                                  isZh
                                      ? '未选择目标仓库目录 — 点击右侧「浏览目录」选择'
                                      : 'No repository selected — click Browse',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFFD29922),
                                  ),
                                )
                              : DropdownButton<String>(
                                  value: repoChoices.contains(_selectedRepo)
                                      ? _selectedRepo
                                      : repoChoices.first,
                                  isExpanded: true,
                                  isDense: true,
                                  underline: const SizedBox.shrink(),
                                  dropdownColor: colors['editor.background'],
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors['foreground'],
                                  ),
                                  items: [
                                    for (final repo in repoChoices)
                                      DropdownMenuItem(
                                        value: repo,
                                        child: Text(
                                          '${p.basename(repo)}  ·  $repo',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                  onChanged: (v) {
                                    if (v != null) {
                                      setState(() => _selectedRepo = v);
                                    }
                                  },
                                ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IdeButton(
                        label: isZh ? '浏览目录' : 'Browse',
                        icon: Codicons.folderOpened,
                        secondary: true,
                        onPressed: () => unawaited(_pickRepoFolder(isZh)),
                      ),
                      const SizedBox(width: 6),
                      IdeButton(
                        label: _useWorktree
                            ? (isZh ? '隔离 Worktree' : 'Worktree')
                            : (isZh ? '当前工作区直跑' : 'In-Place'),
                        icon: Codicons.gitBranch,
                        secondary: _useWorktree,
                        onPressed: () =>
                            setState(() => _useWorktree = !_useWorktree),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Row 3: Title + Kernel/Workflow + Model + Effort (overflow-safe)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          minWidth: 180,
                          maxWidth: 320,
                        ),
                        child: IdeInputBox(
                          controller: _titleController,
                          placeholder: isZh
                              ? '任务标题 / Bug 单号（如 BUG-1024）'
                              : 'Task title / Bug ID',
                        ),
                      ),
                      _CompactDropdown<String>(
                        value: _selectedWorkflowId ?? '__agent__:$_selectedAgent',
                        maxWidth: 200,
                        items: [
                          for (final a in agents)
                            DropdownMenuItem(
                              value: '__agent__:${a.id}',
                              child: Text(
                                a.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          for (final wf in workflows)
                            DropdownMenuItem(
                              value: wf.id,
                              child: Text(
                                '⚡ ${wf.name}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            if (v.startsWith('__agent__:')) {
                              _selectedWorkflowId = null;
                              final next = v.substring(10);
                              if (next != _selectedAgent) {
                                _selectedAgent = next;
                                _selectedModel = '';
                                _selectedEffort = '';
                              }
                            } else {
                              _selectedWorkflowId = v;
                            }
                          });
                        },
                      ),
                      if (_selectedWorkflowId == null) ...[
                        _CompactDropdown<String>(
                          value: _selectedModel,
                          maxWidth: 210,
                          items: [
                            DropdownMenuItem(
                              value: '',
                              child: Text(
                                isZh ? '默认模型' : 'Default model',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            for (final m in models)
                              DropdownMenuItem(
                                value: m.id,
                                child: Text(
                                  m.label,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() {
                              _selectedModel = v;
                              _selectedEffort = '';
                            });
                          },
                        ),
                        if (effortLevels.isNotEmpty)
                          _CompactDropdown<String>(
                            value: _selectedEffort,
                            maxWidth: 120,
                            items: [
                              DropdownMenuItem(
                                value: '',
                                child: Text(
                                  isZh ? '默认强度' : 'Effort',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              for (final e in effortLevels)
                                DropdownMenuItem(
                                  value: e,
                                  child: Text(
                                    e,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (v) {
                              if (v != null) {
                                setState(() => _selectedEffort = v);
                              }
                            },
                          ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Row 4: Prompt + Enqueue
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
                          onSubmitted: (_) => _enqueue(isZh),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IdeButton(
                        label: isZh ? '加入队列' : 'Enqueue',
                        icon: Codicons.add,
                        onPressed: () => _enqueue(isZh),
                      ),
                    ],
                  ),
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 6),
                    _StatusBanner(
                      message: _statusMessage!,
                      tone: _statusTone,
                      onDismiss: () => setState(() => _statusMessage = null),
                    ),
                  ],
                ],
              ),
            ),
            // Filter bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: colors['widget.border'].withValues(alpha: 0.3),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final (f, label, count) in [
                            (
                              _TaskFilter.all,
                              isZh ? '全部' : 'All',
                              allTasks.length,
                            ),
                            (
                              _TaskFilter.queued,
                              isZh ? '待执行' : 'Queued',
                              allTasks
                                  .where(
                                    (t) => t.status == WorktreeTaskStatus.queued,
                                  )
                                  .length,
                            ),
                            (
                              _TaskFilter.running,
                              isZh ? '执行中' : 'Running',
                              allTasks
                                  .where(
                                    (t) =>
                                        t.status == WorktreeTaskStatus.running,
                                  )
                                  .length,
                            ),
                            (
                              _TaskFilter.review,
                              isZh ? '待审阅' : 'Review',
                              allTasks
                                  .where(
                                    (t) => t.status == WorktreeTaskStatus.review,
                                  )
                                  .length,
                            ),
                            (
                              _TaskFilter.merged,
                              isZh ? '已合并' : 'Merged',
                              allTasks
                                  .where(
                                    (t) => t.status == WorktreeTaskStatus.merged,
                                  )
                                  .length,
                            ),
                            (
                              _TaskFilter.failed,
                              isZh ? '失败/取消' : 'Failed',
                              allTasks
                                  .where(
                                    (t) =>
                                        t.status == WorktreeTaskStatus.failed ||
                                        t.status == WorktreeTaskStatus.cancelled,
                                  )
                                  .length,
                            ),
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: _FilterChip(
                                label: '$label ($count)',
                                selected: _filter == f,
                                onTap: () => setState(() => _filter = f),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (finishedCount > 0)
                    IdeButton(
                      label: isZh
                          ? '清理已完成 ($finishedCount)'
                          : 'Clear Finished ($finishedCount)',
                      icon: Codicons.clearAll,
                      secondary: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      onPressed: () async {
                        final removed = await _svc.clearFinishedTasks();
                        if (removed > 0) {
                          _showStatus(
                            isZh
                                ? '已清理 $removed 条已完成/已取消任务'
                                : 'Cleared $removed finished tasks',
                            tone: _StatusTone.info,
                          );
                        }
                      },
                    ),
                  if (failedCount > 0) ...[
                    if (finishedCount > 0) const SizedBox(width: 6),
                    IdeButton(
                      label: isZh
                          ? '清理失败 ($failedCount)'
                          : 'Clear Failed ($failedCount)',
                      icon: Codicons.trash,
                      secondary: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      onPressed: () =>
                          unawaited(_confirmAndClearFailed(isZh, allTasks)),
                    ),
                  ],
                ],
              ),
            ),
            // Task list
            Expanded(
              child: filteredTasks.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          allTasks.isEmpty
                              ? (isZh
                                    ? '暂无队列任务。选择目标仓库并添加任务后，将在独立 Git Worktree 中后台执行，完成后进入「待审阅」供你查看 Diff 并合并。'
                                    : 'No queued tasks. Select a repository and enqueue tasks to run unattended in isolated Git worktrees.')
                              : (isZh
                                    ? '当前筛选条件下暂无任务。'
                                    : 'No tasks match this filter.'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors['descriptionForeground'],
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(10),
                      itemCount: filteredTasks.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) =>
                          _buildCard(filteredTasks[i], isZh),
                    ),
            ),
          ],
        );
      },
    );
  }

  String _formatDuration(Duration? d) {
    if (d == null) return '';
    final secs = d.inSeconds;
    if (secs < 60) return '${secs}s';
    final mins = secs ~/ 60;
    final rem = secs % 60;
    return '${mins}m ${rem}s';
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
    final modelLabel = task.model != null && task.model!.isNotEmpty
        ? AcpAgentService.instance.modelLabel(task.agentId, task.model!)
        : '';
    final elapsedText = _formatDuration(task.elapsed);
    final repoName = task.repoPath.isEmpty ? '' : p.basename(task.repoPath);
    final canEdit =
        task.status == WorktreeTaskStatus.queued ||
        task.status == WorktreeTaskStatus.failed ||
        task.status == WorktreeTaskStatus.cancelled;
    final hasReviewableDiff =
        task.hasDiff || task.diffText.isNotEmpty || task.filesChanged > 0;

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
              if (canEdit) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: isZh ? '编辑任务' : 'Edit task',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () => unawaited(_editTaskDialog(task, isZh)),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        Codicons.edit,
                        size: 13.5,
                        color: colors['descriptionForeground'],
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 4),
              InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () {
                  final opening = !expanded;
                  setState(() {
                    _expandedTaskId = opening ? task.id : null;
                    if (opening) {
                      _detailTab = hasReviewableDiff
                          ? _TaskDetailTab.diff
                          : _TaskDetailTab.log;
                    }
                  });
                  if (opening) {
                    unawaited(_svc.ensureTaskDetailsLoaded(task.id));
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(
                    expanded ? Codicons.chevronUp : Codicons.chevronDown,
                    size: 14,
                    color: colors['descriptionForeground'],
                  ),
                ),
              ),
              const SizedBox(width: 2),
              InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () => unawaited(_confirmAndDiscard(task, isZh)),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(
                    Codicons.trash,
                    size: 13,
                    color: colors['descriptionForeground'],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Overflow-safe action bar
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (task.status == WorktreeTaskStatus.queued)
                IdeButton(
                  label: isZh ? '运行' : 'Run',
                  icon: Codicons.play,
                  secondary: true,
                  onPressed: () => unawaited(_svc.runTask(task.id)),
                ),
              if (task.status == WorktreeTaskStatus.failed ||
                  task.status == WorktreeTaskStatus.cancelled)
                IdeButton(
                  label: isZh ? '重跑' : 'Retry',
                  icon: Codicons.debugRestart,
                  secondary: true,
                  onPressed: () => unawaited(_svc.runTask(task.id)),
                ),
              if (task.status == WorktreeTaskStatus.running)
                IdeButton(
                  label: isZh ? '停止' : 'Stop',
                  icon: Codicons.debugStop,
                  secondary: true,
                  onPressed: () => unawaited(_svc.cancelTask(task.id)),
                ),
              if (hasReviewableDiff &&
                  task.status != WorktreeTaskStatus.running)
                IdeButton(
                  label: isZh ? '审阅 Diff' : 'Review Diff',
                  icon: Codicons.diff,
                  secondary: task.status != WorktreeTaskStatus.review,
                  onPressed: () => unawaited(_openDiffReview(task, isZh)),
                ),
              if (task.status == WorktreeTaskStatus.review)
                IdeButton(
                  label: isZh ? '批准并合并' : 'Approve & Merge',
                  icon: Codicons.gitMerge,
                  onPressed: () async {
                    final res = await _svc.approveAndMerge(task.id);
                    _showStatus(
                      res.message,
                      tone: res.ok ? _StatusTone.success : _StatusTone.error,
                    );
                  },
                ),
              if (widget.onHandOffTask != null &&
                  task.status != WorktreeTaskStatus.running)
                Tooltip(
                  message: isZh
                      ? '在对话中接管该任务的工作区并带入上下文'
                      : 'Hand off task workspace and context into interactive chat',
                  child: IdeButton(
                    label: isZh ? '接管到对话' : 'Chat',
                    icon: Codicons.commentDiscussion,
                    secondary: true,
                    onPressed: () => unawaited(widget.onHandOffTask!(task)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 5),
          // Metadata chips row
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (repoName.isNotEmpty)
                Tooltip(
                  message: task.repoPath,
                  child: _MetaPill(icon: Codicons.folderOpened, text: repoName),
                ),
              if (task.workflowTemplateId != null &&
                  task.workflowTemplateId!.isNotEmpty)
                _MetaPill(text: '⚡ ${task.workflowTemplateId}'),
              if (task.workflowTemplateId == null ||
                  task.workflowTemplateId!.isEmpty)
                _MetaPill(
                  text: [
                    task.agentId,
                    if (modelLabel.isNotEmpty) modelLabel,
                    if (task.effort != null && task.effort!.isNotEmpty)
                      task.effort!,
                  ].join(' · '),
                ),
              if (task.branchName.isNotEmpty)
                _MetaPill(
                  icon: Codicons.gitBranch,
                  text: task.branchName,
                  mono: true,
                ),
              if (!task.useWorktree)
                _MetaPill(text: isZh ? '当前工作区直跑' : 'In-Place'),
              if (task.filesChanged > 0 ||
                  task.linesAdded > 0 ||
                  task.linesRemoved > 0)
                _DiffStatChip(
                  files: task.filesChanged,
                  added: task.linesAdded,
                  removed: task.linesRemoved,
                  isZh: isZh,
                ),
              if (elapsedText.isNotEmpty)
                Text(
                  elapsedText,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: AppFonts.mono,
                    color: colors['descriptionForeground'],
                  ),
                ),
            ],
          ),
          if (!expanded && task.diffStat.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.code,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                task.diffStat,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: AppFonts.mono,
                  color: colors['editor.foreground'],
                ),
              ),
            ),
          ],
          if (task.error != null && task.error!.trim().isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              task.error!,
              style: const TextStyle(fontSize: 11.5, color: Color(0xFFE5534B)),
            ),
          ],
          if (expanded) ...[
            const SizedBox(height: 8),
            _buildExpandedPanel(task, isZh),
          ],
        ],
      ),
    );
  }

  Widget _buildExpandedPanel(WorktreeTask task, bool isZh) {
    final colors = themeColors;
    final parsedFiles = TaskDiffParser.parse(task.diffText);
    return Container(
      decoration: BoxDecoration(
        color: colors['editor.background'].withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: colors['widget.border'].withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Tab strip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: colors['widget.border'].withValues(alpha: 0.35),
                ),
              ),
            ),
            child: Row(
              children: [
                _DetailTabButton(
                  label: isZh
                      ? 'Diff 变更${parsedFiles.isNotEmpty ? ' (${parsedFiles.length})' : ''}'
                      : 'Diff${parsedFiles.isNotEmpty ? ' (${parsedFiles.length})' : ''}',
                  icon: Codicons.diff,
                  selected: _detailTab == _TaskDetailTab.diff,
                  onTap: () => setState(() => _detailTab = _TaskDetailTab.diff),
                ),
                const SizedBox(width: 6),
                _DetailTabButton(
                  label: isZh ? '执行日志' : 'Log',
                  icon: Codicons.terminal,
                  selected: _detailTab == _TaskDetailTab.log,
                  onTap: () => setState(() => _detailTab = _TaskDetailTab.log),
                ),
                const SizedBox(width: 6),
                _DetailTabButton(
                  label: isZh ? '任务说明' : 'Prompt',
                  icon: Codicons.info,
                  selected: _detailTab == _TaskDetailTab.info,
                  onTap: () => setState(() => _detailTab = _TaskDetailTab.info),
                ),
                const Spacer(),
                if (_detailTab == _TaskDetailTab.diff &&
                    task.status != WorktreeTaskStatus.running &&
                    task.status != WorktreeTaskStatus.merged)
                  IdeButton(
                    label: isZh ? '刷新 Diff' : 'Refresh',
                    icon: Codicons.refresh,
                    secondary: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    onPressed: () => unawaited(_svc.refreshTaskDiff(task.id)),
                  ),
                if (_detailTab == _TaskDetailTab.diff &&
                    parsedFiles.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  IdeButton(
                    label: isZh ? '大窗审阅' : 'Full Review',
                    icon: Codicons.splitHorizontal,
                    secondary: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    onPressed: () => unawaited(_openDiffReview(task, isZh)),
                  ),
                ],
                if (_detailTab == _TaskDetailTab.log && task.log.isNotEmpty)
                  IdeButton(
                    label: isZh ? '复制日志' : 'Copy',
                    icon: Codicons.copy,
                    secondary: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    onPressed: () {
                      unawaited(Clipboard.setData(ClipboardData(text: task.log)));
                      _showStatus(
                        isZh ? '已复制任务日志到剪贴板' : 'Copied task log',
                      );
                    },
                  ),
              ],
            ),
          ),
          // Tab content
          Padding(
            padding: const EdgeInsets.all(8),
            child: switch (_detailTab) {
              _TaskDetailTab.diff => _buildInlineDiffPreview(
                task,
                parsedFiles,
                isZh,
              ),
              _TaskDetailTab.log => _buildLogPreview(task, isZh),
              _TaskDetailTab.info => _buildInfoPreview(task, isZh),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildInlineDiffPreview(
    WorktreeTask task,
    List<TaskDiffFile> files,
    bool isZh,
  ) {
    final colors = themeColors;
    if (files.isEmpty && task.diffStat.isEmpty) {
      return Text(
        isZh
            ? '暂无代码变更 Diff（任务尚未执行或未修改任何文件）。'
            : 'No diff captured yet.',
        style: TextStyle(
          fontSize: 11.5,
          color: colors['descriptionForeground'],
        ),
      );
    }
    if (files.isEmpty) {
      return SelectableText(
        task.diffStat,
        style: TextStyle(
          fontSize: 11,
          fontFamily: AppFonts.mono,
          color: colors['editor.foreground'],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final f in files)
              InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () => unawaited(_openDiffReview(task, isZh)),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.code,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: colors['widget.border'].withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _FileStatusTag(status: f.status),
                      const SizedBox(width: 4),
                      Text(
                        f.path,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: AppFonts.mono,
                          color: colors['foreground'],
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (f.added > 0)
                        Text(
                          '+${f.added}',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontFamily: AppFonts.mono,
                            color: const Color(0xFF3FB950),
                          ),
                        ),
                      if (f.removed > 0) ...[
                        const SizedBox(width: 3),
                        Text(
                          '-${f.removed}',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontFamily: AppFonts.mono,
                            color: const Color(0xFFE5534B),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: SingleChildScrollView(
            child: _UnifiedDiffFileBody(file: files.first, compact: true),
          ),
        ),
        if (files.length > 1) ...[
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => unawaited(_openDiffReview(task, isZh)),
              child: Text(
                isZh
                    ? '还有 ${files.length - 1} 个文件未展开 — 点击打开完整 Diff 审阅视图 →'
                    : '${files.length - 1} more files — open full Diff review →',
                style: const TextStyle(fontSize: 11.5),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildLogPreview(WorktreeTask task, bool isZh) {
    final colors = themeColors;
    if (task.log.trim().isEmpty) {
      return Text(
        isZh ? '暂无执行日志。' : 'No log output yet.',
        style: TextStyle(
          fontSize: 11.5,
          color: colors['descriptionForeground'],
        ),
      );
    }
    return Container(
      constraints: const BoxConstraints(maxHeight: 240),
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
    );
  }

  Widget _buildInfoPreview(WorktreeTask task, bool isZh) {
    final colors = themeColors;
    TextStyle labelStyle() => TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: colors['descriptionForeground'],
    );
    TextStyle valStyle({bool mono = false}) => TextStyle(
      fontSize: 11.5,
      fontFamily: mono ? AppFonts.mono : null,
      color: colors['foreground'],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(isZh ? '任务提示词' : 'Prompt', style: labelStyle()),
        const SizedBox(height: 3),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.code,
            borderRadius: BorderRadius.circular(4),
          ),
          child: SelectableText(task.prompt, style: valStyle()),
        ),
        const SizedBox(height: 8),
        SelectableText(
          '${isZh ? '目标仓库' : 'Repo'}: ${task.repoPath}',
          style: valStyle(mono: true),
        ),
        if (task.worktreePath.isNotEmpty)
          SelectableText(
            'Worktree: ${task.worktreePath}',
            style: valStyle(mono: true),
          ),
        if (task.baseCommit.isNotEmpty)
          SelectableText(
            'Base Commit: ${task.baseCommit.substring(0, math.min(12, task.baseCommit.length))}',
            style: valStyle(mono: true),
          ),
      ],
    );
  }
}

/// Dedicated modal Diff Review dialog supporting file navigation, Unified &
/// Side-by-Side modes, live Diff refresh, handoff to chat, and Approve & Merge.
class _TaskDiffReviewDialog extends StatefulWidget {
  const _TaskDiffReviewDialog({
    required this.taskId,
    required this.isZh,
    required this.onApproveAndMerge,
    this.onHandOff,
  });

  final String taskId;
  final bool isZh;
  final Future<({bool ok, String message})> Function() onApproveAndMerge;
  final Future<void> Function()? onHandOff;

  @override
  State<_TaskDiffReviewDialog> createState() => _TaskDiffReviewDialogState();
}

class _TaskDiffReviewDialogState extends State<_TaskDiffReviewDialog> {
  int _selectedFileIndex = 0;
  bool _sideBySide = false;
  bool _merging = false;
  String? _mergeError;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final colors = themeColors;
    final isZh = widget.isZh;

    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      backgroundColor: colors['editor.background'],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors['widget.border']),
      ),
      child: SizedBox(
        width: math.min(1200, size.width * 0.92),
        height: math.min(780, size.height * 0.86),
        child: ListenableBuilder(
          listenable: TaskQueueService.instance,
          builder: (context, _) {
            final task = TaskQueueService.instance.byId(widget.taskId);
            if (task == null) {
              return Center(
                child: Text(isZh ? '任务不存在' : 'Task not found'),
              );
            }
            final files = TaskDiffParser.parse(task.diffText);
            final clampedIdx = files.isEmpty
                ? 0
                : _selectedFileIndex.clamp(0, files.length - 1);
            final currentFile = files.isEmpty ? null : files[clampedIdx];
            final summary = TaskDiffParser.summarize(files);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header toolbar
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: colors['widget.border'].withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Codicons.diff,
                        size: 16,
                        color: colors['foreground'],
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              task.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: colors['foreground'],
                              ),
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                if (task.branchName.isNotEmpty) ...[
                                  Flexible(
                                    child: Text(
                                      task.branchName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontFamily: AppFonts.mono,
                                        color: colors['descriptionForeground'],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                _DiffStatChip(
                                  files: summary.files,
                                  added: summary.added,
                                  removed: summary.removed,
                                  isZh: isZh,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      // Unified / Side-by-Side toggle
                      IdeButton(
                        label: _sideBySide
                            ? (isZh ? '并排对比' : 'Split')
                            : (isZh ? '统一视图' : 'Unified'),
                        icon: _sideBySide
                            ? Codicons.splitHorizontal
                            : Codicons.listFlat,
                        secondary: true,
                        onPressed: () =>
                            setState(() => _sideBySide = !_sideBySide),
                      ),
                      if (task.status != WorktreeTaskStatus.merged &&
                          task.status != WorktreeTaskStatus.running) ...[
                        const SizedBox(width: 6),
                        IdeButton(
                          label: isZh ? '刷新' : 'Refresh',
                          icon: Codicons.refresh,
                          secondary: true,
                          onPressed: () => unawaited(
                            TaskQueueService.instance.refreshTaskDiff(task.id),
                          ),
                        ),
                      ],
                      if (widget.onHandOff != null) ...[
                        const SizedBox(width: 6),
                        IdeButton(
                          label: isZh ? '接管到对话' : 'Hand Off to Chat',
                          icon: Codicons.commentDiscussion,
                          secondary: true,
                          onPressed: () => unawaited(widget.onHandOff!()),
                        ),
                      ],
                      if (task.status == WorktreeTaskStatus.review) ...[
                        const SizedBox(width: 6),
                        IdeButton(
                          label: _merging
                              ? (isZh ? '合并中…' : 'Merging…')
                              : (isZh ? '批准并合并' : 'Approve & Merge'),
                          icon: Codicons.gitMerge,
                          spinning: _merging,
                          onPressed: _merging
                              ? null
                              : () async {
                                  setState(() {
                                    _merging = true;
                                    _mergeError = null;
                                  });
                                  final res = await widget.onApproveAndMerge();
                                  if (!mounted) return;
                                  if (res.ok) {
                                    Navigator.of(this.context).pop();
                                  } else {
                                    setState(() {
                                      _merging = false;
                                      _mergeError = res.message;
                                    });
                                  }
                                },
                        ),
                      ],
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: isZh ? '关闭' : 'Close',
                        icon: Icon(
                          Codicons.close,
                          size: 16,
                          color: colors['descriptionForeground'],
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                if (_mergeError != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                    child: _StatusBanner(
                      message: _mergeError!,
                      tone: _StatusTone.error,
                      onDismiss: () => setState(() => _mergeError = null),
                    ),
                  ),
                // Main split view: left file list, right diff body
                Expanded(
                  child: files.isEmpty
                      ? Center(
                          child: Text(
                            task.diffStat.isNotEmpty
                                ? task.diffStat
                                : (isZh
                                      ? '未检测到代码改动。'
                                      : 'No code changes detected.'),
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: AppFonts.mono,
                              color: colors['descriptionForeground'],
                            ),
                          ),
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // File list sidebar
                            Container(
                              width: 260,
                              decoration: BoxDecoration(
                                color: colors['sideBar.background'].withValues(
                                  alpha: 0.55,
                                ),
                                border: Border(
                                  right: BorderSide(
                                    color: colors['widget.border'].withValues(
                                      alpha: 0.45,
                                    ),
                                  ),
                                ),
                              ),
                              child: ListView.builder(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 6,
                                ),
                                itemCount: files.length,
                                itemBuilder: (context, i) {
                                  final f = files[i];
                                  final selected = i == clampedIdx;
                                  return InkWell(
                                    onTap: () =>
                                        setState(() => _selectedFileIndex = i),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 7,
                                      ),
                                      color: selected
                                          ? colors['list.activeSelectionBackground']
                                                .withValues(alpha: 0.35)
                                          : Colors.transparent,
                                      child: Row(
                                        children: [
                                          _FileStatusTag(status: f.status),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  p.basename(f.path),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: selected
                                                        ? FontWeight.w600
                                                        : FontWeight.w400,
                                                    color: colors['foreground'],
                                                  ),
                                                ),
                                                if (p.dirname(f.path) != '.')
                                                  Text(
                                                    p.dirname(f.path),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 10.5,
                                                      color: colors[
                                                          'descriptionForeground'],
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.end,
                                            children: [
                                              if (f.added > 0)
                                                Text(
                                                  '+${f.added}',
                                                  style: TextStyle(
                                                    fontSize: 10.5,
                                                    fontFamily: AppFonts.mono,
                                                    color: const Color(0xFF3FB950),
                                                  ),
                                                ),
                                              if (f.removed > 0)
                                                Text(
                                                  '-${f.removed}',
                                                  style: TextStyle(
                                                    fontSize: 10.5,
                                                    fontFamily: AppFonts.mono,
                                                    color: const Color(0xFFE5534B),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            // Selected file diff pane
                            Expanded(
                              child: currentFile == null
                                  ? const SizedBox.shrink()
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 7,
                                          ),
                                          decoration: BoxDecoration(
                                            color: AppColors.code,
                                            border: Border(
                                              bottom: BorderSide(
                                                color: colors['widget.border']
                                                    .withValues(alpha: 0.4),
                                              ),
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              _FileStatusTag(
                                                status: currentFile.status,
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: SelectableText(
                                                  currentFile.oldPath != null &&
                                                          currentFile.status ==
                                                              TaskDiffFileStatus
                                                                  .renamed
                                                      ? '${currentFile.oldPath} → ${currentFile.path}'
                                                      : currentFile.path,
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontFamily: AppFonts.mono,
                                                    fontWeight: FontWeight.w600,
                                                    color: colors['foreground'],
                                                  ),
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: isZh
                                                    ? '复制文件路径'
                                                    : 'Copy path',
                                                icon: Icon(
                                                  Codicons.copy,
                                                  size: 13.5,
                                                  color: colors[
                                                      'descriptionForeground'],
                                                ),
                                                onPressed: () => unawaited(
                                                  Clipboard.setData(
                                                    ClipboardData(
                                                      text: currentFile.path,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Expanded(
                                          child: SingleChildScrollView(
                                            padding: const EdgeInsets.all(10),
                                            child: _sideBySide
                                                ? _SplitDiffFileBody(
                                                    file: currentFile,
                                                  )
                                                : _UnifiedDiffFileBody(
                                                    file: currentFile,
                                                  ),
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _UnifiedDiffFileBody extends StatelessWidget {
  const _UnifiedDiffFileBody({required this.file, this.compact = false});

  final TaskDiffFile file;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    if (file.isBinary) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.code,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          'Binary file changed: ${file.path}',
          style: TextStyle(
            fontSize: 11.5,
            fontFamily: AppFonts.mono,
            color: colors['descriptionForeground'],
          ),
        ),
      );
    }
    if (file.hunks.isEmpty) {
      return Text(
        file.path,
        style: TextStyle(
          fontSize: 11.5,
          fontFamily: AppFonts.mono,
          color: colors['descriptionForeground'],
        ),
      );
    }

    final fontSize = compact ? 11.0 : 12.0;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.code,
        borderRadius: BorderRadius.circular(4),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final hunk in file.hunks) ...[
                Container(
                  width: compact ? 800 : 1100,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  color: const Color(0xFF58A6FF).withValues(alpha: 0.12),
                  child: Text(
                    hunk.header,
                    style: TextStyle(
                      fontSize: fontSize,
                      fontFamily: AppFonts.mono,
                      color: const Color(0xFF58A6FF),
                    ),
                  ),
                ),
                for (final line in hunk.lines)
                  _UnifiedLineRow(
                    line: line,
                    fontSize: fontSize,
                    minWidth: compact ? 800 : 1100,
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _UnifiedLineRow extends StatelessWidget {
  const _UnifiedLineRow({
    required this.line,
    required this.fontSize,
    required this.minWidth,
  });

  final TaskDiffLine line;
  final double fontSize;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final bg = switch (line.kind) {
      TaskDiffLineKind.added => const Color(0xFF2EA043).withValues(alpha: 0.18),
      TaskDiffLineKind.removed =>
        const Color(0xFFF85149).withValues(alpha: 0.18),
      TaskDiffLineKind.context || TaskDiffLineKind.meta => Colors.transparent,
    };
    final prefix = switch (line.kind) {
      TaskDiffLineKind.added => '+',
      TaskDiffLineKind.removed => '-',
      TaskDiffLineKind.context => ' ',
      TaskDiffLineKind.meta => ' ',
    };
    final prefixColor = switch (line.kind) {
      TaskDiffLineKind.added => const Color(0xFF3FB950),
      TaskDiffLineKind.removed => const Color(0xFFE5534B),
      TaskDiffLineKind.context || TaskDiffLineKind.meta =>
        colors['descriptionForeground'],
    };

    return Container(
      constraints: BoxConstraints(minWidth: minWidth),
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 38,
            child: Text(
              line.oldLine?.toString() ?? '',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: fontSize - 0.5,
                fontFamily: AppFonts.mono,
                color: colors['descriptionForeground'].withValues(alpha: 0.7),
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 38,
            child: Text(
              line.newLine?.toString() ?? '',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: fontSize - 0.5,
                fontFamily: AppFonts.mono,
                color: colors['descriptionForeground'].withValues(alpha: 0.7),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            prefix,
            style: TextStyle(
              fontSize: fontSize,
              fontFamily: AppFonts.mono,
              fontWeight: FontWeight.w700,
              color: prefixColor,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            line.text,
            style: TextStyle(
              fontSize: fontSize,
              fontFamily: AppFonts.mono,
              color: line.kind == TaskDiffLineKind.meta
                  ? colors['descriptionForeground']
                  : colors['editor.foreground'],
            ),
          ),
        ],
      ),
    );
  }
}

class _SplitDiffFileBody extends StatelessWidget {
  const _SplitDiffFileBody({required this.file});

  final TaskDiffFile file;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    if (file.isBinary) {
      return Text(
        'Binary file changed: ${file.path}',
        style: TextStyle(
          fontSize: 12,
          fontFamily: AppFonts.mono,
          color: colors['descriptionForeground'],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.code,
        borderRadius: BorderRadius.circular(4),
      ),
      child: SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final hunk in file.hunks) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                color: const Color(0xFF58A6FF).withValues(alpha: 0.12),
                child: Text(
                  hunk.header,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontFamily: AppFonts.mono,
                    color: const Color(0xFF58A6FF),
                  ),
                ),
              ),
              for (final row in hunk.toSplitRows())
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _SplitCell(line: row.left, isLeft: true)),
                      Container(
                        width: 1,
                        color: colors['widget.border'].withValues(alpha: 0.35),
                      ),
                      Expanded(
                        child: _SplitCell(line: row.right, isLeft: false),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SplitCell extends StatelessWidget {
  const _SplitCell({required this.line, required this.isLeft});

  final TaskDiffLine? line;
  final bool isLeft;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final l = line;
    if (l == null) {
      return Container(
        color: colors['sideBar.background'].withValues(alpha: 0.25),
      );
    }
    final bg = switch (l.kind) {
      TaskDiffLineKind.added => const Color(0xFF2EA043).withValues(alpha: 0.18),
      TaskDiffLineKind.removed =>
        const Color(0xFFF85149).withValues(alpha: 0.18),
      TaskDiffLineKind.context || TaskDiffLineKind.meta => Colors.transparent,
    };
    final lineNo = isLeft ? l.oldLine : l.newLine;
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 34,
            child: Text(
              lineNo?.toString() ?? '',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11,
                fontFamily: AppFonts.mono,
                color: colors['descriptionForeground'].withValues(alpha: 0.7),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l.text,
              style: TextStyle(
                fontSize: 11.5,
                fontFamily: AppFonts.mono,
                color: colors['editor.foreground'],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactDropdown<T> extends StatelessWidget {
  const _CompactDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    this.maxWidth,
  });

  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    Widget dropdown = DropdownButton<T>(
      value: value,
      isDense: true,
      isExpanded: maxWidth != null,
      underline: const SizedBox.shrink(),
      dropdownColor: colors['editor.background'],
      style: TextStyle(fontSize: 12, color: colors['foreground']),
      items: items,
      onChanged: onChanged,
    );
    if (maxWidth != null) {
      dropdown = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth!),
        child: dropdown,
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: colors['input.background'],
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colors['input.border']),
      ),
      child: dropdown,
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.message,
    required this.tone,
    required this.onDismiss,
  });

  final String message;
  final _StatusTone tone;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final accent = switch (tone) {
      _StatusTone.info => const Color(0xFF58A6FF),
      _StatusTone.success => const Color(0xFF3FB950),
      _StatusTone.error => const Color(0xFFE5534B),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: accent.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              message,
              style: TextStyle(fontSize: 11.5, color: accent),
            ),
          ),
          InkWell(
            onTap: onDismiss,
            child: Icon(Codicons.close, size: 13, color: accent),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: selected
              ? colors['button.background'].withValues(alpha: 0.2)
              : colors['editor.background'],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? colors['button.background'].withValues(alpha: 0.55)
                : colors['widget.border'].withValues(alpha: 0.4),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected
                ? colors['button.background']
                : colors['descriptionForeground'],
          ),
        ),
      ),
    );
  }
}

class _DetailTabButton extends StatelessWidget {
  const _DetailTabButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: selected
              ? colors['button.background'].withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 12.5,
              color: selected
                  ? colors['button.background']
                  : colors['descriptionForeground'],
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? colors['button.background']
                    : colors['descriptionForeground'],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.text, this.icon, this.mono = false});

  final String text;
  final IconData? icon;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors['editor.background'].withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: colors['widget.border'].withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: colors['descriptionForeground']),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 10.5,
              fontFamily: mono ? AppFonts.mono : null,
              color: colors['descriptionForeground'],
            ),
          ),
        ],
      ),
    );
  }
}

class _SmallBadge extends StatelessWidget {
  const _SmallBadge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _DiffStatChip extends StatelessWidget {
  const _DiffStatChip({
    required this.files,
    required this.added,
    required this.removed,
    required this.isZh,
  });

  final int files;
  final int added;
  final int removed;
  final bool isZh;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.code,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: colors['widget.border'].withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isZh ? '$files 文件' : '$files files',
            style: TextStyle(
              fontSize: 10.5,
              color: colors['descriptionForeground'],
            ),
          ),
          if (added > 0) ...[
            const SizedBox(width: 5),
            Text(
              '+$added',
              style: TextStyle(
                fontSize: 10.5,
                fontFamily: AppFonts.mono,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF3FB950),
              ),
            ),
          ],
          if (removed > 0) ...[
            const SizedBox(width: 4),
            Text(
              '-$removed',
              style: TextStyle(
                fontSize: 10.5,
                fontFamily: AppFonts.mono,
                fontWeight: FontWeight.w600,
                color: const Color(0xFFE5534B),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FileStatusTag extends StatelessWidget {
  const _FileStatusTag({required this.status});

  final TaskDiffFileStatus status;

  @override
  Widget build(BuildContext context) {
    final (letter, color) = switch (status) {
      TaskDiffFileStatus.added => ('A', const Color(0xFF3FB950)),
      TaskDiffFileStatus.modified => const ('M', Color(0xFFD29922)),
      TaskDiffFileStatus.deleted => const ('D', Color(0xFFE5534B)),
      TaskDiffFileStatus.renamed => const ('R', Color(0xFF58A6FF)),
    };
    return Container(
      width: 16,
      height: 16,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        letter,
        style: TextStyle(
          fontSize: 10,
          fontFamily: AppFonts.mono,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
