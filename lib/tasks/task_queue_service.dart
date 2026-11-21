import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../acp/acp_agent_service.dart';
import '../canvas/canvas_controller.dart';
import '../platform/data_dir.dart';

enum WorktreeTaskStatus {
  queued,
  running,
  review,
  merged,
  failed,
  cancelled;

  static WorktreeTaskStatus parse(Object? raw) =>
      values.asNameMap()[raw] ?? queued;

  String label({required bool zh}) => switch (this) {
    queued => zh ? '待执行' : 'Queued',
    running => zh ? '执行中' : 'Running',
    review => zh ? '待审阅' : 'Review',
    merged => zh ? '已合并' : 'Merged',
    failed => zh ? '失败' : 'Failed',
    cancelled => zh ? '已取消' : 'Cancelled',
  };
}

class WorktreeTask {
  WorktreeTask({
    required this.id,
    required this.title,
    required this.prompt,
    required this.repoPath,
    this.agentId = 'agy',
    this.useWorktree = true,
    this.workflowTemplateId,
    this.branchName = '',
    this.worktreePath = '',
    this.status = WorktreeTaskStatus.queued,
    DateTime? createdAt,
    this.startedAt,
    this.finishedAt,
    this.log = '',
    this.diffStat = '',
    this.diffText = '',
    this.error,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String title;
  final String prompt;
  final String repoPath;
  final String agentId;

  /// Whether to create an isolated git worktree (`true`) or run directly inside
  /// [repoPath] (`false`, ideal for serial `:4200` build & verification).
  final bool useWorktree;

  /// Optional canvas workflow template id (or
  /// [CanvasController.currentCanvasTemplateId]); when non-null, runs the DAG
  /// workflow instead of a single headless prompt.
  final String? workflowTemplateId;
  String branchName;
  String worktreePath;
  WorktreeTaskStatus status;
  final DateTime createdAt;
  DateTime? startedAt;
  DateTime? finishedAt;
  String log;
  String diffStat;
  String diffText;
  String? error;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'prompt': prompt,
    'repoPath': repoPath,
    'agentId': agentId,
    'useWorktree': useWorktree,
    if (workflowTemplateId != null) 'workflowTemplateId': workflowTemplateId,
    'branchName': branchName,
    'worktreePath': worktreePath,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'startedAt': startedAt?.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'log': log,
    'diffStat': diffStat,
    'diffText': diffText,
    'error': error,
  };

  static WorktreeTask? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'] as String?;
    final title = raw['title'] as String?;
    final prompt = raw['prompt'] as String?;
    final repoPath = raw['repoPath'] as String?;
    if (id == null || title == null || prompt == null || repoPath == null) {
      return null;
    }
    var status = WorktreeTaskStatus.parse(raw['status']);
    // Any task left in `running` from a previous app crash returns to `queued`.
    if (status == WorktreeTaskStatus.running) status = WorktreeTaskStatus.queued;
    return WorktreeTask(
      id: id,
      title: title,
      prompt: prompt,
      repoPath: repoPath,
      agentId: raw['agentId'] as String? ?? 'agy',
      useWorktree: raw['useWorktree'] as bool? ?? true,
      workflowTemplateId: raw['workflowTemplateId'] as String?,
      branchName: raw['branchName'] as String? ?? '',
      worktreePath: raw['worktreePath'] as String? ?? '',
      status: status,
      createdAt:
          DateTime.tryParse(raw['createdAt'] as String? ?? '') ??
          DateTime.now(),
      startedAt: DateTime.tryParse(raw['startedAt'] as String? ?? ''),
      finishedAt: DateTime.tryParse(raw['finishedAt'] as String? ?? ''),
      log: raw['log'] as String? ?? '',
      diffStat: raw['diffStat'] as String? ?? '',
      diffText: raw['diffText'] as String? ?? '',
      error: raw['error'] as String?,
    );
  }
}

/// Manages unattended background coding tasks running in isolated Git worktrees
/// up to [maxConcurrency], always landing in a mandatory `Review` state before
/// merging back into the main branch.
class TaskQueueService extends ChangeNotifier {
  TaskQueueService._();
  static final instance = TaskQueueService._();

  @visibleForTesting
  String? storagePathOverride;

  final List<WorktreeTask> _tasks = [];
  int _maxConcurrency = 2;
  bool _autoDispatch = false;
  bool _loaded = false;
  final Map<String, Process> _runningProcesses = {};
  final Map<String, int> _runningWorkflowRunIds = {};

  List<WorktreeTask> get tasks => List.unmodifiable(_tasks);
  int get maxConcurrency => _maxConcurrency;
  bool get autoDispatch => _autoDispatch;
  int get runningCount =>
      _tasks.where((t) => t.status == WorktreeTaskStatus.running).length;
  int get reviewCount =>
      _tasks.where((t) => t.status == WorktreeTaskStatus.review).length;

  String get _filePath =>
      storagePathOverride ?? p.join(DataDirectory.current.path, 'tasks.json');

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = File(_filePath);
      if (!file.existsSync()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      if (decoded['maxConcurrency'] case final num c) {
        _maxConcurrency = c.toInt().clamp(1, 4);
      }
      if (decoded['autoDispatch'] case final bool auto) {
        _autoDispatch = auto;
      }
      if (decoded['tasks'] case final List rawTasks) {
        _tasks.clear();
        for (final item in rawTasks) {
          if (WorktreeTask.fromJson(item) case final t?) _tasks.add(t);
        }
      }
      notifyListeners();
    } on Object catch (e) {
      debugPrint('TaskQueueService load failed: $e');
    }
  }

  Future<void> _save() async {
    if (Platform.environment.containsKey('FLUTTER_TEST') &&
        storagePathOverride == null) {
      return;
    }
    try {
      final file = File(_filePath);
      file.parent.createSync(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'maxConcurrency': _maxConcurrency,
          'autoDispatch': _autoDispatch,
          'tasks': [for (final t in _tasks) t.toJson()],
        }),
      );
    } on Object catch (e) {
      debugPrint('TaskQueueService save failed: $e');
    }
  }

  void setMaxConcurrency(int count) {
    _maxConcurrency = count.clamp(1, 4);
    notifyListeners();
    unawaited(_save());
    if (_autoDispatch) unawaited(dispatchPending());
  }

  void setAutoDispatch(bool on) {
    _autoDispatch = on;
    notifyListeners();
    unawaited(_save());
    if (on) unawaited(dispatchPending());
  }

  WorktreeTask enqueue({
    required String title,
    required String prompt,
    required String repoPath,
    String agentId = 'agy',
    bool useWorktree = true,
    String? workflowTemplateId,
  }) {
    final id = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final task = WorktreeTask(
      id: id,
      title: title.trim().isEmpty ? prompt.trim().split('\n').first : title.trim(),
      prompt: prompt.trim(),
      repoPath: repoPath.trim(),
      agentId: agentId,
      useWorktree: useWorktree,
      workflowTemplateId: workflowTemplateId,
    );
    _tasks.insert(0, task);
    notifyListeners();
    unawaited(_save());
    if (_autoDispatch) unawaited(dispatchPending());
    return task;
  }

  Future<void> dispatchPending() async {
    while (runningCount < _maxConcurrency) {
      WorktreeTask? next;
      for (final t in _tasks.reversed) {
        if (t.status == WorktreeTaskStatus.queued) {
          next = t;
          break;
        }
      }
      if (next == null) break;
      unawaited(runTask(next.id));
    }
  }

  WorktreeTask? byId(String id) {
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<void> runTask(String taskId) async {
    final task = byId(taskId);
    if (task == null || task.status == WorktreeTaskStatus.running) return;
    task.status = WorktreeTaskStatus.running;
    task.startedAt = DateTime.now();
    task.error = null;
    task.log = '[Ayte] Preparing isolated git worktree...\n';
    notifyListeners();
    unawaited(_save());

    try {
      final isGitRepo = task.useWorktree && await _isGitRepository(task.repoPath);
      String runDir = task.repoPath;
      if (isGitRepo) {
        final branch = 'ayte/task-${task.id}';
        final wtRoot = p.join(
          DataDirectory.current.path,
          'worktrees',
          'task-${task.id}',
        );
        Directory(p.dirname(wtRoot)).createSync(recursive: true);
        final addRes = await Process.run(
          'git',
          ['worktree', 'add', '-b', branch, wtRoot, 'HEAD'],
          workingDirectory: task.repoPath,
        );
        if (addRes.exitCode != 0) {
          throw StateError(
            'git worktree add failed: ${addRes.stderr}'.trim(),
          );
        }
        task.branchName = branch;
        task.worktreePath = wtRoot;
        runDir = wtRoot;
        task.log += '[Ayte] Worktree created at $wtRoot ($branch)\n';
      } else {
        task.log += task.useWorktree
            ? '[Ayte] Directory is not a git repo; running directly in ${task.repoPath}\n'
            : '[Ayte] Reusing current workspace directly: ${task.repoPath}\n';
      }
      notifyListeners();

      final ({bool ok, String? error}) result;
      if (task.workflowTemplateId case final wfId? when wfId.isNotEmpty) {
        final wfRes = await CanvasController.instance.runWorkflow(
          templateId: wfId,
          defaultCwd: runDir,
          selectOnStart: false,
          runName: task.title,
          onRunStarted: (runId) => _runningWorkflowRunIds[task.id] = runId,
          inputs: {
            'bugId': task.title,
            'prompt': task.prompt,
            'repo': runDir,
          },
          onLogChunk: (chunk) {
            task.log += chunk;
            if (task.log.length > 60000) {
              task.log = task.log.substring(task.log.length - 60000);
            }
            notifyListeners();
          },
        );
        _runningWorkflowRunIds.remove(task.id);
        result = (ok: wfRes.ok, error: wfRes.error);
      } else {
        final agentRes = await AcpAgentService.instance.runHeadlessPrompt(
          agentId: task.agentId,
          prompt: task.prompt,
          cwd: runDir,
          onChunk: (chunk) {
            task.log += chunk;
            if (task.log.length > 60000) {
              task.log = task.log.substring(task.log.length - 60000);
            }
            notifyListeners();
          },
          onProcessStarted: (proc) => _runningProcesses[task.id] = proc,
        );
        _runningProcesses.remove(task.id);
        result = (ok: agentRes.ok, error: agentRes.error);
      }

      if (task.status == WorktreeTaskStatus.cancelled) {
        task.finishedAt = DateTime.now();
        notifyListeners();
        unawaited(_save());
        return;
      }

      if (!result.ok) {
        task.status = WorktreeTaskStatus.failed;
        task.error = result.error ?? 'Agent exited with non-zero code.';
        task.finishedAt = DateTime.now();
      } else {
        // Capture git diff in the isolated worktree for mandatory Review.
        if (task.worktreePath.isNotEmpty) {
          final statusRes = await Process.run(
            'git',
            ['status', '--short'],
            workingDirectory: task.worktreePath,
          );
          final statRes = await Process.run(
            'git',
            ['diff', '--stat'],
            workingDirectory: task.worktreePath,
          );
          final diffRes = await Process.run(
            'git',
            ['diff'],
            workingDirectory: task.worktreePath,
          );
          task.diffStat = '${statusRes.stdout}\n${statRes.stdout}'.trim();
          final rawDiff = '${diffRes.stdout}';
          task.diffText = rawDiff.length > 30000
              ? '${rawDiff.substring(0, 30000)}\n... (truncated)'
              : rawDiff;
        }
        task.status = WorktreeTaskStatus.review;
        task.finishedAt = DateTime.now();
      }
    } on Object catch (e) {
      _runningProcesses.remove(task.id);
      _runningWorkflowRunIds.remove(task.id);
      task.status = WorktreeTaskStatus.failed;
      task.error = '$e';
      task.log += '\n[Error] $e\n';
      task.finishedAt = DateTime.now();
    }

    notifyListeners();
    await _save();
    if (_autoDispatch) unawaited(dispatchPending());
  }

  Future<void> cancelTask(String taskId) async {
    final task = byId(taskId);
    if (task == null) return;
    _runningProcesses.remove(taskId)?.kill();
    if (_runningWorkflowRunIds.remove(taskId) case final runId?) {
      CanvasController.instance.stopWorkflow(runId: runId);
    }
    task.status = WorktreeTaskStatus.cancelled;
    task.finishedAt = DateTime.now();
    notifyListeners();
    await _save();
  }

  /// Commits any uncommitted worktree changes onto the task branch, merges the
  /// branch into the main repo, and cleans up the worktree.
  Future<({bool ok, String message})> approveAndMerge(String taskId) async {
    final task = byId(taskId);
    if (task == null) return (ok: false, message: 'Task not found');
    if (task.worktreePath.isEmpty || task.branchName.isEmpty) {
      task.status = WorktreeTaskStatus.merged;
      notifyListeners();
      await _save();
      return (ok: true, message: 'Marked completed');
    }
    try {
      // Stage and commit uncommitted edits in the task worktree.
      await Process.run(
        'git',
        ['add', '-A'],
        workingDirectory: task.worktreePath,
      );
      await Process.run(
        'git',
        ['commit', '-m', 'Ayte task: ${task.title}'],
        workingDirectory: task.worktreePath,
      );
      final mergeRes = await Process.run(
        'git',
        ['merge', '--no-ff', task.branchName, '-m', 'Merge ${task.branchName}'],
        workingDirectory: task.repoPath,
      );
      if (mergeRes.exitCode != 0) {
        return (
          ok: false,
          message: 'Merge failed: ${mergeRes.stderr}\n${mergeRes.stdout}'.trim(),
        );
      }
      await _cleanupWorktree(task);
      task.status = WorktreeTaskStatus.merged;
      notifyListeners();
      await _save();
      return (ok: true, message: 'Merged ${task.branchName} successfully.');
    } on Object catch (e) {
      return (ok: false, message: '$e');
    }
  }

  /// Discards the task worktree & branch without merging.
  Future<void> discardTask(String taskId) async {
    final task = byId(taskId);
    if (task == null) return;
    _runningProcesses.remove(taskId)?.kill();
    if (_runningWorkflowRunIds.remove(taskId) case final runId?) {
      CanvasController.instance.stopWorkflow(runId: runId);
    }
    await _cleanupWorktree(task);
    _tasks.removeWhere((t) => t.id == taskId);
    notifyListeners();
    await _save();
  }

  Future<void> _cleanupWorktree(WorktreeTask task) async {
    if (task.worktreePath.isNotEmpty) {
      try {
        await Process.run(
          'git',
          ['worktree', 'remove', '--force', task.worktreePath],
          workingDirectory: task.repoPath,
        );
      } on Object {
        // Ignore cleanup errors.
      }
    }
    if (task.branchName.isNotEmpty) {
      try {
        await Process.run(
          'git',
          ['branch', '-D', task.branchName],
          workingDirectory: task.repoPath,
        );
      } on Object {
        // Ignore cleanup errors.
      }
    }
  }

  Future<bool> _isGitRepository(String dir) async {
    if (dir.isEmpty || !Directory(dir).existsSync()) return false;
    try {
      final res = await Process.run(
        'git',
        ['rev-parse', '--is-inside-work-tree'],
        workingDirectory: dir,
      );
      return res.exitCode == 0 && '${res.stdout}'.trim() == 'true';
    } on Object {
      return false;
    }
  }
}
