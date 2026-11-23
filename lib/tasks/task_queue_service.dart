import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../acp/acp_agent_service.dart';
import '../canvas/canvas_controller.dart';
import '../kernel/antigravity/antigravity_cli.dart'
    show antigravityBuiltinProviderId;
import '../kernel/codebuddy/codebuddy_cli.dart' show codebuddyBuiltinProviderId;
import '../kernel/kernel_registry.dart' show claudeCodeKernelId, codexKernelId;
import '../platform/data_dir.dart';
import 'task_diff_parser.dart';

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
    this.model,
    this.effort,
    this.useWorktree = true,
    this.workflowTemplateId,
    this.branchName = '',
    this.worktreePath = '',
    this.baseCommit = '',
    this.status = WorktreeTaskStatus.queued,
    DateTime? createdAt,
    this.startedAt,
    this.finishedAt,
    this.log = '',
    this.diffStat = '',
    this.diffText = '',
    this.filesChanged = 0,
    this.linesAdded = 0,
    this.linesRemoved = 0,
    this.hasLog = false,
    this.hasDiff = false,
    this.error,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  String title;
  String prompt;
  String repoPath;
  String agentId;

  /// Optional model ID override for [agentId]; null/empty uses kernel default.
  String? model;

  /// Optional reasoning effort override (`low`, `medium`, `high`, `xhigh`, `max`).
  String? effort;

  /// Whether to create an isolated git worktree (`true`) or run directly inside
  /// [repoPath] (`false`, ideal for serial `:4200` build & verification).
  bool useWorktree;

  /// Optional canvas workflow template id (or
  /// [CanvasController.currentCanvasTemplateId]); when non-null, runs the DAG
  /// workflow instead of a single headless prompt.
  String? workflowTemplateId;
  String branchName;
  String worktreePath;

  /// Exact commit SHA recorded when the worktree/task started so diffs capture
  /// committed, staged, unstaged, and newly created untracked files.
  String baseCommit;
  WorktreeTaskStatus status;
  final DateTime createdAt;
  DateTime? startedAt;
  DateTime? finishedAt;

  /// Execution log in memory (persisted externally in `tasks/<id>.log`).
  String log;
  String diffStat;

  /// Unified git diff in memory (persisted externally in `tasks/<id>.diff`).
  String diffText;
  int filesChanged;
  int linesAdded;
  int linesRemoved;
  bool hasLog;
  bool hasDiff;
  String? error;

  /// Whether external log/diff files have been hydrated into memory.
  bool _detailsLoaded = false;

  /// Elapsed duration of this task, if it has started.
  Duration? get elapsed {
    final start = startedAt;
    if (start == null) return null;
    final end = finishedAt ?? DateTime.now();
    final diff = end.difference(start);
    return diff.isNegative ? Duration.zero : diff;
  }

  /// Lightweight index metadata written into `tasks.json` (and returned by IPC).
  /// Large `log` and `diffText` bodies live in `tasks/<id>.log` & `.diff`.
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'prompt': prompt,
    'repoPath': repoPath,
    'agentId': agentId,
    if (model != null && model!.isNotEmpty) 'model': model,
    if (effort != null && effort!.isNotEmpty) 'effort': effort,
    'useWorktree': useWorktree,
    if (workflowTemplateId != null && workflowTemplateId!.isNotEmpty)
      'workflowTemplateId': workflowTemplateId,
    'branchName': branchName,
    'worktreePath': worktreePath,
    if (baseCommit.isNotEmpty) 'baseCommit': baseCommit,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'startedAt': startedAt?.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'diffStat': diffStat,
    'filesChanged': filesChanged,
    'linesAdded': linesAdded,
    'linesRemoved': linesRemoved,
    'hasLog': hasLog || log.isNotEmpty,
    'hasDiff': hasDiff || diffText.isNotEmpty,
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
    final inlineLog = raw['log'] as String? ?? '';
    final inlineDiff = raw['diffText'] as String? ?? '';
    var filesChanged = (raw['filesChanged'] as num?)?.toInt() ?? 0;
    var linesAdded = (raw['linesAdded'] as num?)?.toInt() ?? 0;
    var linesRemoved = (raw['linesRemoved'] as num?)?.toInt() ?? 0;
    if (inlineDiff.isNotEmpty &&
        filesChanged == 0 &&
        linesAdded == 0 &&
        linesRemoved == 0) {
      final summary = TaskDiffParser.summarize(TaskDiffParser.parse(inlineDiff));
      filesChanged = summary.files;
      linesAdded = summary.added;
      linesRemoved = summary.removed;
    }
    final task = WorktreeTask(
      id: id,
      title: title,
      prompt: prompt,
      repoPath: repoPath,
      agentId: raw['agentId'] as String? ?? 'agy',
      model: (raw['model'] as String?)?.trim(),
      effort: (raw['effort'] as String?)?.trim(),
      useWorktree: raw['useWorktree'] as bool? ?? true,
      workflowTemplateId: raw['workflowTemplateId'] as String?,
      branchName: raw['branchName'] as String? ?? '',
      worktreePath: raw['worktreePath'] as String? ?? '',
      baseCommit: raw['baseCommit'] as String? ?? '',
      status: status,
      createdAt:
          DateTime.tryParse(raw['createdAt'] as String? ?? '') ??
          DateTime.now(),
      startedAt: DateTime.tryParse(raw['startedAt'] as String? ?? ''),
      finishedAt: DateTime.tryParse(raw['finishedAt'] as String? ?? ''),
      log: inlineLog,
      diffStat: raw['diffStat'] as String? ?? '',
      diffText: inlineDiff,
      filesChanged: filesChanged,
      linesAdded: linesAdded,
      linesRemoved: linesRemoved,
      hasLog: (raw['hasLog'] as bool? ?? false) || inlineLog.isNotEmpty,
      hasDiff: (raw['hasDiff'] as bool? ?? false) || inlineDiff.isNotEmpty,
      error: raw['error'] as String?,
    );
    // Legacy tasks.json had inline log/diff already present in memory.
    if (inlineLog.isNotEmpty || inlineDiff.isNotEmpty) {
      task._detailsLoaded = true;
    }
    return task;
  }
}

/// Manages unattended background coding tasks running in isolated Git worktrees
/// up to [maxConcurrency], always landing in a mandatory `Review` state before
/// merging back into the main branch.
class TaskQueueService extends ChangeNotifier {
  TaskQueueService._();
  static final instance = TaskQueueService._();

  static const int maxLogChars = 200000;
  static const int maxDiffChars = 256000;

  @visibleForTesting
  String? storagePathOverride;

  final List<WorktreeTask> _tasks = [];
  int _maxConcurrency = 2;
  bool _autoDispatch = false;
  bool _loaded = false;
  int _idSeq = 0;

  final Map<String, Process> _runningProcesses = {};
  final Map<String, int> _runningWorkflowRunIds = {};
  final Map<String, Future<void>> _runningFutures = {};
  final Set<String> _cancellingIds = {};

  Future<void> _saveChain = Future<void>.value();
  Timer? _streamNotifyTimer;

  List<WorktreeTask> get tasks => List.unmodifiable(_tasks);
  int get maxConcurrency => _maxConcurrency;
  bool get autoDispatch => _autoDispatch;
  int get runningCount =>
      _tasks.where((t) => t.status == WorktreeTaskStatus.running).length;
  int get reviewCount =>
      _tasks.where((t) => t.status == WorktreeTaskStatus.review).length;

  String get _filePath =>
      storagePathOverride ?? p.join(DataDirectory.current.path, 'tasks.json');

  /// Directory storing external `<taskId>.log` and `<taskId>.diff` files so
  /// `tasks.json` stays compact and fast to serialize.
  String get _blobsDir => p.join(p.dirname(_filePath), 'tasks');

  @visibleForTesting
  String logFilePathFor(String taskId) => p.join(_blobsDir, '$taskId.log');

  @visibleForTesting
  String diffFilePathFor(String taskId) => p.join(_blobsDir, '$taskId.diff');

  bool get _persistenceSkipped =>
      Platform.environment.containsKey('FLUTTER_TEST') &&
      storagePathOverride == null;

  @visibleForTesting
  Future<void> flushForTest() => _saveChain;

  @visibleForTesting
  void resetForTest() {
    _streamNotifyTimer?.cancel();
    _streamNotifyTimer = null;
    _tasks.clear();
    _runningProcesses.clear();
    _runningWorkflowRunIds.clear();
    _runningFutures.clear();
    _cancellingIds.clear();
    _maxConcurrency = 2;
    _autoDispatch = false;
    _loaded = false;
    _idSeq = 0;
  }

  void _notifyStreamingThrottled() {
    if (_streamNotifyTimer != null) return;
    _streamNotifyTimer = Timer(const Duration(milliseconds: 80), () {
      _streamNotifyTimer = null;
      notifyListeners();
    });
  }

  void _notifyNow() {
    _streamNotifyTimer?.cancel();
    _streamNotifyTimer = null;
    notifyListeners();
  }

  String _nextTaskId() {
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    while (true) {
      final seq = (_idSeq++).toRadixString(36);
      final candidate = '$ts-$seq';
      if (byId(candidate) == null) return candidate;
    }
  }

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
      var needsMigrationSave = false;
      if (decoded['tasks'] case final List rawTasks) {
        _tasks.clear();
        for (final item in rawTasks) {
          if (WorktreeTask.fromJson(item) case final t?) {
            _tasks.add(t);
            // Migrate legacy inline log/diff fields to external files.
            if (item is Map &&
                ((item['log'] is String && (item['log'] as String).isNotEmpty) ||
                    (item['diffText'] is String &&
                        (item['diffText'] as String).isNotEmpty))) {
              needsMigrationSave = true;
              await _writeTaskBlobs(t);
            }
          }
        }
      }
      _notifyNow();
      if (needsMigrationSave) {
        await _save();
      }
    } on Object catch (e) {
      debugPrint('TaskQueueService load failed: $e');
    }
  }

  Future<void> _save() {
    if (_persistenceSkipped) return Future<void>.value();
    final payload = const JsonEncoder.withIndent('  ').convert({
      'maxConcurrency': _maxConcurrency,
      'autoDispatch': _autoDispatch,
      'tasks': [for (final t in _tasks) t.toJson()],
    });
    final targetPath = _filePath;
    _saveChain = _saveChain.then((_) async {
      try {
        final file = File(targetPath);
        await file.parent.create(recursive: true);
        await writeFileAtomically(file, payload);
      } on Object catch (e) {
        debugPrint('TaskQueueService save failed: $e');
      }
    });
    return _saveChain;
  }

  Future<void> _writeTaskBlobs(WorktreeTask task) async {
    if (_persistenceSkipped) return;
    final logPath = logFilePathFor(task.id);
    final diffPath = diffFilePathFor(task.id);
    final logContent = task.log;
    final diffContent = task.diffText;
    final dirPath = _blobsDir;
    _saveChain = _saveChain.then((_) async {
      try {
        if (logContent.isNotEmpty || diffContent.isNotEmpty) {
          await Directory(dirPath).create(recursive: true);
        }
        if (logContent.isNotEmpty) {
          await writeFileAtomically(File(logPath), logContent);
        }
        if (diffContent.isNotEmpty) {
          await writeFileAtomically(File(diffPath), diffContent);
        }
      } on Object catch (e) {
        debugPrint('TaskQueueService write blobs failed: $e');
      }
    });
    await _saveChain;
  }

  Future<void> _deleteTaskBlobs(String taskId) async {
    if (_persistenceSkipped) return;
    final logFile = File(logFilePathFor(taskId));
    final diffFile = File(diffFilePathFor(taskId));
    _saveChain = _saveChain.then((_) async {
      for (final file in [logFile, diffFile]) {
        try {
          if (await file.exists()) await file.delete();
        } on Object {
          // Ignore blob cleanup errors.
        }
      }
    });
    await _saveChain;
  }

  /// Lazily loads external `<id>.log` and `<id>.diff` into [task] if needed.
  Future<void> ensureTaskDetailsLoaded(String taskId) async {
    final task = byId(taskId);
    if (task == null || task._detailsLoaded) return;
    task._detailsLoaded = true;
    if (_persistenceSkipped) return;

    var changed = false;
    try {
      final logFile = File(logFilePathFor(taskId));
      if (task.log.isEmpty && await logFile.exists()) {
        task.log = await logFile.readAsString();
        task.hasLog = task.log.isNotEmpty;
        changed = true;
      }
    } on Object {
      // Ignore read errors.
    }
    try {
      final diffFile = File(diffFilePathFor(taskId));
      if (task.diffText.isEmpty && await diffFile.exists()) {
        task.diffText = await diffFile.readAsString();
        task.hasDiff = task.diffText.isNotEmpty;
        if (task.diffText.isNotEmpty &&
            task.filesChanged == 0 &&
            task.linesAdded == 0 &&
            task.linesRemoved == 0) {
          final summary = TaskDiffParser.summarize(
            TaskDiffParser.parse(task.diffText),
          );
          task.filesChanged = summary.files;
          task.linesAdded = summary.added;
          task.linesRemoved = summary.removed;
        }
        changed = true;
      }
    } on Object {
      // Ignore read errors.
    }
    if (changed) _notifyNow();
  }

  void setMaxConcurrency(int count) {
    _maxConcurrency = count.clamp(1, 4);
    _notifyNow();
    unawaited(_save());
    if (_autoDispatch) unawaited(dispatchPending());
  }

  void setAutoDispatch(bool on) {
    _autoDispatch = on;
    _notifyNow();
    unawaited(_save());
    if (on) unawaited(dispatchPending());
  }

  WorktreeTask enqueue({
    required String title,
    required String prompt,
    required String repoPath,
    String agentId = 'agy',
    String? model,
    String? effort,
    bool useWorktree = true,
    String? workflowTemplateId,
  }) {
    final cleanPrompt = prompt.trim();
    final cleanTitle = title.trim();
    final effectiveTitle = cleanTitle.isEmpty
        ? (cleanPrompt.isEmpty ? 'Untitled task' : cleanPrompt.split('\n').first)
        : cleanTitle;
    final cleanModel = model?.trim();
    final cleanEffort = effort?.trim();
    final cleanWorkflow = workflowTemplateId?.trim();
    final cleanAgent = AcpAgentService.normalizeAgentId(agentId);
    final task = WorktreeTask(
      id: _nextTaskId(),
      title: effectiveTitle,
      prompt: cleanPrompt.isEmpty ? effectiveTitle : cleanPrompt,
      repoPath: repoPath.trim(),
      agentId: cleanAgent.isEmpty ? 'agy' : cleanAgent,
      model: (cleanModel == null || cleanModel.isEmpty) ? null : cleanModel,
      effort: (cleanEffort == null || cleanEffort.isEmpty) ? null : cleanEffort,
      useWorktree: useWorktree,
      workflowTemplateId:
          (cleanWorkflow == null || cleanWorkflow.isEmpty) ? null : cleanWorkflow,
    ).._detailsLoaded = true;
    _tasks.insert(0, task);
    _notifyNow();
    unawaited(_save());
    if (_autoDispatch) unawaited(dispatchPending());
    return task;
  }

  /// Updates editable fields on a non-running task (e.g. queued/failed/cancelled).
  bool updateTask(
    String taskId, {
    String? title,
    String? prompt,
    String? repoPath,
    String? agentId,
    String? model,
    bool clearModel = false,
    String? effort,
    bool clearEffort = false,
    bool? useWorktree,
    String? workflowTemplateId,
    bool clearWorkflow = false,
  }) {
    final task = byId(taskId);
    if (task == null || task.status == WorktreeTaskStatus.running) return false;
    if (title != null && title.trim().isNotEmpty) task.title = title.trim();
    if (prompt != null && prompt.trim().isNotEmpty) task.prompt = prompt.trim();
    if (repoPath != null && repoPath.trim().isNotEmpty) {
      task.repoPath = repoPath.trim();
    }
    if (agentId != null && agentId.trim().isNotEmpty) {
      task.agentId = AcpAgentService.normalizeAgentId(agentId);
    }
    if (clearModel) {
      task.model = null;
    } else if (model != null) {
      task.model = model.trim().isEmpty ? null : model.trim();
    }
    if (clearEffort) {
      task.effort = null;
    } else if (effort != null) {
      task.effort = effort.trim().isEmpty ? null : effort.trim();
    }
    if (useWorktree != null) task.useWorktree = useWorktree;
    if (clearWorkflow) {
      task.workflowTemplateId = null;
    } else if (workflowTemplateId != null) {
      task.workflowTemplateId = workflowTemplateId.trim().isEmpty
          ? null
          : workflowTemplateId.trim();
    }
    _notifyNow();
    unawaited(_save());
    return true;
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

  Future<void> runTask(String taskId) {
    final existing = _runningFutures[taskId];
    if (existing != null) return existing;
    final task = byId(taskId);
    if (task == null || task.status == WorktreeTaskStatus.running) {
      return Future<void>.value();
    }
    final fut = _runTaskImpl(task);
    _runningFutures[taskId] = fut;
    return fut.whenComplete(() {
      if (identical(_runningFutures[taskId], fut)) {
        _runningFutures.remove(taskId);
      }
    });
  }

  Future<void> _runTaskImpl(WorktreeTask task) async {
    _cancellingIds.remove(task.id);
    task.status = WorktreeTaskStatus.running;
    task.startedAt = DateTime.now();
    task.finishedAt = null;
    task.error = null;
    task.diffStat = '';
    task.diffText = '';
    task.filesChanged = 0;
    task.linesAdded = 0;
    task.linesRemoved = 0;
    task.hasDiff = false;
    task.hasLog = true;
    task._detailsLoaded = true;
    task.log = '[Ayte] Preparing task execution...\n';
    _notifyNow();
    unawaited(_save());

    try {
      if (task.repoPath.isEmpty || !Directory(task.repoPath).existsSync()) {
        throw StateError('目标仓库目录不存在：${task.repoPath}');
      }

      // Clean up any leftover worktree/branch from a prior failed or cancelled
      // attempt before creating a fresh isolated worktree.
      if (task.useWorktree) {
        await _cleanupWorktree(task, forceBranchName: 'ayte/task-${task.id}');
        task.branchName = '';
        task.worktreePath = '';
        task.baseCommit = '';
      }

      if (_isCancelled(task)) {
        await _finalizeCancelled(task);
        return;
      }

      final isGitRepo = await _isGitRepository(task.repoPath);
      final shouldWorktree = task.useWorktree && isGitRepo;
      String runDir = task.repoPath;

      if (shouldWorktree) {
        final branch = 'ayte/task-${task.id}';
        final wtRoot = p.join(
          p.dirname(_filePath),
          'worktrees',
          'task-${task.id}',
        );
        Directory(p.dirname(wtRoot)).createSync(recursive: true);
        if (Directory(wtRoot).existsSync()) {
          await _deleteDirectoryQuietly(wtRoot);
        }
        await Process.run(
          'git',
          ['worktree', 'prune'],
          workingDirectory: task.repoPath,
        );
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
        task.baseCommit = await _readHeadCommit(wtRoot);
        runDir = wtRoot;
        task.log += '[Ayte] Worktree created at $wtRoot ($branch)\n';
      } else {
        if (isGitRepo) {
          task.baseCommit = await _readHeadCommit(task.repoPath);
        }
        task.log += task.useWorktree
            ? '[Ayte] Directory is not a git repo; running directly in ${task.repoPath}\n'
            : '[Ayte] Reusing current workspace directly: ${task.repoPath}\n';
      }
      _notifyNow();

      if (_isCancelled(task)) {
        await _finalizeCancelled(task);
        return;
      }

      void appendLog(String chunk) {
        task.log += chunk;
        if (task.log.length > maxLogChars) {
          task.log = task.log.substring(task.log.length - maxLogChars);
        }
        task.hasLog = true;
        _notifyStreamingThrottled();
      }

      final ({bool ok, String? error}) result;
      if (task.workflowTemplateId case final wfId? when wfId.isNotEmpty) {
        final wfRes = await CanvasController.instance.runWorkflow(
          templateId: wfId,
          defaultCwd: runDir,
          selectOnStart: false,
          runName: task.title,
          onRunStarted: (runId) {
            if (_isCancelled(task)) {
              _runningWorkflowRunIds.remove(task.id);
              CanvasController.instance.stopWorkflow(runId: runId);
            } else {
              _runningWorkflowRunIds[task.id] = runId;
            }
          },
          inputs: {
            'bugId': task.title,
            'prompt': task.prompt,
            'repo': runDir,
          },
          onLogChunk: appendLog,
        );
        _runningWorkflowRunIds.remove(task.id);
        result = (ok: wfRes.ok, error: wfRes.error);
      } else {
        final agentRes = await AcpAgentService.instance.runHeadlessPrompt(
          agentId: task.agentId,
          prompt: task.prompt,
          cwd: runDir,
          model: task.model,
          effort: task.effort,
          onChunk: appendLog,
          onProcessStarted: (proc) {
            if (_isCancelled(task)) {
              _runningProcesses.remove(task.id);
              unawaited(AcpAgentService.killProcessTree(proc));
            } else {
              _runningProcesses[task.id] = proc;
            }
          },
        );
        _runningProcesses.remove(task.id);
        result = (ok: agentRes.ok, error: agentRes.error);
      }

      if (_isCancelled(task)) {
        await _finalizeCancelled(task);
        return;
      }

      if (!result.ok) {
        task.status = WorktreeTaskStatus.failed;
        task.error = result.error ?? 'Agent exited with non-zero code.';
        task.finishedAt = DateTime.now();
        // Capture partial diff even on failure so user can inspect or hand off.
        await _captureDiffForTask(task);
      } else {
        await _captureDiffForTask(task);
        task.status = WorktreeTaskStatus.review;
        task.finishedAt = DateTime.now();
      }
    } on Object catch (e) {
      _runningProcesses.remove(task.id);
      _runningWorkflowRunIds.remove(task.id);
      if (_isCancelled(task)) {
        await _finalizeCancelled(task);
        return;
      }
      task.status = WorktreeTaskStatus.failed;
      task.error = '$e';
      task.log += '\n[Error] $e\n';
      task.hasLog = true;
      task.finishedAt = DateTime.now();
    }

    await _writeTaskBlobs(task);
    _notifyNow();
    await _save();
    if (_autoDispatch) unawaited(dispatchPending());
  }

  bool _isCancelled(WorktreeTask task) =>
      task.status == WorktreeTaskStatus.cancelled ||
      _cancellingIds.contains(task.id);

  Future<void> _finalizeCancelled(WorktreeTask task) async {
    _runningProcesses.remove(task.id);
    _runningWorkflowRunIds.remove(task.id);
    _cancellingIds.remove(task.id);
    task.status = WorktreeTaskStatus.cancelled;
    task.finishedAt = DateTime.now();
    await _writeTaskBlobs(task);
    _notifyNow();
    await _save();
    if (_autoDispatch) unawaited(dispatchPending());
  }

  /// Refreshes the captured git diff for [taskId] from its live worktree (or
  /// repository), capturing committed, staged, unstaged, and untracked edits.
  Future<void> refreshTaskDiff(String taskId) async {
    final task = byId(taskId);
    if (task == null) return;
    await _captureDiffForTask(task);
    await _writeTaskBlobs(task);
    _notifyNow();
    await _save();
  }

  Future<void> _captureDiffForTask(WorktreeTask task) async {
    final targetDir = task.worktreePath.isNotEmpty
        ? task.worktreePath
        : task.repoPath;
    if (targetDir.isEmpty || !Directory(targetDir).existsSync()) return;
    if (!await _isGitRepository(targetDir)) return;

    try {
      final statusRes = await Process.run(
        'git',
        ['status', '--short'],
        workingDirectory: targetDir,
      );
      final statusText = '${statusRes.stdout}'.trim();
      String statText = '';
      String rawDiff = '';

      if (task.worktreePath.isNotEmpty && task.baseCommit.isNotEmpty) {
        // Use a temporary GIT_INDEX_FILE inside the app cache directory so
        // `git add -A` captures committed, staged, unstaged, and newly created
        // untracked files (respecting `.gitignore`) without modifying the
        // worktree's actual git index or writing into Directory.systemTemp.
        final cacheBase = storagePathOverride != null
            ? p.join(p.dirname(_filePath), 'cache')
            : DataDirectory.current.cacheDir;
        final indexDir = Directory(p.join(cacheBase, 'git-index'));
        await indexDir.create(recursive: true);
        final safeId = task.id.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
        final tmpIndex = p.join(
          indexDir.path,
          'ayte-task-idx-$safeId-${DateTime.now().microsecondsSinceEpoch}',
        );
        final gitEnv = {...Platform.environment, 'GIT_INDEX_FILE': tmpIndex};
        try {
          await Process.run(
            'git',
            ['add', '-A'],
            workingDirectory: targetDir,
            environment: gitEnv,
          );
          final statRes = await Process.run(
            'git',
            ['diff', '--cached', '--stat', task.baseCommit],
            workingDirectory: targetDir,
            environment: gitEnv,
          );
          final diffRes = await Process.run(
            'git',
            ['diff', '--cached', task.baseCommit],
            workingDirectory: targetDir,
            environment: gitEnv,
          );
          statText = '${statRes.stdout}'.trim();
          rawDiff = '${diffRes.stdout}';
        } finally {
          for (final path in [tmpIndex, '$tmpIndex.lock']) {
            try {
              final f = File(path);
              if (f.existsSync()) f.deleteSync();
            } on Object {
              // Ignore temp index cleanup failure.
            }
          }
        }
      } else {
        final ref = task.baseCommit.isNotEmpty ? task.baseCommit : 'HEAD';
        final statRes = await Process.run(
          'git',
          ['diff', '--stat', ref],
          workingDirectory: targetDir,
        );
        final diffRes = await Process.run(
          'git',
          ['diff', ref],
          workingDirectory: targetDir,
        );
        if (diffRes.exitCode == 0) {
          statText = '${statRes.stdout}'.trim();
          rawDiff = '${diffRes.stdout}';
        } else {
          final fallbackStat = await Process.run(
            'git',
            ['diff', '--stat'],
            workingDirectory: targetDir,
          );
          final fallbackDiff = await Process.run(
            'git',
            ['diff'],
            workingDirectory: targetDir,
          );
          statText = '${fallbackStat.stdout}'.trim();
          rawDiff = '${fallbackDiff.stdout}';
        }
      }

      task.diffStat = [
        if (statusText.isNotEmpty) statusText,
        if (statText.isNotEmpty) statText,
      ].join('\n').trim();
      task.diffText = rawDiff.length > maxDiffChars
          ? '${rawDiff.substring(0, maxDiffChars)}\n... (truncated)'
          : rawDiff;
      task.hasDiff = task.diffText.isNotEmpty;
      final summary = TaskDiffParser.summarize(
        TaskDiffParser.parse(task.diffText),
      );
      task.filesChanged = summary.files;
      task.linesAdded = summary.added;
      task.linesRemoved = summary.removed;
      task._detailsLoaded = true;
    } on Object catch (e) {
      debugPrint('TaskQueueService diff capture failed: $e');
    }
  }

  Future<void> cancelTask(String taskId) async {
    final task = byId(taskId);
    if (task == null) return;
    _cancellingIds.add(taskId);
    task.status = WorktreeTaskStatus.cancelled;
    task.finishedAt = DateTime.now();
    _notifyNow();

    final proc = _runningProcesses.remove(taskId);
    if (proc != null) {
      await AcpAgentService.killProcessTree(proc);
    }
    if (_runningWorkflowRunIds.remove(taskId) case final runId?) {
      CanvasController.instance.stopWorkflow(runId: runId);
    }
    await _save();
    if (_autoDispatch) unawaited(dispatchPending());
  }

  /// Commits any uncommitted worktree changes onto the task branch, merges the
  /// branch into the main repo, and cleans up the worktree.
  Future<({bool ok, String message})> approveAndMerge(String taskId) async {
    final task = byId(taskId);
    if (task == null) return (ok: false, message: '未找到指定任务');
    if (task.status == WorktreeTaskStatus.running) {
      return (ok: false, message: '任务仍在执行中，请等待完成或先停止。');
    }
    if (task.worktreePath.isEmpty || task.branchName.isEmpty) {
      task.status = WorktreeTaskStatus.merged;
      _notifyNow();
      await _save();
      return (ok: true, message: '已标记为完成');
    }
    if (!Directory(task.worktreePath).existsSync()) {
      return (
        ok: false,
        message: '任务 Worktree 目录不存在：${task.worktreePath}',
      );
    }
    if (task.repoPath.isEmpty || !Directory(task.repoPath).existsSync()) {
      return (ok: false, message: '主仓库目录不存在：${task.repoPath}');
    }
    try {
      // Guard: refuse to merge into a dirty main repository so uncommitted work
      // in the main checkout is never overwritten or mixed with task commits.
      final mainPorcelain = await Process.run(
        'git',
        ['status', '--porcelain'],
        workingDirectory: task.repoPath,
      );
      if (mainPorcelain.exitCode != 0) {
        return (
          ok: false,
          message: '读取主仓库状态失败：${mainPorcelain.stderr}'.trim(),
        );
      }
      final mainDirtyRaw = '${mainPorcelain.stdout}'.trim();
      if (mainDirtyRaw.isNotEmpty) {
        final dirtyLines = const LineSplitter()
            .convert(mainDirtyRaw)
            .where((l) => l.trim().isNotEmpty)
            .toList();
        final preview = dirtyLines.take(8).join('\n');
        final suffix = dirtyLines.length > 8
            ? '\n... (+${dirtyLines.length - 8} more)'
            : '';
        return (
          ok: false,
          message:
              '主仓库存在未提交变更，已取消合并以保护工作区（请先提交或暂存主仓库改动，任务 Worktree 已保留）：\n$preview$suffix',
        );
      }

      // Refresh final diff archive before worktree is deleted.
      await _captureDiffForTask(task);
      await _writeTaskBlobs(task);

      // Only commit when there are actual uncommitted changes in the worktree.
      final porcelain = await Process.run(
        'git',
        ['status', '--porcelain'],
        workingDirectory: task.worktreePath,
      );
      if (porcelain.exitCode != 0) {
        return (
          ok: false,
          message: '读取 Worktree 状态失败：${porcelain.stderr}'.trim(),
        );
      }
      if ('${porcelain.stdout}'.trim().isNotEmpty) {
        final addRes = await Process.run(
          'git',
          ['add', '-A'],
          workingDirectory: task.worktreePath,
        );
        if (addRes.exitCode != 0) {
          return (
            ok: false,
            message: '暂存变更失败（Worktree 已保留）：${addRes.stderr}'.trim(),
          );
        }
        final commitRes = await Process.run(
          'git',
          ['commit', '-m', 'Ayte task: ${task.title}'],
          workingDirectory: task.worktreePath,
        );
        if (commitRes.exitCode != 0) {
          final detail = '${commitRes.stderr}\n${commitRes.stdout}'.trim();
          return (
            ok: false,
            message: '提交 Worktree 变更失败（Worktree 与修改已保留）：\n$detail',
          );
        }
      }

      final mergeRes = await Process.run(
        'git',
        ['merge', '--no-ff', task.branchName, '-m', 'Merge ${task.branchName}'],
        workingDirectory: task.repoPath,
      );
      if (mergeRes.exitCode != 0) {
        // Keep the main repository clean if git left an active merge conflict.
        final mergeHead = await Process.run(
          'git',
          ['rev-parse', '-q', '--verify', 'MERGE_HEAD'],
          workingDirectory: task.repoPath,
        );
        if (mergeHead.exitCode == 0) {
          await Process.run(
            'git',
            ['merge', '--abort'],
            workingDirectory: task.repoPath,
          );
        }
        final detail = '${mergeRes.stderr}\n${mergeRes.stdout}'.trim();
        return (
          ok: false,
          message:
              '合并失败（主分支已安全回滚，任务 Worktree 与分支已保留，可点「接管到对话」继续处理）：\n$detail',
        );
      }

      final mergedBranch = task.branchName;
      await _cleanupWorktree(task);
      task.worktreePath = '';
      task.status = WorktreeTaskStatus.merged;
      _notifyNow();
      await _save();
      return (ok: true, message: '已成功合并 $mergedBranch');
    } on Object catch (e) {
      return (ok: false, message: '$e');
    }
  }

  /// Discards the task worktree & branch without merging and removes its blobs.
  Future<void> discardTask(String taskId) async {
    final task = byId(taskId);
    if (task == null) return;
    _cancellingIds.add(taskId);
    task.status = WorktreeTaskStatus.cancelled;

    final proc = _runningProcesses.remove(taskId);
    if (proc != null) {
      await AcpAgentService.killProcessTree(proc);
    }
    if (_runningWorkflowRunIds.remove(taskId) case final runId?) {
      CanvasController.instance.stopWorkflow(runId: runId);
    }
    if (_runningFutures[taskId] case final running?) {
      try {
        await running.timeout(const Duration(seconds: 2));
      } on Object {
        // Proceed to cleanup even if the task is slow to unwind.
      }
    }

    await _cleanupWorktree(task);
    _tasks.removeWhere((t) => t.id == taskId);
    _cancellingIds.remove(taskId);
    await _deleteTaskBlobs(taskId);
    _notifyNow();
    await _save();
  }

  /// Removes all `merged` and `cancelled` tasks (and `failed` tasks when
  /// [includeFailed] is true) and cleans their external logs, diffs, and any
  /// leftover worktrees.
  Future<int> clearFinishedTasks({bool includeFailed = false}) async {
    final targets = _tasks
        .where(
          (t) =>
              t.status == WorktreeTaskStatus.merged ||
              t.status == WorktreeTaskStatus.cancelled ||
              (includeFailed && t.status == WorktreeTaskStatus.failed),
        )
        .toList();
    if (targets.isEmpty) return 0;
    for (final task in targets) {
      await _cleanupWorktree(task);
      await _deleteTaskBlobs(task.id);
      _tasks.removeWhere((t) => t.id == task.id);
    }
    _notifyNow();
    await _save();
    return targets.length;
  }

  /// Builds the directory, target kernel descriptor ID, optional model/effort,
  /// and pre-filled composer prompt to hand off [taskId] into an interactive
  /// chat session.
  Future<
    ({
      String directory,
      String kernelId,
      String? model,
      String? effort,
      String draftPrompt,
    })?
  >
  buildChatHandoff(String taskId, {required bool isZh}) async {
    final task = byId(taskId);
    if (task == null) return null;
    await ensureTaskDetailsLoaded(taskId);

    final hasWorktree =
        task.worktreePath.isNotEmpty &&
        Directory(task.worktreePath).existsSync();
    final directory = hasWorktree ? task.worktreePath : task.repoPath;
    if (directory.isEmpty || !Directory(directory).existsSync()) return null;

    final kernelId = switch (AcpAgentService.normalizeAgentId(task.agentId)) {
      'agy' => antigravityBuiltinProviderId,
      'codebuddy' => codebuddyBuiltinProviderId,
      'claude' => claudeCodeKernelId,
      'codex' => codexKernelId,
      _ => antigravityBuiltinProviderId,
    };

    final buf = StringBuffer();
    if (isZh) {
      buf.writeln('请接管以下后台任务并继续处理：');
      buf.writeln('- **任务标题**：${task.title}');
      buf.writeln('- **当前状态**：${task.status.label(zh: true)}');
      if (task.branchName.isNotEmpty) {
        buf.writeln('- **分支**：`${task.branchName}`');
      }
      buf.writeln('- **工作目录**：`$directory`');
      buf.writeln('\n### 原始任务指令\n${task.prompt}');
      if (task.error != null && task.error!.trim().isNotEmpty) {
        buf.writeln('\n### 失败原因\n```text\n${task.error!.trim()}\n```');
      }
      if (task.diffStat.trim().isNotEmpty) {
        buf.writeln('\n### 当前变更摘要\n```text\n${task.diffStat.trim()}\n```');
      }
      final tail = _tailLines(task.log, 30);
      if (tail.isNotEmpty && task.status == WorktreeTaskStatus.failed) {
        buf.writeln('\n### 最近日志\n```text\n$tail\n```');
      }
      buf.writeln(
        task.status == WorktreeTaskStatus.review
            ? '\n请先审阅当前改动，确认边界情况和测试是否充分，或按我接下来的指示微调。'
            : '\n请先排查上述问题并继续完成任务。',
      );
    } else {
      buf.writeln('Please take over the following background task:');
      buf.writeln('- **Title**: ${task.title}');
      buf.writeln('- **Status**: ${task.status.label(zh: false)}');
      if (task.branchName.isNotEmpty) {
        buf.writeln('- **Branch**: `${task.branchName}`');
      }
      buf.writeln('- **Directory**: `$directory`');
      buf.writeln('\n### Original Prompt\n${task.prompt}');
      if (task.error != null && task.error!.trim().isNotEmpty) {
        buf.writeln('\n### Error\n```text\n${task.error!.trim()}\n```');
      }
      if (task.diffStat.trim().isNotEmpty) {
        buf.writeln('\n### Diff Summary\n```text\n${task.diffStat.trim()}\n```');
      }
      final tail = _tailLines(task.log, 30);
      if (tail.isNotEmpty && task.status == WorktreeTaskStatus.failed) {
        buf.writeln('\n### Recent Log\n```text\n$tail\n```');
      }
      buf.writeln(
        task.status == WorktreeTaskStatus.review
            ? '\nPlease review the current changes, verify edge cases/tests, and help polish before merge.'
            : '\nPlease diagnose the issue above and finish the task.',
      );
    }

    final model = task.model?.trim();
    final effort = task.effort?.trim();
    return (
      directory: directory,
      kernelId: kernelId,
      model: (model != null && model.isNotEmpty) ? model : null,
      effort: (effort != null && effort.isNotEmpty) ? effort : null,
      draftPrompt: buf.toString().trim(),
    );
  }

  static String _tailLines(String text, int maxLines) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '';
    final lines = trimmed.split('\n');
    if (lines.length <= maxLines) return trimmed;
    return lines.sublist(lines.length - maxLines).join('\n');
  }

  Future<void> _cleanupWorktree(
    WorktreeTask task, {
    String? forceBranchName,
  }) async {
    final repoExists =
        task.repoPath.isNotEmpty && Directory(task.repoPath).existsSync();
    final isGitRepo = repoExists && await _isGitRepository(task.repoPath);
    if (task.worktreePath.isNotEmpty) {
      if (isGitRepo) {
        try {
          await Process.run(
            'git',
            ['worktree', 'remove', '--force', task.worktreePath],
            workingDirectory: task.repoPath,
          );
        } on Object {
          // Ignore git worktree remove errors; fallback deletion follows.
        }
      }
      await _deleteDirectoryQuietly(task.worktreePath);
    }
    if (isGitRepo) {
      try {
        await Process.run(
          'git',
          ['worktree', 'prune'],
          workingDirectory: task.repoPath,
        );
      } on Object {
        // Ignore prune errors.
      }
    }
    final branches = <String>{
      if (task.branchName.isNotEmpty) task.branchName,
      if (forceBranchName != null && forceBranchName.isNotEmpty)
        forceBranchName,
    };
    if (isGitRepo) {
      for (final branch in branches) {
        try {
          await Process.run(
            'git',
            ['branch', '-D', branch],
            workingDirectory: task.repoPath,
          );
        } on Object {
          // Ignore branch deletion errors (e.g., branch doesn't exist).
        }
      }
    }
  }

  Future<void> _deleteDirectoryQuietly(String path) async {
    final dir = Directory(path);
    if (!dir.existsSync()) return;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await dir.delete(recursive: true);
        return;
      } on Object {
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
      }
    }
  }

  Future<String> _readHeadCommit(String dir) async {
    try {
      final res = await Process.run(
        'git',
        ['rev-parse', 'HEAD'],
        workingDirectory: dir,
      );
      if (res.exitCode == 0) return '${res.stdout}'.trim();
    } on Object {
      // Ignore.
    }
    return '';
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
