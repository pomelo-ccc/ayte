import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../acp/acp_agent_service.dart';
import '../notifications/attention_host.dart';
import '../notifications/attention_settings.dart';
import '../notifications/notification_sound.dart';
import '../platform/data_dir.dart';

/// Node categories supported by Ayte's Executable Workflow Canvas.
enum CanvasNodeKind {
  trigger,
  command,
  agent,
  http,
  condition,
  approval,
  note,
  chat,
  file,
  group;

  static CanvasNodeKind parse(Object? raw) =>
      values.asNameMap()[raw] ?? note;

  bool get isExecutable => switch (this) {
    trigger || command || agent || http || condition || approval => true,
    note || chat || file || group => false,
  };

  String label(bool isZh) => switch (this) {
    trigger => isZh ? '触发输入' : 'Trigger',
    command => isZh ? 'Shell 命令' : 'Shell',
    agent => isZh ? 'AI Agent' : 'AI Agent',
    http => isZh ? 'HTTP 接口' : 'HTTP',
    condition => isZh ? '条件门禁' : 'Condition',
    approval => isZh ? '人工确认' : 'Approval',
    note => isZh ? '便签' : 'Note',
    chat => isZh ? '会话卡' : 'Chat',
    file => isZh ? '文件卡' : 'File',
    group => isZh ? '分组框' : 'Group',
  };

  int get defaultColorValue => switch (this) {
    trigger => 0xFF39C5CF,
    command => 0xFFA371F7,
    agent => 0xFF58A6FF,
    http => 0xFF2EA043,
    condition => 0xFFD29922,
    approval => 0xFFF0883E,
    note => 0xFFD29922,
    chat => 0xFF58A6FF,
    file => 0xFF3FB950,
    group => 0xFF6E7681,
  };
}

/// Branch condition carried by a directed workflow edge.
enum CanvasEdgeBranch {
  onPass,
  onFail,
  always;

  static CanvasEdgeBranch parse(Object? raw) =>
      values.asNameMap()[raw] ?? onPass;

  String label(bool isZh) => switch (this) {
    onPass => isZh ? '通过' : 'Pass',
    onFail => isZh ? '失败' : 'Fail',
    always => isZh ? '总是' : 'Always',
  };
}

/// Live execution state of a workflow node during a run.
enum CanvasNodeRunStatus {
  idle,
  queued,
  running,
  waitingApproval,
  succeeded,
  failed,
  skipped;

  static CanvasNodeRunStatus parse(Object? raw) =>
      values.asNameMap()[raw] ?? idle;

  String label(bool isZh) => switch (this) {
    idle => isZh ? '待命' : 'Idle',
    queued => isZh ? '排队中' : 'Queued',
    running => isZh ? '执行中' : 'Running',
    waitingApproval => isZh ? '等待确认' : 'Awaiting Approval',
    succeeded => isZh ? '通过' : 'Passed',
    failed => isZh ? '失败' : 'Failed',
    skipped => isZh ? '已跳过' : 'Skipped',
  };
}

/// Directed connection between two nodes on the workflow canvas.
class CanvasEdge {
  const CanvasEdge({
    required this.id,
    required this.fromId,
    required this.toId,
    this.branch = CanvasEdgeBranch.onPass,
  });

  final String id;
  final String fromId;
  final String toId;
  final CanvasEdgeBranch branch;

  Map<String, Object?> toJson() => {
    'id': id,
    'fromId': fromId,
    'toId': toId,
    'branch': branch.name,
  };

  static CanvasEdge? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'] as String?;
    final fromId = raw['fromId'] as String?;
    final toId = raw['toId'] as String?;
    if (id == null ||
        id.isEmpty ||
        fromId == null ||
        fromId.isEmpty ||
        toId == null ||
        toId.isEmpty) {
      return null;
    }
    return CanvasEdge(
      id: id,
      fromId: fromId,
      toId: toId,
      branch: CanvasEdgeBranch.parse(raw['branch']),
    );
  }
}

/// A node on the 2D workflow canvas (executable step or whiteboard card).
class CanvasNode {
  CanvasNode({
    required this.id,
    required this.kind,
    required this.title,
    required this.x,
    required this.y,
    this.width = 280,
    this.height = 190,
    this.content = '',
    this.refId = '',
    this.colorValue = 0xFF58A6FF,
    this.agentId = '',
    this.model = '',
    this.effort = '',
    this.httpMethod = 'POST',
    this.httpUrl = '',
    this.httpHeaders = '',
    this.conditionExpr = 'notContains:FAIL',
    this.timeoutSeconds = 600,
    this.maxRetries = 0,
    this.retryDelaySeconds = 2,
    this.recoversFailure = false,
    this.output = '',
    this.running = false,
    this.runStatus = CanvasNodeRunStatus.idle,
    this.exitCode,
  });

  final String id;
  final CanvasNodeKind kind;
  String title;
  double x;
  double y;
  double width;
  double height;

  /// Primary payload:
  /// - `trigger`: `key=value` lines (e.g. `bugId=BUG-1024`)
  /// - `command`: shell script
  /// - `agent`: prompt template with `{{input.bugId}}` / `{{prev.output}}`
  /// - `http`: request body template (JSON)
  /// - `condition`: optional notes/description
  /// - `approval`: instructions shown to the reviewer
  /// - `note` / `chat` / `file`: card text
  String content;

  /// Working directory (`cwd`), file path, or chat session id.
  String refId;
  int colorValue;

  /// Native kernel id for `agent` nodes (`''` = inherit workflow default, or
  /// explicit `'agy'`, `'codebuddy'`, `'claude'`, `'codex'`).
  String agentId;

  /// Optional explicit model id for `agent` nodes (`''` = inherit workflow
  /// default model or the chosen kernel's default).
  String model;

  /// Optional reasoning effort (`''` = inherit workflow default, or
  /// `'low' | 'medium' | 'high' | 'xhigh' | 'max'`).
  String effort;

  /// HTTP node fields.
  String httpMethod;
  String httpUrl;
  String httpHeaders;

  /// Condition expression: `contains:X`, `notContains:X`, `regex:X`, `equals:X`,
  /// or `exitZero`.
  String conditionExpr;

  /// Per-node execution timeout in seconds.
  int timeoutSeconds;

  /// Automatic retry attempts on transient failure (0 = no retries).
  int maxRetries;

  /// Base backoff delay in seconds before retrying a failed node.
  int retryDelaySeconds;

  /// Whether an `onFail` handler node recovers the workflow to `ok: true` when
  /// it succeeds (default `false`: diagnostic/alert fail handlers still keep
  /// the overall run status as failed so false celebrations never fire).
  bool recoversFailure;

  /// Runtime state (not persisted).
  String output;
  bool running;
  CanvasNodeRunStatus runStatus;
  int? exitCode;
  DateTime? startedAt;
  DateTime? finishedAt;

  Duration? get runDuration {
    final s = startedAt;
    if (s == null) return null;
    final e = running ? DateTime.now() : (finishedAt ?? DateTime.now());
    return e.difference(s);
  }

  CanvasNode clone({bool includeRuntime = false}) {
    final copy = CanvasNode(
      id: id,
      kind: kind,
      title: title,
      x: x,
      y: y,
      width: width,
      height: height,
      content: content,
      refId: refId,
      colorValue: colorValue,
      agentId: agentId,
      model: model,
      effort: effort,
      httpMethod: httpMethod,
      httpUrl: httpUrl,
      httpHeaders: httpHeaders,
      conditionExpr: conditionExpr,
      timeoutSeconds: timeoutSeconds,
      maxRetries: maxRetries,
      retryDelaySeconds: retryDelaySeconds,
      recoversFailure: recoversFailure,
    );
    if (includeRuntime) {
      copy.output = output;
      copy.running = false;
      copy.runStatus = runStatus == CanvasNodeRunStatus.running ||
              runStatus == CanvasNodeRunStatus.waitingApproval
          ? CanvasNodeRunStatus.failed
          : runStatus;
      copy.exitCode = exitCode;
      copy.startedAt = startedAt;
      copy.finishedAt = finishedAt;
    }
    return copy;
  }

  Map<String, Object?> toJson({bool includeRuntime = false}) => {
    'id': id,
    'kind': kind.name,
    'title': title,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'content': content,
    'refId': refId,
    'colorValue': colorValue,
    'agentId': agentId,
    'model': model,
    'effort': effort,
    'httpMethod': httpMethod,
    'httpUrl': httpUrl,
    'httpHeaders': httpHeaders,
    'conditionExpr': conditionExpr,
    'timeoutSeconds': timeoutSeconds,
    if (maxRetries > 0) 'maxRetries': maxRetries,
    if (retryDelaySeconds != 2) 'retryDelaySeconds': retryDelaySeconds,
    if (recoversFailure) 'recoversFailure': true,
    if (includeRuntime) ...{
      'runStatus': runStatus.name,
      'output': output.length <= 12000
          ? output
          : output.substring(output.length - 12000),
      'exitCode': exitCode,
      'startedAt': startedAt?.toIso8601String(),
      'finishedAt': finishedAt?.toIso8601String(),
    },
  };

  /// Normalizes a node timeout: approval gates allow `0` (wait indefinitely)
  /// or `10..86400s`, while automated nodes clamp to `10..3600s`.
  static int normalizeTimeout(CanvasNodeKind kind, int? raw) {
    if (kind == CanvasNodeKind.approval) {
      if (raw == null || raw <= 0) return 0;
      return raw.clamp(10, 86400);
    }
    return (raw ?? 600).clamp(10, 3600);
  }

  static CanvasNode? fromJson(Object? raw, {bool includeRuntime = false}) {
    if (raw is! Map) return null;
    final id = raw['id'] as String?;
    if (id == null || id.isEmpty) return null;
    final kind = CanvasNodeKind.parse(raw['kind']);
    final maxW = kind == CanvasNodeKind.group ? 1800.0 : 960.0;
    final maxH = kind == CanvasNodeKind.group ? 1200.0 : 760.0;
    final node = CanvasNode(
      id: id,
      kind: kind,
      title: raw['title'] as String? ?? kind.label(true),
      x: (raw['x'] as num?)?.toDouble() ?? 80,
      y: (raw['y'] as num?)?.toDouble() ?? 80,
      width: ((raw['width'] as num?)?.toDouble() ?? 280).clamp(180.0, maxW),
      height: ((raw['height'] as num?)?.toDouble() ?? 190).clamp(110.0, maxH),
      content: raw['content'] as String? ?? '',
      refId: raw['refId'] as String? ?? '',
      colorValue:
          (raw['colorValue'] as num?)?.toInt() ?? kind.defaultColorValue,
      agentId: raw['agentId'] as String? ?? '',
      model: raw['model'] as String? ?? '',
      effort: raw['effort'] as String? ?? '',
      httpMethod: raw['httpMethod'] as String? ?? 'POST',
      httpUrl: raw['httpUrl'] as String? ?? '',
      httpHeaders: raw['httpHeaders'] as String? ?? '',
      conditionExpr: raw['conditionExpr'] as String? ?? 'notContains:FAIL',
      timeoutSeconds: normalizeTimeout(
        kind,
        (raw['timeoutSeconds'] as num?)?.toInt(),
      ),
      maxRetries: ((raw['maxRetries'] as num?)?.toInt() ?? 0).clamp(0, 5),
      retryDelaySeconds:
          ((raw['retryDelaySeconds'] as num?)?.toInt() ?? 2).clamp(0, 120),
      recoversFailure: raw['recoversFailure'] == true,
    );
    if (includeRuntime) {
      node.runStatus = CanvasNodeRunStatus.parse(raw['runStatus']);
      if (node.runStatus == CanvasNodeRunStatus.running ||
          node.runStatus == CanvasNodeRunStatus.waitingApproval) {
        node.runStatus = CanvasNodeRunStatus.failed;
      }
      node.output = raw['output'] as String? ?? '';
      node.exitCode = (raw['exitCode'] as num?)?.toInt();
      if (raw['startedAt'] case final String s) {
        node.startedAt = DateTime.tryParse(s);
      }
      if (raw['finishedAt'] case final String s) {
        node.finishedAt = DateTime.tryParse(s);
      }
    }
    return node;
  }
}

/// A saved reusable workflow graph template (nodes + directed edges).
class CanvasWorkflowTemplate {
  const CanvasWorkflowTemplate({
    required this.id,
    required this.name,
    required this.nodes,
    required this.edges,
    this.defaultAgentId = 'agy',
    this.defaultModel = '',
    this.defaultEffort = '',
  });

  final String id;
  final String name;
  final List<CanvasNode> nodes;
  final List<CanvasEdge> edges;
  final String defaultAgentId;
  final String defaultModel;
  final String defaultEffort;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'defaultAgentId': defaultAgentId,
    'defaultModel': defaultModel,
    'defaultEffort': defaultEffort,
    'nodes': [for (final n in nodes) n.toJson()],
    'edges': [for (final e in edges) e.toJson()],
  };

  static CanvasWorkflowTemplate? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'] as String?;
    final name = raw['name'] as String?;
    if (id == null || id.isEmpty || name == null || name.isEmpty) return null;
    final nodes = <CanvasNode>[
      if (raw['nodes'] case final List list)
        for (final item in list) ?CanvasNode.fromJson(item),
    ];
    final edges = <CanvasEdge>[
      if (raw['edges'] case final List list)
        for (final item in list) ?CanvasEdge.fromJson(item),
    ];
    return CanvasWorkflowTemplate(
      id: id,
      name: name,
      nodes: nodes,
      edges: edges,
      defaultAgentId: raw['defaultAgentId'] as String? ?? 'agy',
      defaultModel: raw['defaultModel'] as String? ?? '',
      defaultEffort: raw['defaultEffort'] as String? ?? '',
    );
  }
}

/// Summary returned after a workflow run completes or stops.
class WorkflowRunResult {
  const WorkflowRunResult({
    required this.ok,
    required this.log,
    this.error,
    this.executedNodes = 0,
    this.failedNodeId,
    this.runId,
  });

  final bool ok;
  final String log;
  final String? error;
  final int executedNodes;
  final String? failedNodeId;
  final int? runId;
}

/// Lifecycle status of an independent concurrent [WorkflowRun].
enum WorkflowRunStatus {
  running,
  waitingApproval,
  succeeded,
  failed,
  cancelled;

  String label(bool isZh) => switch (this) {
    running => isZh ? '运行中' : 'Running',
    waitingApproval => isZh ? '待审批' : 'Approval',
    succeeded => isZh ? '已完成' : 'Passed',
    failed => isZh ? '未通过' : 'Failed',
    cancelled => isZh ? '已停止' : 'Stopped',
  };
}

/// Self-contained execution instance of a workflow DAG.
///
/// Each [WorkflowRun] owns its own deep-cloned [nodes], [edges], logs, active
/// subprocess handle, cancellation flag, and Human-in-the-Loop approval gate so
/// multiple workflows can execute concurrently without interfering with one
/// another or with the editor canvas.
class WorkflowRun {
  WorkflowRun({
    required this.id,
    required this.name,
    required this.nodes,
    required this.edges,
    required this.defaultAgentId,
    required this.defaultModel,
    required this.defaultEffort,
    required this.startedAt,
    this.sourceTemplateId,
    this.resumedFromNodeTitle,
    Map<String, String>? capturedVars,
  }) : capturedVars = capturedVars ?? {};

  final int id;
  final String name;
  final String? sourceTemplateId;
  final String? resumedFromNodeTitle;
  final List<CanvasNode> nodes;
  final List<CanvasEdge> edges;
  final String defaultAgentId;
  final String defaultModel;
  final String defaultEffort;
  final DateTime startedAt;
  final Map<String, String> capturedVars;

  DateTime? finishedAt;
  bool running = true;
  bool cancelRequested = false;
  bool? ok;
  String? error;
  String log = '';
  String? currentRunningNodeId;
  String? activeApprovalNodeId;
  Completer<({bool approved, String note})>? approvalCompleter;
  final Set<Process> activeProcesses = {};
  final Set<HttpClient> activeHttpClients = {};
  int executedNodes = 0;

  Process? get activeProcess => activeProcesses.firstOrNull;
  set activeProcess(Process? p) {
    activeProcesses.clear();
    if (p != null) activeProcesses.add(p);
  }

  CanvasNode? nodeById(String nodeId) {
    for (final n in nodes) {
      if (n.id == nodeId) return n;
    }
    return null;
  }

  List<CanvasNode> get executableNodes => [
    for (final n in nodes)
      if (n.kind.isExecutable) n,
  ];

  int get execTotal => nodes.where((n) => n.kind.isExecutable).length;

  int get execDone => nodes
      .where(
        (n) =>
            n.runStatus == CanvasNodeRunStatus.succeeded ||
            n.runStatus == CanvasNodeRunStatus.failed ||
            n.runStatus == CanvasNodeRunStatus.skipped,
      )
      .length;

  int get execSucceeded =>
      nodes.where((n) => n.runStatus == CanvasNodeRunStatus.succeeded).length;

  /// Nodes ordered by longest-path topological depth so resume picks the
  /// earliest upstream failure rather than raw array insertion order.
  List<CanvasNode> get _topologicalExecutableNodes {
    final exec = executableNodes;
    final depth = <String, int>{for (final n in exec) n.id: 0};
    for (var i = 0; i < exec.length; i++) {
      var changed = false;
      for (final e in edges) {
        final f = depth[e.fromId];
        final t = depth[e.toId];
        if (f != null && t != null && f + 1 > t) {
          depth[e.toId] = f + 1;
          changed = true;
        }
      }
      if (!changed) break;
    }
    final sorted = List<CanvasNode>.from(exec);
    sorted.sort((a, b) => (depth[a.id] ?? 0).compareTo(depth[b.id] ?? 0));
    return sorted;
  }

  /// Best node to resume execution from after a failure or cancellation:
  /// prefers the earliest topological failed executable node, then the first
  /// unreached/skipped primary-lane node after a cancellation.
  String? get resumableNodeId {
    if (running) return null;
    final ordered = _topologicalExecutableNodes;
    for (final n in ordered) {
      if (n.runStatus == CanvasNodeRunStatus.failed) {
        return n.id;
      }
    }
    if (cancelRequested) {
      final failOnlyIds = <String>{};
      for (final n in ordered) {
        final inc = edges.where((e) => e.toId == n.id).toList();
        if (inc.isNotEmpty &&
            inc.every((e) => e.branch == CanvasEdgeBranch.onFail)) {
          failOnlyIds.add(n.id);
        }
      }
      for (final n in ordered) {
        if (!failOnlyIds.contains(n.id) &&
            (n.runStatus == CanvasNodeRunStatus.skipped ||
                n.runStatus == CanvasNodeRunStatus.queued ||
                n.runStatus == CanvasNodeRunStatus.idle)) {
          return n.id;
        }
      }
    }
    return null;
  }

  Duration get duration {
    final end = running ? DateTime.now() : (finishedAt ?? DateTime.now());
    final diff = end.difference(startedAt);
    return diff.isNegative ? Duration.zero : diff;
  }

  WorkflowRunStatus get status {
    if (running && activeApprovalNodeId != null) {
      return WorkflowRunStatus.waitingApproval;
    }
    if (running) return WorkflowRunStatus.running;
    if (cancelRequested) return WorkflowRunStatus.cancelled;
    return ok == true ? WorkflowRunStatus.succeeded : WorkflowRunStatus.failed;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'sourceTemplateId': sourceTemplateId,
    'resumedFromNodeTitle': resumedFromNodeTitle,
    'defaultAgentId': defaultAgentId,
    'defaultModel': defaultModel,
    'defaultEffort': defaultEffort,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'cancelRequested': cancelRequested,
    'ok': ok,
    'error': error,
    'executedNodes': executedNodes,
    'log': log.length <= 36000 ? log : log.substring(log.length - 36000),
    'capturedVars': {
      for (final e in capturedVars.entries)
        e.key: e.value.length <= 8000
            ? e.value
            : e.value.substring(e.value.length - 8000),
    },
    'nodes': [for (final n in nodes) n.toJson(includeRuntime: true)],
    'edges': [for (final e in edges) e.toJson()],
  };

  static WorkflowRun? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = (raw['id'] as num?)?.toInt();
    final name = raw['name'] as String?;
    if (id == null || id <= 0 || name == null || name.isEmpty) return null;
    final startedAt =
        DateTime.tryParse(raw['startedAt'] as String? ?? '') ?? DateTime.now();
    final nodes = <CanvasNode>[
      if (raw['nodes'] case final List list)
        for (final item in list) ?CanvasNode.fromJson(item, includeRuntime: true),
    ];
    final edges = <CanvasEdge>[
      if (raw['edges'] case final List list)
        for (final item in list) ?CanvasEdge.fromJson(item),
    ];
    final vars = <String, String>{};
    if (raw['capturedVars'] case final Map m) {
      for (final entry in m.entries) {
        if (entry.key is String && entry.value is String) {
          vars[entry.key as String] = entry.value as String;
        }
      }
    }
    final run = WorkflowRun(
      id: id,
      name: name,
      sourceTemplateId: raw['sourceTemplateId'] as String?,
      resumedFromNodeTitle: raw['resumedFromNodeTitle'] as String?,
      nodes: nodes,
      edges: edges,
      defaultAgentId: raw['defaultAgentId'] as String? ?? 'agy',
      defaultModel: raw['defaultModel'] as String? ?? '',
      defaultEffort: raw['defaultEffort'] as String? ?? '',
      startedAt: startedAt,
      capturedVars: vars,
    );
    run.running = false;
    if (raw['finishedAt'] case final String s) {
      run.finishedAt = DateTime.tryParse(s);
    }
    run.cancelRequested = raw['cancelRequested'] == true;
    run.ok = raw['ok'] as bool?;
    run.error = raw['error'] as String?;
    run.executedNodes = (raw['executedNodes'] as num?)?.toInt() ?? 0;
    run.log = raw['log'] as String? ?? '';
    return run;
  }
}

/// Emitted whenever a full workflow run ends so UI overlays can display a
/// celebratory fireworks banner (on success) or a failure alert.
class WorkflowCompletionEvent {
  const WorkflowCompletionEvent({
    required this.runId,
    required this.ok,
    required this.cancelled,
    required this.workflowName,
    required this.executedNodes,
    required this.succeededNodes,
    required this.duration,
    required this.completedAt,
    this.error,
    this.workflowRunId,
  });

  /// Monotonically increasing completion sequence id (ordered by finish time
  /// so out-of-order concurrent runs never drop completion overlays).
  final int runId;
  final bool ok;
  final bool cancelled;
  final String workflowName;
  final int executedNodes;
  final int succeededNodes;
  final Duration duration;
  final DateTime completedAt;
  final String? error;

  /// Optional [WorkflowRun.id] of the completed run instance.
  final int? workflowRunId;
}

/// Alignment operation for multi-selected nodes on the canvas.
enum CanvasNodeAlignment { left, centerH, right, top, centerV, bottom, distributeH, distributeV }

class _CanvasSnapshot {
  const _CanvasSnapshot({
    required this.nodes,
    required this.edges,
    required this.workflowName,
    required this.defaultAgentId,
    required this.defaultModel,
    required this.defaultEffort,
  });

  final List<CanvasNode> nodes;
  final List<CanvasEdge> edges;
  final String workflowName;
  final String defaultAgentId;
  final String defaultModel;
  final String defaultEffort;
}

/// Bounded ring/tail string accumulator preventing O(N^2) allocations while
/// streaming high-volume command or agent output.
class _TailBuffer {
  _TailBuffer({this.maxChars = 24000});

  final int maxChars;
  final List<String> _chunks = [];
  int _length = 0;

  void write(String chunk) {
    if (chunk.isEmpty) return;
    _chunks.add(chunk);
    _length += chunk.length;
    while (_length > maxChars && _chunks.length > 1) {
      _length -= _chunks.removeAt(0).length;
    }
    if (_length > maxChars && _chunks.length == 1) {
      final only = _chunks.first;
      _chunks[0] = only.substring(only.length - maxChars);
      _length = _chunks[0].length;
    }
  }

  @override
  String toString() => _chunks.join();
}

/// Manages Ayte's 2D Executable Workflow Canvas: nodes, directed pass/fail
/// edges, multi-workflow documents, undo/redo history, templates, variable
/// interpolation, Human-in-the-Loop approval gates, and parallel DAG execution
/// (usable interactively or serially from the Task Queue).
class CanvasController extends ChangeNotifier {
  CanvasController._();

  /// Creates an isolated controller instance for unit testing without mutating
  /// the global singleton.
  @visibleForTesting
  CanvasController.forTest({String? storagePath})
    : storagePathOverride = storagePath;

  static final instance = CanvasController._();

  static const currentCanvasTemplateId = '__current_canvas__';
  static const bugVerifyTemplateId = 'builtin-bug-verify-69';
  static const plmLocalRebuildTemplateId = 'builtin-plm-local-rebuild';
  static const refreshModelTemplateId = 'builtin-plm-refresh-model';
  static const deploy69TemplateId = 'builtin-deploy-69-jenkins';
  static const defaultAngular21Root = '/Users/pomelo/work/projects/company/angular21';
  static const defaultPlm69ApiUrl = 'http://172.16.100.69';
  static const defaultJenkins69Url =
      'http://172.16.100.122:4875/view/快速构建/job/build-all-project/build?delay=0sec';

  static const double maxBoardX = 24000.0;
  static const double maxBoardY = 12000.0;
  static const int maxParallelNodes = 4;
  static const int _maxUndoDepth = 60;

  static bool isBuiltInTemplateId(String id) =>
      id == plmLocalRebuildTemplateId ||
      id == refreshModelTemplateId ||
      id == deploy69TemplateId ||
      id == bugVerifyTemplateId;

  /// Computes a dynamic scene size large enough to comfortably fit all [nodes]
  /// without clipping when workflows grow beyond the default 4800×2400 board.
  static ({double width, double height}) computeBoardSize(
    List<CanvasNode> nodes,
  ) {
    var maxX = 4800.0;
    var maxY = 2400.0;
    for (final n in nodes) {
      final right = n.x + n.width + 1200.0;
      final bottom = n.y + n.height + 900.0;
      if (right > maxX) maxX = right;
      if (bottom > maxY) maxY = bottom;
    }
    return (
      width: math.min(maxBoardX + 1200.0, maxX),
      height: math.min(maxBoardY + 900.0, maxY),
    );
  }

  @visibleForTesting
  String? storagePathOverride;

  final List<CanvasNode> _nodes = [];
  final List<CanvasEdge> _edges = [];
  final List<CanvasWorkflowTemplate> _templates = [];
  final List<CanvasWorkflowTemplate> _workflows = [];
  String _activeWorkflowId = 'wf_default';
  bool _loaded = false;
  Future<void>? _loadFuture;
  int _idSeq = 0;

  // Undo / redo history stacks.
  final List<_CanvasSnapshot> _undoStack = [];
  final List<_CanvasSnapshot> _redoStack = [];
  String? _lastTypingUndoNodeId;
  DateTime? _lastTypingUndoAt;

  // Debounced, serialized, atomic disk persistence.
  Timer? _saveDebounceTimer;
  Future<void> _saveQueue = Future<void>.value();
  Future<void> _saveRunsQueue = Future<void>.value();

  // Throttled streaming UI notifications (~75ms) to prevent rebuild storms.
  Timer? _streamNotifyTimer;
  bool _streamNotifyPending = false;

  /// Workflow-level default kernel, model, and effort inherited by any Agent
  /// node whose own field is left blank (`''`).
  String _defaultAgentId = 'agy';
  String _defaultModel = '';
  String _defaultEffort = '';

  String get defaultAgentId => _defaultAgentId;
  String get defaultModel => _defaultModel;
  String get defaultEffort => _defaultEffort;
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
  String get activeWorkflowId => _activeWorkflowId;
  List<CanvasWorkflowTemplate> get workflows => List.unmodifiable(_workflows);

  String _nextId(String prefix) =>
      '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${++_idSeq}';

  _CanvasSnapshot _captureSnapshot() => _CanvasSnapshot(
    nodes: [for (final n in _nodes) n.clone()],
    edges: [..._edges],
    workflowName: _activeWorkflowName,
    defaultAgentId: _defaultAgentId,
    defaultModel: _defaultModel,
    defaultEffort: _defaultEffort,
  );

  void _restoreSnapshot(_CanvasSnapshot snap) {
    _nodes
      ..clear()
      ..addAll([for (final n in snap.nodes) n.clone()]);
    _edges
      ..clear()
      ..addAll(snap.edges);
    _activeWorkflowName = snap.workflowName;
    _defaultAgentId = snap.defaultAgentId;
    _defaultModel = snap.defaultModel;
    _defaultEffort = snap.defaultEffort;
    _syncActiveWorkflowDocument();
    notifyListeners();
    _scheduleSave();
  }

  /// Captures the current board state on the undo stack (call before a drag or
  /// resize gesture so the entire gesture reverts as a single Ctrl+Z step).
  void pushUndoSnapshot() {
    _undoStack.add(_captureSnapshot());
    if (_undoStack.length > _maxUndoDepth) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
    _lastTypingUndoNodeId = null;
  }

  bool undo() {
    if (_undoStack.isEmpty) return false;
    _redoStack.add(_captureSnapshot());
    final prev = _undoStack.removeLast();
    _restoreSnapshot(prev);
    return true;
  }

  bool redo() {
    if (_redoStack.isEmpty) return false;
    _undoStack.add(_captureSnapshot());
    final next = _redoStack.removeLast();
    _restoreSnapshot(next);
    return true;
  }

  void _syncActiveWorkflowDocument() {
    final name = _activeWorkflowName.trim().isEmpty
        ? '默认工作流'
        : _activeWorkflowName.trim();
    final doc = CanvasWorkflowTemplate(
      id: _activeWorkflowId,
      name: name,
      nodes: [for (final n in _nodes) n.clone()],
      edges: [..._edges],
      defaultAgentId: _defaultAgentId,
      defaultModel: _defaultModel,
      defaultEffort: _defaultEffort,
    );
    final idx = _workflows.indexWhere((w) => w.id == _activeWorkflowId);
    if (idx >= 0) {
      _workflows[idx] = doc;
    } else {
      _workflows.insert(0, doc);
    }
  }

  /// Creates a new empty workflow document and switches the canvas to it
  /// without discarding the current workflow.
  CanvasWorkflowTemplate createWorkflow(String name) {
    _syncActiveWorkflowDocument();
    final trimmed = name.trim();
    final id = _nextId('wf');
    final doc = CanvasWorkflowTemplate(
      id: id,
      name: trimmed.isEmpty ? '新建工作流 ${_workflows.length + 1}' : trimmed,
      nodes: const [],
      edges: const [],
      defaultAgentId: _defaultAgentId,
      defaultModel: _defaultModel,
      defaultEffort: _defaultEffort,
    );
    _workflows.add(doc);
    _activeWorkflowId = id;
    _selectedRunId = null;
    _activeWorkflowName = doc.name;
    _nodes.clear();
    _edges.clear();
    _undoStack.clear();
    _redoStack.clear();
    _singleStepLog = '';
    notifyListeners();
    _scheduleSave();
    return doc;
  }

  /// Switches the editor to another saved workflow document by [workflowId].
  bool switchWorkflow(String workflowId) {
    if (workflowId == _activeWorkflowId) return true;
    _syncActiveWorkflowDocument();
    final idx = _workflows.indexWhere((w) => w.id == workflowId);
    if (idx < 0) return false;
    final target = _workflows[idx];
    _activeWorkflowId = target.id;
    _selectedRunId = null;
    _activeWorkflowName = target.name;
    _defaultAgentId = target.defaultAgentId.isEmpty ? 'agy' : target.defaultAgentId;
    _defaultModel = target.defaultModel;
    _defaultEffort = target.defaultEffort;
    _nodes
      ..clear()
      ..addAll([for (final n in target.nodes) n.clone()]);
    _edges
      ..clear()
      ..addAll(target.edges);
    _undoStack.clear();
    _redoStack.clear();
    _singleStepLog = '';
    notifyListeners();
    _scheduleSave();
    return true;
  }

  void renameActiveWorkflow(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == _activeWorkflowName) return;
    _activeWorkflowName = trimmed;
    _syncActiveWorkflowDocument();
    notifyListeners();
    _scheduleSave();
  }

  bool deleteWorkflow(String workflowId) {
    if (_workflows.length <= 1) return false;
    final idx = _workflows.indexWhere((w) => w.id == workflowId);
    if (idx < 0) return false;
    _workflows.removeAt(idx);
    if (_activeWorkflowId == workflowId) {
      final fallback = _workflows.first;
      _activeWorkflowId = fallback.id;
      _selectedRunId = null;
      _activeWorkflowName = fallback.name;
      _defaultAgentId = fallback.defaultAgentId.isEmpty ? 'agy' : fallback.defaultAgentId;
      _defaultModel = fallback.defaultModel;
      _defaultEffort = fallback.defaultEffort;
      _nodes
        ..clear()
        ..addAll([for (final n in fallback.nodes) n.clone()]);
      _edges
        ..clear()
        ..addAll(fallback.edges);
      _undoStack.clear();
      _redoStack.clear();
    }
    notifyListeners();
    _scheduleSave();
    return true;
  }

  /// Exports the current workflow graph as a standalone portable JSON string.
  String exportWorkflowJson({String? name}) {
    final wfName = (name ?? _activeWorkflowName).trim();
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'ayte-workflow',
      'version': 4,
      'name': wfName.isEmpty ? _resolveWorkflowName() : wfName,
      'defaultAgentId': _defaultAgentId,
      'defaultModel': _defaultModel,
      'defaultEffort': _defaultEffort,
      'nodes': [for (final n in _nodes) n.toJson()],
      'edges': [for (final e in _edges) e.toJson()],
    });
  }

  /// Imports a workflow JSON document (produced by [exportWorkflowJson] or
  /// AI generation) onto the canvas, pushing an undo snapshot first.
  ({String name, int nodeCount, int edgeCount}) importWorkflowJson(
    String rawJson, {
    bool createNewTab = false,
  }) {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map) {
      throw const FormatException('工作流 JSON 必须是对象格式');
    }
    final parsedNodes = <CanvasNode>[
      if (decoded['nodes'] case final List list)
        for (final item in list) ?CanvasNode.fromJson(item),
    ];
    if (parsedNodes.isEmpty) {
      throw const FormatException('导入的 JSON 中未包含有效节点');
    }
    final validNodeIds = {for (final n in parsedNodes) n.id};
    final parsedEdges = <CanvasEdge>[
      if (decoded['edges'] case final List list)
        for (final item in list)
          if (CanvasEdge.fromJson(item) case final e?
              when validNodeIds.contains(e.fromId) &&
                  validNodeIds.contains(e.toId) &&
                  e.fromId != e.toId)
            e,
    ];
    final wfName = (decoded['name'] as String?)?.trim();
    final resolvedName =
        (wfName != null && wfName.isNotEmpty) ? wfName : '导入的工作流';

    if (createNewTab) {
      createWorkflow(resolvedName);
    } else {
      pushUndoSnapshot();
    }

    _selectedRunId = null;
    _activeWorkflowName = resolvedName;
    final agent = (decoded['defaultAgentId'] as String?)?.trim();
    if (agent != null && agent.isNotEmpty) _defaultAgentId = agent;
    _defaultModel = (decoded['defaultModel'] as String? ?? '').trim();
    _defaultEffort = (decoded['defaultEffort'] as String? ?? '').trim();
    _nodes
      ..clear()
      ..addAll(parsedNodes);
    _edges
      ..clear()
      ..addAll(parsedEdges);
    _singleStepLog = '';
    _syncActiveWorkflowDocument();
    notifyListeners();
    _scheduleSave();
    return (
      name: resolvedName,
      nodeCount: parsedNodes.length,
      edgeCount: parsedEdges.length,
    );
  }

  /// Applies an AI-generated (or modified) workflow onto the canvas and runs
  /// topological auto-layout cleanly as a single undoable step.
  void applyGeneratedWorkflow({
    required String name,
    required List<CanvasNode> nodes,
    required List<CanvasEdge> edges,
    bool createNewTab = false,
  }) {
    if (createNewTab) {
      createWorkflow(name);
    } else {
      pushUndoSnapshot();
    }
    _selectedRunId = null;
    _activeWorkflowName = name.trim().isEmpty ? 'AI 工作流' : name.trim();
    _nodes
      ..clear()
      ..addAll([for (final n in nodes) n.clone()]);
    _edges
      ..clear()
      ..addAll(edges);
    _singleStepLog = '';
    _autoLayoutInternal();
    _syncActiveWorkflowDocument();
    notifyListeners();
    _scheduleSave();
  }

  void setWorkflowDefaults({
    String? agentId,
    String? model,
    String? effort,
  }) {
    var changed = false;
    if (agentId != null && agentId.isNotEmpty && agentId != _defaultAgentId) {
      _defaultAgentId = agentId;
      changed = true;
    }
    if (model != null && model != _defaultModel) {
      _defaultModel = model;
      changed = true;
    }
    if (effort != null && effort != _defaultEffort) {
      _defaultEffort = effort;
      changed = true;
    }
    if (changed) {
      _syncActiveWorkflowDocument();
      notifyListeners();
      _scheduleSave();
    }
  }

  /// Resets all Agent nodes on the current canvas to inherit the workflow
  /// default kernel/model/effort (or optionally writes explicit overrides).
  void applyWorkflowDefaultsToAllAgents() {
    pushUndoSnapshot();
    for (final n in _nodes) {
      if (n.kind == CanvasNodeKind.agent) {
        n.agentId = '';
        n.model = '';
        n.effort = '';
      }
    }
    _syncActiveWorkflowDocument();
    notifyListeners();
    _scheduleSave();
  }

  /// Resolves the effective kernel, model, and effort for an Agent [node],
  /// combining per-node overrides with workflow-level defaults (or a specific
  /// [run]'s captured snapshot defaults).
  ({
    String agentId,
    String model,
    String effort,
    bool inheritedAgent,
    bool inheritedModel,
  })
  effectiveAgentConfig(CanvasNode node, {WorkflowRun? run}) {
    final baseAgent = run?.defaultAgentId ?? _defaultAgentId;
    final baseModel = run?.defaultModel ?? _defaultModel;
    final baseEffort = run?.defaultEffort ?? _defaultEffort;
    final inheritedAgent = node.agentId.trim().isEmpty;
    final resolvedAgent = inheritedAgent
        ? (baseAgent.isEmpty ? 'agy' : baseAgent)
        : node.agentId.trim();
    final sameKernelAsDefault = resolvedAgent == baseAgent;
    final inheritedModel = node.model.trim().isEmpty && sameKernelAsDefault;
    final resolvedModel = node.model.trim().isNotEmpty
        ? node.model.trim()
        : (sameKernelAsDefault ? baseModel.trim() : '');
    final resolvedEffort = node.effort.trim().isNotEmpty
        ? node.effort.trim()
        : (sameKernelAsDefault ? baseEffort.trim() : '');
    return (
      agentId: resolvedAgent,
      model: resolvedModel,
      effort: resolvedEffort,
      inheritedAgent: inheritedAgent,
      inheritedModel: inheritedModel,
    );
  }

  static const _maxRetainedRuns = 24;

  final List<WorkflowRun> _runs = [];
  int? _selectedRunId;
  String _activeWorkflowName = '';
  int _runSequence = 0;
  int _completionSequence = 0;
  WorkflowCompletionEvent? _lastCompletionEvent;

  // Single-step test runs executed directly on the editor canvas.
  String _singleStepLog = '';
  String? _singleStepRunningNodeId;
  String? _singleStepApprovalNodeId;
  Completer<({bool approved, String note})>? _singleStepApprovalCompleter;
  final Map<String, Process> _singleStepProcesses = {};

  List<CanvasNode> get nodes => List.unmodifiable(_nodes);
  List<CanvasEdge> get edges => List.unmodifiable(_edges);
  List<CanvasWorkflowTemplate> get templates => List.unmodifiable(_templates);

  /// All workflow runs (newest first), including currently running and recent
  /// finished runs.
  List<WorkflowRun> get runs => List.unmodifiable(_runs);

  /// Currently running (or waiting-for-approval) workflow runs.
  List<WorkflowRun> get activeRuns => [
    for (final r in _runs)
      if (r.running) r,
  ];

  int get activeRunCount => _runs.where((r) => r.running).length;

  int get pendingApprovalCount =>
      _runs.where((r) => r.running && r.activeApprovalNodeId != null).length +
      (_singleStepApprovalNodeId != null ? 1 : 0);

  /// Badge count surfaced in the workspace side panel tab.
  int get sidePanelBadgeCount =>
      pendingApprovalCount > 0 ? pendingApprovalCount : activeRunCount;

  /// Currently inspected [WorkflowRun] id, or `null` when viewing/editing the
  /// main editor canvas.
  int? get selectedRunId => _selectedRunId;

  WorkflowRun? get selectedRun =>
      _selectedRunId == null ? null : runById(_selectedRunId!);

  WorkflowRun? runById(int id) {
    for (final r in _runs) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// First background run currently waiting for human approval (excluding the
  /// currently selected run, if any).
  WorkflowRun? get firstBackgroundApprovalRun {
    for (final r in _runs) {
      if (r.running &&
          r.activeApprovalNodeId != null &&
          r.id != _selectedRunId) {
        return r;
      }
    }
    return null;
  }

  bool get anyWorkflowRunning => activeRunCount > 0;

  /// Whether the currently viewed run (or any background run when on editor
  /// canvas) is executing.
  bool get workflowRunning => selectedRun?.running ?? anyWorkflowRunning;

  String get workflowLog => selectedRun?.log ?? _singleStepLog;
  String get activeWorkflowName => _activeWorkflowName;
  WorkflowCompletionEvent? get lastCompletionEvent => _lastCompletionEvent;
  String? get activeApprovalNodeId =>
      selectedRun?.activeApprovalNodeId ?? _singleStepApprovalNodeId;
  String? get currentRunningNodeId =>
      selectedRun?.currentRunningNodeId ?? _singleStepRunningNodeId;
  DateTime? get workflowStartedAt => selectedRun?.startedAt;
  DateTime? get workflowFinishedAt => selectedRun?.finishedAt;
  bool? get lastRunOk => selectedRun?.ok ?? _runs.firstOrNull?.ok;
  String? get lastRunError => selectedRun?.error ?? _runs.firstOrNull?.error;

  /// Nodes/edges currently displayed on screen (either the inspected run
  /// snapshot or the editable canvas).
  List<CanvasNode> get displayNodes => selectedRun?.nodes ?? nodes;
  List<CanvasEdge> get displayEdges => selectedRun?.edges ?? edges;

  CanvasNode? displayNodeById(String id) =>
      selectedRun != null ? selectedRun!.nodeById(id) : nodeById(id);

  void selectRun(int? runId) {
    final target = runId == null ? null : runById(runId)?.id;
    if (_selectedRunId == target) return;
    _selectedRunId = target;
    notifyListeners();
  }

  void dismissRun(int runId) {
    final run = runById(runId);
    if (run == null) return;
    if (run.running) {
      stopWorkflow(runId: runId);
    }
    _runs.removeWhere((r) => r.id == runId);
    if (_selectedRunId == runId) {
      _selectedRunId = activeRuns.firstOrNull?.id;
    }
    notifyListeners();
    unawaited(_saveRuns());
  }

  void clearFinishedRuns() {
    _runs.removeWhere((r) => !r.running);
    if (_selectedRunId != null && runById(_selectedRunId!) == null) {
      _selectedRunId = activeRuns.firstOrNull?.id;
    }
    notifyListeners();
    unawaited(_saveRuns());
  }

  @visibleForTesting
  void clearAllRunsForTest() {
    stopAllWorkflows();
    _runs.clear();
    _selectedRunId = null;
    _singleStepLog = '';
    _singleStepRunningNodeId = null;
    _singleStepApprovalNodeId = null;
    _singleStepApprovalCompleter = null;
    notifyListeners();
  }

  @visibleForTesting
  void resetLoadedForTest() {
    _loaded = false;
    _loadFuture = null;
  }

  String _resolveWorkflowNameFromNodes(
    List<CanvasNode> sourceNodes, {
    String? explicitName,
  }) {
    if (explicitName != null && explicitName.trim().isNotEmpty) {
      return explicitName.trim();
    }
    if (_activeWorkflowName.trim().isNotEmpty && identical(sourceNodes, _nodes)) {
      return _activeWorkflowName.trim();
    }
    for (final n in sourceNodes) {
      if (n.kind.isExecutable && n.title.trim().isNotEmpty) {
        return n.title.trim().replaceFirst(RegExp(r'^\d+\.\s*'), '');
      }
    }
    return '工作流';
  }

  String _resolveWorkflowName() => _resolveWorkflowNameFromNodes(_nodes);

  /// Re-triggers the celebratory fireworks overlay for a specific [runId], the
  /// currently selected run, or the most recent successful run.
  void replayLastCelebration({int? runId}) {
    final run = runId != null ? runById(runId) : selectedRun;
    final prev = _lastCompletionEvent;
    final sourceNodes = run?.nodes ?? _nodes;
    final execNodes = [
      for (final n in sourceNodes)
        if (n.kind.isExecutable) n,
    ];
    final succeeded = execNodes
        .where((n) => n.runStatus == CanvasNodeRunStatus.succeeded)
        .length;
    _lastCompletionEvent = WorkflowCompletionEvent(
      runId: ++_completionSequence,
      workflowRunId: run?.id ?? prev?.workflowRunId,
      ok: true,
      cancelled: false,
      workflowName: run?.name ?? prev?.workflowName ?? _resolveWorkflowName(),
      executedNodes: run?.executedNodes ?? prev?.executedNodes ?? execNodes.length,
      succeededNodes: run != null
          ? (run.execSucceeded > 0 ? run.execSucceeded : execNodes.length)
          : (prev?.succeededNodes ??
                (succeeded > 0 ? succeeded : execNodes.length)),
      duration: run?.duration ?? prev?.duration ?? workflowDuration ?? Duration.zero,
      completedAt: DateTime.now(),
    );
    notifyListeners();
  }

  void dismissCompletionEvent() {
    if (_lastCompletionEvent == null) return;
    _lastCompletionEvent = null;
    notifyListeners();
  }

  Duration? get workflowDuration => selectedRun?.duration;

  void clearWorkflowLog({int? runId}) {
    final run = runId != null ? runById(runId) : selectedRun;
    if (run != null) {
      run.log = '';
      unawaited(_saveRuns());
    } else {
      _singleStepLog = '';
    }
    notifyListeners();
  }

  /// Batches rapid stdout/stderr streaming updates (~75ms) to eliminate global
  /// widget rebuild storms while builds emit hundreds of lines per second.
  void _scheduleStreamNotify() {
    _streamNotifyPending = true;
    if (_streamNotifyTimer != null) return;
    _streamNotifyTimer = Timer(const Duration(milliseconds: 75), () {
      _streamNotifyTimer = null;
      if (_streamNotifyPending) {
        _streamNotifyPending = false;
        notifyListeners();
      }
    });
  }

  void _flushStreamNotify() {
    _streamNotifyTimer?.cancel();
    _streamNotifyTimer = null;
    if (_streamNotifyPending) {
      _streamNotifyPending = false;
    }
    notifyListeners();
  }

  void _appendRunLog(
    String chunk, {
    WorkflowRun? run,
    void Function(String)? onLogChunk,
    bool immediate = false,
  }) {
    if (chunk.isEmpty) return;
    if (run != null) {
      run.log = _trimTail('${run.log}$chunk', max: 120000);
    } else {
      _singleStepLog = _trimTail('$_singleStepLog$chunk', max: 120000);
    }
    onLogChunk?.call(chunk);
    if (immediate) {
      _flushStreamNotify();
    } else {
      _scheduleStreamNotify();
    }
  }

  String get _filePath =>
      storagePathOverride ?? p.join(DataDirectory.current.path, 'canvas.json');

  String get _runsFilePath {
    final override = storagePathOverride;
    if (override != null) {
      final base = p.basenameWithoutExtension(override);
      return p.join(p.dirname(override), '${base}_runs.json');
    }
    return p.join(DataDirectory.current.path, 'canvas_runs.json');
  }

  CanvasNode? nodeById(String id) {
    for (final n in _nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loadFuture ??= _loadInternal();
  }

  Future<void> _loadInternal() async {
    try {
      final file = File(_filePath);
      if (await file.exists()) {
        final rawText = await file.readAsString();
        try {
          final decoded = jsonDecode(rawText);
          if (decoded is List) {
            // Legacy v1 canvas.json format: bare list of nodes.
            _nodes
              ..clear()
              ..addAll([for (final item in decoded) ?CanvasNode.fromJson(item)]);
            _edges.clear();
          } else if (decoded is Map) {
            _defaultAgentId =
                (decoded['defaultAgentId'] as String?)?.trim().isNotEmpty == true
                ? (decoded['defaultAgentId'] as String).trim()
                : 'agy';
            _defaultModel = (decoded['defaultModel'] as String? ?? '').trim();
            _defaultEffort = (decoded['defaultEffort'] as String? ?? '').trim();
            _activeWorkflowName =
                (decoded['activeWorkflowName'] as String? ?? '').trim();
            final savedActiveId = (decoded['activeWorkflowId'] as String?)?.trim();
            if (savedActiveId != null && savedActiveId.isNotEmpty) {
              _activeWorkflowId = savedActiveId;
            }
            _nodes
              ..clear()
              ..addAll([
                if (decoded['nodes'] case final List list)
                  for (final item in list) ?CanvasNode.fromJson(item),
              ]);
            _edges
              ..clear()
              ..addAll([
                if (decoded['edges'] case final List list)
                  for (final item in list) ?CanvasEdge.fromJson(item),
              ]);
            _templates
              ..clear()
              ..addAll([
                if (decoded['templates'] case final List list)
                  for (final item in list) ?CanvasWorkflowTemplate.fromJson(item),
              ]);
            _workflows
              ..clear()
              ..addAll([
                if (decoded['workflows'] case final List list)
                  for (final item in list) ?CanvasWorkflowTemplate.fromJson(item),
              ]);
          }
        } on FormatException catch (e) {
          debugPrint('CanvasController corrupted JSON backed up: $e');
          // Preserve corrupted file as .bak so the user never silently loses work.
          try {
            await file.copy('${file.path}.bak');
          } on Object {
            // Ignore backup failure.
          }
        }
      }
      _syncActiveWorkflowDocument();
      await _loadRuns();
      _loaded = true;
      notifyListeners();
    } on Object catch (e) {
      debugPrint('CanvasController load failed: $e');
      _loadFuture = null;
    }
  }

  Future<void> _loadRuns() async {
    try {
      final file = File(_runsFilePath);
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      final list = decoded is Map ? decoded['runs'] : decoded;
      if (list is! List) return;
      final restored = <WorkflowRun>[
        for (final item in list) ?WorkflowRun.fromJson(item),
      ];
      if (restored.isEmpty) return;
      final existingIds = {for (final r in _runs) r.id};
      var maxId = _runSequence;
      for (final r in restored) {
        if (r.id > maxId) maxId = r.id;
        if (!existingIds.contains(r.id)) {
          _runs.add(r);
          existingIds.add(r.id);
        }
      }
      _runs.sort((a, b) => b.id.compareTo(a.id));
      _runSequence = maxId;
      _trimRunHistory();
    } on Object catch (e) {
      debugPrint('CanvasController load runs failed: $e');
    }
  }

  static Future<void> _writeFileAtomic(String targetPath, String content) async {
    final file = File(targetPath);
    await file.parent.create(recursive: true);
    final tmp = File('$targetPath.tmp');
    await tmp.writeAsString(content, flush: true);
    try {
      await tmp.rename(targetPath);
    } on FileSystemException {
      // Windows rename fails if destination is briefly held; copy + clean up.
      await file.writeAsString(content, flush: true);
      try {
        if (await tmp.exists()) await tmp.delete();
      } on Object {
        // Ignore temp cleanup failure.
      }
    }
  }

  Future<void> _saveRuns() {
    if (Platform.environment.containsKey('FLUTTER_TEST') &&
        storagePathOverride == null) {
      return Future<void>.value();
    }
    final payload = const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'runs': [
        for (final r in _runs.where((r) => !r.running).take(_maxRetainedRuns))
          r.toJson(),
      ],
    });
    final path = _runsFilePath;
    _saveRunsQueue = _saveRunsQueue.then((_) async {
      try {
        await _writeFileAtomic(path, payload);
      } on Object catch (e) {
        debugPrint('CanvasController save runs failed: $e');
      }
    });
    return _saveRunsQueue;
  }

  void _scheduleSave({bool immediate = false}) {
    if (Platform.environment.containsKey('FLUTTER_TEST') &&
        storagePathOverride == null) {
      return;
    }
    _saveDebounceTimer?.cancel();
    if (immediate) {
      unawaited(_save());
      return;
    }
    final delay = Platform.environment.containsKey('FLUTTER_TEST')
        ? const Duration(milliseconds: 15)
        : const Duration(milliseconds: 320);
    _saveDebounceTimer = Timer(delay, () {
      _saveDebounceTimer = null;
      unawaited(_save());
    });
  }

  /// Flushes any debounced board save immediately and awaits disk write.
  Future<void> flushSave() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    return _save();
  }

  Future<void> _save() {
    if (Platform.environment.containsKey('FLUTTER_TEST') &&
        storagePathOverride == null) {
      return Future<void>.value();
    }
    _syncActiveWorkflowDocument();
    final payload = const JsonEncoder.withIndent('  ').convert({
      'version': 4,
      'activeWorkflowId': _activeWorkflowId,
      'defaultAgentId': _defaultAgentId,
      'defaultModel': _defaultModel,
      'defaultEffort': _defaultEffort,
      'activeWorkflowName': _activeWorkflowName,
      'nodes': [for (final n in _nodes) n.toJson()],
      'edges': [for (final e in _edges) e.toJson()],
      'templates': [for (final t in _templates) t.toJson()],
      'workflows': [for (final w in _workflows) w.toJson()],
    });
    final path = _filePath;
    _saveQueue = _saveQueue.then((_) async {
      try {
        await _writeFileAtomic(path, payload);
      } on Object catch (e) {
        debugPrint('CanvasController save failed: $e');
      }
    });
    return _saveQueue;
  }

  // --- Graph Editing ----------------------------------------------------------

  /// Returns true if adding a directed edge `fromId -> toId` would introduce a
  /// cycle into the workflow DAG.
  bool wouldCreateCycle(String fromId, String toId, {String? ignoreEdgeId}) {
    if (fromId == toId) return true;
    final visited = <String>{toId};
    final stack = <String>[toId];
    while (stack.isNotEmpty) {
      final cur = stack.removeLast();
      if (cur == fromId) return true;
      for (final e in _edges) {
        if (ignoreEdgeId != null && e.id == ignoreEdgeId) continue;
        if (e.fromId == cur && visited.add(e.toId)) {
          stack.add(e.toId);
        }
      }
    }
    return false;
  }

  CanvasNode addNode({
    required CanvasNodeKind kind,
    required String title,
    String content = '',
    String refId = '',
    double? x,
    double? y,
    double? width,
    double? height,
    int? colorValue,
    String agentId = '',
    String model = '',
    String effort = '',
    String httpMethod = 'POST',
    String httpUrl = '',
    String httpHeaders = '',
    String conditionExpr = 'notContains:FAIL',
    int? timeoutSeconds,
    int maxRetries = 0,
    int retryDelaySeconds = 2,
    bool recoversFailure = false,
    bool recordUndo = true,
  }) {
    if (recordUndo) pushUndoSnapshot();
    final offset = (_nodes.length % 6) * 32.0;
    final defaultWidth = kind == CanvasNodeKind.group ? 540.0 : 280.0;
    final defaultHeight = switch (kind) {
      CanvasNodeKind.trigger ||
      CanvasNodeKind.condition ||
      CanvasNodeKind.approval => 165.0,
      CanvasNodeKind.http => 185.0,
      CanvasNodeKind.group => 340.0,
      _ => 190.0,
    };
    final node = CanvasNode(
      id: _nextId('node'),
      kind: kind,
      title: title,
      x: (x ?? (80 + offset)).clamp(0.0, maxBoardX),
      y: (y ?? (80 + offset)).clamp(0.0, maxBoardY),
      width: width ?? defaultWidth,
      height: height ?? defaultHeight,
      content: content,
      refId: refId,
      colorValue: colorValue ?? kind.defaultColorValue,
      agentId: agentId,
      model: model,
      effort: effort,
      httpMethod: httpMethod,
      httpUrl: httpUrl,
      httpHeaders: httpHeaders,
      conditionExpr: conditionExpr,
      timeoutSeconds: CanvasNode.normalizeTimeout(kind, timeoutSeconds),
      maxRetries: maxRetries,
      retryDelaySeconds: retryDelaySeconds,
      recoversFailure: recoversFailure,
    );
    if (kind == CanvasNodeKind.group) {
      // Group frames render behind workflow cards.
      _nodes.insert(0, node);
    } else {
      _nodes.add(node);
    }
    notifyListeners();
    _scheduleSave();
    return node;
  }

  CanvasEdge? connect(
    String fromId,
    String toId, {
    CanvasEdgeBranch branch = CanvasEdgeBranch.onPass,
    bool recordUndo = true,
  }) {
    if (fromId == toId) return null;
    final fromNode = nodeById(fromId);
    final toNode = nodeById(toId);
    if (fromNode == null || toNode == null) return null;
    if (fromNode.kind == CanvasNodeKind.group ||
        toNode.kind == CanvasNodeKind.group) {
      return null;
    }
    for (final existing in _edges) {
      if (existing.fromId == fromId &&
          existing.toId == toId &&
          existing.branch == branch) {
        return existing;
      }
    }
    if (wouldCreateCycle(fromId, toId)) return null;
    if (recordUndo) pushUndoSnapshot();
    final edge = CanvasEdge(
      id: _nextId('edge'),
      fromId: fromId,
      toId: toId,
      branch: branch,
    );
    _edges.add(edge);
    notifyListeners();
    _scheduleSave();
    return edge;
  }

  void removeEdge(String edgeId) {
    if (!_edges.any((e) => e.id == edgeId)) return;
    pushUndoSnapshot();
    _edges.removeWhere((e) => e.id == edgeId);
    notifyListeners();
    _scheduleSave();
  }

  /// Updates an existing edge's branch or endpoints safely (validating cycles).
  CanvasEdge? reconnectEdge(
    String edgeId, {
    String? fromId,
    String? toId,
    CanvasEdgeBranch? branch,
  }) {
    final idx = _edges.indexWhere((e) => e.id == edgeId);
    if (idx < 0) return null;
    final cur = _edges[idx];
    final nextFrom = fromId ?? cur.fromId;
    final nextTo = toId ?? cur.toId;
    final nextBranch = branch ?? cur.branch;
    if (nextFrom == nextTo) return null;
    if (nodeById(nextFrom) == null || nodeById(nextTo) == null) return null;
    if (wouldCreateCycle(nextFrom, nextTo, ignoreEdgeId: edgeId)) return null;
    pushUndoSnapshot();
    final updated = CanvasEdge(
      id: cur.id,
      fromId: nextFrom,
      toId: nextTo,
      branch: nextBranch,
    );
    _edges[idx] = updated;
    notifyListeners();
    _scheduleSave();
    return updated;
  }

  /// Inserts a new node of [kind] midway along [edgeId], rewiring
  /// `from -> newNode (edge.branch)` and `newNode -> to (onPass)`.
  CanvasNode? insertNodeOnEdge(
    String edgeId,
    CanvasNodeKind kind, {
    String? title,
  }) {
    final idx = _edges.indexWhere((e) => e.id == edgeId);
    if (idx < 0) return null;
    final edge = _edges[idx];
    final from = nodeById(edge.fromId);
    final to = nodeById(edge.toId);
    if (from == null || to == null) return null;

    pushUndoSnapshot();
    final midX = ((from.x + to.x) / 2.0).clamp(0.0, maxBoardX);
    final midY = ((from.y + to.y) / 2.0).clamp(0.0, maxBoardY);
    final created = addNode(
      kind: kind,
      title: (title != null && title.trim().isNotEmpty)
          ? title.trim()
          : kind.label(true),
      refId: from.refId,
      x: midX,
      y: midY,
      recordUndo: false,
    );
    _edges.removeWhere((e) => e.id == edgeId);
    _edges.add(
      CanvasEdge(
        id: _nextId('edge'),
        fromId: edge.fromId,
        toId: created.id,
        branch: edge.branch,
      ),
    );
    _edges.add(
      CanvasEdge(
        id: _nextId('edge'),
        fromId: created.id,
        toId: edge.toId,
        branch: CanvasEdgeBranch.onPass,
      ),
    );
    notifyListeners();
    _scheduleSave();
    return created;
  }

  void moveNode(String id, double dx, double dy) {
    for (final n in _nodes) {
      if (n.id == id) {
        n.x = (n.x + dx).clamp(0.0, maxBoardX);
        n.y = (n.y + dy).clamp(0.0, maxBoardY);
        notifyListeners();
        return;
      }
    }
  }

  /// Moves a set of selected nodes together by `(dx, dy)` in a single notify.
  void moveNodes(Set<String> ids, double dx, double dy) {
    if (ids.isEmpty || (dx == 0 && dy == 0)) return;
    var changed = false;
    for (final n in _nodes) {
      if (ids.contains(n.id)) {
        n.x = (n.x + dx).clamp(0.0, maxBoardX);
        n.y = (n.y + dy).clamp(0.0, maxBoardY);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// Sets exact positions for multiple nodes (e.g. after snapping or nudge).
  void setNodePositions(Map<String, ({double x, double y})> positions) {
    if (positions.isEmpty) return;
    var changed = false;
    for (final n in _nodes) {
      final pos = positions[n.id];
      if (pos != null) {
        n.x = pos.x.clamp(0.0, maxBoardX);
        n.y = pos.y.clamp(0.0, maxBoardY);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// Aligns or distributes 2+ selected nodes cleanly (Figma-style alignment).
  void alignNodes(Set<String> ids, CanvasNodeAlignment alignment) {
    final selected = [
      for (final n in _nodes)
        if (ids.contains(n.id)) n,
    ];
    if (selected.length < 2) return;
    pushUndoSnapshot();
    switch (alignment) {
      case CanvasNodeAlignment.left:
        final target = selected.map((n) => n.x).reduce(math.min);
        for (final n in selected) {
          n.x = target;
        }
      case CanvasNodeAlignment.centerH:
        final avg =
            selected.map((n) => n.x + n.width / 2).reduce((a, b) => a + b) /
            selected.length;
        for (final n in selected) {
          n.x = (avg - n.width / 2).clamp(0.0, maxBoardX);
        }
      case CanvasNodeAlignment.right:
        final target = selected.map((n) => n.x + n.width).reduce(math.max);
        for (final n in selected) {
          n.x = (target - n.width).clamp(0.0, maxBoardX);
        }
      case CanvasNodeAlignment.top:
        final target = selected.map((n) => n.y).reduce(math.min);
        for (final n in selected) {
          n.y = target;
        }
      case CanvasNodeAlignment.centerV:
        final avg =
            selected.map((n) => n.y + n.height / 2).reduce((a, b) => a + b) /
            selected.length;
        for (final n in selected) {
          n.y = (avg - n.height / 2).clamp(0.0, maxBoardY);
        }
      case CanvasNodeAlignment.bottom:
        final target = selected.map((n) => n.y + n.height).reduce(math.max);
        for (final n in selected) {
          n.y = (target - n.height).clamp(0.0, maxBoardY);
        }
      case CanvasNodeAlignment.distributeH:
        if (selected.length >= 3) {
          selected.sort((a, b) => a.x.compareTo(b.x));
          final minX = selected.first.x;
          final maxX = selected.last.x;
          final step = (maxX - minX) / (selected.length - 1);
          for (var i = 1; i < selected.length - 1; i++) {
            selected[i].x = minX + step * i;
          }
        }
      case CanvasNodeAlignment.distributeV:
        if (selected.length >= 3) {
          selected.sort((a, b) => a.y.compareTo(b.y));
          final minY = selected.first.y;
          final maxY = selected.last.y;
          final step = (maxY - minY) / (selected.length - 1);
          for (var i = 1; i < selected.length - 1; i++) {
            selected[i].y = minY + step * i;
          }
        }
    }
    notifyListeners();
    _scheduleSave();
  }

  void resizeNode(String id, double dw, double dh) {
    for (final n in _nodes) {
      if (n.id == id) {
        final maxW = n.kind == CanvasNodeKind.group ? 1800.0 : 960.0;
        final maxH = n.kind == CanvasNodeKind.group ? 1200.0 : 760.0;
        n.width = (n.width + dw).clamp(200.0, maxW);
        n.height = (n.height + dh).clamp(120.0, maxH);
        notifyListeners();
        return;
      }
    }
  }

  void commitLayout() => _scheduleSave();

  void updateNode(
    String id, {
    String? title,
    String? content,
    String? refId,
    int? colorValue,
    String? agentId,
    String? model,
    String? effort,
    String? httpMethod,
    String? httpUrl,
    String? httpHeaders,
    String? conditionExpr,
    int? timeoutSeconds,
    int? maxRetries,
    int? retryDelaySeconds,
    bool? recoversFailure,
  }) {
    for (final n in _nodes) {
      if (n.id == id) {
        final now = DateTime.now();
        final shouldPush =
            _lastTypingUndoNodeId != id ||
            _lastTypingUndoAt == null ||
            now.difference(_lastTypingUndoAt!) >
                const Duration(milliseconds: 1200);
        if (shouldPush) {
          pushUndoSnapshot();
        }
        _lastTypingUndoNodeId = id;
        _lastTypingUndoAt = now;

        if (title != null) n.title = title;
        if (content != null) n.content = content;
        if (refId != null) n.refId = refId;
        if (colorValue != null) n.colorValue = colorValue;
        if (agentId != null) n.agentId = agentId;
        if (model != null) n.model = model;
        if (effort != null) n.effort = effort;
        if (httpMethod != null) n.httpMethod = httpMethod;
        if (httpUrl != null) n.httpUrl = httpUrl;
        if (httpHeaders != null) n.httpHeaders = httpHeaders;
        if (conditionExpr != null) n.conditionExpr = conditionExpr;
        if (timeoutSeconds != null) {
          n.timeoutSeconds = CanvasNode.normalizeTimeout(
            n.kind,
            timeoutSeconds,
          );
        }
        if (maxRetries != null) n.maxRetries = maxRetries.clamp(0, 5);
        if (retryDelaySeconds != null) {
          n.retryDelaySeconds = retryDelaySeconds.clamp(0, 120);
        }
        if (recoversFailure != null) n.recoversFailure = recoversFailure;
        notifyListeners();
        _scheduleSave();
        return;
      }
    }
  }

  void removeNode(String id) {
    if (nodeById(id) == null) return;
    pushUndoSnapshot();
    _nodes.removeWhere((n) => n.id == id);
    _edges.removeWhere((e) => e.fromId == id || e.toId == id);
    notifyListeners();
    _scheduleSave();
  }

  void removeNodes(Set<String> ids) {
    if (ids.isEmpty) return;
    if (!_nodes.any((n) => ids.contains(n.id))) return;
    pushUndoSnapshot();
    _nodes.removeWhere((n) => ids.contains(n.id));
    _edges.removeWhere((e) => ids.contains(e.fromId) || ids.contains(e.toId));
    notifyListeners();
    _scheduleSave();
  }

  /// Duplicates an existing node slightly offset for fast authoring.
  CanvasNode? duplicateNode(String id) {
    final src = nodeById(id);
    if (src == null) return null;
    final copy = addNode(
      kind: src.kind,
      title: '${src.title} (副本)',
      content: src.content,
      refId: src.refId,
      x: src.x + 36,
      y: src.y + 36,
      width: src.width,
      height: src.height,
      colorValue: src.colorValue,
      agentId: src.agentId,
      model: src.model,
      effort: src.effort,
      httpMethod: src.httpMethod,
      httpUrl: src.httpUrl,
      httpHeaders: src.httpHeaders,
      conditionExpr: src.conditionExpr,
      timeoutSeconds: src.timeoutSeconds,
      maxRetries: src.maxRetries,
      retryDelaySeconds: src.retryDelaySeconds,
      recoversFailure: src.recoversFailure,
    );
    return copy;
  }

  /// Duplicates multiple selected nodes and preserves all internal edges
  /// between them. Returns the list of newly created nodes.
  List<CanvasNode> duplicateNodes(
    Set<String> ids, {
    double dx = 40,
    double dy = 40,
  }) {
    final selected = [
      for (final n in _nodes)
        if (ids.contains(n.id)) n,
    ];
    if (selected.isEmpty) return const [];
    final internalEdges = [
      for (final e in _edges)
        if (ids.contains(e.fromId) && ids.contains(e.toId)) e,
    ];
    return pasteNodes(
      selected,
      internalEdges,
      dx: dx,
      dy: dy,
      appendCopySuffix: selected.length == 1,
    );
  }

  /// Pastes copied [sourceNodes] and their internal [sourceEdges] offset by
  /// `(dx, dy)` as a single undoable transaction.
  List<CanvasNode> pasteNodes(
    List<CanvasNode> sourceNodes,
    List<CanvasEdge> sourceEdges, {
    double dx = 44,
    double dy = 44,
    bool appendCopySuffix = false,
  }) {
    if (sourceNodes.isEmpty) return const [];
    pushUndoSnapshot();
    final idMap = <String, String>{};
    final created = <CanvasNode>[];
    for (final src in sourceNodes) {
      final copy = addNode(
        kind: src.kind,
        title: appendCopySuffix ? '${src.title} (副本)' : src.title,
        content: src.content,
        refId: src.refId,
        x: src.x + dx,
        y: src.y + dy,
        width: src.width,
        height: src.height,
        colorValue: src.colorValue,
        agentId: src.agentId,
        model: src.model,
        effort: src.effort,
        httpMethod: src.httpMethod,
        httpUrl: src.httpUrl,
        httpHeaders: src.httpHeaders,
        conditionExpr: src.conditionExpr,
        timeoutSeconds: src.timeoutSeconds,
        maxRetries: src.maxRetries,
        retryDelaySeconds: src.retryDelaySeconds,
        recoversFailure: src.recoversFailure,
        recordUndo: false,
      );
      idMap[src.id] = copy.id;
      created.add(copy);
    }
    for (final e in sourceEdges) {
      final f = idMap[e.fromId];
      final t = idMap[e.toId];
      if (f != null && t != null && f != t) {
        _edges.add(
          CanvasEdge(
            id: _nextId('edge'),
            fromId: f,
            toId: t,
            branch: e.branch,
          ),
        );
      }
    }
    notifyListeners();
    _scheduleSave();
    return created;
  }

  /// One-click authoring helper: creates a downstream node neatly placed beside
  /// [fromId] (or at explicit [x]/[y]) and wires the [branch] edge immediately.
  CanvasNode? addConnectedNode({
    required String fromId,
    required CanvasEdgeBranch branch,
    required CanvasNodeKind kind,
    required String title,
    String content = '',
    String refId = '',
    String httpUrl = '',
    double? x,
    double? y,
  }) {
    final src = nodeById(fromId);
    if (src == null) return null;
    pushUndoSnapshot();
    final siblings = _edges.where((e) => e.fromId == fromId).length;
    final targetX = (x ?? (src.x + src.width + 80)).clamp(40.0, maxBoardX);
    final targetY =
        (y ??
                (src.y +
                    (branch == CanvasEdgeBranch.onFail
                        ? 220.0
                        : siblings * 185.0)))
            .clamp(40.0, maxBoardY);
    final created = addNode(
      kind: kind,
      title: title,
      content: content,
      refId: refId.isNotEmpty ? refId : src.refId,
      x: targetX,
      y: targetY,
      httpUrl: httpUrl,
      recordUndo: false,
    );
    connect(fromId, created.id, branch: branch, recordUndo: false);
    return created;
  }

  /// Arranges all non-group nodes cleanly from left to right by DAG topological
  /// depth, placing failure-branch nodes neatly on a lower lane.
  void autoLayout() {
    if (_nodes.isEmpty) return;
    pushUndoSnapshot();
    _autoLayoutInternal();
    notifyListeners();
    _scheduleSave();
  }

  void _autoLayoutInternal() {
    final layoutNodes = [
      for (final n in _nodes)
        if (n.kind != CanvasNodeKind.group) n,
    ];
    if (layoutNodes.isEmpty) return;
    final depth = <String, int>{for (final n in layoutNodes) n.id: 0};
    final failOnly = <String>{};
    for (final n in layoutNodes) {
      final incoming = _edges.where((e) => e.toId == n.id).toList();
      if (incoming.isNotEmpty &&
          incoming.every((e) => e.branch == CanvasEdgeBranch.onFail)) {
        failOnly.add(n.id);
      }
    }

    // Relax longest-path depths up to N iterations (DAG-safe even with cycles).
    for (var iter = 0; iter < layoutNodes.length; iter++) {
      var changed = false;
      for (final e in _edges) {
        if (!depth.containsKey(e.fromId) || !depth.containsKey(e.toId)) {
          continue;
        }
        final next = depth[e.fromId]! + 1;
        if (next > depth[e.toId]!) {
          depth[e.toId] = next;
          changed = true;
        }
      }
      if (!changed) break;
    }

    // Group primary-lane nodes by column depth.
    final columns = <int, List<CanvasNode>>{};
    final failNodes = <CanvasNode>[];
    for (final n in layoutNodes) {
      if (failOnly.contains(n.id)) {
        failNodes.add(n);
      } else {
        final col = depth[n.id] ?? 0;
        (columns[col] ??= []).add(n);
      }
    }

    const startX = 48.0;
    const startY = 84.0;
    const colGap = 350.0;
    const rowGap = 230.0;

    var maxMainY = startY + rowGap;
    final sortedCols = columns.keys.toList()..sort();
    for (final col in sortedCols) {
      final list = columns[col]!;
      for (var row = 0; row < list.length; row++) {
        final node = list[row];
        node.x = startX + col * colGap;
        node.y = startY + row * rowGap;
        final bottom = node.y + node.height;
        if (bottom > maxMainY) maxMainY = bottom;
      }
    }

    for (var i = 0; i < failNodes.length; i++) {
      final node = failNodes[i];
      node.x = startX + (i + 1) * colGap;
      node.y = maxMainY + 76.0;
    }
  }

  void clearBoard() {
    if (_nodes.isNotEmpty || _edges.isNotEmpty) {
      pushUndoSnapshot();
    }
    _selectedRunId = null;
    _nodes.clear();
    _edges.clear();
    _singleStepLog = '';
    _activeWorkflowName = '';
    notifyListeners();
    _scheduleSave();
  }

  // --- Templates --------------------------------------------------------------

  static String _effectiveAngularRoot(String? defaultCwd) {
    if (defaultCwd != null &&
        defaultCwd.isNotEmpty &&
        Directory(p.join(defaultCwd, 'lc')).existsSync()) {
      return defaultCwd;
    }
    return defaultAngular21Root;
  }

  /// Built-in Template #1: Local PLM Rebuild & Restart
  /// LC -> BC -> Install to PDM/PPM/UMC -> tmux restart (SSO kept alive).
  static CanvasWorkflowTemplate buildPlmLocalRebuildTemplate({
    String? defaultCwd,
  }) {
    final root = _effectiveAngularRoot(defaultCwd);
    final nodes = [
      CanvasNode(
        id: 'plm_trigger',
        kind: CanvasNodeKind.trigger,
        title: '1. 工作区配置（angular21）',
        x: 48,
        y: 84,
        width: 270,
        height: 170,
        colorValue: CanvasNodeKind.trigger.defaultColorValue,
        refId: root,
        content: 'root=$root\napps=pdm umc ppm',
      ),
      CanvasNode(
        id: 'plm_build_lc',
        kind: CanvasNodeKind.command,
        title: '2. 重新打包 LC',
        x: 398,
        y: 84,
        width: 275,
        height: 175,
        colorValue: CanvasNodeKind.command.defaultColorValue,
        refId: root,
        content:
            'cd "{{input.root}}/lc" && '
            'node projects/ng-lc-dpp/dpp-table/scripts/build-grid-styles.mjs && '
            './node_modules/.bin/ng build ng-lc-dpp-lib',
      ),
      CanvasNode(
        id: 'plm_build_bc',
        kind: CanvasNodeKind.command,
        title: '3. 同步 LC 并重新打包 BC',
        x: 748,
        y: 84,
        width: 275,
        height: 175,
        colorValue: CanvasNodeKind.command.defaultColorValue,
        refId: root,
        content:
            'cd "{{input.root}}" && '
            'rm -rf ng-bc-dpp/node_modules/ng-lc-dpp && '
            'cp -R lc/dist/ng-lc-dpp ng-bc-dpp/node_modules/ng-lc-dpp && '
            'cd ng-bc-dpp && ./node_modules/.bin/ng build ng-bc-dpp',
      ),
      CanvasNode(
        id: 'plm_install_apps',
        kind: CanvasNodeKind.command,
        title: '4. 装入 PDM / PPM / UMC 并清缓存',
        x: 1098,
        y: 84,
        width: 280,
        height: 180,
        colorValue: CanvasNodeKind.command.defaultColorValue,
        refId: root,
        content:
            'cd "{{input.root}}" && '
            'for app in {{input.apps}}; do '
            'rm -rf "\$app/node_modules/ng-lc-dpp" "\$app/node_modules/ng-bc-dpp" "\$app/.angular/cache" "\$app/node_modules/.cache" && '
            'cp -R lc/dist/ng-lc-dpp "\$app/node_modules/ng-lc-dpp" && '
            'cp -R ng-bc-dpp/dist/ng-bc-dpp "\$app/node_modules/ng-bc-dpp"; '
            'done && echo "已同步 LC/BC 至 {{input.apps}}"',
      ),
      CanvasNode(
        id: 'plm_tmux_restart',
        kind: CanvasNodeKind.command,
        title: '5. tmux 重启 PDM/UMC/PPM（SSO 常驻）',
        x: 1448,
        y: 84,
        width: 290,
        height: 185,
        colorValue: CanvasNodeKind.command.defaultColorValue,
        refId: root,
        content: '''ROOT="{{input.root}}"
if ! tmux has-session -t plm 2>/dev/null; then
  tmux new-session -d -s plm -n sso -c "\$ROOT/sso"
  tmux new-window -d -t plm -n pdm -c "\$ROOT/pdm"
  tmux new-window -d -t plm -n umc -c "\$ROOT/umc"
  tmux new-window -d -t plm -n ppm -c "\$ROOT/ppm"
  for w in sso pdm umc ppm; do tmux set-option -w -t plm:\$w remain-on-exit on; done
fi
# SSO 保持常驻：仅在 4201 未监听时拉起
if [ "\$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:4201/)" != "200" ]; then
  tmux send-keys -t plm:sso C-c; sleep 0.5
  tmux send-keys -t plm:sso "./node_modules/.bin/ng serve --port 4201 --host=0.0.0.0 2>&1 | tee /tmp/plm-sso.log" Enter
fi
for w in pdm umc ppm; do tmux send-keys -t plm:\$w C-c; done
sleep 1
tmux send-keys -t plm:pdm "./node_modules/.bin/ng serve --host=0.0.0.0 --allowed-hosts=all --port 4200 2>&1 | tee /tmp/plm-pdm.log" Enter
tmux send-keys -t plm:umc "./node_modules/.bin/ng serve --hmr --port=4203 --host=0.0.0.0 --allowed-hosts=all 2>&1 | tee /tmp/plm-umc.log" Enter
tmux send-keys -t plm:ppm "./node_modules/.bin/ng serve --port 4205 --host=0.0.0.0 2>&1 | tee /tmp/plm-ppm.log" Enter
echo "已通过 tmux (plm) 重启 pdm/umc/ppm，sso 保持常驻"''',
      ),
      CanvasNode(
        id: 'plm_health_check',
        kind: CanvasNodeKind.command,
        title: '6. 四端口健康校验（4200/4201/4203/4205）',
        x: 1798,
        y: 84,
        width: 280,
        height: 175,
        colorValue: CanvasNodeKind.http.defaultColorValue,
        refId: root,
        content: '''for i in \$(seq 1 45); do
  ok=1
  for port in 4201 4200 4203 4205; do
    code=\$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:\$port/")
    [ "\$code" = "200" ] || ok=0
  done
  if [ "\$ok" = "1" ]; then
    echo "✅ 4201(sso) / 4200(pdm) / 4203(umc) / 4205(ppm) 全部就绪 (200)"
    exit 0
  fi
  sleep 2
done
echo "❌ 部分端口未在 90s 内就绪，请检查 /tmp/plm-*.log"
exit 1''',
      ),
      CanvasNode(
        id: 'plm_fail_diag',
        kind: CanvasNodeKind.command,
        title: '失败日志排查（/tmp/plm-*.log）',
        x: 748,
        y: 350,
        width: 280,
        height: 165,
        colorValue: 0xFFE5534B,
        refId: root,
        content:
            'for f in /tmp/plm-pdm.log /tmp/plm-umc.log /tmp/plm-ppm.log; do '
            'echo "=== \$f ==="; tail -n 15 "\$f" 2>/dev/null; done',
      ),
    ];
    const edges = [
      CanvasEdge(id: 'plm_e1', fromId: 'plm_trigger', toId: 'plm_build_lc'),
      CanvasEdge(id: 'plm_e2', fromId: 'plm_build_lc', toId: 'plm_build_bc'),
      CanvasEdge(
        id: 'plm_e2f',
        fromId: 'plm_build_lc',
        toId: 'plm_fail_diag',
        branch: CanvasEdgeBranch.onFail,
      ),
      CanvasEdge(id: 'plm_e3', fromId: 'plm_build_bc', toId: 'plm_install_apps'),
      CanvasEdge(
        id: 'plm_e3f',
        fromId: 'plm_build_bc',
        toId: 'plm_fail_diag',
        branch: CanvasEdgeBranch.onFail,
      ),
      CanvasEdge(
        id: 'plm_e4',
        fromId: 'plm_install_apps',
        toId: 'plm_tmux_restart',
      ),
      CanvasEdge(
        id: 'plm_e5',
        fromId: 'plm_tmux_restart',
        toId: 'plm_health_check',
      ),
      CanvasEdge(
        id: 'plm_e6f',
        fromId: 'plm_health_check',
        toId: 'plm_fail_diag',
        branch: CanvasEdgeBranch.onFail,
      ),
    ];
    return CanvasWorkflowTemplate(
      id: plmLocalRebuildTemplateId,
      name: '本地重建启动（LC→BC→PDM/PPM/UMC + SSO 常驻）',
      nodes: nodes,
      edges: edges,
    );
  }

  /// Helper that builds a deterministic, zero-token shell script calling
  /// Jenkins' REST API directly through the user's logged-in Tabbit browser tab
  /// (using `/crumbIssuer/api/json`, `/buildWithParameters`, short-interval
  /// `/api/json` polling, and `/consoleText` tail on failure).
  static String _buildJenkinsZeroTokenScript({
    required String stepLabel,
    required String skipCheckShell,
    required String jobSpecShell,
    String? verifyVerdaccioPkg,
  }) {
    final verdaccioCheck = verifyVerdaccioPkg == null
        ? ''
        : '''
VER_AFTER=\$(curl -sS -m 5 "{{input.registryUrl}}/-/package/$verifyVerdaccioPkg/dist-tags" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(String(d[process.argv[1]]||""));' "{{input.distTag}}" 2>/dev/null || true)
echo "📦 私服版本确认: $verifyVerdaccioPkg@{{input.distTag}} = \${VER_AFTER:-unknown}"
''';
    return '''set -euo pipefail
DEPLOY_MODE="{{input.deployMode}}"
APPROVAL_NOTE="{{approval.note}}"
JENKINS_BASE="{{input.jenkinsBaseUrl}}"
TABBIT="\$HOME/.local/bin/tabbit-cli"

$skipCheckShell

if [ ! -x "\$TABBIT" ]; then
  echo "❌ 未找到 Tabbit CLI (\$TABBIT)，请确认已安装 tabbit-cli。"
  exit 1
fi

DIAG_OUT="\$("\$TABBIT" diagnose 2>&1 || true)"
INST="\$(printf '%s\\n' "\$DIAG_OUT" | sed -n 's/.*TABBIT_PLAYWRIGHT_INSTANCE=\\([A-Fa-f0-9]\\{8,\\}\\).*/\\1/p' | head -n 1)"
if [ -n "\$INST" ]; then
  export TABBIT_PLAYWRIGHT_INSTANCE="\$INST"
fi

TAB_ID="\$(printf '%s\\n' "\$DIAG_OUT" | JENKINS_BASE="\$JENKINS_BASE" node -e '
  const raw = require("fs").readFileSync(0, "utf8");
  const idx = raw.indexOf("{");
  if (idx < 0) process.exit(0);
  const host = (process.env.JENKINS_BASE || "172.16.100.122:4875").replace(/^https?:\\/\\//, "").replace(/\\/.*\$/, "");
  try {
    const j = JSON.parse(raw.slice(idx));
    const all = [
      ...(j.available?.tabs || []),
      ...((j.available?.groups || []).flatMap(g => g.tabs || [])),
      ...((j.owned?.tabs || [])),
    ];
    const hit = all.find(t => String(t.url || "").includes(host));
    if (hit && hit.tabId != null) process.stdout.write(String(hit.tabId));
  } catch {}
')"

if [ -z "\$TAB_ID" ]; then
  echo "❌ 未在 Tabbit 中找到已打开的 Jenkins 标签页 (\$JENKINS_BASE)。"
  echo "请先在 Tabbit 浏览器中打开并登录 \$JENKINS_BASE，然后点击「从失败节点续跑」即可零 Token 继续！"
  exit 1
fi

TASK_NAME="ayte_j69_\$\$"
cleanup() {
  "\$TABBIT" finish --task "\$TASK_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_jenkins_job() {
  local JOB_URL="\$1"
  local PARAMS_QUERY="\$2"
  local LABEL="\$3"
  local CLAIM_FLAG="\$4"
  echo "▶ [\$LABEL] 直调 Jenkins API（零 Token）: \$JOB_URL"
  echo "  参数: \${PARAMS_QUERY:-(无参数)}"

  # 1. 检查登录态、Executor 负载、CSRF Crumb 并触发 buildWithParameters
  local TRIGGER_JSON
  TRIGGER_JSON="\$(JOB_URL="\$JOB_URL" PARAMS_QUERY="\$PARAMS_QUERY" "\$TABBIT" nodejs --task "\$TASK_NAME" \$CLAIM_FLAG --timeout-ms 25000 <<JS
const jobUrl = "\$JOB_URL".replace(/\\/+\$/, "");
const params = "\$PARAMS_QUERY";
const base = new URL(jobUrl).origin;
const comp = await page.fetch(base + "/computer/api/json?tree=computer[displayName,numExecutors,idle,executors[currentExecutable[fullDisplayName]]]", {as: "json"});
if (!comp.ok) throw new Error("Jenkins 会话未登录或无权限 (HTTP " + comp.status + ")，请先在 Tabbit 登录 " + base);
const busy = [];
for (const c of (comp.json?.computer || [])) {
  for (const ex of (c.executors || [])) {
    if (ex.currentExecutable?.fullDisplayName) busy.push(ex.currentExecutable.fullDisplayName);
  }
}
const infoBefore = await page.fetch(jobUrl + "/api/json?tree=lastBuild[number],nextBuildNumber", {as: "json"});
if (!infoBefore.ok) throw new Error("读取 Job 信息失败 (HTTP " + infoBefore.status + "): " + jobUrl);
const prevNum = Number(infoBefore.json?.lastBuild?.number || 0);
const crumbRes = await page.fetch(base + "/crumbIssuer/api/json", {as: "json"});
const headers = {"Content-Type": "application/x-www-form-urlencoded"};
if (crumbRes.ok && crumbRes.json?.crumbRequestField && crumbRes.json?.crumb) {
  headers[crumbRes.json.crumbRequestField] = crumbRes.json.crumb;
}
const endpoint = params ? (jobUrl + "/buildWithParameters") : (jobUrl + "/build");
const trig = await page.fetch(endpoint, {method: "POST", headers, body: params, as: "text"});
if (!trig.ok && trig.status !== 201 && trig.status !== 302) {
  throw new Error("触发构建失败 (HTTP " + trig.status + "): " + (trig.text || "").slice(0, 240));
}
return {prevNum, nextHint: Number(infoBefore.json?.nextBuildNumber || prevNum + 1), busy};
JS
)"

  local PREV_NUM
  PREV_NUM="\$(printf '%s\\n' "\$TRIGGER_JSON" | node -e '
    const raw = require("fs").readFileSync(0, "utf8");
    const idx = raw.indexOf("{");
    const j = JSON.parse(raw.slice(idx));
    const r = j.result || j.value || j;
    if (r.busy && r.busy.length) console.error("  当前集群忙碌任务 (" + r.busy.length + "): " + r.busy.join(" | "));
    else console.error("  当前 Jenkins Executor 空闲");
    process.stdout.write(String(r.prevNum ?? 0));
  ')"

  echo "  已提交构建请求（触发前最新构建号: #\$PREV_NUM），等待分配新构建号..."
  local BUILD_NUM=""
  for wait_i in \$(seq 1 45); do
    sleep 3
    local POLL_NUM
    POLL_NUM="\$("\$TABBIT" nodejs --task "\$TASK_NAME" --timeout-ms 15000 <<JS
const jobUrl = "\$JOB_URL".replace(/\\/+\$/, "");
const r = await page.fetch(jobUrl + "/api/json?tree=lastBuild[number],inQueue", {as: "json"});
return {lastNum: Number(r.json?.lastBuild?.number || 0), inQueue: Boolean(r.json?.inQueue)};
JS
)"
    BUILD_NUM="\$(printf '%s\\n' "\$POLL_NUM" | PREV_NUM="\$PREV_NUM" node -e '
      const raw = require("fs").readFileSync(0, "utf8");
      const j = JSON.parse(raw.slice(raw.indexOf("{")));
      const r = j.result || j.value || j;
      const prev = Number(process.env.PREV_NUM || 0);
      if (Number(r.lastNum || 0) > prev) process.stdout.write(String(r.lastNum));
    ')"
    if [ -n "\$BUILD_NUM" ]; then
      echo "  ✓ 已进入构建: #\$BUILD_NUM (\$JOB_URL/\$BUILD_NUM/)"
      break
    fi
  done

  if [ -z "\$BUILD_NUM" ]; then
    echo "❌ 等待 135s 仍未分配新构建号（可能被队列阻塞或参数被去重跳过），请检查 \$JOB_URL"
    exit 1
  fi

  # 2. 短间隔轮询 /api/json（单次调用 <10s，永不触发超时）
  for poll_i in \$(seq 1 120); do
    local STATUS_OUT
    STATUS_OUT="\$("\$TABBIT" nodejs --task "\$TASK_NAME" --timeout-ms 15000 <<JS
const jobUrl = "\$JOB_URL".replace(/\\/+\$/, "");
const r = await page.fetch(jobUrl + "/\$BUILD_NUM/api/json?tree=number,building,result,duration,estimatedDuration", {as: "json"});
return r.json || {};
JS
)"
    local PARSED
    PARSED="\$(printf '%s\\n' "\$STATUS_OUT" | node -e '
      const raw = require("fs").readFileSync(0, "utf8");
      const j = JSON.parse(raw.slice(raw.indexOf("{")));
      const r = j.result || j.value || j;
      const b = r.building ? "1" : "0";
      const res = r.result || "";
      const sec = Math.round(Number(r.duration || 0) / 1000);
      process.stdout.write(b + "|" + res + "|" + sec);
    ')"
    local BUILDING="\${PARSED%%|*}"
    local REST="\${PARSED#*|}"
    local RESULT="\${REST%%|*}"
    local DUR_SEC="\${REST#*|}"
    if [ "\$BUILDING" = "0" ] && [ -n "\$RESULT" ]; then
      if [ "\$RESULT" = "SUCCESS" ]; then
        echo "✅ [\$LABEL] #\$BUILD_NUM 构建成功（耗时 \${DUR_SEC}s）"
        return 0
      fi
      echo "❌ [\$LABEL] #\$BUILD_NUM 构建未通过（result=\$RESULT，耗时 \${DUR_SEC}s），抓取末尾控制台日志："
      "\$TABBIT" nodejs --task "\$TASK_NAME" --timeout-ms 15000 <<JS || true
const jobUrl = "\$JOB_URL".replace(/\\/+\$/, "");
const r = await page.fetch(jobUrl + "/\$BUILD_NUM/consoleText", {as: "text"});
const lines = String(r.text || "").split(/\\r?\\n/);
return lines.slice(-35).join("\\n");
JS
      exit 1
    fi
    if [ \$((poll_i % 2)) -eq 1 ]; then
      echo "  ⏳ [\$LABEL] #\$BUILD_NUM 运行中（已轮询 \$((poll_i * 8))s）..."
    fi
    sleep 8
  done
  echo "❌ [\$LABEL] #\$BUILD_NUM 超过 16 分钟仍未结束，已判定超时阻断。"
  exit 1
}

$jobSpecShell
$verdaccioCheck
echo "✅ $stepLabel 全部完成！"''';
  }

  /// Built-in Template #2: Zero-Token Smart Fast-Path / Full Jenkins 69-sts Deployment
  /// Uses direct Jenkins REST API via logged-in Tabbit tab (`frontend-lc`,
  /// `frontend-bc`, `frontend-pdm`, `build-all-project`), zero LLM tokens burned,
  /// avoids nested `BUILD_LC_FIRST` deadlocks, and verifies Verdaccio dist-tags.
  static CanvasWorkflowTemplate buildDeploy69Template({String? defaultCwd}) {
    final root = _effectiveAngularRoot(defaultCwd);
    final nodes = [
      CanvasNode(
        id: 'd69_trigger',
        kind: CanvasNodeKind.trigger,
        title: '1. 69 极速/全量部署参数',
        x: 48,
        y: 84,
        width: 285,
        height: 205,
        colorValue: CanvasNodeKind.trigger.defaultColorValue,
        refId: root,
        content:
            'root=$root\n'
            'deployMode=smart\n'
            'targetApps=pdm\n'
            'jenkinsBaseUrl=http://172.16.100.122:4875\n'
            'jenkinsUrl=$defaultJenkins69Url\n'
            'allJobUrl=http://172.16.100.122:4875/view/%E5%BF%AB%E9%80%9F%E6%9E%84%E5%BB%BA/job/build-all-project/\n'
            'lcJobUrl=http://172.16.100.122:4875/job/frontend-lc/job/feature%252Fangular-upgrade/\n'
            'bcJobUrl=http://172.16.100.122:4875/job/frontend-bc/job/feature%252Fangular-upgrade/\n'
            'pdmJobUrl=http://172.16.100.122:4875/job/frontend-pdm/job/feature%252Fangular-upgrade/\n'
            'registryUrl=http://172.16.100.122:4873\n'
            'distTag=test5030\n'
            'branch=feature/angular-upgrade\n'
            'deployTarget=69-sts\n'
            'deploySource=frontEnd\n'
            'repos=lc ng-bc-dpp pdm ppm umc sso',
      ),
      CanvasNode(
        id: 'd69_git_check',
        kind: CanvasNodeKind.command,
        title: '2. 扫描仓库改动 & 记录私服版本基线',
        x: 398,
        y: 84,
        width: 290,
        height: 190,
        colorValue: CanvasNodeKind.command.defaultColorValue,
        refId: root,
        content: '''cd "{{input.root}}"
echo "=== 1. 本地仓库分支 / 未提交 / 待推送状态 ==="
for repo in {{input.repos}}; do
  if [ -d "\$repo/.git" ]; then
    b=\$(git -C "\$repo" branch --show-current)
    dirty=\$(git -C "\$repo" status --short | wc -l | tr -d ' ')
    ahead=\$(git -C "\$repo" rev-list --count "@{u}..HEAD" 2>/dev/null || echo "?")
    sha=\$(git -C "\$repo" rev-parse --short HEAD 2>/dev/null)
    echo "[\$repo] 分支:\$b | HEAD:\$sha | 未提交:\$dirty | 待推送:\$ahead"
  fi
done
echo ""
echo "=== 2. 部署前私服 ({{input.registryUrl}}) {{input.distTag}} 版本基线 ==="
LC_BEFORE=\$(curl -sS -m 5 "{{input.registryUrl}}/-/package/ng-lc-dpp/dist-tags" | python3 -c "import sys,json; print(json.load(sys.stdin).get('{{input.distTag}}',''))" 2>/dev/null || echo "")
BC_BEFORE=\$(curl -sS -m 5 "{{input.registryUrl}}/-/package/ng-bc-dpp/dist-tags" | python3 -c "import sys,json; print(json.load(sys.stdin).get('{{input.distTag}}',''))" 2>/dev/null || echo "")
echo "LC_BEFORE=\$LC_BEFORE" > /tmp/ayte-69-baseline.env
echo "BC_BEFORE=\$BC_BEFORE" >> /tmp/ayte-69-baseline.env
echo "ng-lc-dpp@{{input.distTag}} = \$LC_BEFORE"
echo "ng-bc-dpp@{{input.distTag}} = \$BC_BEFORE"''',
      ),
      CanvasNode(
        id: 'd69_confirm',
        kind: CanvasNodeKind.approval,
        title: '3. 人工确认发版模式（极速精准 / 全量 69）',
        x: 748,
        y: 84,
        width: 295,
        height: 195,
        colorValue: CanvasNodeKind.approval.defaultColorValue,
        content:
            '当前模式：{{input.deployMode}}（目标应用：{{input.targetApps}} → {{input.deployTarget}} · 零 Token 直调 Jenkins API）\n'
            '• 极速模式（默认）：先推代码 → 按需串行调 API 发 LC → BC → 仅部署目标应用（BUILD_LC_FIRST=false + DUPLICATE_DEPLOY_CHECK=false，热缓存单应用 ~1.2 分钟）。\n'
            '• 如没改 LC/BC 仅改业务，意见填「跳过LC和BC」；如需全量并行（lc→bc→4应用并行，~5 分钟），意见填「全量」。\n\n'
            '{{prev.output}}',
      ),
      CanvasNode(
        id: 'd69_git_push',
        kind: CanvasNodeKind.command,
        title: '4. 推送待推送提交至远端分支',
        x: 1098,
        y: 84,
        width: 285,
        height: 185,
        colorValue: CanvasNodeKind.command.defaultColorValue,
        refId: root,
        content: '''cd "{{input.root}}"
PUSHED=0
for repo in {{input.repos}}; do
  if [ -d "\$repo/.git" ]; then
    b=\$(git -C "\$repo" branch --show-current)
    ahead=\$(git -C "\$repo" rev-list --count "@{u}..HEAD" 2>/dev/null || echo "0")
    if [ "\$b" = "{{input.branch}}" ] && [ "\$ahead" != "0" ]; then
      echo "▶ 正在推送 \$repo (\$ahead 个提交) → origin/{{input.branch}} ..."
      git -C "\$repo" push origin "{{input.branch}}" || exit 1
      PUSHED=\$((PUSHED + 1))
    fi
  fi
done
echo "PUSHED_REPOS=\$PUSHED" >> /tmp/ayte-69-baseline.env
echo "✅ Git 推送检查完成（本次推送仓库数：\$PUSHED）"''',
      ),
      CanvasNode(
        id: 'd69_build_lc',
        kind: CanvasNodeKind.command,
        title: '5. 零 Token 直调 API：发布 LC',
        x: 1448,
        y: 84,
        width: 295,
        height: 195,
        colorValue: CanvasNodeKind.command.defaultColorValue,
        timeoutSeconds: 1200,
        refId: root,
        content: _buildJenkinsZeroTokenScript(
          stepLabel: '1/3 frontend-lc 构建发布',
          skipCheckShell: '''if [ "\$DEPLOY_MODE" = "all" ] || [[ "\$APPROVAL_NOTE" == *全量* ]]; then
  echo "⏭ 当前为全量模式（build-all-project 内部自带 LC→BC→并行应用），跳过独立 LC。"
  exit 0
fi
if [[ "\$APPROVAL_NOTE" == *跳过LC* ]] || [[ "\$APPROVAL_NOTE" == *跳过lc* ]]; then
  echo "⏭ 按人工意见（\$APPROVAL_NOTE）跳过独立 LC 发布。"
  exit 0
fi''',
          jobSpecShell:
              'run_jenkins_job "{{input.lcJobUrl}}" "BUILDING_DOC=false" "frontend-lc" "--claim tab:\$TAB_ID"',
          verifyVerdaccioPkg: 'ng-lc-dpp',
        ),
      ),
      CanvasNode(
        id: 'd69_build_bc',
        kind: CanvasNodeKind.command,
        title: '6. 零 Token 直调 API：发布 BC（不嵌 LC）',
        x: 1798,
        y: 84,
        width: 295,
        height: 195,
        colorValue: CanvasNodeKind.command.defaultColorValue,
        timeoutSeconds: 1200,
        refId: root,
        content: _buildJenkinsZeroTokenScript(
          stepLabel: '2/3 frontend-bc 构建发布',
          skipCheckShell: '''if [ "\$DEPLOY_MODE" = "all" ] || [[ "\$APPROVAL_NOTE" == *全量* ]]; then
  echo "⏭ 当前为全量模式（build-all-project 内部自带 LC→BC→并行应用），跳过独立 BC。"
  exit 0
fi
if [[ "\$APPROVAL_NOTE" == *跳过BC* ]] || [[ "\$APPROVAL_NOTE" == *跳过bc* ]] || [[ "\$APPROVAL_NOTE" == *跳过LC和BC* ]]; then
  echo "⏭ 按人工意见（\$APPROVAL_NOTE）跳过独立 BC 发布。"
  exit 0
fi''',
          jobSpecShell:
              'run_jenkins_job "{{input.bcJobUrl}}" "BUILD_LC_FIRST=false" "frontend-bc" "--claim tab:\$TAB_ID"',
          verifyVerdaccioPkg: 'ng-bc-dpp',
        ),
      ),
      CanvasNode(
        id: 'd69_jenkins_run',
        kind: CanvasNodeKind.command,
        title: '7. 零 Token 直调 API：部署应用至 69-sts',
        x: 2148,
        y: 84,
        width: 300,
        height: 195,
        colorValue: CanvasNodeKind.command.defaultColorValue,
        timeoutSeconds: 1200,
        refId: root,
        content: _buildJenkinsZeroTokenScript(
          stepLabel: '3/3 部署业务应用到 69-sts',
          skipCheckShell: '# 极速模式直调目标应用 Job，全量模式直调 build-all-project（已启用 4 应用并行）',
          jobSpecShell: '''if [ "\$DEPLOY_MODE" = "all" ] || [[ "\$APPROVAL_NOTE" == *全量* ]]; then
  ALL_URL="{{input.allJobUrl}}"
  ENC_BRANCH="\$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "{{input.branch}}")"
  run_jenkins_job "\$ALL_URL" "DEPLOY_BRANCH_NAME=\${ENC_BRANCH}&DEPLOY_TARGET={{input.deployTarget}}&DEPLOY_SOURCE={{input.deploySource}}" "build-all-project (全量并行)" "--claim tab:\$TAB_ID"
else
  ENC_JOB_BRANCH="\$(node -e 'process.stdout.write(encodeURIComponent(encodeURIComponent(process.argv[1])))' "{{input.branch}}")"
  FIRST=1
  for app in {{input.targetApps}}; do
    APP_URL="\${JENKINS_BASE%/}/job/frontend-\${app}/job/\${ENC_JOB_BRANCH}/"
    CLAIM_OPT=""
    if [ "\$FIRST" = "1" ]; then
      CLAIM_OPT="--claim tab:\$TAB_ID"
      FIRST=0
    fi
    run_jenkins_job "\$APP_URL" "DEPLOY_TARGET={{input.deployTarget}}&BUILD_LC_FIRST=false&DUPLICATE_DEPLOY_CHECK=false" "frontend-\${app}" "\$CLAIM_OPT"
  done
fi''',
        ),
      ),
      CanvasNode(
        id: 'd69_done',
        kind: CanvasNodeKind.command,
        title: '8. 校验私服版本递进 & 69 部署留痕',
        x: 2498,
        y: 84,
        width: 290,
        height: 185,
        colorValue: CanvasNodeKind.http.defaultColorValue,
        refId: root,
        content: '''source /tmp/ayte-69-baseline.env 2>/dev/null || true
LC_AFTER=\$(curl -sS -m 5 "{{input.registryUrl}}/-/package/ng-lc-dpp/dist-tags" | python3 -c "import sys,json; print(json.load(sys.stdin).get('{{input.distTag}}',''))" 2>/dev/null || echo "")
BC_AFTER=\$(curl -sS -m 5 "{{input.registryUrl}}/-/package/ng-bc-dpp/dist-tags" | python3 -c "import sys,json; print(json.load(sys.stdin).get('{{input.distTag}}',''))" 2>/dev/null || echo "")
echo "=== 69-sts 精准部署验收对比 (\$(date)) ==="
echo "ng-lc-dpp@{{input.distTag}}: \${LC_BEFORE:-?}  -->  \${LC_AFTER:-?}"
echo "ng-bc-dpp@{{input.distTag}}: \${BC_BEFORE:-?}  -->  \${BC_AFTER:-?}"
echo "本次推送仓库数: \${PUSHED_REPOS:-0}"
echo "✅ 69-sts ({{input.deployMode}} / {{input.targetApps}} / {{input.branch}}) 零 Token 直调部署验证完成！"''',
      ),
      CanvasNode(
        id: 'd69_fail',
        kind: CanvasNodeKind.command,
        title: '69 部署阻断告警（支持断点续跑）',
        x: 1448,
        y: 365,
        width: 300,
        height: 170,
        colorValue: 0xFFE5534B,
        refId: root,
        content: '''source /tmp/ayte-69-baseline.env 2>/dev/null || true
echo "❌ Jenkins 69 部署未通过，已终止后续步骤！"
echo "常见原因排查："
echo "1) 请先在 Tabbit 浏览器打开并登录 {{input.jenkinsBaseUrl}}；"
echo "2) 查看上方失败节点输出的最后 35 行 Jenkins consoleText 定位报错；"
echo "3) 解决后直接点击顶部「从失败节点续跑」，无需从头推送或重跑已完成步骤！"''',
      ),
    ];
    const edges = [
      CanvasEdge(id: 'd69_e1', fromId: 'd69_trigger', toId: 'd69_git_check'),
      CanvasEdge(id: 'd69_e2', fromId: 'd69_git_check', toId: 'd69_confirm'),
      CanvasEdge(id: 'd69_e3', fromId: 'd69_confirm', toId: 'd69_git_push'),
      CanvasEdge(id: 'd69_e4', fromId: 'd69_git_push', toId: 'd69_build_lc'),
      CanvasEdge(
        id: 'd69_e4f',
        fromId: 'd69_git_push',
        toId: 'd69_fail',
        branch: CanvasEdgeBranch.onFail,
      ),
      CanvasEdge(id: 'd69_e5', fromId: 'd69_build_lc', toId: 'd69_build_bc'),
      CanvasEdge(
        id: 'd69_e5f',
        fromId: 'd69_build_lc',
        toId: 'd69_fail',
        branch: CanvasEdgeBranch.onFail,
      ),
      CanvasEdge(id: 'd69_e6', fromId: 'd69_build_bc', toId: 'd69_jenkins_run'),
      CanvasEdge(
        id: 'd69_e6f',
        fromId: 'd69_build_bc',
        toId: 'd69_fail',
        branch: CanvasEdgeBranch.onFail,
      ),
      CanvasEdge(id: 'd69_e7', fromId: 'd69_jenkins_run', toId: 'd69_done'),
      CanvasEdge(
        id: 'd69_e7f',
        fromId: 'd69_jenkins_run',
        toId: 'd69_fail',
        branch: CanvasEdgeBranch.onFail,
      ),
    ];
    return CanvasWorkflowTemplate(
      id: deploy69TemplateId,
      name: 'Jenkins 69-sts 零 Token 部署（LC → BC → 目标应用）',
      nodes: nodes,
      edges: edges,
    );
  }

  /// Built-in Template #3: Full Autonomous Bug Discovery -> Triage -> Human
  /// Decision -> PR Status Sync -> Fix + Diff Trace -> Local 4200 Verify +
  /// Screenshot/Video -> Jenkins 69 Deploy & Verify + Media -> Final Approval
  /// -> PLM Status (PRCFMD/QC) + Media Attachment & Trace Archive.
  static CanvasWorkflowTemplate buildBugVerificationTemplate({
    String? defaultCwd,
  }) {
    final root = _effectiveAngularRoot(defaultCwd);
    final evidenceDir = p.join(root, '.bug-evidence');
    final nodes = [
      CanvasNode(
        id: 'step_trigger',
        kind: CanvasNodeKind.trigger,
        title: '1. 网站筛选条件与留证配置',
        x: 48,
        y: 84,
        width: 285,
        height: 205,
        colorValue: CanvasNodeKind.trigger.defaultColorValue,
        refId: root,
        content:
            'bugsUrl=https://pomeloc.top/bugs/\n'
            'bugId=\n'
            'filterStatus=REOPENED,PR,ASSIGN,NEW\n'
            'filterAssignee=当前视角账号\n'
            'filterModule=全部\n'
            'filterSeverity=全部\n'
            'pickRule=优先未做本地排查、按 REOPENED>PR>ASSIGN>NEW 且严重程度最高的第一条\n'
            'backendOwner=林泽世 (linzsb)\n'
            'root=$root\n'
            'evidenceDir=$evidenceDir\n'
            'localUrl=http://127.0.0.1:4200\n'
            'jenkinsUrl=$defaultJenkins69Url\n'
            'branch=feature/angular-upgrade\n'
            'deployTarget=69-sts',
      ),
      CanvasNode(
        id: 'step_triage',
        kind: CanvasNodeKind.agent,
        title: '2. 网站自动筛选拉单 & 清晰研判',
        x: 398,
        y: 84,
        width: 295,
        height: 195,
        colorValue: CanvasNodeKind.agent.defaultColorValue,
        agentId: '',
        refId: root,
        timeoutSeconds: 900,
        content:
            '请通过问题单平台 {{input.bugsUrl}} 的直连 REST API 拉取并研判问题单（无头模式下**禁止**尝试打开交互浏览器或 Tabbit 抓 DOM；访问 pomeloc.top 时务必绕过本地代理，直接用 `curl -sSL --noproxy \'*\' -m 90` 或 Python `ProxyHandler({})` 且超时 ≥ 90s（冷缓存 TTFB 约 30~45s，切勿用小于 60s 的超时），基础前缀 `API="https://pomeloc.top/bugs/api"`）：\n'
            '1. 【自动筛选选单】调用 `GET \${API}/bugs`（返回 `{meta:{currentUser:{id,name}}, bugs:[...]}`）：\n'
            '   - 若指定了单号 `{{input.bugId ?? \'\'}}`（非空），直接定位该 `key`；\n'
            '   - 否则按条件筛选：`status.code`/`status.label` 匹配 `{{input.filterStatus}}`、处理人 `assignee` 匹配 `{{input.filterAssignee}}`（`当前视角账号` 即 `meta.currentUser.id/name`）、模块=`{{input.filterModule}}`、严重程度=`{{input.filterSeverity}}`；按规则「{{input.pickRule}}」选中 1 条待处理单（`analysis` 为空优先，`severity.rank` 越小优先级越高）。若接口不可达或 0 条命中，明确说明原因并直接输出 `VERDICT: FAIL`。\n'
            '2. 【读取完整详情与附件】调用 `GET \${API}/instance/detail?guid=<guid>&className=<className>` 获取完整正文、历史回复 `replies`、`files`、`inlineImages`、`classGuid` 与 `commitFolder`。若有图片附件或内嵌图，可下载到 `{{input.evidenceDir}}/<BUG_ID>/attachments/` 并用看图工具核实。\n'
            '3. 【结合代码初判】在 `{{input.root}}` 内按目标模块精确检索具体子仓 `src`/`projects`（遵循 AGENTS.md，禁止无过滤扫全仓），定位对应组件/服务/接口，核实是否前端问题。\n'
            '4. 【本地状态同步与建档】调用 `POST \${API}/analysis/state`（JSON `{"key":"<BUG_ID>","state":"ROOT_CAUSE"}` 或 `"BLOCKED"`）同步本地排查结论；并在 `{{input.evidenceDir}}/<BUG_ID>/trace.md` 记录拉单时间、原单链接、GUID、筛选条件、附件清单与初判结论。\n'
            '5. 【严格结构化输出】开头必须单独成行输出：\n'
            '   BUG_ID: <单号>\n'
            '   BUG_GUID: <guid>\n'
            '   BUG_TITLE: <单据标题>\n'
            '   BUG_URL: <原单链接>\n'
            '   随后清晰输出：清晰重述（实际现象 / 期望结果 / 复现路径）、归属判断（精确到 lc/ng-bc-dpp/pdm/ppm/umc 具体文件，或后端转 {{input.backendOwner}}，或需求/数据问题）、建议决策、疑问点及 `trace.md` 绝对路径，末行必须单独输出 `VERDICT: PASS` 或 `VERDICT: FAIL`。',
      ),
      CanvasNode(
        id: 'step_triage_gate',
        kind: CanvasNodeKind.approval,
        title: '3. 人工研判决策（改不改 / 前后端 / 补充）',
        x: 748,
        y: 84,
        width: 295,
        height: 195,
        colorValue: CanvasNodeKind.approval.defaultColorValue,
        timeoutSeconds: 0,
        content:
            '请审阅 AI 自动筛选拉取的问题单（{{bug.id ?? 待识别}}）与清晰化研判：\n'
            '• 确认由前端修改：可在下方补充修改要求或清晰描述后点「通过放行」（将自动置状态为 程序修改中 PR 并修复）。\n'
            '• 不需修改 / 转交后端 {{input.backendOwner}} / 描述不清需退回补充：填写意见后点「驳回」（将自动更新平台状态并写入回复，不改动代码）。\n\n'
            '{{step_triage.output ?? prev.output}}',
      ),
      CanvasNode(
        id: 'step_mark_pr',
        kind: CanvasNodeKind.agent,
        title: '4. 置状态「程序修改中(PR)」并记录追踪',
        x: 1098,
        y: 84,
        width: 285,
        height: 190,
        colorValue: CanvasNodeKind.http.defaultColorValue,
        agentId: '',
        refId: root,
        content:
            '目标单号：{{bug.id ?? 请从上游提取}}（GUID: {{bug.guid ?? 请从上游提取}}）\n'
            '人工决策意见：{{step_triage_gate.note ?? 无}}\n\n'
            '上游研判摘要：\n{{step_triage.output ?? prev.output}}\n\n'
            '请通过 {{input.bugsUrl}} REST API 完成状态同步（访问 pomeloc.top 务必 `--noproxy \'*\'` / 绕过代理，基础前缀 `API="https://pomeloc.top/bugs/api"`）：\n'
            '1. 若该单当前状态还不是 `PR`（程序修改中），调用 `POST \${API}/quick-reply`（JSON `{"action":"fix","items":[{"guid":"<BUG_GUID>","className":"BugInner","key":"<BUG_ID>"}]}`）将状态置为「程序修改中(PR)」；若返回未登录/401，先用 `RD-ENV.md` 中的 Keychain 密码（`security find-generic-password -a chenlonga -s rd-plm -w`）调用 `POST \${API}/plm/operator`（`{"userId":"chenlonga","password":"..."}`）携带 Cookie 后重试；若当前已是 `PR` 则记录「原态已为 PR，无需重复流转」。\n'
            '2. 在 `{{input.evidenceDir}}/{{bug.id}}/trace.md` 追加一条状态变更审计记录（时间 · 原状态 → 程序修改中(PR) · 人工决策备注）。\n'
            '3. 输出 `BUG_ID: {{bug.id}}`、状态更新结果与 `trace.md` 绝对路径，末行单独输出 `VERDICT: PASS` 或 `VERDICT: FAIL`。',
      ),
      CanvasNode(
        id: 'step_fix_code',
        kind: CanvasNodeKind.agent,
        title: '5. AI 精准修复 + 单测 + Diff 留痕',
        x: 1448,
        y: 84,
        width: 290,
        height: 190,
        colorValue: CanvasNodeKind.agent.defaultColorValue,
        agentId: '',
        refId: root,
        timeoutSeconds: 900,
        content:
            '目标单号：{{bug.id ?? 请从上游提取}}（GUID: {{bug.guid ?? \'\'}}）\n'
            '人工决策与补充说明：{{step_triage_gate.note ?? 无}}\n\n'
            '【完整研判上下文】\n{{step_triage.output ?? prev.output}}\n\n'
            '【PR 状态同步结果】\n{{step_mark_pr.output ?? 无}}\n\n'
            '请在 {{input.root}} 中执行：\n'
            '1. 按最小化精准原则修复前端代码（仅修改与本单直接相关的文件，严禁碰其他无关未提交改动），仅对修改文件运行 lint/单测校验。\n'
            '2. 【留痕可溯源】仅导出本次改动文件的 `git diff` 保存到 `{{input.evidenceDir}}/{{bug.id}}/git.diff`，并在 `{{input.evidenceDir}}/{{bug.id}}/trace.md` 记录修改仓库、文件清单、核心变更摘要与单测结果。\n'
            '3. 【同步本地排查状态】通过 `POST https://pomeloc.top/bugs/api/analysis/state`（`--noproxy \'*\'`，JSON `{"key":"{{bug.id}}","state":"MODIFIED_LOCAL"}`）更新本地排查状态。\n'
            '4. 结尾必须单独成行输出：\n'
            '   BUG_ID: {{bug.id}}\n'
            '   CHANGED_REPOS: <空格分隔的本次改动仓库名，如 pdm 或 lc ng-bc-dpp pdm>\n'
            '   以及修改文件清单、diff 绝对路径，末行单独输出 `VERDICT: PASS` 或 `VERDICT: FAIL`。',
      ),
      CanvasNode(
        id: 'step_rebuild_local',
        kind: CanvasNodeKind.command,
        title: '6. 按需重建 LC/BC 并重启本地 4200',
        x: 1798,
        y: 84,
        width: 290,
        height: 190,
        colorValue: CanvasNodeKind.command.defaultColorValue,
        refId: root,
        content: '''ROOT="{{input.root}}"
CHANGED="\${AYTE_FIX_REPOS:-}"
NEED_LC=0
NEED_BC=0
if [ -n "\$CHANGED" ]; then
  case " \$CHANGED " in *" lc "*) NEED_LC=1 ;; esac
  case " \$CHANGED " in *" ng-bc-dpp "*) NEED_BC=1 ;; esac
else
  [ -n "\$(git -C "\$ROOT/lc" status --short 2>/dev/null)" ] && NEED_LC=1
  [ -n "\$(git -C "\$ROOT/ng-bc-dpp" status --short 2>/dev/null)" ] && NEED_BC=1
fi
echo "BUG_ID: {{bug.id ?? ''}}"
echo "本次检测改动仓库: \${CHANGED:-auto} (NEED_LC=\$NEED_LC, NEED_BC=\$NEED_BC)"
if [ "\$NEED_LC" = "1" ]; then
  (cd "\$ROOT/lc" && node projects/ng-lc-dpp/dpp-table/scripts/build-grid-styles.mjs && ./node_modules/.bin/ng build ng-lc-dpp-lib) || exit 1
  rm -rf "\$ROOT/ng-bc-dpp/node_modules/ng-lc-dpp" && cp -R "\$ROOT/lc/dist/ng-lc-dpp" "\$ROOT/ng-bc-dpp/node_modules/ng-lc-dpp" || exit 1
fi
if [ "\$NEED_LC" = "1" ] || [ "\$NEED_BC" = "1" ]; then
  (cd "\$ROOT/ng-bc-dpp" && ./node_modules/.bin/ng build ng-bc-dpp) || exit 1
  for app in pdm umc ppm; do
    [ -d "\$ROOT/\$app" ] || continue
    rm -rf "\$ROOT/\$app/node_modules/ng-bc-dpp" "\$ROOT/\$app/.angular/cache" "\$ROOT/\$app/node_modules/.cache"
    cp -R "\$ROOT/ng-bc-dpp/dist/ng-bc-dpp" "\$ROOT/\$app/node_modules/ng-bc-dpp" || exit 1
    if [ "\$NEED_LC" = "1" ] && [ -d "\$ROOT/lc/dist/ng-lc-dpp" ]; then
      rm -rf "\$ROOT/\$app/node_modules/ng-lc-dpp"
      cp -R "\$ROOT/lc/dist/ng-lc-dpp" "\$ROOT/\$app/node_modules/ng-lc-dpp" || exit 1
    fi
  done
  if tmux has-session -t plm 2>/dev/null; then
    tmux send-keys -t plm:pdm C-c
    tmux send-keys -t plm:umc C-c 2>/dev/null || true
    tmux send-keys -t plm:ppm C-c 2>/dev/null || true
    sleep 2
    tmux send-keys -t plm:pdm "./node_modules/.bin/ng serve --host=0.0.0.0 --allowed-hosts=all --port 4200 2>&1 | tee /tmp/plm-pdm.log" Enter
    tmux send-keys -t plm:umc "./node_modules/.bin/ng serve --hmr --port=4203 --host=0.0.0.0 --allowed-hosts=all 2>&1 | tee /tmp/plm-umc.log" Enter 2>/dev/null || true
    tmux send-keys -t plm:ppm "./node_modules/.bin/ng serve --port 4205 --host=0.0.0.0 --allowed-hosts=all 2>&1 | tee /tmp/plm-ppm.log" Enter 2>/dev/null || true
    sleep 3
  fi
else
  echo "⏭ 未改动 lc/ng-bc-dpp，按并发安全规范复用现有本地服务（不重启 ng serve）。"
fi
for i in \$(seq 1 90); do
  code=\$(curl -s -m 3 -o /dev/null -w "%{http_code}" "{{input.localUrl}}/")
  if [ "\$code" = "200" ]; then
    echo "✅ 本地 4200 已就绪 (HTTP 200)"
    exit 0
  fi
  sleep 2
done
echo "❌ 本地 4200 启动超时，请检查 /tmp/plm-pdm.log"
exit 1''',
      ),
      CanvasNode(
        id: 'step_local_verify',
        kind: CanvasNodeKind.agent,
        title: '7. 本地 4200 验证 + 截图/录屏留证',
        x: 2148,
        y: 84,
        width: 295,
        height: 195,
        colorValue: CanvasNodeKind.agent.defaultColorValue,
        agentId: '',
        refId: root,
        content:
            '目标单号：{{bug.id ?? 请从上游提取}}\n\n'
            '【原单与复现路径】\n{{step_triage.output ?? 无}}\n\n'
            '【本次代码修复摘要】\n{{step_fix_code.output ?? 无}}\n\n'
            '请在本地 `{{input.localUrl}}` 按真实复现路径验证本问题单（严格遵守 15 步浏览器操作熔断，若缺数据或连续 2 次登录失败立即停下汇报）：\n'
            '1. 【截图 + 视频双留证】本机已安装 Python Playwright（`python3` + `from playwright.sync_api import sync_playwright`，不要用未本地安装的 Node `require("playwright")`）。编写临时脚本开启 `record_video_dir`：\n'
            '   - 登录规范（PLM Angular Reactive Form）：若跳到 4201/SSO 登录页，用 `page.evaluate` 通过 `Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set` 设置 `#myNameInput`=`admin`、`#myPasswordInput`=`super` 并触发 `input` 事件，点击「登入」后轮询 500~1500ms，如弹出「讯息」保密提示框则点击「确认」。\n'
            '   - 回归验证并保存关键结果截图 `{{input.evidenceDir}}/{{bug.id}}/local-4200-after.png` 与完整操作录屏 `{{input.evidenceDir}}/{{bug.id}}/local-4200-verify.webm`，检查 Console/Network 无新增报错。\n'
            '2. 【同步状态与溯源】通过 `POST https://pomeloc.top/bugs/api/analysis/state`（`--noproxy \'*\'`，JSON `{"key":"{{bug.id}}","state":"FIXED_WS"}`）更新本地排查状态，并在 `{{input.evidenceDir}}/{{bug.id}}/trace.md` 追加验证时间、截图与视频绝对路径。\n'
            '3. 输出 `BUG_ID: {{bug.id}}`、截图/视频绝对路径，末行单独输出 `VERDICT: PASS` 或 `VERDICT: FAIL`。',
      ),
      CanvasNode(
        id: 'step_deploy_69_gate',
        kind: CanvasNodeKind.approval,
        title: '8. 审阅本地截图视频 → 放行部署 69',
        x: 2498,
        y: 84,
        width: 290,
        height: 190,
        colorValue: CanvasNodeKind.approval.defaultColorValue,
        timeoutSeconds: 0,
        content:
            '问题单 {{bug.id ?? ""}} 本地 4200 验证已通过并已生成截图与录屏留证！\n'
            '请点击下方按钮打开留证目录核对 `local-4200-after.png`、`local-4200-verify.webm` 和 `git.diff`，确认代码已提交推送至 {{input.branch}} 后点击「通过放行」触发 Jenkins 69-sts 部署（若无需重发 LC/BC 可在意见中写「跳过LC和BC」）：\n\n'
            '{{step_local_verify.output ?? prev.output}}',
      ),
      CanvasNode(
        id: 'step_69_deploy_verify',
        kind: CanvasNodeKind.agent,
        title: '9. 串行部署 69（LC→BC→业务）& 复验留证',
        x: 2848,
        y: 84,
        width: 295,
        height: 195,
        colorValue: CanvasNodeKind.agent.defaultColorValue,
        agentId: '',
        refId: root,
        timeoutSeconds: 1800,
        content:
            '目标单号：{{bug.id ?? 请从上游提取}}\n'
            '本次改动仓库：{{fix.repos ?? 请核对 git 状态}}\n'
            '人工部署意见：{{step_deploy_69_gate.note ?? 无}}\n\n'
            '【本地修复与验证摘要】\n{{step_fix_code.output ?? 无}}\n\n{{step_local_verify.output ?? 无}}\n\n'
            '【严格按依赖顺序上 69，严禁虚报成功】\n'
            '1. 确认所有本次改动仓库已提交并推送到 `origin/{{input.branch}}`（记录最新 Commit Hash）。\n'
            '2. 读取 `{{input.root}}/JENKINS-ENV.md` 获取 Jenkins Basic Auth 凭证，直接通过 Jenkins REST API（`curl -u <user>:<pass>` + `/crumbIssuer/api/json` + `/buildWithParameters`，绕过浏览器依赖）按改动范围严格串行构建 `http://172.16.100.122:4875`：\n'
            '   - 若改动了 `lc` 且人工未跳过：先触发 `frontend-lc`（`feature%252Fangular-upgrade`），轮询至 `SUCCESS` 并核对 `http://172.16.100.122:4873/-/package/ng-lc-dpp/dist-tags` 的 `test5030` 版本递增；\n'
            '   - 若改动了 `lc` 或 `ng-bc-dpp` 且人工未跳过：再触发 `frontend-bc`（`BUILD_LC_FIRST=false`），轮询至 `SUCCESS` 并核对 `ng-bc-dpp` 的 `test5030` 版本递增；\n'
            '   - 最后触发目标业务应用（`frontend-pdm` 等，参数 `DEPLOY_TARGET={{input.deployTarget}}&BUILD_LC_FIRST=false&DUPLICATE_DEPLOY_CHECK=false`）或 `{{input.jenkinsUrl}}`，轮询等待构建号彻底 `SUCCESS`。\n'
            '3. 使用 Python Playwright（`playwright.sync_api` + `record_video_dir`）在 69 环境（`http://172.16.100.69`）复现验证该问题单，保存 `{{input.evidenceDir}}/{{bug.id}}/env-69-after.png` 与 `{{input.evidenceDir}}/{{bug.id}}/env-69-verify.webm`。\n'
            '4. 将 LC/BC 新版本号、Jenkins 构建号、Commit Hash、69 截图与视频绝对路径写入 `{{input.evidenceDir}}/{{bug.id}}/trace.md`。\n'
            '5. 输出 `BUG_ID: {{bug.id}}`、构建号、Commit Hash 与留证路径；任一步未真实触发或未变绿必须末行单独输出 `VERDICT: FAIL`，全部真实通过才输出 `VERDICT: PASS`。',
      ),
      CanvasNode(
        id: 'step_human_confirm',
        kind: CanvasNodeKind.approval,
        title: '10. 终审 69 留证 → 放行回写状态',
        x: 3198,
        y: 84,
        width: 290,
        height: 190,
        colorValue: CanvasNodeKind.approval.defaultColorValue,
        timeoutSeconds: 0,
        content:
            '问题单 {{bug.id ?? ""}} 69 环境已部署并完成复验！请核对 Jenkins 构建号及 `env-69-after.png` / `env-69-verify.webm`：\n'
            '• 默认放行后将在 {{input.bugsUrl}} 更新为「开发已确认(PRCFMD)」（如需直接转测，可在下方意见点选「转交测试(QC)」）并写入完整溯源说明。\n\n'
            '{{step_69_deploy_verify.output ?? prev.output}}',
      ),
      CanvasNode(
        id: 'step_update_bug',
        kind: CanvasNodeKind.agent,
        title: '11. 改 PLM 状态 + 溯源回复 + 归档',
        x: 3548,
        y: 84,
        width: 295,
        height: 195,
        colorValue: CanvasNodeKind.http.defaultColorValue,
        agentId: '',
        refId: root,
        content:
            '目标单号：{{bug.id ?? 请从上游提取}}（GUID: {{bug.guid ?? 请从上游提取}}）\n'
            '人工终审意见：{{step_human_confirm.note ?? 无}}\n\n'
            '【研判 / 修复 / 本地与 69 验证上下文】\n'
            '{{step_fix_code.output ?? 无}}\n\n'
            '{{step_69_deploy_verify.output ?? prev.output}}\n\n'
            '请通过 {{input.bugsUrl}} REST API 完成最终闭环交付（访问 pomeloc.top 务必 `--noproxy \'*\'` / 绕过代理，基础前缀 `API="https://pomeloc.top/bugs/api"`）：\n'
            '1. 调用 `GET \${API}/plm/meta` 与 `GET \${API}/instance/detail?guid={{bug.guid}}&className=BugInner` 获取 `classGuid`、`commitFolder`、`templateName` 及目标状态/处理人 GUID（若人工意见包含「转交测试/QC」则流转为 `QC` → 提单人，否则流转为 `PRCFMD` → 当前用户）。\n'
            '2. 组装结构化溯源回复 `REPLYTO`：包含根因与修复范围（仓库/文件/Git Commit Hash）、Jenkins 69-sts 构建号与部署分支、本地 4200 & 69 验证结果、本地截图/视频/trace.md 归档路径以及人工补充意见。\n'
            '3. 调用 `POST \${API}/instance/reply`（若返回 401/需登录则先用 Keychain `security find-generic-password -a chenlonga -s rd-plm -w` 登录 `POST \${API}/plm/operator` 后携带 Cookie 重试）；同步 `POST \${API}/analysis/state` 为 `FIXED_WS`。\n'
            '4. 在 `{{input.evidenceDir}}/{{bug.id}}/trace.md` 末尾写入最终状态变更时间与 `DELIVERED` 标记。\n'
            '5. 末行必须单独输出 `VERDICT: PASS`（PLM 真实回写成功）或 `VERDICT: FAIL`。',
      ),
      CanvasNode(
        id: 'step_reject_reply',
        kind: CanvasNodeKind.agent,
        title: '不修改 / 转后端 / 退回补充（同步状态）',
        x: 748,
        y: 365,
        width: 300,
        height: 185,
        colorValue: 0xFFE5534B,
        agentId: '',
        refId: root,
        recoversFailure: true,
        content:
            '目标单号：{{bug.id ?? 请从上游提取}}（GUID: {{bug.guid ?? 请从上游提取}}）\n'
            '人工决策意见：{{step_triage_gate.note ?? 无}}\n\n'
            '【上游研判上下文】\n{{step_triage.output ?? prev.output}}\n\n'
            '问题单经人工研判不在前端修改，请通过 {{input.bugsUrl}} REST API 执行对应流转与留痕（访问 pomeloc.top 务必 `--noproxy \'*\'` / 绕过代理，基础前缀 `API="https://pomeloc.top/bugs/api"`；PLM 写接口若需登录则先用 Keychain `rd-plm` 调 `POST \${API}/plm/operator`）：\n'
            '1. 若人工意见需转后端：调用 `POST \${API}/quick-reply`（`action: "backend"`）或 `POST \${API}/instance/reply`（保持原状态、转至 {{input.backendOwner}} 并附前端排查证据与后端线索），同时标记本地状态 `NO_CHANGE`；\n'
            '2. 若描述不清需退回补充：调用 `POST \${API}/analysis/state` 标记为 `BLOCKED`，并调用 `POST \${API}/remarks`（及按需 `/instance/reply`）写入清晰的补充清单；\n'
            '3. 若确认无需修改：调用 `POST \${API}/analysis/state` 标记为 `NO_CHANGE` 并写明依据到 `/remarks`；\n'
            '4. 将最终状态流转与回复内容同步记录到 `{{input.evidenceDir}}/{{bug.id}}/trace.md` 备查。\n'
            '5. 末行必须单独输出 `VERDICT: PASS` 或 `VERDICT: FAIL`。',
      ),
      CanvasNode(
        id: 'step_fail_report',
        kind: CanvasNodeKind.command,
        title: '硬门禁阻断（保留现场 · 禁止误改完成态）',
        x: 2148,
        y: 365,
        width: 300,
        height: 165,
        colorValue: 0xFFE5534B,
        refId: root,
        content:
            'echo "[硬门禁阻断] 问题单 {{bug.id ?? 未定单}} 在构建/部署/验证阶段未通过，已终止后续流转，绝不将 PLM 状态改为开发已确认或转测。"\n'
            'echo "排查与留证目录：{{input.evidenceDir}}/{{bug.id ?? \'\'}}"',
      ),
    ];
    const edges = [
      CanvasEdge(id: 'e1', fromId: 'step_trigger', toId: 'step_triage'),
      CanvasEdge(id: 'e2', fromId: 'step_triage', toId: 'step_triage_gate'),
      CanvasEdge(id: 'e3', fromId: 'step_triage_gate', toId: 'step_mark_pr'),
      CanvasEdge(
        id: 'e3_reject',
        fromId: 'step_triage_gate',
        toId: 'step_reject_reply',
        branch: CanvasEdgeBranch.onFail,
      ),
      CanvasEdge(id: 'e3b', fromId: 'step_mark_pr', toId: 'step_fix_code'),
      CanvasEdge(
        id: 'e3b_fail',
        fromId: 'step_mark_pr',
        toId: 'step_fail_report',
        branch: CanvasEdgeBranch.onFail,
      ),
      CanvasEdge(
        id: 'e4',
        fromId: 'step_fix_code',
        toId: 'step_rebuild_local',
      ),
      CanvasEdge(
        id: 'e4_fail',
        fromId: 'step_fix_code',
        toId: 'step_fail_report',
        branch: CanvasEdgeBranch.onFail,
      ),
      CanvasEdge(
        id: 'e5',
        fromId: 'step_rebuild_local',
        toId: 'step_local_verify',
      ),
      CanvasEdge(
        id: 'e5_fail',
        fromId: 'step_rebuild_local',
        toId: 'step_fail_report',
        branch: CanvasEdgeBranch.onFail,
      ),
      CanvasEdge(
        id: 'e6',
        fromId: 'step_local_verify',
        toId: 'step_deploy_69_gate',
      ),
      CanvasEdge(
        id: 'e6_fail',
        fromId: 'step_local_verify',
        toId: 'step_fail_report',
        branch: CanvasEdgeBranch.onFail,
      ),
      CanvasEdge(
        id: 'e7',
        fromId: 'step_deploy_69_gate',
        toId: 'step_69_deploy_verify',
      ),
      CanvasEdge(
        id: 'e8',
        fromId: 'step_69_deploy_verify',
        toId: 'step_human_confirm',
      ),
      CanvasEdge(
        id: 'e8_fail',
        fromId: 'step_69_deploy_verify',
        toId: 'step_fail_report',
        branch: CanvasEdgeBranch.onFail,
      ),
      CanvasEdge(
        id: 'e9',
        fromId: 'step_human_confirm',
        toId: 'step_update_bug',
      ),
    ];
    return CanvasWorkflowTemplate(
      id: bugVerifyTemplateId,
      name: 'Bug 自动筛单→研判→PR→修复→4200/69 图文视频留证→改单',
      nodes: nodes,
      edges: edges,
    );
  }

  /// Built-in Template #4: PLM Refresh Model
  /// Scans modified CSC CSVs -> validates GBK encoding -> uploads via
  /// `PUT /api/internal/base/admin/model/{client}` -> triggers
  /// `POST /api/internal/base/admin/model/refresh` (+ optional layout clear)
  /// -> probes model i18n endpoint.
  static CanvasWorkflowTemplate buildRefreshModelTemplate({
    String? defaultCwd,
  }) {
    final root = _effectiveAngularRoot(defaultCwd);
    final nodes = [
      CanvasNode(
        id: 'rm_trigger',
        kind: CanvasNodeKind.trigger,
        title: '1. 刷新模型环境与参数',
        x: 48,
        y: 84,
        width: 280,
        height: 190,
        colorValue: CanvasNodeKind.trigger.defaultColorValue,
        refId: root,
        content:
            'root=$root\n'
            'apiUrl=$defaultPlm69ApiUrl\n'
            'username=admin\n'
            'password=super\n'
            'uploadModified=true\n'
            'files=\n'
            'deleteLayoutKey=',
      ),
      CanvasNode(
        id: 'rm_scan_gbk',
        kind: CanvasNodeKind.command,
        title: '2. 扫描 CSC 变更 CSV & GBK 编码校验',
        x: 398,
        y: 84,
        width: 290,
        height: 190,
        colorValue: CanvasNodeKind.command.defaultColorValue,
        refId: root,
        content: r'''LIST_FILE="/tmp/ayte-refresh-model-files.txt"
: > "$LIST_FILE"
UPLOAD_MODIFIED="{{input.uploadModified}}"
MANUAL_FILES="{{input.files}}"
CSC="{{input.root}}/csc"

if [ "$UPLOAD_MODIFIED" = "false" ] || [ "$UPLOAD_MODIFIED" = "0" ]; then
  echo "已设为纯刷新模式（uploadModified=$UPLOAD_MODIFIED），跳过本地 CSV 扫描。"
  exit 0
fi

if [ ! -d "$CSC" ]; then
  echo "未找到 CSC 仓库 ($CSC)，跳过本地 CSV 上传，直接执行全量刷新模型。"
  exit 0
fi

CANDIDATES=()
if [ -n "$MANUAL_FILES" ]; then
  IFS=',' read -rA raw_items <<< "$MANUAL_FILES"
  for item in "${raw_items[@]}"; do
    rel="$(echo "$item" | xargs)"
    [ -z "$rel" ] && continue
    if [[ "$rel" == src/main/resources/model/* ]]; then
      CANDIDATES+=("$rel")
    else
      CANDIDATES+=("src/main/resources/model/$rel")
    fi
  done
else
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    st="${line[1,2]}"
    [[ "$st" == *D* ]] && continue
    rel="${line[4,-1]}"
    rel="${rel##* -> }"
    rel="${rel#\"}"
    rel="${rel%\"}"
    if [[ "$rel" == src/main/resources/model/*/*.csv ]]; then
      CANDIDATES+=("$rel")
    fi
  done < <(git -C "$CSC" status --porcelain -- src/main/resources/model 2>/dev/null)
fi

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  echo "csc/src/main/resources/model 下无本地改动 CSV，将直接执行全量刷新模型。"
  exit 0
fi

ERR=0
COUNT=0
for rel in "${CANDIDATES[@]}"; do
  abs="$CSC/$rel"
  if [ ! -f "$abs" ]; then
    echo "❌ 文件不存在: $abs"
    ERR=1
    continue
  fi
  sub="${rel#src/main/resources/model/}"
  client="${sub%%/*}"
  case "$client" in
    pdm|umc|ppm|common|uid) ;;
    *)
      echo "⚠️ 跳过非标准客户端目录: $rel"
      continue
      ;;
  esac
  if iconv -f GBK -t UTF-8 "$abs" > /tmp/ayte-gbk-check.txt 2>&1; then
    echo "✓ [GBK OK] [$client] $rel"
    echo "$client|$abs" >> "$LIST_FILE"
    COUNT=$((COUNT + 1))
  else
    echo "❌ [GBK CORRUPT] $rel"
    echo "   修复命令: iconv -f UTF-8 -t GBK \"$abs\" > /tmp/fixed.csv && cp /tmp/fixed.csv \"$abs\""
    ERR=1
  fi
done

if [ "$ERR" -ne 0 ]; then
  echo "❌ 存在编码损坏或缺失的 CSV，已阻断上传（请先修复为 GBK 编码）。"
  exit 1
fi
echo "✅ 共校验通过 $COUNT 个模型 CSV，准备上传。"''',
      ),
      CanvasNode(
        id: 'rm_upload_csv',
        kind: CanvasNodeKind.command,
        title: '3. 登录 admin 并上传变更模型 CSV',
        x: 748,
        y: 84,
        width: 290,
        height: 190,
        colorValue: CanvasNodeKind.command.defaultColorValue,
        refId: root,
        content: r'''API_URL="{{input.apiUrl}}" \
PLM_USER="{{input.username}}" \
PLM_PASS="{{input.password}}" \
LIST_FILE="/tmp/ayte-refresh-model-files.txt" \
node - <<'EOF'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const apiUrl = (process.env.API_URL || 'http://172.16.100.69').replace(/\/+$/, '');
const username = process.env.PLM_USER || 'admin';
const password = process.env.PLM_PASS || 'super';
const listFile = process.env.LIST_FILE || '/tmp/ayte-refresh-model-files.txt';
const basic = 'Basic ' + Buffer.from('web_app:fa2563e21c50ac56b7e5c65a695559da').toString('base64');

async function login() {
  const code = crypto.createHash('md5').update(String(Math.floor(Math.random() * 1e10))).digest('hex');
  const r1 = await fetch(`${apiUrl}/api/sso/authorize/code?code=${code}`, { headers: { Authorization: basic } });
  const j1 = await r1.json();
  if (!r1.ok || !j1.success || !j1.data) {
    throw new Error(`获取登录公钥失败 (${r1.status}): ${JSON.stringify(j1)}`);
  }
  const rawPub = Buffer.from(j1.data, 'base64').toString('utf8');
  const pem = `-----BEGIN PUBLIC KEY-----\n${rawPub}\n-----END PUBLIC KEY-----`;
  const enc = crypto.publicEncrypt(
    { key: pem, padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' },
    Buffer.from(password.slice(0, 50), 'utf8')
  ).toString('base64');
  const pwd = Buffer.from(Buffer.from(`${code}:${enc}`).toString('base64')).toString('base64');
  const body = new URLSearchParams({ grant_type: 'password', username, password: pwd });
  const r2 = await fetch(`${apiUrl}/api/sso/oauth2/token`, {
    method: 'POST',
    headers: { Authorization: basic, 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });
  const j2 = await r2.json();
  const token = j2?.data?.access_token;
  if (!r2.ok || !j2.success || !token) {
    throw new Error(`SSO 登录失败 (${r2.status}): ${JSON.stringify(j2)}`);
  }
  return token;
}

(async () => {
  const lines = fs.existsSync(listFile)
    ? fs.readFileSync(listFile, 'utf8').split(/\r?\n/).map(s => s.trim()).filter(Boolean)
    : [];
  if (lines.length === 0) {
    console.log('无待上传的本地模型 CSV，跳过上传步骤，直接进入全量刷新。');
    return;
  }
  const byClient = new Map();
  for (const line of lines) {
    const idx = line.indexOf('|');
    if (idx <= 0) continue;
    const client = line.slice(0, idx);
    const absPath = line.slice(idx + 1);
    if (!byClient.has(client)) byClient.set(client, []);
    byClient.get(client).push(absPath);
  }
  const token = await login();
  console.log(`✓ 已通过 SSO 登录 (${username}@${apiUrl})`);
  for (const [client, files] of byClient.entries()) {
    const form = new FormData();
    for (const fp of files) {
      form.append('files', new Blob([fs.readFileSync(fp)]), path.basename(fp));
    }
    const resp = await fetch(`${apiUrl}/api/internal/base/admin/model/${client}`, {
      method: 'PUT',
      headers: { Authorization: `Bearer ${token}` },
      body: form,
    });
    const text = await resp.text();
    let json = null;
    try { json = JSON.parse(text); } catch {}
    if (!resp.ok || (json && json.success === false)) {
      throw new Error(`[${client}] 上传失败 (HTTP ${resp.status}): ${text}`);
    }
    const msgs = Array.isArray(json?.data)
      ? json.data.filter(m => m && m !== '无需校验')
      : [];
    if (msgs.length > 0) {
      throw new Error(`[${client}] CSV 结构校验未通过:\n- ${msgs.join('\n- ')}`);
    }
    console.log(`✅ [${client}] 已上传 ${files.length} 个模型文件: ${files.map(f => path.basename(f)).join(', ')}`);
  }
})().catch(err => {
  console.error('❌ ' + (err?.message || err));
  process.exit(1);
});
EOF''',
      ),
      CanvasNode(
        id: 'rm_refresh_cache',
        kind: CanvasNodeKind.command,
        title: '4. 全量刷新模型（UI + 多语言缓存）',
        x: 1098,
        y: 84,
        width: 290,
        height: 190,
        colorValue: CanvasNodeKind.command.defaultColorValue,
        refId: root,
        content: r'''API_URL="{{input.apiUrl}}" \
PLM_USER="{{input.username}}" \
PLM_PASS="{{input.password}}" \
DELETE_LAYOUT_KEY="{{input.deleteLayoutKey}}" \
node - <<'EOF'
const crypto = require('crypto');

const apiUrl = (process.env.API_URL || 'http://172.16.100.69').replace(/\/+$/, '');
const username = process.env.PLM_USER || 'admin';
const password = process.env.PLM_PASS || 'super';
const deleteLayoutKey = (process.env.DELETE_LAYOUT_KEY || '').trim();
const basic = 'Basic ' + Buffer.from('web_app:fa2563e21c50ac56b7e5c65a695559da').toString('base64');

async function login() {
  const code = crypto.createHash('md5').update(String(Math.floor(Math.random() * 1e10))).digest('hex');
  const r1 = await fetch(`${apiUrl}/api/sso/authorize/code?code=${code}`, { headers: { Authorization: basic } });
  const j1 = await r1.json();
  if (!r1.ok || !j1.success || !j1.data) {
    throw new Error(`获取登录公钥失败 (${r1.status}): ${JSON.stringify(j1)}`);
  }
  const rawPub = Buffer.from(j1.data, 'base64').toString('utf8');
  const pem = `-----BEGIN PUBLIC KEY-----\n${rawPub}\n-----END PUBLIC KEY-----`;
  const enc = crypto.publicEncrypt(
    { key: pem, padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' },
    Buffer.from(password.slice(0, 50), 'utf8')
  ).toString('base64');
  const pwd = Buffer.from(Buffer.from(`${code}:${enc}`).toString('base64')).toString('base64');
  const body = new URLSearchParams({ grant_type: 'password', username, password: pwd });
  const r2 = await fetch(`${apiUrl}/api/sso/oauth2/token`, {
    method: 'POST',
    headers: { Authorization: basic, 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });
  const j2 = await r2.json();
  const token = j2?.data?.access_token;
  if (!r2.ok || !j2.success || !token) {
    throw new Error(`SSO 登录失败 (${r2.status}): ${JSON.stringify(j2)}`);
  }
  return token;
}

(async () => {
  const token = await login();
  console.log(`→ 正在调用 POST ${apiUrl}/api/internal/base/admin/model/refresh ...`);
  const t0 = Date.now();
  const resp = await fetch(`${apiUrl}/api/internal/base/admin/model/refresh`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: '{}',
  });
  const text = await resp.text();
  let json = null;
  try { json = JSON.parse(text); } catch {}
  if (!resp.ok || (json && json.success === false)) {
    const hint = resp.status === 403 ? '（该接口要求 @GrantAccess("admin") 权限）' : '';
    throw new Error(`刷新模型失败 (HTTP ${resp.status})${hint}: ${text}`);
  }
  const sec = ((Date.now() - t0) / 1000).toFixed(2);
  console.log(`✅ 模型全量刷新成功（耗时 ${sec}s）：uiModel / propertiesI18n / serverI18n 缓存已重建`);

  if (deleteLayoutKey) {
    console.log(`→ 正在清理持久化布局: ${deleteLayoutKey}`);
    const delResp = await fetch(`${apiUrl}/api/internal/base/dock-layout-state`, {
      method: 'DELETE',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ layoutKey: deleteLayoutKey }),
    });
    const delText = await delResp.text();
    if (!delResp.ok) {
      throw new Error(`清理持久化布局失败 (HTTP ${delResp.status}): ${delText}`);
    }
    console.log(`✅ 持久化布局 "${deleteLayoutKey}" 已清理`);
  }
})().catch(err => {
  console.error('❌ ' + (err?.message || err));
  process.exit(1);
});
EOF''',
      ),
      CanvasNode(
        id: 'rm_verify',
        kind: CanvasNodeKind.command,
        title: '5. 模型服务探活与完成摘要',
        x: 1448,
        y: 84,
        width: 280,
        height: 175,
        colorValue: CanvasNodeKind.http.defaultColorValue,
        refId: root,
        content: r'''API_URL="{{input.apiUrl}}"
code=$(curl -s -o /dev/null -w "%{http_code}" "${API_URL%/}/api/internal/base/i18n/pdm/zh_cn")
if [ "$code" = "200" ]; then
  echo "✅ 刷新模型完成并探活通过 (HTTP 200 · ${API_URL})"
  echo "时间: $(date '+%Y-%m-%d %H:%M:%S') | 如浏览器已打开 PLM 页面，请按 Cmd+Shift+R 强刷生效。"
  exit 0
fi
echo "❌ 模型服务探活异常 (HTTP $code · ${API_URL}/api/internal/base/i18n/pdm/zh_cn)"
exit 1''',
      ),
      CanvasNode(
        id: 'rm_fail_diag',
        kind: CanvasNodeKind.command,
        title: '失败排查指引（GBK / 权限 / 页面兜底）',
        x: 748,
        y: 350,
        width: 300,
        height: 175,
        colorValue: 0xFFE5534B,
        refId: root,
        content: r'''echo "❌ 刷新模型流程未通过，排查建议："
echo "1. 若为 CSC CSV 编码报错，请将文件转回 GBK："
echo "   iconv -f UTF-8 -t GBK <file.csv> > /tmp/fixed.csv && cp /tmp/fixed.csv <file.csv>"
echo "2. 若为 401/403，请确认账号为 admin（后端 /admin/model/refresh 要求 @GrantAccess(\"admin\")）。"
echo "3. 页面兜底入口：http://127.0.0.1:4200/uploadModel 或 {{input.apiUrl}}/plmweb/uploadModel"''',
      ),
    ];
    const edges = [
      CanvasEdge(id: 'rm_e1', fromId: 'rm_trigger', toId: 'rm_scan_gbk'),
      CanvasEdge(id: 'rm_e2', fromId: 'rm_scan_gbk', toId: 'rm_upload_csv'),
      CanvasEdge(
        id: 'rm_e2f',
        fromId: 'rm_scan_gbk',
        toId: 'rm_fail_diag',
        branch: CanvasEdgeBranch.onFail,
      ),
      CanvasEdge(id: 'rm_e3', fromId: 'rm_upload_csv', toId: 'rm_refresh_cache'),
      CanvasEdge(
        id: 'rm_e3f',
        fromId: 'rm_upload_csv',
        toId: 'rm_fail_diag',
        branch: CanvasEdgeBranch.onFail,
      ),
      CanvasEdge(id: 'rm_e4', fromId: 'rm_refresh_cache', toId: 'rm_verify'),
      CanvasEdge(
        id: 'rm_e4f',
        fromId: 'rm_refresh_cache',
        toId: 'rm_fail_diag',
        branch: CanvasEdgeBranch.onFail,
      ),
      CanvasEdge(
        id: 'rm_e5f',
        fromId: 'rm_verify',
        toId: 'rm_fail_diag',
        branch: CanvasEdgeBranch.onFail,
      ),
    ];
    return CanvasWorkflowTemplate(
      id: refreshModelTemplateId,
      name: '刷新模型（CSC CSV 校验 → 上传 → 全量重建缓存）',
      nodes: nodes,
      edges: edges,
    );
  }

  /// All built-in engineering workflow templates ready out of the box.
  static List<CanvasWorkflowTemplate> builtInTemplates({String? defaultCwd}) => [
    buildPlmLocalRebuildTemplate(defaultCwd: defaultCwd),
    buildRefreshModelTemplate(defaultCwd: defaultCwd),
    buildDeploy69Template(defaultCwd: defaultCwd),
    buildBugVerificationTemplate(defaultCwd: defaultCwd),
  ];

  /// Resolves a built-in or user-saved template by [templateId] without
  /// mutating the editor canvas.
  CanvasWorkflowTemplate? resolveTemplate(
    String templateId, {
    String? defaultCwd,
  }) {
    if (isBuiltInTemplateId(templateId)) {
      return switch (templateId) {
        plmLocalRebuildTemplateId => buildPlmLocalRebuildTemplate(
          defaultCwd: defaultCwd,
        ),
        refreshModelTemplateId => buildRefreshModelTemplate(
          defaultCwd: defaultCwd,
        ),
        deploy69TemplateId => buildDeploy69Template(defaultCwd: defaultCwd),
        _ => buildBugVerificationTemplate(defaultCwd: defaultCwd),
      };
    }
    for (final t in _templates) {
      if (t.id == templateId) return t;
    }
    return null;
  }

  void loadBuiltInTemplate(String templateId, {String? defaultCwd}) {
    final tpl =
        resolveTemplate(templateId, defaultCwd: defaultCwd) ??
        buildBugVerificationTemplate(defaultCwd: defaultCwd);
    applyTemplate(tpl);
  }

  void loadBugVerificationTemplate({String? defaultCwd}) =>
      loadBuiltInTemplate(bugVerifyTemplateId, defaultCwd: defaultCwd);

  CanvasWorkflowTemplate saveCurrentAsTemplate(String name) {
    final trimmed = name.trim();
    final resolvedName = trimmed.isEmpty ? '工作流模板' : trimmed;
    final existingIdx = _templates.indexWhere((t) => t.name == resolvedName);
    final tplId = existingIdx >= 0
        ? _templates[existingIdx].id
        : _nextId('tpl');
    final tpl = CanvasWorkflowTemplate(
      id: tplId,
      name: resolvedName,
      nodes: [for (final n in _nodes) n.clone()],
      edges: [..._edges],
      defaultAgentId: _defaultAgentId,
      defaultModel: _defaultModel,
      defaultEffort: _defaultEffort,
    );
    if (existingIdx >= 0) {
      _templates.removeAt(existingIdx);
    }
    _templates.insert(0, tpl);
    notifyListeners();
    _scheduleSave();
    return tpl;
  }

  void deleteTemplate(String id) {
    _templates.removeWhere((t) => t.id == id);
    notifyListeners();
    _scheduleSave();
  }

  void applyTemplate(CanvasWorkflowTemplate tpl) {
    // Switching the editor template NEVER interrupts background workflow runs.
    if (_nodes.isNotEmpty || _edges.isNotEmpty) {
      pushUndoSnapshot();
    }
    _selectedRunId = null;
    _activeWorkflowName = tpl.name;
    _defaultAgentId = tpl.defaultAgentId.isEmpty ? 'agy' : tpl.defaultAgentId;
    _defaultModel = tpl.defaultModel;
    _defaultEffort = tpl.defaultEffort;
    _nodes
      ..clear()
      ..addAll([for (final n in tpl.nodes) n.clone()]);
    _edges
      ..clear()
      ..addAll(tpl.edges);
    _singleStepLog = '';
    _syncActiveWorkflowDocument();
    notifyListeners();
    _scheduleSave();
  }

  List<({String id, String name})> get runnableWorkflowChoices => [
    (id: currentCanvasTemplateId, name: '当前画布工作流'),
    (
      id: plmLocalRebuildTemplateId,
      name: '预置：本地重建启动（LC→BC→PDM/PPM/UMC）',
    ),
    (
      id: refreshModelTemplateId,
      name: '预置：刷新模型（CSC CSV 校验→上传→全量刷新）',
    ),
    (id: deploy69TemplateId, name: '预置：Jenkins 69-sts 一键部署'),
    (id: bugVerifyTemplateId, name: '预置：Bug 研判→人工决策→修复验证→69→改单'),
    for (final t in _templates) (id: t.id, name: t.name),
  ];

  // --- Variable Interpolation & Condition Evaluation --------------------------

  static Map<String, String> parseKeyValueLines(String raw) {
    final map = <String, String>{};
    for (final line in const LineSplitter().convert(raw)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final idx = trimmed.indexOf('=');
      if (idx <= 0) continue;
      final key = trimmed.substring(0, idx).trim();
      final value = trimmed.substring(idx + 1).trim();
      if (key.isNotEmpty) map[key] = value;
    }
    return map;
  }

  /// Safely interpolates `{{key}}`, `{{key ?? fallback}}`, and escaping
  /// filters (`{{key | shell}}`, `{{key | json}}`, `{{key | url}}`).
  static String interpolate(String template, Map<String, String> vars) {
    return template.replaceAllMapped(RegExp(r'\{\{\s*([^{}]+?)\s*\}\}'), (m) {
      var expr = m.group(1)!.trim();
      String? filter;
      final pipeIdx = expr.indexOf('|');
      if (pipeIdx > 0) {
        filter = expr.substring(pipeIdx + 1).trim().toLowerCase();
        expr = expr.substring(0, pipeIdx).trim();
      }
      String? fallback;
      var fallbackQuoted = false;
      final fbIdx = expr.indexOf('??');
      if (fbIdx > 0) {
        fallback = expr.substring(fbIdx + 2).trim();
        if (fallback.length >= 2 &&
            ((fallback.startsWith("'") && fallback.endsWith("'")) ||
                (fallback.startsWith('"') && fallback.endsWith('"')))) {
          fallback = fallback.substring(1, fallback.length - 1);
          fallbackQuoted = true;
        }
        expr = expr.substring(0, fbIdx).trim();
      }
      final rawVal = vars[expr];
      final resolvedFallback = (!fallbackQuoted &&
              fallback != null &&
              vars[fallback] != null &&
              vars[fallback]!.isNotEmpty)
          ? vars[fallback]
          : fallback;
      final value = (rawVal != null && rawVal.isNotEmpty)
          ? rawVal
          : (resolvedFallback ?? (rawVal ?? m.group(0)!));
      if (rawVal == null && resolvedFallback == null) {
        return value;
      }
      return switch (filter) {
        'shell' => "'${value.replaceAll("'", "'\\''")}'",
        'json' => (() {
          final encoded = jsonEncode(value);
          return encoded.substring(1, encoded.length - 1);
        })(),
        'url' => Uri.encodeComponent(value),
        _ => value,
      };
    });
  }

  /// Extracts unique local evidence / media file paths (screenshots, videos,
  /// trace logs, diffs) across both Windows (`C:\...`) and POSIX (`/...`)
  /// outputs.
  static List<String> extractEvidencePaths(String text) {
    if (text.isEmpty) return const [];
    final seen = <String>{};
    final result = <String>[];
    final pattern = RegExp(
      r'''([A-Za-z]:[\\/][^\s"'`<>|*?]+?(?:\.(?:png|jpe?g|webp|gif|webm|mp4|mov|diff)|[\\/]trace\.md|[\\/]git\.diff)|(?<![A-Za-z0-9_:\\])/[A-Za-z0-9._\-/@+~]+(?:\.(?:png|jpe?g|webp|gif|webm|mp4|mov|diff)|/trace\.md|/git\.diff))''',
      caseSensitive: false,
    );
    for (final m in pattern.allMatches(text)) {
      var candidate = m.group(1)!;
      while (candidate.isNotEmpty &&
          const {'.', ',', ';', ':', ')', ']', '}', '`', '"', "'"}.contains(
            candidate[candidate.length - 1],
          )) {
        candidate = candidate.substring(0, candidate.length - 1);
      }
      if (candidate.length > 2 && seen.add(candidate)) {
        result.add(candidate);
      }
    }
    return result;
  }

  /// Finds the configured `evidenceDir` from runtime captured inputs first,
  /// falling back to any Trigger node in [nodes].
  static String? resolveEvidenceDirFromNodes(
    List<CanvasNode> nodes, {
    Map<String, String> capturedVars = const {},
  }) {
    final runtimeDir = capturedVars['input.evidenceDir']?.trim();
    if (runtimeDir != null && runtimeDir.isNotEmpty) return runtimeDir;
    for (final n in nodes) {
      if (n.kind == CanvasNodeKind.trigger) {
        final pairs = parseKeyValueLines(n.content);
        final dir = pairs['evidenceDir']?.trim();
        if (dir != null && dir.isNotEmpty) return dir;
      }
    }
    return null;
  }

  /// Extracts well-known structured key-value outputs emitted by Agent/Command
  /// nodes (such as `BUG_ID: I2611000627`, `BUG_GUID: ...`, `CHANGED_REPOS: ...`)
  /// so downstream nodes can reference `{{bug.id}}`, `{{bug.guid}}`,
  /// `{{fix.repos}}`, etc. reliably across intermediate steps.
  static Map<String, String> extractOutputVariables(String output) {
    if (output.trim().isEmpty) return const {};
    const keyMap = <String, List<String>>{
      'BUG_ID': ['bug.id', 'bugId'],
      'BUG_GUID': ['bug.guid'],
      'BUG_TITLE': ['bug.title'],
      'BUG_URL': ['bug.url'],
      'CHANGED_REPOS': ['fix.repos'],
    };
    final result = <String, String>{};
    final lineRe = RegExp(
      r'''^\s*(?:[-*•>]\s*)?[*`]*([A-Z][A-Z0-9_]{2,24})[*`]*\s*[:：]\s*(.+?)\s*$''',
    );
    for (final rawLine in const LineSplitter().convert(output)) {
      final m = lineRe.firstMatch(rawLine);
      if (m == null) continue;
      final key = m.group(1)!.toUpperCase();
      final targets = keyMap[key];
      if (targets == null) continue;
      var val = m.group(2)!.trim();
      // Strip symmetric markdown emphasis/backticks wrapping the value.
      while (val.length >= 2 &&
          ((val.startsWith('**') && val.endsWith('**')) ||
              (val.startsWith('`') && val.endsWith('`')))) {
        val = val.startsWith('**')
            ? val.substring(2, val.length - 2).trim()
            : val.substring(1, val.length - 1).trim();
      }
      if (val.isEmpty ||
          val == '无' ||
          val == '待定' ||
          val.startsWith('<') && val.endsWith('>')) {
        continue;
      }
      for (final target in targets) {
        result[target] = val;
      }
    }
    return result;
  }

  /// Evaluates the final `VERDICT: PASS` / `VERDICT: FAIL` signal in an agent's
  /// output, preferring standalone verdict lines and taking the last verdict so
  /// prose quoting rules (e.g. "若失败输出 VERDICT: FAIL") before the final
  /// `VERDICT: PASS` does not falsely trigger a failure.
  static ({bool? finalVerdict, bool hasPass, bool hasFail}) evaluateVerdict(
    String output,
  ) {
    if (output.isEmpty) {
      return (finalVerdict: null, hasPass: false, hasFail: false);
    }
    final standaloneRe = RegExp(
      r'''^\s*(?:[-*•>]\s*)?[*`]*VERDICT\s*[:：]\s*(PASS|FAIL)\b[*`.\s]*$''',
      caseSensitive: false,
      multiLine: true,
    );
    final standalone = standaloneRe.allMatches(output).toList();
    final matches = standalone.isNotEmpty
        ? standalone
        : RegExp(
            r'VERDICT\s*[:：]\s*(PASS|FAIL)\b',
            caseSensitive: false,
          ).allMatches(output).toList();
    if (matches.isEmpty) {
      return (finalVerdict: null, hasPass: false, hasFail: false);
    }
    var hasPass = false;
    var hasFail = false;
    for (final m in matches) {
      final token = m.group(1)!.toUpperCase();
      if (token == 'PASS') hasPass = true;
      if (token == 'FAIL') hasFail = true;
    }
    final last = matches.last.group(1)!.toUpperCase();
    return (finalVerdict: last == 'PASS', hasPass: hasPass, hasFail: hasFail);
  }

  static bool evaluateCondition(
    String expr, {
    required String prevOutput,
    required int? prevExitCode,
  }) {
    final trimmed = expr.trim();
    if (trimmed.isEmpty || trimmed == 'exitZero') {
      return (prevExitCode ?? 0) == 0;
    }
    final colon = trimmed.indexOf(':');
    if (colon <= 0) {
      return prevOutput.contains(trimmed);
    }
    final op = trimmed.substring(0, colon).trim();
    final arg = trimmed.substring(colon + 1).trim();
    switch (op) {
      case 'contains':
        return prevOutput.contains(arg);
      case 'notContains':
        return !prevOutput.contains(arg);
      case 'equals':
        return prevOutput.trim() == arg;
      case 'regex':
        try {
          return RegExp(arg, multiLine: true).hasMatch(prevOutput);
        } on FormatException {
          return false;
        }
      case 'exitZero':
        return (prevExitCode ?? 0) == 0;
      default:
        return prevOutput.contains(trimmed);
    }
  }

  /// Resolves a cross-platform shell executable and argument list for
  /// `CanvasNodeKind.command` nodes (BaoCode/Git Bash or PowerShell on Windows;
  /// zsh/bash/sh on macOS & Linux).
  static ({String executable, List<String> args, bool isBash})
  resolveCommandShell(String command) {
    if (Platform.isWindows) {
      final bashCandidates = <String>[
        p.join(DataDirectory.current.path, 'tools', 'bash-exe', 'bash.exe'),
        r'C:\Program Files\Git\bin\bash.exe',
        r'C:\Program Files\Git\usr\bin\bash.exe',
        r'C:\Program Files (x86)\Git\bin\bash.exe',
      ];
      for (final candidate in bashCandidates) {
        if (File(candidate).existsSync()) {
          return (executable: candidate, args: ['-c', command], isBash: true);
        }
      }
      return (
        executable: 'powershell.exe',
        args: ['-NoProfile', '-NonInteractive', '-Command', command],
        isBash: false,
      );
    }
    if (File('/bin/zsh').existsSync()) {
      return (executable: '/bin/zsh', args: ['-lc', command], isBash: true);
    }
    if (File('/bin/bash').existsSync()) {
      return (executable: '/bin/bash', args: ['-lc', command], isBash: true);
    }
    return (executable: '/bin/sh', args: ['-c', command], isBash: true);
  }

  static void _killProcessTree(Process proc) {
    final pid = proc.pid;
    if (Platform.isWindows) {
      if (pid > 0) {
        unawaited(
          Process.run('taskkill', ['/PID', '$pid', '/T', '/F'])
              .catchError((Object _) => ProcessResult(0, 1, '', '')),
        );
      }
      proc.kill();
    } else {
      proc.kill(ProcessSignal.sigterm);
      if (pid > 0) {
        Timer(const Duration(milliseconds: 400), () {
          proc.kill(ProcessSignal.sigkill);
        });
      }
    }
  }

  static Map<String, String> _buildCommandEnvironment(
    Map<String, String> vars, {
    String? runDir,
  }) {
    final env = <String, String>{
      ...Platform.environment,
      'PATH': AcpAgentService.buildEnrichedPath(),
      'CHERE_INVOKING': '1',
      if (runDir != null && runDir.isNotEmpty) 'AYTE_RUN_DIR': runDir,
    };
    for (final e in vars.entries) {
      if (e.key.startsWith('input.')) {
        final safeKey = e.key
            .substring(6)
            .toUpperCase()
            .replaceAll(RegExp(r'[^A-Z0-9_]'), '_');
        if (safeKey.isNotEmpty && e.value.length <= 16000) {
          env['AYTE_INPUT_$safeKey'] = e.value;
        }
      }
    }
    if (vars['prev.output'] case final po? when po.length <= 16000) {
      env['AYTE_PREV_OUTPUT'] = po;
    }
    if (vars['prev.exitCode'] case final pe?) {
      env['AYTE_PREV_EXIT_CODE'] = pe;
    }
    if (vars['approval.note'] case final an?) {
      env['AYTE_APPROVAL_NOTE'] = an;
    }
    if (vars['bug.id'] case final bid? when bid.isNotEmpty) {
      env['AYTE_BUG_ID'] = bid;
    }
    if (vars['bug.guid'] case final bguid? when bguid.isNotEmpty) {
      env['AYTE_BUG_GUID'] = bguid;
    }
    if (vars['fix.repos'] case final frepos? when frepos.isNotEmpty) {
      env['AYTE_FIX_REPOS'] = frepos;
    }
    if (vars['cwd'] case final cwd? when cwd.isNotEmpty) {
      env['AYTE_CWD'] = cwd;
    }
    return env;
  }

  // --- Single Node Execution --------------------------------------------------

  Future<void> runCommandNode(String id) async {
    final node = nodeById(id);
    if (node == null || node.running) return;
    final vars = <String, String>{'cwd': node.refId};
    // Seed trigger inputs and completed upstream outputs so single-step tests
    // can reference {{input.*}}, {{bug.id}}, and {{prev.output}} directly.
    for (final n in _nodes) {
      if (n.kind == CanvasNodeKind.trigger) {
        final parsed = parseKeyValueLines(n.content);
        for (final e in parsed.entries) {
          vars.putIfAbsent('input.${e.key}', () => e.value);
        }
        if (vars['cwd']!.isEmpty && n.refId.isNotEmpty) {
          vars['cwd'] = n.refId;
        }
      }
      if (n.output.isNotEmpty) {
        vars['${n.id}.output'] = n.output;
        vars['${n.id}.status'] =
            n.runStatus == CanvasNodeRunStatus.succeeded ? 'PASS' : 'FAIL';
        vars.addAll(extractOutputVariables(n.output));
      }
    }
    var prevOutput = '';
    int? prevExit = 0;
    for (final e in _edges) {
      if (e.toId == node.id) {
        final pred = nodeById(e.fromId);
        if (pred != null && pred.output.isNotEmpty) {
          prevOutput = pred.output;
          prevExit = pred.exitCode ?? 0;
          break;
        }
      }
    }
    vars['prev.output'] = prevOutput;
    vars['prev.exitCode'] = '${prevExit ?? 0}';
    _singleStepRunningNodeId = node.id;
    _appendRunLog(
      '\n▶ [单步试跑] ${node.title} (${node.kind.label(true)})\n',
      immediate: true,
    );
    try {
      final passed = await _executeNodeWithRetry(
        node,
        vars: vars,
        prevOutput: prevOutput,
        prevExitCode: prevExit,
      );
      _appendRunLog(
        passed
            ? '\n✓ [单步试跑] ${node.title} 通过\n'
            : '\n✗ [单步试跑] ${node.title} 未通过（exit=${node.exitCode ?? 1}）\n',
        immediate: true,
      );
    } finally {
      if (_singleStepRunningNodeId == node.id) {
        _singleStepRunningNodeId = null;
      }
      _flushStreamNotify();
    }
  }

  // --- Full Concurrent DAG Workflow Execution --------------------------------

  void _completeApproval(
    String nodeId, {
    required bool approved,
    String note = '',
    int? runId,
  }) {
    final trimmed = note.trim();
    if (runId != null) {
      final run = runById(runId);
      if (run != null &&
          run.activeApprovalNodeId == nodeId &&
          run.approvalCompleter != null &&
          !run.approvalCompleter!.isCompleted) {
        run.approvalCompleter!.complete((approved: approved, note: trimmed));
      }
      return;
    }

    // Prefer the currently selected run, then any matching background run,
    // then single-step editor canvas approval.
    final sel = selectedRun;
    if (sel != null &&
        sel.activeApprovalNodeId == nodeId &&
        sel.approvalCompleter != null &&
        !sel.approvalCompleter!.isCompleted) {
      sel.approvalCompleter!.complete((approved: approved, note: trimmed));
      return;
    }
    for (final run in _runs) {
      if (run.activeApprovalNodeId == nodeId &&
          run.approvalCompleter != null &&
          !run.approvalCompleter!.isCompleted) {
        run.approvalCompleter!.complete((approved: approved, note: trimmed));
        return;
      }
    }
    if (_singleStepApprovalNodeId == nodeId &&
        _singleStepApprovalCompleter != null &&
        !_singleStepApprovalCompleter!.isCompleted) {
      _singleStepApprovalCompleter!.complete((
        approved: approved,
        note: trimmed,
      ));
    }
  }

  void approveNode(String nodeId, {String note = '', int? runId}) =>
      _completeApproval(nodeId, approved: true, note: note, runId: runId);

  void rejectNode(String nodeId, {String note = '', int? runId}) =>
      _completeApproval(nodeId, approved: false, note: note, runId: runId);

  void _stopSingleRun(WorkflowRun run) {
    run.cancelRequested = true;
    for (final proc in List<Process>.from(run.activeProcesses)) {
      _killProcessTree(proc);
    }
    run.activeProcesses.clear();
    for (final client in List<HttpClient>.from(run.activeHttpClients)) {
      try {
        client.close(force: true);
      } on Object {
        // Ignore already-closed HTTP client.
      }
    }
    run.activeHttpClients.clear();
    if (run.approvalCompleter != null && !run.approvalCompleter!.isCompleted) {
      run.approvalCompleter!.complete((approved: false, note: ''));
    }
  }

  /// Stops a specific [WorkflowRun] by [runId], or the currently selected
  /// running workflow, or all running workflows if none is selected.
  void stopWorkflow({int? runId}) {
    if (runId != null) {
      final run = runById(runId);
      if (run != null) {
        _stopSingleRun(run);
        notifyListeners();
      }
      return;
    }
    final sel = selectedRun;
    if (sel != null && sel.running) {
      _stopSingleRun(sel);
      notifyListeners();
      return;
    }
    stopAllWorkflows();
  }

  /// Stops every currently active workflow run and single-step test process.
  void stopAllWorkflows() {
    for (final run in _runs) {
      if (run.running) _stopSingleRun(run);
    }
    for (final proc in List<Process>.from(_singleStepProcesses.values)) {
      _killProcessTree(proc);
    }
    _singleStepProcesses.clear();
    if (_singleStepApprovalCompleter != null &&
        !_singleStepApprovalCompleter!.isCompleted) {
      _singleStepApprovalCompleter!.complete((approved: false, note: ''));
    }
    notifyListeners();
  }

  void _trimRunHistory() {
    if (_runs.length <= _maxRetainedRuns) return;
    for (var i = _runs.length - 1;
        i >= 0 && _runs.length > _maxRetainedRuns;
        i--) {
      final r = _runs[i];
      if (!r.running && r.id != _selectedRunId) {
        _runs.removeAt(i);
      }
    }
  }

  /// Launches a fresh concurrent run cloned from a previous [WorkflowRun].
  Future<WorkflowRunResult> rerunWorkflow(
    WorkflowRun run, {
    String? defaultCwd,
    Map<String, String> inputs = const {},
    bool selectOnStart = true,
  }) => runWorkflow(
    templateId: run.sourceTemplateId,
    defaultCwd: defaultCwd,
    inputs: inputs,
    selectOnStart: selectOnStart,
    runName: run.name,
    customNodes: run.nodes,
    customEdges: run.edges,
    defaultAgentIdOverride: run.defaultAgentId,
    defaultModelOverride: run.defaultModel,
    defaultEffortOverride: run.defaultEffort,
  );

  /// Resumes a finished/failed/cancelled [sourceRun] starting from
  /// [startNodeId], preserving upstream completed nodes' statuses, outputs,
  /// and captured variables while resetting [startNodeId] and its downstream
  /// subgraph to execute fresh. When [useLatestEditorConfig] is true, any
  /// matching nodes modified on the current editor canvas inherit their latest
  /// script/prompt/settings so users can fix a broken step and resume cleanly.
  Future<WorkflowRunResult> resumeWorkflowFromNode(
    WorkflowRun sourceRun,
    String startNodeId, {
    String? defaultCwd,
    Map<String, String> inputs = const {},
    bool selectOnStart = true,
    bool useLatestEditorConfig = true,
  }) {
    final mergedNodes = <CanvasNode>[
      for (final n in sourceRun.nodes)
        if (useLatestEditorConfig && nodeById(n.id) != null)
          nodeById(n.id)!.clone()
        else
          n.clone(),
    ];
    return runWorkflow(
      templateId: sourceRun.sourceTemplateId,
      defaultCwd: defaultCwd,
      inputs: inputs,
      selectOnStart: selectOnStart,
      runName: sourceRun.name,
      customNodes: mergedNodes,
      customEdges: sourceRun.edges,
      defaultAgentIdOverride: sourceRun.defaultAgentId,
      defaultModelOverride: sourceRun.defaultModel,
      defaultEffortOverride: sourceRun.defaultEffort,
      startNodeId: startNodeId,
      preserveRuntimeFromNodes: sourceRun.nodes,
      initialVars: sourceRun.capturedVars,
    );
  }

  /// Starts a workflow run directly from any chosen [startNodeId] on the
  /// current editable canvas, seeding trigger inputs automatically.
  Future<WorkflowRunResult> runFromEditorNode(
    String startNodeId, {
    String? defaultCwd,
    Map<String, String> inputs = const {},
    bool selectOnStart = true,
  }) => runWorkflow(
    defaultCwd: defaultCwd,
    inputs: inputs,
    selectOnStart: selectOnStart,
    startNodeId: startNodeId,
    preserveRuntimeFromNodes: _nodes,
  );

  static Set<String> _reachableNodeIds(
    Iterable<String> startIds,
    List<CanvasEdge> edges,
  ) {
    final visited = <String>{...startIds};
    final frontier = <String>[...startIds];
    while (frontier.isNotEmpty) {
      final cur = frontier.removeAt(0);
      for (final e in edges) {
        if (e.fromId == cur && visited.add(e.toId)) {
          frontier.add(e.toId);
        }
      }
    }
    return visited;
  }

  /// Runs either the current canvas, a saved/built-in template by [templateId],
  /// or an explicit [customNodes]/[customEdges] snapshot as an isolated
  /// concurrent [WorkflowRun] using a dependency-aware parallel DAG scheduler.
  Future<WorkflowRunResult> runWorkflow({
    String? templateId,
    String? defaultCwd,
    Map<String, String> inputs = const {},
    void Function(String chunk)? onLogChunk,
    void Function(int runId)? onRunStarted,
    bool selectOnStart = true,
    String? runName,
    List<CanvasNode>? customNodes,
    List<CanvasEdge>? customEdges,
    String? defaultAgentIdOverride,
    String? defaultModelOverride,
    String? defaultEffortOverride,
    String? startNodeId,
    List<CanvasNode>? preserveRuntimeFromNodes,
    Map<String, String> initialVars = const {},
  }) async {
    late final List<CanvasNode> runNodes;
    late final List<CanvasEdge> runEdges;
    late final String wfName;
    String effectiveDefaultAgent = defaultAgentIdOverride ?? _defaultAgentId;
    String effectiveDefaultModel = defaultModelOverride ?? _defaultModel;
    String effectiveDefaultEffort = defaultEffortOverride ?? _defaultEffort;

    if (customNodes != null && customEdges != null) {
      runNodes = [for (final n in customNodes) n.clone()];
      runEdges = [...customEdges];
      wfName = _resolveWorkflowNameFromNodes(runNodes, explicitName: runName);
    } else if (templateId != null && templateId != currentCanvasTemplateId) {
      final tpl = resolveTemplate(templateId, defaultCwd: defaultCwd);
      if (tpl == null) {
        final err = '未找到工作流模板：$templateId';
        _appendRunLog('[Workflow] $err\n', onLogChunk: onLogChunk, immediate: true);
        return WorkflowRunResult(ok: false, log: err, error: err);
      }
      runNodes = [for (final n in tpl.nodes) n.clone()];
      runEdges = [...tpl.edges];
      wfName = _resolveWorkflowNameFromNodes(
        runNodes,
        explicitName: runName ?? tpl.name,
      );
      if (defaultAgentIdOverride == null && tpl.defaultAgentId.isNotEmpty) {
        effectiveDefaultAgent = tpl.defaultAgentId;
      }
      if (defaultModelOverride == null && tpl.defaultModel.isNotEmpty) {
        effectiveDefaultModel = tpl.defaultModel;
      }
      if (defaultEffortOverride == null && tpl.defaultEffort.isNotEmpty) {
        effectiveDefaultEffort = tpl.defaultEffort;
      }
    } else {
      runNodes = [for (final n in _nodes) n.clone()];
      runEdges = [..._edges];
      wfName = _resolveWorkflowNameFromNodes(_nodes, explicitName: runName);
    }

    final execNodes = [
      for (final n in runNodes)
        if (n.kind.isExecutable) n,
    ];
    if (execNodes.isEmpty) {
      const err = '画布中没有可执行节点（请先从「模板」载入或添加触发/Shell/Agent 节点）。';
      _appendRunLog('[Workflow] $err\n', onLogChunk: onLogChunk, immediate: true);
      return const WorkflowRunResult(ok: false, log: err, error: err);
    }

    CanvasNode? startNode;
    if (startNodeId != null) {
      for (final n in execNodes) {
        if (n.id == startNodeId) {
          startNode = n;
          break;
        }
      }
      if (startNode == null) {
        final err = '未找到可续跑的起始节点：$startNodeId';
        _appendRunLog('[Workflow] $err\n', onLogChunk: onLogChunk, immediate: true);
        return WorkflowRunResult(ok: false, log: err, error: err);
      }
    }

    final reachableFromStart = startNode != null
        ? _reachableNodeIds([startNode.id], runEdges)
        : null;
    final priorById = <String, CanvasNode>{
      if (preserveRuntimeFromNodes != null)
        for (final pNode in preserveRuntimeFromNodes) pNode.id: pNode,
    };

    var preservedCount = 0;
    for (final n in runNodes) {
      final isUpstreamPreserved =
          reachableFromStart != null && !reachableFromStart.contains(n.id);
      if (isUpstreamPreserved) {
        final prior = priorById[n.id];
        if (prior != null &&
            prior.runStatus != CanvasNodeRunStatus.idle &&
            prior.runStatus != CanvasNodeRunStatus.queued) {
          n.runStatus = prior.runStatus == CanvasNodeRunStatus.running ||
                  prior.runStatus == CanvasNodeRunStatus.waitingApproval
              ? CanvasNodeRunStatus.failed
              : prior.runStatus;
          n.output = prior.output;
          n.exitCode = prior.exitCode;
          n.running = false;
          n.startedAt = prior.startedAt;
          n.finishedAt = prior.finishedAt;
          if (n.runStatus == CanvasNodeRunStatus.succeeded) {
            preservedCount++;
          }
          continue;
        }
        n.runStatus = CanvasNodeRunStatus.skipped;
        n.output = '';
        n.exitCode = null;
        n.running = false;
        n.startedAt = null;
        n.finishedAt = null;
        continue;
      }

      n.runStatus = n.kind.isExecutable
          ? CanvasNodeRunStatus.queued
          : CanvasNodeRunStatus.idle;
      n.output = '';
      n.exitCode = null;
      n.running = false;
      n.startedAt = null;
      n.finishedAt = null;
    }

    final run = WorkflowRun(
      id: ++_runSequence,
      name: wfName,
      sourceTemplateId: templateId,
      resumedFromNodeTitle: startNode?.title,
      nodes: runNodes,
      edges: runEdges,
      defaultAgentId: effectiveDefaultAgent,
      defaultModel: effectiveDefaultModel,
      defaultEffort: effectiveDefaultEffort,
      startedAt: DateTime.now(),
    );
    _runs.insert(0, run);
    _trimRunHistory();
    if (selectOnStart) {
      _selectedRunId = run.id;
    }
    onRunStarted?.call(run.id);
    notifyListeners();

    void logLine(String msg, {bool immediate = false}) {
      _appendRunLog(
        '$msg\n',
        run: run,
        onLogChunk: onLogChunk,
        immediate: immediate,
      );
    }

    // Create an isolated per-run temp folder so concurrent runs never collide.
    Directory? runTempDir;
    try {
      runTempDir = await Directory.systemTemp.createTemp('ayte_wf_${run.id}_');
    } on Object {
      runTempDir = null;
    }

    // Build initial variable context: prior captured vars -> Trigger defaults -> explicit inputs.
    final vars = <String, String>{
      ...initialVars,
      'cwd': (defaultCwd != null && defaultCwd.isNotEmpty)
          ? defaultCwd
          : (initialVars['cwd'] ?? ''),
      if (runTempDir != null) 'runDir': runTempDir.path,
      for (final e in inputs.entries) 'input.${e.key}': e.value,
    };
    for (final n in execNodes) {
      if (n.kind == CanvasNodeKind.trigger) {
        final parsed = parseKeyValueLines(n.content);
        for (final e in parsed.entries) {
          vars.putIfAbsent('input.${e.key}', () => e.value);
        }
        if (vars['cwd']!.isEmpty && n.refId.isNotEmpty) {
          vars['cwd'] = n.refId;
        }
      }
    }
    if (reachableFromStart != null) {
      for (final n in execNodes) {
        if (!reachableFromStart.contains(n.id) &&
            (n.runStatus == CanvasNodeRunStatus.succeeded ||
                n.runStatus == CanvasNodeRunStatus.failed)) {
          vars['${n.id}.output'] = n.output;
          vars['${n.id}.status'] =
              n.runStatus == CanvasNodeRunStatus.succeeded ? 'PASS' : 'FAIL';
          if (n.runStatus == CanvasNodeRunStatus.succeeded) {
            vars.addAll(extractOutputVariables(n.output));
          }
        }
      }
    }
    run.capturedVars
      ..clear()
      ..addAll(vars);

    // Determine entry root nodes & active subgraph.
    final entrySeeds = <({String nodeId, String prevOutput, int? prevExit})>[];
    if (startNode != null) {
      String seedPrevOutput = vars['prev.output'] ?? '';
      int? seedPrevExit = int.tryParse(vars['prev.exitCode'] ?? '') ?? 0;
      for (final e in run.edges) {
        if (e.toId != startNode.id) continue;
        final pred = run.nodeById(e.fromId);
        if (pred != null &&
            (pred.runStatus == CanvasNodeRunStatus.succeeded ||
                pred.runStatus == CanvasNodeRunStatus.failed)) {
          seedPrevOutput = pred.output;
          seedPrevExit =
              pred.exitCode ??
              (pred.runStatus == CanvasNodeRunStatus.succeeded ? 0 : 1);
          if (pred.runStatus == CanvasNodeRunStatus.succeeded) break;
        }
      }
      entrySeeds.add((
        nodeId: startNode.id,
        prevOutput: seedPrevOutput,
        prevExit: seedPrevExit,
      ));
    } else {
      final execIds = {for (final n in execNodes) n.id};
      final incomingCount = <String, int>{for (final id in execIds) id: 0};
      for (final e in run.edges) {
        if (execIds.contains(e.fromId) && execIds.contains(e.toId)) {
          incomingCount[e.toId] = incomingCount[e.toId]! + 1;
        }
      }
      final triggers = [
        for (final n in execNodes)
          if (n.kind == CanvasNodeKind.trigger) n,
      ];
      final roots = triggers.isNotEmpty
          ? triggers
          : [
              for (final n in execNodes)
                if ((incomingCount[n.id] ?? 0) == 0) n,
            ];
      if (roots.isEmpty) {
        roots.add(execNodes.first);
      }
      for (final r in roots) {
        entrySeeds.add((nodeId: r.id, prevOutput: '', prevExit: 0));
      }
    }

    final activeIds = _reachableNodeIds(
      entrySeeds.map((s) => s.nodeId),
      run.edges,
    ).where((id) => run.nodeById(id)?.kind.isExecutable == true).toSet();

    // Build dependency maps restricted to activeIds for proper diamond fan-in.
    final incomingEdges = <String, List<CanvasEdge>>{
      for (final id in activeIds) id: [],
    };
    final outgoingEdges = <String, List<CanvasEdge>>{
      for (final id in activeIds) id: [],
    };
    for (final e in run.edges) {
      if (activeIds.contains(e.fromId) && activeIds.contains(e.toId)) {
        incomingEdges[e.toId]!.add(e);
        outgoingEdges[e.fromId]!.add(e);
      }
    }

    final resolvedCount = <String, int>{for (final id in activeIds) id: 0};
    final firedInputs =
        <String, List<({String fromId, String output, int? exitCode})>>{
          for (final id in activeIds) id: [],
        };
    final completedIds = <String>{};
    final readyQueue = <({String nodeId, String prevOutput, int? prevExit})>[];
    final queuedIds = <String>{};

    for (final seed in entrySeeds) {
      if (queuedIds.add(seed.nodeId)) {
        readyQueue.add(seed);
      }
    }

    void resolveDownstream(
      String fromId, {
      required bool executed,
      required bool passed,
      required String output,
      required int? exitCode,
    }) {
      for (final edge in outgoingEdges[fromId] ?? const <CanvasEdge>[]) {
        final targetId = edge.toId;
        if (completedIds.contains(targetId) || queuedIds.contains(targetId)) {
          continue;
        }
        final branchFired =
            executed &&
            (edge.branch == CanvasEdgeBranch.always ||
                (passed && edge.branch == CanvasEdgeBranch.onPass) ||
                (!passed && edge.branch == CanvasEdgeBranch.onFail));
        if (branchFired) {
          firedInputs[targetId]!.add((
            fromId: fromId,
            output: output,
            exitCode: exitCode,
          ));
        }
        resolvedCount[targetId] = (resolvedCount[targetId] ?? 0) + 1;
        final totalIn = incomingEdges[targetId]?.length ?? 0;
        if (resolvedCount[targetId]! >= totalIn) {
          final inputsForTarget = firedInputs[targetId]!;
          if (inputsForTarget.isNotEmpty) {
            final joinedOutput = inputsForTarget.length == 1
                ? inputsForTarget.first.output
                : [
                    for (final item in inputsForTarget)
                      '[${run.nodeById(item.fromId)?.title ?? item.fromId}]\n${item.output}',
                  ].join('\n\n');
            final lastExit = inputsForTarget.last.exitCode;
            if (queuedIds.add(targetId)) {
              readyQueue.add((
                nodeId: targetId,
                prevOutput: joinedOutput,
                prevExit: lastExit,
              ));
            }
          } else {
            // Every incoming branch to this join was inactive: skip & cascade.
            completedIds.add(targetId);
            final skippedNode = run.nodeById(targetId);
            if (skippedNode != null &&
                skippedNode.runStatus == CanvasNodeRunStatus.queued) {
              skippedNode.runStatus = CanvasNodeRunStatus.skipped;
            }
            resolveDownstream(
              targetId,
              executed: false,
              passed: false,
              output: '',
              exitCode: null,
            );
          }
        }
      }
    }

    var executedCount = 0;
    var hadUnhandledFailure = false;
    String? failedNodeId;

    if (startNode != null) {
      logLine(
        '[Workflow #${run.id}] 从断点节点「${startNode.title}」续跑「${run.name}」（已保留 $preservedCount 个已完成上游节点）...',
        immediate: true,
      );
    } else {
      logLine(
        '[Workflow #${run.id}] 开始执行「${run.name}」（共 ${execNodes.length} 个可执行节点）...',
        immediate: true,
      );
    }

    try {
      final inflight = <Future<void>>{};

      Future<void> runStep(
        ({String nodeId, String prevOutput, int? prevExit}) step,
      ) async {
        if (run.cancelRequested) return;
        final node = run.nodeById(step.nodeId);
        if (node == null || !node.kind.isExecutable) {
          completedIds.add(step.nodeId);
          return;
        }
        executedCount++;
        run.executedNodes = executedCount;
        run.currentRunningNodeId = node.id;

        final stepVars = Map<String, String>.from(vars)
          ..['prev.output'] = step.prevOutput
          ..['prev.exitCode'] = '${step.prevExit ?? 0}';
        logLine(
          '\n━━ ▶ [${node.title}] (${node.kind.label(true)}) ━━',
          immediate: true,
        );

        final passed = await _executeNodeWithRetry(
          node,
          run: run,
          vars: stepVars,
          prevOutput: step.prevOutput,
          prevExitCode: step.prevExit,
          defaultCwd: defaultCwd,
          runDir: runTempDir?.path,
          onLogChunk: onLogChunk,
        );

        // Merge back trigger inputs, approval notes, and extracted outputs.
        for (final entry in stepVars.entries) {
          if (entry.key.startsWith('input.') ||
              entry.key == 'approval.note' ||
              entry.key.endsWith('.note') ||
              entry.key == 'cwd') {
            vars[entry.key] = entry.value;
          }
        }
        if (passed && node.output.isNotEmpty) {
          vars.addAll(extractOutputVariables(node.output));
        }
        vars['prev.output'] = node.output;
        vars['prev.exitCode'] = '${node.exitCode ?? (passed ? 0 : 1)}';
        vars['${node.id}.output'] = node.output;
        vars['${node.id}.status'] = passed ? 'PASS' : 'FAIL';
        run.capturedVars
          ..clear()
          ..addAll(vars);
        completedIds.add(node.id);

        if (run.cancelRequested) {
          return;
        }

        final durStr = node.runDuration == null
            ? ''
            : ' (${(node.runDuration!.inMilliseconds / 1000).toStringAsFixed(1)}s)';
        logLine(
          passed
              ? '✓ [${node.title}] 通过$durStr'
              : '✗ [${node.title}] 未通过（exit=${node.exitCode ?? 1}$durStr）',
          immediate: true,
        );

        final approvalTimedOut = stepVars['_approvalTimedOut'] == '1';
        if (approvalTimedOut) {
          // Never execute onFail human-rejection side-effects on a passive
          // approval timeout — abort downstream cleanly instead.
          hadUnhandledFailure = true;
          failedNodeId ??= node.id;
          resolveDownstream(
            node.id,
            executed: false,
            passed: false,
            output: node.output,
            exitCode: node.exitCode,
          );
          return;
        }

        final outgoing = outgoingEdges[node.id] ?? const <CanvasEdge>[];
        if (!passed) {
          final hasRecovery = outgoing.any(
            (e) =>
                e.branch == CanvasEdgeBranch.onFail &&
                (run.nodeById(e.toId)?.recoversFailure ?? false),
          );
          if (!hasRecovery) {
            hadUnhandledFailure = true;
            failedNodeId ??= node.id;
          }
        }

        resolveDownstream(
          node.id,
          executed: true,
          passed: passed,
          output: node.output,
          exitCode: node.exitCode,
        );
      }

      while (!run.cancelRequested &&
          (readyQueue.isNotEmpty || inflight.isNotEmpty)) {
        while (!run.cancelRequested &&
            readyQueue.isNotEmpty &&
            inflight.length < maxParallelNodes) {
          final next = readyQueue.removeAt(0);
          late final Future<void> task;
          task = runStep(next).whenComplete(() => inflight.remove(task));
          inflight.add(task);
        }
        if (inflight.isNotEmpty) {
          await Future.any(inflight);
        }
      }
      if (inflight.isNotEmpty) {
        await Future.wait(inflight);
      }
      if (run.cancelRequested) {
        logLine('■ 工作流 #${run.id} 已被手动停止。', immediate: true);
      }

      // Mark any unreached queued nodes as skipped.
      for (final n in execNodes) {
        if (n.runStatus == CanvasNodeRunStatus.queued) {
          n.runStatus = CanvasNodeRunStatus.skipped;
        }
      }
    } finally {
      run.running = false;
      run.finishedAt = DateTime.now();
      run.currentRunningNodeId = null;
      run.activeApprovalNodeId = null;
      run.approvalCompleter = null;
      run.activeProcesses.clear();
      run.activeHttpClients.clear();
      run.capturedVars
        ..clear()
        ..addAll(vars);
      final ok = !run.cancelRequested && !hadUnhandledFailure;
      run.ok = ok;
      run.error = run.cancelRequested
          ? '工作流已取消'
          : hadUnhandledFailure
          ? '节点 ${run.nodeById(failedNodeId ?? '')?.title ?? failedNodeId} 执行失败'
          : null;
      logLine(
        ok
            ? '\n[Workflow #${run.id}] 全部执行完成 ✓'
            : '\n[Workflow #${run.id}] 执行中止 ✗',
        immediate: true,
      );
      final succeededCount = run.execSucceeded;
      final completion = WorkflowCompletionEvent(
        runId: ++_completionSequence,
        workflowRunId: run.id,
        ok: ok,
        cancelled: run.cancelRequested,
        workflowName: run.name,
        executedNodes: executedCount,
        succeededNodes: succeededCount,
        duration: run.duration,
        completedAt: run.finishedAt ?? DateTime.now(),
        error: run.error,
      );
      _lastCompletionEvent = completion;
      _flushStreamNotify();
      unawaited(_saveRuns());
      if (runTempDir != null) {
        final tempToClean = runTempDir;
        unawaited(
          tempToClean.delete(recursive: true).catchError((Object _) => tempToClean),
        );
      }
      if (!run.cancelRequested &&
          !Platform.environment.containsKey('FLUTTER_TEST')) {
        unawaited(_notifySystemWorkflowFinished(completion));
      }
    }

    final ok = !run.cancelRequested && !hadUnhandledFailure;
    return WorkflowRunResult(
      ok: ok,
      log: run.log,
      error: run.error,
      executedNodes: executedCount,
      failedNodeId: failedNodeId,
      runId: run.id,
    );
  }

  Future<void> _notifySystemWorkflowFinished(
    WorkflowCompletionEvent event,
  ) async {
    try {
      final secs = (event.duration.inMilliseconds / 1000).toStringAsFixed(1);
      if (event.ok) {
        await ChannelAttentionHost.instance.notify(
          id: 'workflow_${event.runId}',
          title: '工作流执行完成',
          body: '${event.workflowName} · 已通过 ${event.succeededNodes} 个节点 (${secs}s)',
        );
        await NotificationSound.play(
          ChannelAttentionHost.instance,
          NotificationSoundValue.microwave,
        );
      } else {
        await ChannelAttentionHost.instance.notify(
          id: 'workflow_${event.runId}',
          title: '工作流执行未通过',
          body:
              '${event.workflowName} · ${event.error ?? '部分节点执行失败'} (${secs}s)',
        );
      }
    } on Object catch (e) {
      debugPrint('Workflow completion notification failed: $e');
    }
  }

  Future<bool> _executeNodeWithRetry(
    CanvasNode node, {
    WorkflowRun? run,
    required Map<String, String> vars,
    required String prevOutput,
    required int? prevExitCode,
    String? defaultCwd,
    String? runDir,
    void Function(String chunk)? onLogChunk,
  }) async {
    final canRetry =
        node.kind == CanvasNodeKind.command ||
        node.kind == CanvasNodeKind.http ||
        node.kind == CanvasNodeKind.agent;
    final totalAttempts = canRetry ? (1 + node.maxRetries.clamp(0, 5)) : 1;
    for (var attempt = 0; attempt < totalAttempts; attempt++) {
      final ok = await _executeNode(
        node,
        run: run,
        vars: vars,
        prevOutput: prevOutput,
        prevExitCode: prevExitCode,
        defaultCwd: defaultCwd,
        runDir: runDir,
        onLogChunk: onLogChunk,
      );
      if (ok || (run?.cancelRequested ?? false) || attempt + 1 >= totalAttempts) {
        return ok;
      }
      final delaySec = node.retryDelaySeconds * (attempt + 1);
      _appendRunLog(
        '\n↻ [${node.title}] 第 ${attempt + 1}/$totalAttempts 次失败，${delaySec}s 后自动重试…\n',
        run: run,
        onLogChunk: onLogChunk,
        immediate: true,
      );
      if (delaySec > 0) {
        final deadline = DateTime.now().add(Duration(seconds: delaySec));
        while (DateTime.now().isBefore(deadline)) {
          if (run?.cancelRequested ?? false) return false;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }
    return false;
  }

  Future<bool> _executeNode(
    CanvasNode node, {
    WorkflowRun? run,
    required Map<String, String> vars,
    required String prevOutput,
    required int? prevExitCode,
    String? defaultCwd,
    String? runDir,
    void Function(String chunk)? onLogChunk,
  }) async {
    bool isCancelled() => run?.cancelRequested ?? false;
    Process? ownedProc;
    void setActiveProcess(Process? p) {
      if (run != null) {
        if (ownedProc != null) run.activeProcesses.remove(ownedProc);
        ownedProc = p;
        if (p != null) {
          if (run.cancelRequested) {
            _killProcessTree(p);
          } else {
            run.activeProcesses.add(p);
          }
        }
      } else if (p != null) {
        ownedProc = p;
        _singleStepProcesses[node.id] = p;
      } else {
        ownedProc = null;
        _singleStepProcesses.remove(node.id);
      }
    }

    node.running = true;
    node.runStatus = CanvasNodeRunStatus.running;
    node.output = '';
    node.exitCode = null;
    node.startedAt = DateTime.now();
    node.finishedAt = null;
    _flushStreamNotify();

    final cwd = _resolveCwd(node.refId, vars, defaultCwd);

    try {
      switch (node.kind) {
        case CanvasNodeKind.trigger:
          final parsed = parseKeyValueLines(node.content);
          final lines = <String>[];
          for (final e in parsed.entries) {
            final effective = vars['input.${e.key}'] ?? e.value;
            vars['input.${e.key}'] = effective;
            lines.add('${e.key} = $effective');
          }
          for (final e in vars.entries) {
            if (e.key.startsWith('input.')) {
              final k = e.key.substring(6);
              if (!parsed.containsKey(k)) lines.add('$k = ${e.value}');
            }
          }
          node.output = lines.isEmpty ? 'Triggered' : lines.join('\n');
          _appendRunLog('${node.output}\n', run: run, onLogChunk: onLogChunk);
          node.exitCode = 0;
          node.runStatus = CanvasNodeRunStatus.succeeded;
          return true;

        case CanvasNodeKind.command:
          final cmd = interpolate(node.content, vars).trim();
          if (cmd.isEmpty) {
            node.output = '(空命令，直接通过)';
            _appendRunLog('${node.output}\n', run: run, onLogChunk: onLogChunk);
            node.exitCode = 0;
            node.runStatus = CanvasNodeRunStatus.succeeded;
            return true;
          }
          final effectiveDir =
              cwd.isNotEmpty && await Directory(cwd).exists() ? cwd : null;
          _appendRunLog(
            '\$ $cmd\n${effectiveDir != null ? "(cwd: $effectiveDir)\n" : ""}',
            run: run,
            onLogChunk: onLogChunk,
          );
          final env = _buildCommandEnvironment(vars, runDir: runDir);
          final shell = resolveCommandShell(cmd);
          final proc = await Process.start(
            shell.executable,
            shell.args,
            workingDirectory: effectiveDir,
            environment: env,
          );
          setActiveProcess(proc);
          if (isCancelled()) {
            _killProcessTree(proc);
            node.exitCode = -1;
            node.runStatus = CanvasNodeRunStatus.failed;
            return false;
          }
          unawaited(proc.stdin.close().catchError((_) {}));
          final outBuf = _TailBuffer(maxChars: 24000);
          final outDone = Completer<void>();
          final errDone = Completer<void>();
          final s1 = proc.stdout
              .transform(const Utf8Decoder(allowMalformed: true))
              .listen(
                (c) {
                  outBuf.write(c);
                  node.output = outBuf.toString();
                  _appendRunLog(c, run: run, onLogChunk: onLogChunk);
                },
                onDone: () {
                  if (!outDone.isCompleted) outDone.complete();
                },
                onError: (_) {
                  if (!outDone.isCompleted) outDone.complete();
                },
              );
          final s2 = proc.stderr
              .transform(const Utf8Decoder(allowMalformed: true))
              .listen(
                (c) {
                  outBuf.write(c);
                  node.output = outBuf.toString();
                  _appendRunLog(c, run: run, onLogChunk: onLogChunk);
                },
                onDone: () {
                  if (!errDone.isCompleted) errDone.complete();
                },
                onError: (_) {
                  if (!errDone.isCompleted) errDone.complete();
                },
              );
          final code = await proc.exitCode.timeout(
            Duration(seconds: node.timeoutSeconds),
            onTimeout: () {
              _killProcessTree(proc);
              _appendRunLog(
                '\n[Timeout] 节点超时（${node.timeoutSeconds}s），已终止进程树。\n',
                run: run,
                onLogChunk: onLogChunk,
                immediate: true,
              );
              return -1;
            },
          );
          // Drain trailing buffered stdout/stderr chunks cleanly before closing.
          try {
            await Future.wait([outDone.future, errDone.future]).timeout(
              const Duration(seconds: 2),
            );
          } on TimeoutException {
            // Child process left stdio open; force close listeners.
          }
          await s1.cancel();
          await s2.cancel();
          setActiveProcess(null);
          node.output = outBuf.toString();
          node.exitCode = code;
          if (node.output.trim().isEmpty) node.output = '(Exit $code)';
          final ok = code == 0 && !isCancelled();
          node.runStatus = ok
              ? CanvasNodeRunStatus.succeeded
              : CanvasNodeRunStatus.failed;
          return ok;

        case CanvasNodeKind.agent:
          final prompt = interpolate(node.content, vars).trim();
          if (prompt.isEmpty) {
            node.output = '未填写 Agent 提示词';
            _appendRunLog('${node.output}\n', run: run, onLogChunk: onLogChunk);
            node.exitCode = 1;
            node.runStatus = CanvasNodeRunStatus.failed;
            return false;
          }
          final cfg = effectiveAgentConfig(node, run: run);
          final modelTag = cfg.model.isEmpty ? '默认模型' : cfg.model;
          final effortTag = cfg.effort.isEmpty ? '' : ' · effort:${cfg.effort}';
          _appendRunLog(
            '[Agent:${cfg.agentId} · $modelTag$effortTag] 正在启动内核并发送任务（cwd: ${cwd.isEmpty ? "默认" : cwd}）...\n',
            run: run,
            onLogChunk: onLogChunk,
            immediate: true,
          );
          final outBuf = _TailBuffer(maxChars: 24000);
          final res = await AcpAgentService.instance.runHeadlessPrompt(
            agentId: cfg.agentId,
            model: cfg.model,
            effort: cfg.effort,
            prompt: prompt,
            cwd: cwd,
            timeout: Duration(seconds: node.timeoutSeconds),
            onProcessStarted: setActiveProcess,
            onChunk: (c) {
              outBuf.write(c);
              node.output = outBuf.toString();
              _appendRunLog(c, run: run, onLogChunk: onLogChunk);
            },
          );
          setActiveProcess(null);
          if (res.output.trim().isNotEmpty) {
            node.output = _trimTail(res.output.trim());
          } else if (res.error != null) {
            node.output = res.error!;
            _appendRunLog(
              '[Error] ${res.error!}\n',
              run: run,
              onLogChunk: onLogChunk,
              immediate: true,
            );
          }
          // Inspect the node's OWN prompt template (not interpolated upstream
          // output) so mentioning VERDICT: PASS in an upstream node never
          // falsely arms the hard verdict gate on downstream nodes.
          final requiresPassVerdict = RegExp(
            r'VERDICT\s*[:：]\s*PASS\b',
            caseSensitive: false,
          ).hasMatch(node.content);
          final verdict = evaluateVerdict(node.output);
          final verdictFail = verdict.finalVerdict == false;
          final missingRequiredPass =
              requiresPassVerdict && verdict.finalVerdict != true;
          if (missingRequiredPass && !verdictFail && res.ok) {
            _appendRunLog(
              '\n[硬门禁阻断] 该节点要求明确输出 VERDICT: PASS，但实际输出未确认通过，已判定失败以防虚报成功。\n',
              run: run,
              onLogChunk: onLogChunk,
              immediate: true,
            );
          }
          final ok =
              res.ok && !verdictFail && !missingRequiredPass && !isCancelled();
          node.exitCode = ok ? 0 : 1;
          node.runStatus = ok
              ? CanvasNodeRunStatus.succeeded
              : CanvasNodeRunStatus.failed;
          return ok;

        case CanvasNodeKind.http:
          final urlStr = interpolate(node.httpUrl, vars).trim();
          final uri = Uri.tryParse(urlStr);
          if (uri == null || !uri.hasScheme) {
            node.output = '无效的 URL：$urlStr';
            _appendRunLog('${node.output}\n', run: run, onLogChunk: onLogChunk);
            node.exitCode = 1;
            node.runStatus = CanvasNodeRunStatus.failed;
            return false;
          }
          _appendRunLog(
            '→ ${node.httpMethod.trim().toUpperCase()} $urlStr\n',
            run: run,
            onLogChunk: onLogChunk,
            immediate: true,
          );
          final client = HttpClient()
            ..connectionTimeout = Duration(
              seconds: node.timeoutSeconds.clamp(5, 60),
            );
          run?.activeHttpClients.add(client);
          try {
            if (isCancelled()) return false;
            final method = node.httpMethod.trim().toUpperCase();
            final req = await client.openUrl(method, uri);
            for (final line in const LineSplitter().convert(node.httpHeaders)) {
              final idx = line.indexOf(':');
              if (idx <= 0) continue;
              final k = line.substring(0, idx).trim();
              final v = interpolate(
                line.substring(idx + 1).trim(),
                vars,
              ).replaceAll(RegExp(r'[\r\n]+'), ' ');
              if (k.isNotEmpty) req.headers.set(k, v);
            }
            final body = interpolate(node.content, vars).trim();
            if (body.isNotEmpty && method != 'GET' && method != 'HEAD') {
              req.headers.contentType ??= ContentType.json;
              req.write(body);
            }
            final timeout = Duration(seconds: node.timeoutSeconds);
            final resp = await req.close().timeout(timeout);
            // Bounded response read (max 2 MB) with timeout to prevent OOM/hang.
            final bytes = <int>[];
            const maxRespBytes = 2 * 1024 * 1024;
            await for (final chunk in resp.timeout(timeout)) {
              if (isCancelled()) break;
              if (bytes.length + chunk.length > maxRespBytes) {
                bytes.addAll(chunk.take(maxRespBytes - bytes.length));
                break;
              }
              bytes.addAll(chunk);
            }
            final respBody = utf8.decode(bytes, allowMalformed: true);
            node.output = _trimTail('HTTP ${resp.statusCode}\n$respBody');
            _appendRunLog('${node.output}\n', run: run, onLogChunk: onLogChunk);
            final ok =
                !isCancelled() &&
                resp.statusCode >= 200 &&
                resp.statusCode < 300;
            node.exitCode = ok ? 0 : resp.statusCode;
            node.runStatus = ok
                ? CanvasNodeRunStatus.succeeded
                : CanvasNodeRunStatus.failed;
            return ok;
          } finally {
            run?.activeHttpClients.remove(client);
            client.close(force: true);
          }

        case CanvasNodeKind.condition:
          final resolvedExpr = interpolate(node.conditionExpr, vars);
          final ok = evaluateCondition(
            resolvedExpr,
            prevOutput: prevOutput,
            prevExitCode: prevExitCode,
          );
          node.output =
              '规则: $resolvedExpr\n结果: ${ok ? "通过 (PASS)" : "未通过 (FAIL)"}';
          _appendRunLog('${node.output}\n', run: run, onLogChunk: onLogChunk);
          node.exitCode = ok ? 0 : 1;
          node.runStatus = ok
              ? CanvasNodeRunStatus.succeeded
              : CanvasNodeRunStatus.failed;
          return ok;

        case CanvasNodeKind.approval:
          node.runStatus = CanvasNodeRunStatus.waitingApproval;
          node.output = interpolate(
            node.content.isEmpty
                ? '请确认是否放行继续下游节点。\n\n{{prev.output}}'
                : node.content,
            vars,
          );
          final completer = Completer<({bool approved, String note})>();
          if (run != null) {
            run.activeApprovalNodeId = node.id;
            run.approvalCompleter = completer;
          } else {
            _singleStepApprovalNodeId = node.id;
            _singleStepApprovalCompleter = completer;
          }
          _appendRunLog(
            '⏸ 流程已暂停，等待人工决策：「${node.title}」\n',
            run: run,
            onLogChunk: onLogChunk,
            immediate: true,
          );
          _flushStreamNotify();
          var timedOut = false;
          final decision = node.timeoutSeconds <= 0
              ? await completer.future
              : await completer.future.timeout(
                  Duration(seconds: node.timeoutSeconds),
                  onTimeout: () {
                    timedOut = true;
                    return (
                      approved: false,
                      note: '审批超时（${node.timeoutSeconds}s）自动中止（未触发驳回分支）',
                    );
                  },
                );
          if (run != null) {
            if (run.activeApprovalNodeId == node.id) {
              run.activeApprovalNodeId = null;
              run.approvalCompleter = null;
            }
          } else {
            if (_singleStepApprovalNodeId == node.id) {
              _singleStepApprovalNodeId = null;
              _singleStepApprovalCompleter = null;
            }
          }
          vars['approval.note'] = decision.note;
          vars['${node.id}.note'] = decision.note;
          if (timedOut) {
            vars['_approvalTimedOut'] = '1';
          }
          node.exitCode = decision.approved ? 0 : (timedOut ? 124 : 1);
          node.runStatus = decision.approved
              ? CanvasNodeRunStatus.succeeded
              : CanvasNodeRunStatus.failed;
          final noteLine = decision.note.isEmpty
              ? ''
              : '\n人工补充意见：${decision.note}';
          final statusTag = decision.approved
              ? '✅ 人工已放行'
              : (timedOut ? '⏱ 审批已超时' : '❌ 人工已驳回');
          node.output = '$statusTag$noteLine\n\n${node.output}';
          _appendRunLog(
            '$statusTag${decision.note.isEmpty ? "" : "（意见：${decision.note}）"}\n',
            run: run,
            onLogChunk: onLogChunk,
            immediate: true,
          );
          return decision.approved;

        case CanvasNodeKind.note ||
            CanvasNodeKind.chat ||
            CanvasNodeKind.file ||
            CanvasNodeKind.group:
          node.runStatus = CanvasNodeRunStatus.idle;
          return true;
      }
    } on Object catch (e) {
      node.output = 'Error: $e';
      _appendRunLog(
        '[Error] $e\n',
        run: run,
        onLogChunk: onLogChunk,
        immediate: true,
      );
      node.exitCode = 1;
      node.runStatus = CanvasNodeRunStatus.failed;
      return false;
    } finally {
      setActiveProcess(null);
      node.running = false;
      node.finishedAt = DateTime.now();
      _flushStreamNotify();
    }
  }

  String _resolveCwd(
    String nodeRef,
    Map<String, String> vars,
    String? defaultCwd,
  ) {
    final interpolated = interpolate(nodeRef, vars).trim();
    if (interpolated.isNotEmpty && Directory(interpolated).existsSync()) {
      return interpolated;
    }
    if (vars['input.repo'] case final r?
        when r.isNotEmpty && Directory(r).existsSync()) {
      return r;
    }
    if (vars['cwd'] case final c?
        when c.isNotEmpty && Directory(c).existsSync()) {
      return c;
    }
    if (defaultCwd != null &&
        defaultCwd.isNotEmpty &&
        Directory(defaultCwd).existsSync()) {
      return defaultCwd;
    }
    if (interpolated.isNotEmpty) return interpolated;
    if (vars['input.repo'] case final r? when r.isNotEmpty) return r;
    if (vars['cwd'] case final c? when c.isNotEmpty) return c;
    return defaultCwd ?? '';
  }

  static String _trimTail(String s, {int max = 24000}) =>
      s.length <= max ? s : s.substring(s.length - max);
}
