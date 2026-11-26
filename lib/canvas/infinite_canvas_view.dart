import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../acp/acp_agent_service.dart';
import '../chat/chat_session.dart';
import '../ide/ide_button.dart';
import '../ide/ide_dialog.dart';
import '../ide/ide_input.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import 'canvas_ai_dialog.dart';
import 'canvas_context_menu.dart';
import 'canvas_controller.dart';
import 'canvas_minimap.dart';
import 'canvas_search_palette.dart';

/// Cross-platform OS file/directory opener (replaces macOS-only `open`).
Future<void> _openPathInOs(String targetPath, {bool reveal = false}) async {
  try {
    if (Platform.isWindows) {
      final winPath = targetPath.replaceAll('/', r'\');
      if (reveal) {
        await Process.start('explorer.exe', ['/select,$winPath']);
      } else {
        await Process.start('explorer.exe', [winPath]);
      }
    } else if (Platform.isMacOS) {
      await Process.run('open', [if (reveal) '-R', targetPath]);
    } else {
      final dirPath = reveal ? p.dirname(targetPath) : targetPath;
      await Process.run('xdg-open', [dirPath]);
    }
  } on Object catch (e) {
    debugPrint('Canvas _openPathInOs failed for $targetPath: $e');
  }
}

/// Non-blocking TTL filesystem cache so `build()` never calls sync disk I/O.
abstract final class _CanvasFsCache {
  static final Map<String, ({bool exists, DateTime at})> _exists = {};
  static final Map<String, ({String preview, DateTime at})> _previews = {};
  static final Set<String> _pendingExists = {};
  static final Set<String> _pendingPreviews = {};
  static const _ttl = Duration(seconds: 6);

  static bool? existsCached(String path, VoidCallback onReady) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return false;
    final hit = _exists[trimmed];
    if (hit != null && DateTime.now().difference(hit.at) < _ttl) {
      return hit.exists;
    }
    if (_pendingExists.add(trimmed)) {
      unawaited(
        FileSystemEntity.type(trimmed)
            .then((type) {
              _exists[trimmed] = (
                exists: type != FileSystemEntityType.notFound,
                at: DateTime.now(),
              );
            })
            .catchError((_) {
              _exists[trimmed] = (exists: false, at: DateTime.now());
            })
            .whenComplete(() {
              _pendingExists.remove(trimmed);
              onReady();
            }),
      );
    }
    return hit?.exists;
  }

  static String? filePreviewCached(String path, VoidCallback onReady) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return null;
    final hit = _previews[trimmed];
    if (hit != null && DateTime.now().difference(hit.at) < _ttl) {
      return hit.preview;
    }
    if (_pendingPreviews.add(trimmed)) {
      unawaited(() async {
        try {
          final f = File(trimmed);
          if (await f.exists()) {
            final bytes = await f.openRead(0, 4096).fold<List<int>>(
              <int>[],
              (acc, chunk) => acc..addAll(chunk),
            );
            _previews[trimmed] = (
              preview: utf8.decode(bytes, allowMalformed: true),
              at: DateTime.now(),
            );
          } else {
            _previews[trimmed] = (preview: '', at: DateTime.now());
          }
        } on Object {
          _previews[trimmed] = (preview: '', at: DateTime.now());
        } finally {
          _pendingPreviews.remove(trimmed);
          onReady();
        }
      }());
    }
    return hit?.preview;
  }
}

/// Isolated 1-second timer widget that ticks elapsed time locally on active
/// cards/strips without forcing a root canvas rebuild every second.
class _LiveElapsedText extends StatefulWidget {
  const _LiveElapsedText({
    required this.startedAt,
    required this.finishedAt,
    required this.running,
    this.prefix = '',
    this.suffix = '',
    required this.style,
  });

  final DateTime? startedAt;
  final DateTime? finishedAt;
  final bool running;
  final String prefix;
  final String suffix;
  final TextStyle style;

  @override
  State<_LiveElapsedText> createState() => _LiveElapsedTextState();
}

class _LiveElapsedTextState extends State<_LiveElapsedText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _LiveElapsedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.running != widget.running ||
        oldWidget.startedAt != widget.startedAt) {
      _sync();
    }
  }

  void _sync() {
    if (widget.running && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!widget.running && _timer != null) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.startedAt;
    if (s == null) return const SizedBox.shrink();
    final end = widget.running
        ? DateTime.now()
        : (widget.finishedAt ?? DateTime.now());
    final d = end.difference(s);
    return Text(
      '${widget.prefix}${_formatElapsed(d)}${widget.suffix}',
      style: widget.style,
    );
  }
}

typedef _SnapGuide = ({bool vertical, double pos, double start, double end});

/// Studio-grade 2D Executable Workflow Canvas (DAG):
/// - Clean single-row 48px studio toolbar with properly constrained menus
/// - Elevated cards with crisp icon badges, tailored per-kind body previews,
///   clean single-dot ports, and hover-revealed actions
/// - Smart Bezier edge routing (forward S-curves + clean downward arcs for
///   lower-lane fail handlers — zero hairpin loops) with exact midpoint badges
/// - Responsive right-side Inspector (split on wide, slide-over on narrow panel)
class InfiniteCanvasView extends StatefulWidget {
  const InfiniteCanvasView({super.key, this.session});

  final ChatSession? session;

  @override
  State<InfiniteCanvasView> createState() => _InfiniteCanvasViewState();
}

class _InfiniteCanvasViewState extends State<InfiniteCanvasView>
    with SingleTickerProviderStateMixin {
  static const double _gridStep = 22.0;

  final _transform = TransformationController();
  final _boardKey = GlobalKey();
  final _canvasFocusNode = FocusNode(debugLabel: 'WorkflowCanvas');
  final _approvalNoteCtrl = TextEditingController();
  final _logScrollCtrl = ScrollController();

  // Dedicated high-frequency notifiers avoid rebuilding node cards on drag/hover.
  final _wirePointerNotifier = ValueNotifier<Offset?>(null);
  final _marqueeRectNotifier = ValueNotifier<Rect?>(null);
  final _snapGuidesNotifier = ValueNotifier<List<_SnapGuide>>(const []);

  late final AnimationController _camAnimCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  Animation<Matrix4>? _camAnim;

  Set<String> _selectedNodeIds = {};
  String? _selectedEdgeId;
  ({String fromId, CanvasEdgeBranch branch})? _connecting;
  bool _dragWiring = false;
  Offset? _wireStartScene;

  bool _marqueeMode = false;
  bool _spacePanning = false;
  bool _middleMousePanning = false;
  Offset? _marqueeOriginScene;

  Map<String, ({double x, double y})>? _dragInitialPositions;
  Offset _dragAccumDelta = Offset.zero;
  String? _dragAnchorId;

  List<CanvasNode> _copiedNodes = const [];
  List<CanvasEdge> _copiedEdges = const [];

  bool _snapToGrid = true;
  bool _showMinimap = true;
  bool _autoFollowActiveNode = false;
  bool _showLogDrawer = false;
  bool _logExpanded = false;
  bool _logSelectedNodeOnly = false;
  bool _consolePinnedToBottom = true;
  double _inspectorWidth = 400.0;
  Size _viewportSize = const Size(960, 620);

  int? _lastSelectedRunId;
  String? _lastTrackedRunningId;
  String? _lastTrackedApprovalId;
  int _lastLogLen = 0;

  CanvasController get _ctrl => CanvasController.instance;

  double get _currentScale =>
      _transform.value.getMaxScaleOnAxis().clamp(0.25, 2.5);

  String? get _primarySelectedNodeId =>
      _selectedNodeIds.length == 1 ? _selectedNodeIds.first : null;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onControllerChanged);
    _logScrollCtrl.addListener(_onLogScroll);
    _camAnimCtrl.addListener(_onCamAnimTick);
    _lastSelectedRunId = _ctrl.selectedRunId;
    if (_ctrl.anyWorkflowRunning || _ctrl.workflowLog.isNotEmpty) {
      _showLogDrawer = true;
    }
    unawaited(
      _ctrl.load().then((_) {
        if (mounted && _ctrl.displayNodes.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _fitToView(animate: false),
          );
        }
      }),
    );
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onControllerChanged);
    _logScrollCtrl.removeListener(_onLogScroll);
    _camAnimCtrl.removeListener(_onCamAnimTick);
    _camAnimCtrl.dispose();
    _canvasFocusNode.dispose();
    _approvalNoteCtrl.dispose();
    _logScrollCtrl.dispose();
    _wirePointerNotifier.dispose();
    _marqueeRectNotifier.dispose();
    _snapGuidesNotifier.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _onCamAnimTick() {
    final anim = _camAnim;
    if (anim != null) {
      _transform.value = anim.value;
    }
  }

  void _animateToMatrix(Matrix4 target, {bool animate = true}) {
    if (!animate) {
      _camAnimCtrl.stop();
      _camAnim = null;
      _transform.value = target;
      return;
    }
    _camAnim = Matrix4Tween(begin: _transform.value.clone(), end: target)
        .animate(
          CurvedAnimation(parent: _camAnimCtrl, curve: Curves.easeOutCubic),
        );
    _camAnimCtrl.forward(from: 0);
  }

  void _onLogScroll() {
    if (!_logScrollCtrl.hasClients) return;
    final pos = _logScrollCtrl.position;
    final atBottom = (pos.maxScrollExtent - pos.pixels) < 42.0;
    if (atBottom != _consolePinnedToBottom) {
      setState(() => _consolePinnedToBottom = atBottom);
    }
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final selectedRunId = _ctrl.selectedRunId;
    final runNodeId = _ctrl.currentRunningNodeId;
    final approvalId = _ctrl.activeApprovalNodeId;
    var needsState = false;

    if (selectedRunId != _lastSelectedRunId) {
      _lastSelectedRunId = selectedRunId;
      _lastTrackedRunningId = null;
      _lastTrackedApprovalId = null;
      _connecting = null;
      _wirePointerNotifier.value = null;
      _selectedEdgeId = null;
      final run = _ctrl.selectedRun;
      if (run != null) {
        final targetId =
            run.activeApprovalNodeId ??
            run.currentRunningNodeId ??
            (_primarySelectedNodeId != null &&
                    run.nodeById(_primarySelectedNodeId!) != null
                ? _primarySelectedNodeId
                : null);
        _selectedNodeIds = targetId == null ? {} : {targetId};
      } else {
        _selectedNodeIds = {
          for (final id in _selectedNodeIds)
            if (_ctrl.nodeById(id) != null) id,
        };
      }
      needsState = true;
    } else {
      final existing = {for (final n in _ctrl.displayNodes) n.id};
      final pruned = _selectedNodeIds.intersection(existing);
      if (pruned.length != _selectedNodeIds.length) {
        _selectedNodeIds = pruned;
        needsState = true;
      }
      if (_selectedEdgeId != null &&
          !_ctrl.displayEdges.any((e) => e.id == _selectedEdgeId)) {
        _selectedEdgeId = null;
        needsState = true;
      }
    }

    if ((_ctrl.selectedRun?.running == true || runNodeId != null) &&
        !_showLogDrawer) {
      _showLogDrawer = true;
      needsState = true;
    }

    if (runNodeId != null && runNodeId != _lastTrackedRunningId) {
      _lastTrackedRunningId = runNodeId;
      if (_autoFollowActiveNode) {
        _selectedNodeIds = {runNodeId};
        needsState = true;
        final node = _ctrl.displayNodeById(runNodeId);
        if (node != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _focusNode(node);
          });
        }
      }
    } else if (runNodeId == null) {
      _lastTrackedRunningId = null;
    }

    if (approvalId != null && approvalId != _lastTrackedApprovalId) {
      _lastTrackedApprovalId = approvalId;
      _selectedNodeIds = {approvalId};
      needsState = true;
      final node = _ctrl.displayNodeById(approvalId);
      if (node != null && _autoFollowActiveNode) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusNode(node);
        });
      }
    } else if (approvalId == null) {
      _lastTrackedApprovalId = null;
    }

    final logLen = _ctrl.workflowLog.length;
    if (logLen != _lastLogLen) {
      _lastLogLen = logLen;
      if (_showLogDrawer && _consolePinnedToBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _logScrollCtrl.hasClients && _consolePinnedToBottom) {
            _logScrollCtrl.jumpTo(_logScrollCtrl.position.maxScrollExtent);
          }
        });
      }
    }

    if (needsState) setState(() {});
  }

  void _selectRunAndFocus(int? runId) {
    _ctrl.selectRun(runId);
    final run = runId == null ? null : _ctrl.runById(runId);
    setState(() {
      _connecting = null;
      _wirePointerNotifier.value = null;
      _selectedEdgeId = null;
      if (run != null) {
        _showLogDrawer = true;
        final id =
            run.activeApprovalNodeId ??
            run.currentRunningNodeId ??
            run.nodes.firstOrNull?.id;
        _selectedNodeIds = id == null ? {} : {id};
      } else {
        _selectedNodeIds = {
          for (final id in _selectedNodeIds)
            if (_ctrl.nodeById(id) != null) id,
        };
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final targetId = run?.activeApprovalNodeId ?? run?.currentRunningNodeId;
      final targetNode = targetId == null
          ? null
          : _ctrl.displayNodeById(targetId);
      if (targetNode != null) {
        _focusNode(targetNode);
      } else {
        _fitToView();
      }
    });
  }

  void _launchParallelWorkflow(String templateId) {
    setState(() => _showLogDrawer = true);
    unawaited(
      _ctrl.runWorkflow(
        templateId: templateId,
        defaultCwd: widget.session?.root,
        selectOnStart: true,
      ),
    );
  }

  Future<void> _startEditorWorkflowWithParams(bool isZh) async {
    CanvasNode? triggerNode;
    for (final n in _ctrl.nodes) {
      if (n.kind == CanvasNodeKind.trigger) {
        triggerNode = n;
        break;
      }
    }
    final pairs = triggerNode == null
        ? const <String, String>{}
        : CanvasController.parseKeyValueLines(triggerNode.content);
    if (triggerNode == null || pairs.isEmpty) {
      setState(() => _showLogDrawer = true);
      unawaited(_ctrl.runWorkflow(defaultCwd: widget.session?.root));
      return;
    }

    final result = await showDialog<({Map<String, String> params, bool save})>(
      context: context,
      builder: (_) => _PreRunWorkflowDialog(
        ctrl: _ctrl,
        workflowName: _ctrl.activeWorkflowName.isNotEmpty
            ? _ctrl.activeWorkflowName
            : triggerNode!.title,
        initialParams: pairs,
        modelSummaryBuilder: () => _workflowModelBadgeLabel(isZh),
        isZh: isZh,
        onConfigureModels: () => unawaited(_openWorkflowModelDialog(isZh)),
      ),
    );
    if (!mounted || result == null) return;
    if (result.save) {
      final lines = [for (final e in result.params.entries) '${e.key}=${e.value}'];
      _ctrl.updateNode(triggerNode.id, content: lines.join('\n'));
    }
    setState(() => _showLogDrawer = true);
    unawaited(
      _ctrl.runWorkflow(
        defaultCwd: widget.session?.root,
        inputs: result.params,
      ),
    );
  }

  void _resumeRunFromNode(WorkflowRun sourceRun, String nodeId) {
    setState(() => _showLogDrawer = true);
    unawaited(
      _ctrl.resumeWorkflowFromNode(
        sourceRun,
        nodeId,
        defaultCwd: widget.session?.root,
      ),
    );
  }

  void _runEditorFromNode(String nodeId) {
    setState(() => _showLogDrawer = true);
    unawaited(
      _ctrl.runFromEditorNode(
        nodeId,
        defaultCwd: widget.session?.root,
      ),
    );
  }

  void _focusNode(CanvasNode node, {bool animate = true}) {
    final s = _currentScale.clamp(0.55, 1.0);
    final vw = math.max(320.0, _viewportSize.width);
    final vh = math.max(220.0, _viewportSize.height);
    final cx = node.x + node.width / 2;
    final cy = node.y + node.height / 2;
    final tx = vw / 2 - cx * s;
    final ty = vh / 2 - cy * s;
    final m = Matrix4.identity()
      ..setEntry(0, 0, s)
      ..setEntry(1, 1, s)
      ..setEntry(0, 3, tx)
      ..setEntry(1, 3, ty);
    _animateToMatrix(m, animate: animate);
  }

  void _startSingleStep(CanvasNode node) {
    setState(() {
      _selectedNodeIds = {node.id};
      _selectedEdgeId = null;
      _showLogDrawer = true;
    });
    unawaited(_ctrl.runCommandNode(node.id));
  }

  void _fitNodes(List<CanvasNode> nodes, {bool animate = true}) {
    if (nodes.isEmpty) {
      _animateToMatrix(Matrix4.identity(), animate: animate);
      return;
    }
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final n in nodes) {
      minX = math.min(minX, n.x);
      minY = math.min(minY, n.y);
      maxX = math.max(maxX, n.x + n.width);
      maxY = math.max(maxY, n.y + n.height);
    }
    const pad = 72.0;
    final contentW = math.max(260.0, (maxX - minX) + pad * 2);
    final contentH = math.max(200.0, (maxY - minY) + pad * 2);
    final vw = math.max(320.0, _viewportSize.width);
    final vh = math.max(240.0, _viewportSize.height);
    final s = math.min(vw / contentW, vh / contentH).clamp(0.35, 1.0);
    final tx = (vw - (maxX - minX) * s) / 2 - minX * s;
    final ty = (vh - (maxY - minY) * s) / 2 - minY * s;
    final m = Matrix4.identity()
      ..setEntry(0, 0, s)
      ..setEntry(1, 1, s)
      ..setEntry(0, 3, tx)
      ..setEntry(1, 3, ty);
    _animateToMatrix(m, animate: animate);
  }

  void _fitToView({bool animate = true}) =>
      _fitNodes(_ctrl.displayNodes, animate: animate);

  void _fitToSelection() {
    if (_selectedNodeIds.isEmpty) {
      _fitToView();
      return;
    }
    final selected = [
      for (final n in _ctrl.displayNodes)
        if (_selectedNodeIds.contains(n.id)) n,
    ];
    _fitNodes(selected);
  }

  void _resetZoom100() {
    final center = Offset(_viewportSize.width / 2, _viewportSize.height / 2);
    final sceneCenter = _transform.toScene(center);
    final m = Matrix4.identity()
      ..setEntry(0, 3, center.dx - sceneCenter.dx)
      ..setEntry(1, 3, center.dy - sceneCenter.dy);
    _animateToMatrix(m);
  }

  void _zoomBy(double factor, {Offset? focalViewport}) {
    final next = (_currentScale * factor).clamp(0.25, 2.5);
    final center =
        focalViewport ??
        Offset(_viewportSize.width / 2, _viewportSize.height / 2);
    final sceneCenter = _transform.toScene(center);
    final m = Matrix4.identity()
      ..setEntry(0, 0, next)
      ..setEntry(1, 1, next)
      ..setEntry(0, 3, center.dx - sceneCenter.dx * next)
      ..setEntry(1, 3, center.dy - sceneCenter.dy * next);
    _transform.value = m;
  }

  ({String content, String httpUrl}) _defaultsFor(
    CanvasNodeKind kind,
    bool isZh,
  ) {
    final cwd = widget.session?.root ?? '';
    return (
      content: switch (kind) {
        CanvasNodeKind.trigger =>
          'bugId=BUG-001\nrepo=$cwd\nlocalUrl=http://127.0.0.1:4200\nenv69Url=http://192.168.1.69',
        CanvasNodeKind.command => 'git status -s',
        CanvasNodeKind.agent =>
          isZh
              ? '针对 {{input.bugId}} 执行验证，结尾必须明确输出 VERDICT: PASS 或 VERDICT: FAIL。'
              : 'Verify {{input.bugId}} and end with VERDICT: PASS or VERDICT: FAIL.',
        CanvasNodeKind.http =>
          '{"status": "开发已确认", "bugId": "{{input.bugId}}"}',
        CanvasNodeKind.approval =>
          isZh
              ? '请检查上一步输出并确认是否放行：\n\n{{prev.output}}'
              : 'Review previous output before continuing:\n\n{{prev.output}}',
        CanvasNodeKind.condition => '',
        CanvasNodeKind.note => isZh ? '记录架构说明或待办…' : 'Write notes here...',
        CanvasNodeKind.chat =>
          'Session: ${widget.session?.sessionId ?? "new"}',
        CanvasNodeKind.file => '',
        CanvasNodeKind.group =>
          isZh ? '拖动标题框可连同内部节点一起移动' : 'Drag header to move enclosed nodes',
      },
      httpUrl: kind == CanvasNodeKind.http ? 'http://pomeloc.top/bugs/' : '',
    );
  }

  double _snapVal(double v) =>
      _snapToGrid ? (v / _gridStep).round() * _gridStep : v;

  void _addNode(CanvasNodeKind kind, bool isZh, {Offset? atScenePos}) {
    if (_ctrl.selectedRunId != null) {
      _ctrl.selectRun(null);
    }
    final cwd = widget.session?.root ?? '';
    final d = _defaultsFor(kind, isZh);
    final basePos =
        atScenePos ??
        _transform.toScene(
          Offset(_viewportSize.width * 0.35, _viewportSize.height * 0.35),
        );
    final jitter = atScenePos == null ? (_ctrl.nodes.length % 5) * 26.0 : 0.0;
    final node = _ctrl.addNode(
      kind: kind,
      title: kind.label(isZh),
      refId: cwd,
      x: _snapVal(basePos.dx + jitter).clamp(40.0, CanvasController.maxBoardX),
      y: _snapVal(basePos.dy + jitter).clamp(40.0, CanvasController.maxBoardY),
      content: d.content,
      httpUrl: d.httpUrl,
    );
    setState(() {
      _selectedNodeIds = {node.id};
      _selectedEdgeId = null;
    });
  }

  void _quickAppendNode(
    String fromId,
    CanvasEdgeBranch branch,
    CanvasNodeKind kind,
    bool isZh, {
    Offset? atScenePos,
  }) {
    final d = _defaultsFor(kind, isZh);
    final created = _ctrl.addConnectedNode(
      fromId: fromId,
      branch: branch,
      kind: kind,
      title: kind.label(isZh),
      content: d.content,
      refId: widget.session?.root ?? '',
      httpUrl: d.httpUrl,
      x: atScenePos != null ? _snapVal(atScenePos.dx) : null,
      y: atScenePos != null ? _snapVal(atScenePos.dy) : null,
    );
    if (created != null) {
      setState(() {
        _selectedNodeIds = {created.id};
        _selectedEdgeId = null;
        _connecting = null;
        _dragWiring = false;
      });
      _wirePointerNotifier.value = null;
    }
  }

  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: const TextStyle(fontSize: 12)),
          duration: const Duration(milliseconds: 2200),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  bool _isTextInputFocused() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || focus == _canvasFocusNode) return false;
    final ctx = focus.context;
    if (ctx == null) return false;
    if (ctx.widget is EditableText) return true;
    return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _handleNodeDragStart(CanvasNode anchor) {
    if (_ctrl.selectedRunId != null) return;
    _ctrl.pushUndoSnapshot();
    final idsToMove = _selectedNodeIds.contains(anchor.id)
        ? Set<String>.from(_selectedNodeIds)
        : {anchor.id};

    // Moving a Group Frame automatically moves cards whose center is inside it.
    for (final id in List<String>.from(idsToMove)) {
      final n = _ctrl.nodeById(id);
      if (n != null && n.kind == CanvasNodeKind.group) {
        final rect = Rect.fromLTWH(n.x, n.y, n.width, n.height);
        for (final other in _ctrl.nodes) {
          if (other.id == n.id || other.kind == CanvasNodeKind.group) continue;
          final center = Offset(
            other.x + other.width / 2,
            other.y + other.height / 2,
          );
          if (rect.contains(center)) {
            idsToMove.add(other.id);
          }
        }
      }
    }

    _dragAnchorId = anchor.id;
    _dragAccumDelta = Offset.zero;
    _dragInitialPositions = {
      for (final id in idsToMove)
        if (_ctrl.nodeById(id) case final n?) id: (x: n.x, y: n.y),
    };
  }

  void _handleNodeDragUpdate(CanvasNode anchor, Offset viewportDelta) {
    final initial = _dragInitialPositions;
    if (initial == null || _dragAnchorId != anchor.id) {
      _handleNodeDragStart(anchor);
    }
    final baseMap = _dragInitialPositions;
    if (baseMap == null) return;
    final anchorStart = baseMap[anchor.id];
    if (anchorStart == null) return;

    final s = _currentScale;
    _dragAccumDelta += Offset(viewportDelta.dx / s, viewportDelta.dy / s);
    var targetX = (anchorStart.x + _dragAccumDelta.dx).clamp(
      0.0,
      CanvasController.maxBoardX,
    );
    var targetY = (anchorStart.y + _dragAccumDelta.dy).clamp(
      0.0,
      CanvasController.maxBoardY,
    );

    const snapTol = 6.5;
    double? snapX;
    double? snapY;
    final guides = <_SnapGuide>[];

    final anchorW = anchor.width;
    final anchorH = anchor.height;
    for (final other in _ctrl.nodes) {
      if (baseMap.containsKey(other.id)) continue;
      if (other.kind == CanvasNodeKind.group &&
          anchor.kind != CanvasNodeKind.group) {
        continue;
      }

      if (snapX == null) {
        final pairsX = <(double aOff, double oCoord)>[
          (0.0, other.x),
          (anchorW / 2, other.x + other.width / 2),
          (anchorW, other.x + other.width),
        ];
        for (final (aOff, oCoord) in pairsX) {
          if (((targetX + aOff) - oCoord).abs() <= snapTol) {
            snapX = oCoord - aOff;
            guides.add((
              vertical: true,
              pos: oCoord,
              start: math.min(targetY, other.y) - 24,
              end: math.max(targetY + anchorH, other.y + other.height) + 24,
            ));
            break;
          }
        }
      }

      if (snapY == null) {
        final pairsY = <(double aOff, double oCoord)>[
          (0.0, other.y),
          (anchorH / 2, other.y + other.height / 2),
          (anchorH, other.y + other.height),
        ];
        for (final (aOff, oCoord) in pairsY) {
          if (((targetY + aOff) - oCoord).abs() <= snapTol) {
            snapY = oCoord - aOff;
            guides.add((
              vertical: false,
              pos: oCoord,
              start: math.min(targetX, other.x) - 24,
              end: math.max(targetX + anchorW, other.x + other.width) + 24,
            ));
            break;
          }
        }
      }
      if (snapX != null && snapY != null) break;
    }

    targetX = snapX ?? _snapVal(targetX);
    targetY = snapY ?? _snapVal(targetY);
    final appliedDx = targetX - anchorStart.x;
    final appliedDy = targetY - anchorStart.y;

    _snapGuidesNotifier.value = guides;
    _ctrl.setNodePositions({
      for (final e in baseMap.entries)
        e.key: (x: e.value.x + appliedDx, y: e.value.y + appliedDy),
    });
  }

  void _handleNodeDragEnd() {
    _dragInitialPositions = null;
    _dragAnchorId = null;
    _dragAccumDelta = Offset.zero;
    _snapGuidesNotifier.value = const [];
    _ctrl.commitLayout();
  }

  void _startPortDrag(CanvasNode from, CanvasEdgeBranch branch) {
    if (_ctrl.selectedRunId != null) return;
    final start = _outputPortOffset(from, branch);
    _dragWiring = true;
    _wireStartScene = start;
    _wirePointerNotifier.value = start;
    setState(() {
      _connecting = (fromId: from.id, branch: branch);
      _selectedEdgeId = null;
    });
  }

  void _updatePortDrag(Offset globalPosition) {
    if (!_dragWiring || _connecting == null) return;
    final box = _boardKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(globalPosition);
    _wirePointerNotifier.value = _transform.toScene(local);
  }

  Future<void> _endPortDrag(Offset globalPosition, bool isZh) async {
    final conn = _connecting;
    if (!_dragWiring || conn == null) return;
    _dragWiring = false;
    final dropScene = _wirePointerNotifier.value;
    final startScene = _wireStartScene;
    _wireStartScene = null;

    if (dropScene == null) return;

    CanvasNode? hitNode;
    for (final n in _ctrl.nodes.reversed) {
      if (n.id == conn.fromId || !n.kind.isExecutable) continue;
      final hitRect = Rect.fromLTWH(
        n.x - 14,
        n.y - 10,
        n.width + 28,
        n.height + 20,
      );
      if (hitRect.contains(dropScene)) {
        hitNode = n;
        break;
      }
    }

    if (hitNode != null) {
      final edge = _ctrl.connect(conn.fromId, hitNode.id, branch: conn.branch);
      setState(() {
        _connecting = null;
        if (edge != null) {
          _selectedNodeIds = {hitNode!.id};
        }
      });
      _wirePointerNotifier.value = null;
      if (edge == null) {
        _showToast(
          isZh
              ? '无法连接：目标连线会形成环形依赖 (DAG 不允许成环)'
              : 'Cannot connect: edge would introduce a cycle.',
        );
      }
      return;
    }

    if (startScene != null && (dropScene - startScene).distance > 28) {
      final pickedKind = await CanvasContextMenu.showDropCreateNodeMenu(
        context,
        globalPos: globalPosition,
        isZh: isZh,
      );
      if (!mounted) return;
      if (pickedKind != null) {
        _quickAppendNode(
          conn.fromId,
          conn.branch,
          pickedKind,
          isZh,
          atScenePos: Offset(dropScene.dx, math.max(20.0, dropScene.dy - 70)),
        );
        return;
      }
    }

    setState(() => _connecting = null);
    _wirePointerNotifier.value = null;
  }

  void _copySelected() {
    if (_selectedNodeIds.isEmpty) return;
    _copiedNodes = [
      for (final n in _ctrl.nodes)
        if (_selectedNodeIds.contains(n.id)) n.clone(),
    ];
    _copiedEdges = [
      for (final e in _ctrl.edges)
        if (_selectedNodeIds.contains(e.fromId) &&
            _selectedNodeIds.contains(e.toId))
          e,
    ];
  }

  void _pasteCopied({Offset? atScenePos}) {
    if (_ctrl.selectedRunId != null || _copiedNodes.isEmpty) return;
    double dx = 44;
    double dy = 44;
    if (atScenePos != null) {
      final minX = _copiedNodes.map((n) => n.x).reduce(math.min);
      final minY = _copiedNodes.map((n) => n.y).reduce(math.min);
      dx = _snapVal(atScenePos.dx - minX);
      dy = _snapVal(atScenePos.dy - minY);
    }
    final created = _ctrl.pasteNodes(_copiedNodes, _copiedEdges, dx: dx, dy: dy);
    if (created.isNotEmpty) {
      setState(() {
        _selectedNodeIds = {for (final n in created) n.id};
        _selectedEdgeId = null;
      });
    }
  }

  void _duplicateSelected() {
    if (_ctrl.selectedRunId != null || _selectedNodeIds.isEmpty) return;
    final created = _ctrl.duplicateNodes(_selectedNodeIds);
    if (created.isNotEmpty) {
      setState(() {
        _selectedNodeIds = {for (final n in created) n.id};
        _selectedEdgeId = null;
      });
    }
  }

  void _deleteSelected() {
    if (_ctrl.selectedRunId != null) return;
    if (_selectedEdgeId != null) {
      final eid = _selectedEdgeId!;
      setState(() => _selectedEdgeId = null);
      _ctrl.removeEdge(eid);
      return;
    }
    if (_selectedNodeIds.isEmpty) return;
    final ids = Set<String>.from(_selectedNodeIds);
    setState(() => _selectedNodeIds = {});
    _ctrl.removeNodes(ids);
  }

  void _nudgeSelected(double dx, double dy) {
    if (_ctrl.selectedRunId != null || _selectedNodeIds.isEmpty) return;
    _ctrl.pushUndoSnapshot();
    _ctrl.moveNodes(_selectedNodeIds, dx, dy);
    _ctrl.commitLayout();
  }

  Future<void> _openSearchPalette(bool isZh) async {
    final picked = await showCanvasSearchPalette(
      context,
      nodes: _ctrl.displayNodes,
      isZh: isZh,
      kindIcon: _kindIcon,
    );
    if (!mounted || picked == null) return;
    setState(() {
      _selectedNodeIds = {picked.id};
      _selectedEdgeId = null;
    });
    _focusNode(picked);
  }

  Future<void> _openAiGeneratorDialog(bool isZh) async {
    if (_ctrl.selectedRunId != null) {
      _ctrl.selectRun(null);
    }
    final applied = await showCanvasAiWorkflowDialog(
      context,
      ctrl: _ctrl,
      isZh: isZh,
      cwd: widget.session?.root,
    );
    if (!mounted || !applied) return;
    setState(() {
      _selectedNodeIds = _ctrl.nodes.isEmpty ? {} : {_ctrl.nodes.first.id};
      _selectedEdgeId = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitToView());
  }

  Future<void> _openJsonIoDialog(bool isZh) async {
    final imported = await showCanvasJsonDialog(
      context,
      ctrl: _ctrl,
      isZh: isZh,
      defaultDir: widget.session?.root,
    );
    if (!mounted || !imported) return;
    setState(() {
      _selectedNodeIds = _ctrl.nodes.isEmpty ? {} : {_ctrl.nodes.first.id};
      _selectedEdgeId = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitToView());
  }

  Future<void> _promptNewOrRenameWorkflow({
    required bool isZh,
    required bool rename,
  }) async {
    final nameCtrl = TextEditingController(
      text: rename
          ? _ctrl.activeWorkflowName
          : (isZh
                ? '工作流 ${_ctrl.workflows.length + 1}'
                : 'Workflow ${_ctrl.workflows.length + 1}'),
    );
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          rename
              ? (isZh ? '重命名当前工作流' : 'Rename Workflow')
              : (isZh ? '新建空白工作流' : 'New Workflow'),
        ),
        content: SizedBox(
          width: 340,
          child: IdeInputBox(
            controller: nameCtrl,
            placeholder: isZh ? '输入工作流名称…' : 'Workflow name...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
            child: Text(isZh ? '确定' : 'OK'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    if (!mounted || res == null || res.isEmpty) return;
    if (rename) {
      _ctrl.renameActiveWorkflow(res);
    } else {
      _ctrl.createWorkflow(res);
      setState(() {
        _selectedNodeIds = {};
        _selectedEdgeId = null;
      });
    }
  }

  Future<void> _handleBoardContextMenu(
    Offset globalPos,
    Offset localViewportPos,
    bool isZh,
  ) async {
    final scenePos = _transform.toScene(localViewportPos);
    final action = await CanvasContextMenu.showBoardMenu(
      context,
      globalPos: globalPos,
      isZh: isZh,
      hasClipboard: _copiedNodes.isNotEmpty,
      snapToGrid: _snapToGrid,
      showMinimap: _showMinimap,
      readOnly: _ctrl.selectedRunId != null,
    );
    if (!mounted || action == null) return;
    if (action.startsWith('add:')) {
      final kind = CanvasNodeKind.parse(action.substring(4));
      _addNode(kind, isZh, atScenePos: scenePos);
    } else if (action == 'paste') {
      _pasteCopied(atScenePos: scenePos);
    } else if (action == 'ai_generate') {
      unawaited(_openAiGeneratorDialog(isZh));
    } else if (action == 'auto_layout') {
      _ctrl.autoLayout();
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitToView());
    } else if (action == 'select_all') {
      setState(() {
        _selectedNodeIds = {for (final n in _ctrl.displayNodes) n.id};
        _selectedEdgeId = null;
      });
    } else if (action == 'search') {
      unawaited(_openSearchPalette(isZh));
    } else if (action == 'fit_view') {
      _fitToView();
    } else if (action == 'toggle_snap') {
      setState(() => _snapToGrid = !_snapToGrid);
    } else if (action == 'toggle_minimap') {
      setState(() => _showMinimap = !_showMinimap);
    } else if (action == 'json_io') {
      unawaited(_openJsonIoDialog(isZh));
    }
  }

  Future<void> _handleNodeContextMenu(
    Offset globalPos,
    CanvasNode node,
    bool isZh,
  ) async {
    if (!_selectedNodeIds.contains(node.id)) {
      setState(() {
        _selectedNodeIds = {node.id};
        _selectedEdgeId = null;
      });
    }
    final isRunView = _ctrl.selectedRunId != null;
    final action = await CanvasContextMenu.showNodeMenu(
      context,
      globalPos: globalPos,
      node: node,
      selectionCount: _selectedNodeIds.length,
      isZh: isZh,
      readOnly: isRunView,
    );
    if (!mounted || action == null) return;
    if (action == 'test_step') {
      _startSingleStep(node);
    } else if (action == 'run_from_here') {
      final viewingRun = _ctrl.selectedRun;
      if (viewingRun != null && !viewingRun.running) {
        _resumeRunFromNode(viewingRun, node.id);
      } else if (!isRunView) {
        _runEditorFromNode(node.id);
      }
    } else if (action == 'ai_assist') {
      final updated = await showCanvasNodeAiAssistDialog(
        context,
        node: node,
        availableVars: _availableTemplateVars(),
        isZh: isZh,
        cwd: widget.session?.root,
      );
      if (mounted && updated != null) {
        if (node.kind == CanvasNodeKind.condition) {
          _ctrl.updateNode(node.id, conditionExpr: updated.trim());
        } else {
          _ctrl.updateNode(node.id, content: updated);
        }
      }
    } else if (action == 'copy') {
      _copySelected();
    } else if (action == 'duplicate') {
      _duplicateSelected();
    } else if (action.startsWith('align:')) {
      final alignName = action.substring(6);
      final align = CanvasNodeAlignment.values.asNameMap()[alignName];
      if (align != null) {
        _ctrl.alignNodes(_selectedNodeIds, align);
      }
    } else if (action == 'delete') {
      _deleteSelected();
    }
  }

  Future<void> _handleEdgeContextMenu(
    Offset globalPos,
    CanvasEdge edge,
    bool isZh,
  ) async {
    if (_ctrl.selectedRunId != null) return;
    final action = await CanvasContextMenu.showEdgeMenu(
      context,
      globalPos: globalPos,
      edge: edge,
      isZh: isZh,
    );
    if (!mounted || action == null) return;
    if (action.startsWith('insert:')) {
      final kind = CanvasNodeKind.parse(action.substring(7));
      final created = _ctrl.insertNodeOnEdge(
        edge.id,
        kind,
        title: kind.label(isZh),
      );
      if (created != null) {
        final d = _defaultsFor(kind, isZh);
        _ctrl.updateNode(
          created.id,
          content: d.content,
          httpUrl: d.httpUrl,
        );
        setState(() {
          _selectedNodeIds = {created.id};
          _selectedEdgeId = null;
        });
      }
    } else if (action.startsWith('branch:')) {
      final branch = CanvasEdgeBranch.parse(action.substring(7));
      _ctrl.reconnectEdge(edge.id, branch: branch);
    } else if (action == 'delete') {
      setState(() => _selectedEdgeId = null);
      _ctrl.removeEdge(edge.id);
    }
  }

  List<String> _availableTemplateVars() {
    final vars = <String>[
      '{{prev.output}}',
      '{{prev.exitCode}}',
      '{{approval.note}}',
      '{{input.root}}',
    ];
    for (final n in _ctrl.displayNodes) {
      if (n.kind == CanvasNodeKind.trigger) {
        for (final k in CanvasController.parseKeyValueLines(n.content).keys) {
          final tok = '{{input.$k}}';
          if (!vars.contains(tok)) vars.add(tok);
        }
      }
    }
    return vars;
  }

  CanvasEdge? _hitTestEdge(Offset scenePos) {
    final nodes = _ctrl.displayNodes;
    final byId = {for (final n in nodes) n.id: n};
    CanvasEdge? best;
    var bestDist = 14.0;
    for (final edge in _ctrl.displayEdges) {
      final from = byId[edge.fromId];
      final to = byId[edge.toId];
      if (from == null || to == null) continue;
      final geom = _computeEdgeGeometry(from, to, edge.branch);
      for (var i = 1; i <= 16; i++) {
        final pt = _cubicPoint(geom.p0, geom.c1, geom.c2, geom.p3, i / 17.0);
        final d = (pt - scenePos).distance;
        if (d < bestDist) {
          bestDist = d;
          best = edge;
        }
      }
    }
    return best;
  }

  KeyEventResult _handleCanvasKeyEvent(FocusNode node, KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent && !_isTextInputFocused()) {
        if (!_spacePanning) setState(() => _spacePanning = true);
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent && _spacePanning) {
        setState(() => _spacePanning = false);
        return KeyEventResult.handled;
      }
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final key = event.logicalKey;
    final mod =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    if (key == LogicalKeyboardKey.escape) {
      if (_connecting != null) {
        setState(() {
          _connecting = null;
          _dragWiring = false;
        });
        _wirePointerNotifier.value = null;
        return KeyEventResult.handled;
      }
      if (_selectedNodeIds.isNotEmpty || _selectedEdgeId != null) {
        setState(() {
          _selectedNodeIds = {};
          _selectedEdgeId = null;
        });
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (mod &&
        (key == LogicalKeyboardKey.keyK || key == LogicalKeyboardKey.keyF)) {
      unawaited(_openSearchPalette(isZh));
      return KeyEventResult.handled;
    }

    if (_isTextInputFocused()) return KeyEventResult.ignored;

    if (mod && key == LogicalKeyboardKey.keyZ) {
      if (shift) {
        _ctrl.redo();
      } else {
        _ctrl.undo();
      }
      return KeyEventResult.handled;
    }
    if (mod && key == LogicalKeyboardKey.keyY) {
      _ctrl.redo();
      return KeyEventResult.handled;
    }
    if (mod && key == LogicalKeyboardKey.keyA) {
      setState(() {
        _selectedNodeIds = {for (final n in _ctrl.displayNodes) n.id};
        _selectedEdgeId = null;
      });
      return KeyEventResult.handled;
    }
    if (mod && key == LogicalKeyboardKey.keyC) {
      _copySelected();
      return KeyEventResult.handled;
    }
    if (mod && key == LogicalKeyboardKey.keyV) {
      _pasteCopied();
      return KeyEventResult.handled;
    }
    if (mod && key == LogicalKeyboardKey.keyD) {
      _duplicateSelected();
      return KeyEventResult.handled;
    }
    if (mod && key == LogicalKeyboardKey.digit0) {
      _resetZoom100();
      return KeyEventResult.handled;
    }
    if (shift && !mod && key == LogicalKeyboardKey.digit1) {
      _fitToView();
      return KeyEventResult.handled;
    }
    if (shift && !mod && key == LogicalKeyboardKey.digit2) {
      _fitToSelection();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      _deleteSelected();
      return KeyEventResult.handled;
    }
    final step = shift ? _gridStep : 4.0;
    if (key == LogicalKeyboardKey.arrowLeft) {
      _nudgeSelected(-step, 0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _nudgeSelected(step, 0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _nudgeSelected(0, -step);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _nudgeSelected(0, step);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _saveTemplateDialog(bool isZh) async {
    final nameCtrl = TextEditingController(
      text: isZh ? '自定义工作流' : 'Custom Workflow',
    );
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isZh ? '保存当前画布为模板' : 'Save Canvas as Template'),
        content: SizedBox(
          width: 340,
          child: IdeInputBox(
            controller: nameCtrl,
            placeholder: isZh ? '输入模板名称…' : 'Template name...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
            child: Text(isZh ? '保存' : 'Save'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    if (saved != null && saved.isNotEmpty) {
      _ctrl.saveCurrentAsTemplate(saved);
    }
  }

  Future<void> _openWorkflowModelDialog(bool isZh) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _WorkflowModelConfigDialog(
        ctrl: _ctrl,
        isZh: isZh,
        onSelectNode: (id) {
          setState(() {
            _selectedNodeIds = {id};
            _selectedEdgeId = null;
          });
        },
      ),
    );
  }

  String _workflowModelBadgeLabel(bool isZh) {
    final agentName = switch (_ctrl.defaultAgentId) {
      'agy' => 'agy',
      'codebuddy' => 'CodeBuddy',
      'claude' => 'Claude',
      'codex' => 'Codex',
      _ => _ctrl.defaultAgentId,
    };
    if (_ctrl.defaultModel.isEmpty) {
      return isZh ? '模型: $agentName · 默认' : 'Model: $agentName';
    }
    final lbl = AcpAgentService.instance.modelLabel(
      _ctrl.defaultAgentId,
      _ctrl.defaultModel,
    );
    final short = lbl.length > 18 ? '${lbl.substring(0, 17)}…' : lbl;
    return '$agentName · $short';
  }

  String? _resolveEvidenceDir() {
    final run = _ctrl.selectedRun;
    return CanvasController.resolveEvidenceDirFromNodes(
      _ctrl.displayNodes,
      capturedVars: run?.capturedVars ?? const {},
    );
  }

  Future<void> _confirmClear(bool isZh) async {
    final choice = await showIdeDialog(
      context,
      message: isZh ? '清空当前画布？' : 'Clear current canvas?',
      detail: isZh
          ? '将移除画布上的所有节点和连线（已保存的模板不会受影响）。'
          : 'Removes all nodes and edges on the board (saved templates stay intact).',
      buttons: [isZh ? '清空' : 'Clear'],
    );
    if (choice == 0) {
      setState(() {
        _selectedNodeIds = {};
        _selectedEdgeId = null;
        _connecting = null;
        _dragWiring = false;
      });
      _wirePointerNotifier.value = null;
      _ctrl.clearBoard();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final colors = themeColors;
    final dark = colors.dark;
    final canvasBg = dark
        ? const Color(0xFF14161A)
        : const Color(0xFFF5F4F0);
    final menuBg = dark ? const Color(0xFF1F2228) : Colors.white;
    final menuBorder = dark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.09);

    return Focus(
      focusNode: _canvasFocusNode,
      autofocus: true,
      onKeyEvent: _handleCanvasKeyEvent,
      child: ListenableBuilder(
        listenable: _ctrl,
        builder: (context, _) {
          final viewingRun = _ctrl.selectedRun;
          final isRunView = viewingRun != null;
          final nodes = _ctrl.displayNodes;
          final edges = _ctrl.displayEdges;
          final selectedNode = _primarySelectedNodeId == null
              ? null
              : _ctrl.displayNodeById(_primarySelectedNodeId!);
          final approvalNode = _ctrl.activeApprovalNodeId == null
              ? null
              : _ctrl.displayNodeById(_ctrl.activeApprovalNodeId!);
          final bgApprovalRun = _ctrl.firstBackgroundApprovalRun;

          final execTotal = nodes.where((n) => n.kind.isExecutable).length;
          final execDone = nodes
              .where(
                (n) =>
                    n.runStatus == CanvasNodeRunStatus.succeeded ||
                    n.runStatus == CanvasNodeRunStatus.failed ||
                    n.runStatus == CanvasNodeRunStatus.skipped,
              )
              .length;
          final currentRunActive = viewingRun != null && viewingRun.running;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Refined 48px Studio Toolbar
              Container(
                height: 48,
                decoration: BoxDecoration(
                  color: colors['editor.background'],
                  border: Border(
                    bottom: BorderSide(
                      color: dark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.black.withValues(alpha: 0.07),
                    ),
                  ),
                ),
                child: LayoutBuilder(
                  builder: (context, barBox) => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minWidth: math.max(0, barBox.maxWidth - 24),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Multi-Workflow Document Switcher
                              PopupMenuButton<String>(
                                tooltip: _ctrl.activeWorkflowName.isEmpty
                                    ? (isZh
                                          ? '切换或管理多条工作流画布'
                                          : 'Switch or manage workflow documents')
                                    : (isZh
                                          ? '${_ctrl.activeWorkflowName}（点击切换或管理工作流）'
                                          : '${_ctrl.activeWorkflowName} (Switch or manage workflows)'),
                                offset: const Offset(0, 38),
                                color: menuBg,
                                surfaceTintColor: Colors.transparent,
                                elevation: 12,
                                constraints: const BoxConstraints(
                                  minWidth: 230,
                                  maxWidth: 320,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(11),
                                  side: BorderSide(color: menuBorder),
                                ),
                                onSelected: (val) {
                                  if (val == '__new__') {
                                    unawaited(
                                      _promptNewOrRenameWorkflow(
                                        isZh: isZh,
                                        rename: false,
                                      ),
                                    );
                                  } else if (val == '__rename__') {
                                    unawaited(
                                      _promptNewOrRenameWorkflow(
                                        isZh: isZh,
                                        rename: true,
                                      ),
                                    );
                                  } else if (val == '__delete__') {
                                    _ctrl.deleteWorkflow(
                                      _ctrl.activeWorkflowId,
                                    );
                                    setState(() {
                                      _selectedNodeIds = {};
                                      _selectedEdgeId = null;
                                    });
                                    WidgetsBinding.instance
                                        .addPostFrameCallback(
                                          (_) => _fitToView(),
                                        );
                                  } else if (val.startsWith('wf:')) {
                                    _ctrl.switchWorkflow(val.substring(3));
                                    setState(() {
                                      _selectedNodeIds = {};
                                      _selectedEdgeId = null;
                                    });
                                    WidgetsBinding.instance
                                        .addPostFrameCallback(
                                          (_) => _fitToView(),
                                        );
                                  }
                                },
                                itemBuilder: (_) => [
                                  for (final w in _ctrl.workflows)
                                    PopupMenuItem(
                                      value: 'wf:${w.id}',
                                      height: 36,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            w.id == _ctrl.activeWorkflowId
                                                ? Codicons.check
                                                : Codicons.layers,
                                            size: 13,
                                            color:
                                                w.id == _ctrl.activeWorkflowId
                                                ? const Color(0xFF2563EB)
                                                : colors[
                                                      'descriptionForeground'],
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              w.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight:
                                                    w.id ==
                                                        _ctrl.activeWorkflowId
                                                    ? FontWeight.w600
                                                    : FontWeight.w400,
                                                color: colors['foreground'],
                                              ),
                                            ),
                                          ),
                                          Text(
                                            '${w.nodes.length}',
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: colors[
                                                  'descriptionForeground'],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  const PopupMenuDivider(height: 8),
                                  PopupMenuItem(
                                    value: '__new__',
                                    height: 34,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Codicons.add,
                                          size: 13,
                                          color: Color(0xFF2563EB),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          isZh ? '新建空白工作流…' : 'New Workflow...',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: colors['foreground'],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: '__rename__',
                                    height: 34,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Codicons.edit,
                                          size: 13,
                                          color: colors['foreground'],
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          isZh
                                              ? '重命名当前工作流…'
                                              : 'Rename Current...',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: colors['foreground'],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (_ctrl.workflows.length > 1)
                                    PopupMenuItem(
                                      value: '__delete__',
                                      height: 34,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Codicons.trash,
                                            size: 13,
                                            color: Color(0xFFDC2626),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            isZh
                                                ? '删除当前工作流'
                                                : 'Delete Workflow',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Color(0xFFDC2626),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                                child: _ToolbarPill(
                                  icon: Codicons.layers,
                                  label: _ctrl.activeWorkflowName.isEmpty
                                      ? (isZh ? '默认工作流' : 'Workflow')
                                      : _ctrl.activeWorkflowName,
                                  chevron: true,
                                  maxWidth: 184,
                                ),
                              ),
                              const SizedBox(width: 6),
                              // Primary Run / Stop / Re-run Pill
                              _RunWorkflowButton(
                                running: currentRunActive,
                                label: currentRunActive
                                    ? (isZh
                                          ? '停止 #${viewingRun.id} ($execDone/$execTotal)'
                                          : 'Stop #${viewingRun.id} ($execDone/$execTotal)')
                                    : (isRunView
                                          ? (isZh ? '重新运行' : 'Re-run')
                                          : (isZh ? '运行工作流' : 'Run Workflow')),
                                onTap: currentRunActive
                                    ? () => _ctrl.stopWorkflow(
                                        runId: viewingRun.id,
                                      )
                                    : isRunView
                                    ? () {
                                        setState(() => _showLogDrawer = true);
                                        unawaited(
                                          _ctrl.rerunWorkflow(
                                            viewingRun,
                                            defaultCwd: widget.session?.root,
                                          ),
                                        );
                                      }
                                    : () => unawaited(
                                        _startEditorWorkflowWithParams(isZh),
                                      ),
                              ),
                              const SizedBox(width: 6),
                              // Quick Parallel Launch Menu (launch another workflow without disturbing active runs or editor)
                              PopupMenuButton<String>(
                                tooltip: isZh
                                    ? '并行启动一个新工作流（不中断正在运行的工作流）'
                                    : 'Launch another workflow in parallel',
                                offset: const Offset(0, 38),
                                color: menuBg,
                                surfaceTintColor: Colors.transparent,
                                elevation: 12,
                                constraints: const BoxConstraints(
                                  minWidth: 320,
                                  maxWidth: 400,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(11),
                                  side: BorderSide(color: menuBorder),
                                ),
                                onSelected: _launchParallelWorkflow,
                                itemBuilder: (_) => [
                                  if (_ctrl.nodes.any(
                                    (n) => n.kind.isExecutable,
                                  )) ...[
                                    PopupMenuItem(
                                      value: CanvasController
                                          .currentCanvasTemplateId,
                                      height: 40,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Codicons.playCircle,
                                            size: 14,
                                            color: Color(0xFF2563EB),
                                          ),
                                          const SizedBox(width: 9),
                                          Expanded(
                                            child: Text(
                                              isZh
                                                  ? '并行启动：当前编辑画布'
                                                  : 'Run Current Editor Canvas',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                                color: colors['foreground'],
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const PopupMenuDivider(height: 8),
                                  ],
                                  _templateMenuItem(
                                    value: CanvasController
                                        .plmLocalRebuildTemplateId,
                                    icon: Codicons.rocket,
                                    color: const Color(0xFF8B5CF6),
                                    title: isZh
                                        ? '本地重建启动（LC → BC → 业务）'
                                        : 'Local Rebuild LC -> BC -> Apps',
                                    subtitle: isZh
                                        ? '作为独立实例后台并行执行'
                                        : 'Run as isolated background instance',
                                    fg: colors['foreground'],
                                    muted: colors['descriptionForeground'],
                                  ),
                                  _templateMenuItem(
                                    value: CanvasController
                                        .refreshModelTemplateId,
                                    icon: Codicons.sync,
                                    color: const Color(0xFFD97706),
                                    title: isZh
                                        ? '刷新模型（CSC CSV → 全量刷新）'
                                        : 'Refresh PLM Model',
                                    subtitle: isZh
                                        ? '作为独立实例后台并行执行'
                                        : 'Run as isolated background instance',
                                    fg: colors['foreground'],
                                    muted: colors['descriptionForeground'],
                                  ),
                                  _templateMenuItem(
                                    value: CanvasController.deploy69TemplateId,
                                    icon: Codicons.cloudUpload,
                                    color: const Color(0xFF16A34A),
                                    title: isZh
                                        ? 'Jenkins 69-sts 串行部署'
                                        : 'Jenkins 69-sts Deploy',
                                    subtitle: isZh
                                        ? '作为独立实例后台并行执行'
                                        : 'Run as isolated background instance',
                                    fg: colors['foreground'],
                                    muted: colors['descriptionForeground'],
                                  ),
                                  _templateMenuItem(
                                    value: CanvasController.bugVerifyTemplateId,
                                    icon: Codicons.bug,
                                    color: const Color(0xFF2563EB),
                                    title: isZh
                                        ? 'Bug 自动筛单 → 研判 → 改单'
                                        : 'Bug Auto-Triage -> Fix -> Close',
                                    subtitle: isZh
                                        ? '作为独立实例后台并行执行'
                                        : 'Run as isolated background instance',
                                    fg: colors['foreground'],
                                    muted: colors['descriptionForeground'],
                                  ),
                                  if (_ctrl.templates.isNotEmpty) ...[
                                    const PopupMenuDivider(height: 8),
                                    for (final t in _ctrl.templates)
                                      PopupMenuItem(
                                        value: t.id,
                                        height: 36,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              Codicons.layers,
                                              size: 13,
                                              color: colors[
                                                  'descriptionForeground'],
                                            ),
                                            const SizedBox(width: 9),
                                            Expanded(
                                              child: Text(
                                                t.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: colors['foreground'],
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ],
                                child: _ToolbarPill(
                                  icon: Codicons.runAll,
                                  label: isZh ? '并行启动' : 'Run Parallel',
                                  chevron: true,
                                  active: _ctrl.activeRunCount > 1,
                                ),
                              ),
                              const SizedBox(width: 6),
                              // Add Node Menu (properly constrained width)
                              PopupMenuButton<CanvasNodeKind>(
                                tooltip: isZh ? '添加工作流节点' : 'Add workflow node',
                                offset: const Offset(0, 38),
                                color: menuBg,
                                surfaceTintColor: Colors.transparent,
                                elevation: 12,
                                constraints: const BoxConstraints(
                                  minWidth: 280,
                                  maxWidth: 320,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(11),
                                  side: BorderSide(color: menuBorder),
                                ),
                                onSelected: (kind) => _addNode(kind, isZh),
                                itemBuilder: (_) => [
                                  for (final kind in const [
                                    CanvasNodeKind.trigger,
                                    CanvasNodeKind.command,
                                    CanvasNodeKind.agent,
                                    CanvasNodeKind.http,
                                    CanvasNodeKind.condition,
                                    CanvasNodeKind.approval,
                                    CanvasNodeKind.group,
                                    CanvasNodeKind.note,
                                  ])
                                    PopupMenuItem(
                                      value: kind,
                                      height: 44,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 4,
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 26,
                                            height: 26,
                                            alignment: Alignment.center,
                                            decoration: BoxDecoration(
                                              color: Color(
                                                kind.defaultColorValue,
                                              ).withValues(alpha: 0.14),
                                              borderRadius:
                                                  BorderRadius.circular(7),
                                            ),
                                            child: Icon(
                                              _kindIcon(kind),
                                              size: 14,
                                              color: Color(
                                                kind.defaultColorValue,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                Text(
                                                  kind.label(isZh),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 12.5,
                                                    fontWeight: FontWeight.w600,
                                                    color: colors['foreground'],
                                                  ),
                                                ),
                                                Text(
                                                  _kindSubtitle(kind, isZh),
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
                                        ],
                                      ),
                                    ),
                                ],
                                child: _ToolbarPill(
                                  icon: Codicons.add,
                                  label: isZh ? '添加节点' : 'Add Node',
                                  chevron: true,
                                ),
                              ),
                              const SizedBox(width: 6),
                              // Templates Menu (wide, non-clipping, structured)
                              PopupMenuButton<String>(
                                tooltip: isZh ? '工作流模板' : 'Workflow templates',
                                offset: const Offset(0, 38),
                                color: menuBg,
                                surfaceTintColor: Colors.transparent,
                                elevation: 12,
                                constraints: const BoxConstraints(
                                  minWidth: 340,
                                  maxWidth: 420,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(11),
                                  side: BorderSide(color: menuBorder),
                                ),
                                onSelected: (value) {
                                  if (CanvasController.isBuiltInTemplateId(
                                    value,
                                  )) {
                                    _ctrl.loadBuiltInTemplate(
                                      value,
                                      defaultCwd: widget.session?.root,
                                    );
                                    setState(() {
                                      final first = _ctrl.nodes.firstOrNull?.id;
                                      _selectedNodeIds = first == null
                                          ? {}
                                          : {first};
                                      _selectedEdgeId = null;
                                      _connecting = null;
                                    });
                                    _wirePointerNotifier.value = null;
                                    WidgetsBinding.instance
                                        .addPostFrameCallback(
                                          (_) => _fitToView(),
                                        );
                                  } else if (value == '__save__') {
                                    unawaited(_saveTemplateDialog(isZh));
                                  } else if (value == '__clear__') {
                                    unawaited(_confirmClear(isZh));
                                  } else {
                                    final tpl = _ctrl.templates
                                        .where((t) => t.id == value)
                                        .firstOrNull;
                                    if (tpl != null) {
                                      _ctrl.applyTemplate(tpl);
                                      WidgetsBinding.instance
                                          .addPostFrameCallback(
                                            (_) => _fitToView(),
                                          );
                                    }
                                  }
                                },
                                itemBuilder: (_) => [
                                  _templateMenuItem(
                                    value: CanvasController
                                        .plmLocalRebuildTemplateId,
                                    icon: Codicons.rocket,
                                    color: const Color(0xFF8B5CF6),
                                    title: isZh
                                        ? '本地重建启动（LC → BC → PDM/PPM/UMC）'
                                        : 'Local Rebuild LC -> BC -> Apps',
                                    subtitle: isZh
                                        ? '打包同步并 tmux 重启 4200/4203/4205，SSO 常驻'
                                        : 'Build, sync & restart via tmux',
                                    fg: colors['foreground'],
                                    muted: colors['descriptionForeground'],
                                  ),
                                  _templateMenuItem(
                                    value: CanvasController
                                        .refreshModelTemplateId,
                                    icon: Codicons.sync,
                                    color: const Color(0xFFD97706),
                                    title: isZh
                                        ? '刷新模型（CSC CSV 上传 → 全量重建缓存）'
                                        : 'Refresh PLM Model (Upload CSV & Rebuild Cache)',
                                    subtitle: isZh
                                        ? 'GBK 编码校验 → 上传变更 CSV → POST /admin/model/refresh'
                                        : 'GBK check -> upload CSC CSV -> POST /admin/model/refresh',
                                    fg: colors['foreground'],
                                    muted: colors['descriptionForeground'],
                                  ),
                                  _templateMenuItem(
                                    value: CanvasController.deploy69TemplateId,
                                    icon: Codicons.cloudUpload,
                                    color: const Color(0xFF16A34A),
                                    title: isZh
                                        ? 'Jenkins 69-sts 零 Token 部署（LC → BC → 业务）'
                                        : 'Jenkins 69-sts Zero-Token Deploy',
                                    subtitle: isZh
                                        ? 'Shell 直调 Jenkins API · 零 Token · 支持极速/全量并行与断点续跑'
                                        : 'Direct Jenkins API via Tabbit · zero LLM tokens',
                                    fg: colors['foreground'],
                                    muted: colors['descriptionForeground'],
                                  ),
                                  _templateMenuItem(
                                    value: CanvasController.bugVerifyTemplateId,
                                    icon: Codicons.bug,
                                    color: const Color(0xFF2563EB),
                                    title: isZh
                                        ? 'Bug 自动筛单 → 研判 → PR → 留证 → 改单'
                                        : 'Bug Auto-Triage -> Fix -> Media -> Close',
                                    subtitle: isZh
                                        ? 'pomeloc.top/bugs · 全程状态同步 + 截图录屏溯源'
                                        : 'pomeloc.top/bugs full traceable pipeline',
                                    fg: colors['foreground'],
                                    muted: colors['descriptionForeground'],
                                  ),
                                  const PopupMenuDivider(height: 10),
                                  PopupMenuItem(
                                    value: '__save__',
                                    height: 36,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Codicons.save,
                                          size: 14,
                                          color: colors['foreground'],
                                        ),
                                        const SizedBox(width: 9),
                                        Expanded(
                                          child: Text(
                                            isZh
                                                ? '保存当前画布为模板…'
                                                : 'Save Current as Template...',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: colors['foreground'],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (_ctrl.templates.isNotEmpty) ...[
                                    const PopupMenuDivider(height: 10),
                                    for (final t in _ctrl.templates)
                                      PopupMenuItem(
                                        value: t.id,
                                        height: 36,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              Codicons.layers,
                                              size: 13,
                                              color: colors[
                                                  'descriptionForeground'],
                                            ),
                                            const SizedBox(width: 9),
                                            Expanded(
                                              child: Text(
                                                t.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: colors['foreground'],
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                  const PopupMenuDivider(height: 10),
                                  PopupMenuItem(
                                    value: '__clear__',
                                    height: 36,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Codicons.trash,
                                          size: 14,
                                          color: Color(0xFFDC2626),
                                        ),
                                        const SizedBox(width: 9),
                                        Expanded(
                                          child: Text(
                                            isZh ? '清空当前画布' : 'Clear Board',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Color(0xFFDC2626),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                child: _ToolbarPill(
                                  icon: Codicons.sparkle,
                                  label: isZh ? '模板' : 'Templates',
                                  chevron: true,
                                ),
                              ),
                              const SizedBox(width: 6),
                              // AI Workflow Generator Button
                              Tooltip(
                                message: isZh
                                    ? '用自然语言让 AI 自动生成或改造整条可执行工作流'
                                    : 'Generate or modify workflow with AI',
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(7),
                                  onTap: () => unawaited(
                                    _openAiGeneratorDialog(isZh),
                                  ),
                                  child: Container(
                                    height: 30,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 9,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF8B5CF6).withValues(
                                        alpha: dark ? 0.2 : 0.1,
                                      ),
                                      borderRadius: BorderRadius.circular(7),
                                      border: Border.all(
                                        color: const Color(0xFF8B5CF6)
                                            .withValues(alpha: 0.45),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Codicons.wand,
                                          size: 13,
                                          color: Color(0xFF8B5CF6),
                                        ),
                                        const SizedBox(width: 5),
                                        Text(
                                          isZh ? 'AI 生成' : 'AI Build',
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w600,
                                            color: dark
                                                ? const Color(0xFFC4B5FD)
                                                : const Color(0xFF6D28D9),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              // Workflow & Per-Node Model Config Button
                              Tooltip(
                                message: isZh
                                    ? '配置工作流默认模型，并一览/单独指定每个 Agent 节点使用的模型'
                                    : 'Configure workflow default model & per-node models',
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(7),
                                  onTap: () => unawaited(
                                    _openWorkflowModelDialog(isZh),
                                  ),
                                  child: _ToolbarPill(
                                    icon: Codicons.hubot,
                                    label: _workflowModelBadgeLabel(isZh),
                                    chevron: true,
                                    maxWidth: 200,
                                    active:
                                        _ctrl.defaultModel.isNotEmpty ||
                                        _ctrl.nodes.any(
                                          (n) =>
                                              n.kind == CanvasNodeKind.agent &&
                                              (n.agentId.isNotEmpty ||
                                                  n.model.isNotEmpty),
                                        ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 14),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Undo / Redo group
                              if (!isRunView) ...[
                                _ToolbarIconBtn(
                                  icon: Codicons.discard,
                                  tooltip: isZh ? '撤销 (Ctrl+Z)' : 'Undo (Ctrl+Z)',
                                  enabled: _ctrl.canUndo,
                                  onTap: _ctrl.undo,
                                ),
                                const SizedBox(width: 3),
                                _ToolbarIconBtn(
                                  icon: Codicons.redo,
                                  tooltip: isZh ? '重做 (Ctrl+Y)' : 'Redo (Ctrl+Y)',
                                  enabled: _ctrl.canRedo,
                                  onTap: _ctrl.redo,
                                ),
                                const SizedBox(width: 6),
                              ],
                              // Box-select vs Pan mode toggle
                              _ToolbarIconBtn(
                                icon: Codicons.selection,
                                tooltip: _marqueeMode
                                    ? (isZh
                                          ? '当前为框选模式（按住空格可平移，点击切回拖拽平移）'
                                          : 'Box-Select mode (hold Space to pan)')
                                    : (isZh
                                          ? '切换框选多选模式（也可按住 Shift 框选）'
                                          : 'Toggle Box-Select mode (or Shift+Drag)'),
                                active: _marqueeMode,
                                onTap: () => setState(
                                  () => _marqueeMode = !_marqueeMode,
                                ),
                              ),
                              const SizedBox(width: 3),
                              // Snap-to-grid toggle
                              _ToolbarIconBtn(
                                icon: Codicons.magnet,
                                tooltip: isZh
                                    ? '网格吸附 22px（${_snapToGrid ? "已开启" : "已关闭"}）'
                                    : 'Snap to 22px grid',
                                active: _snapToGrid,
                                onTap: () =>
                                    setState(() => _snapToGrid = !_snapToGrid),
                              ),
                              const SizedBox(width: 3),
                              // Auto-follow active node toggle
                              _ToolbarIconBtn(
                                icon: Codicons.target,
                                tooltip: isZh
                                    ? '运行时自动跟随焦点镜头（${_autoFollowActiveNode ? "已开启" : "已关闭"}）'
                                    : 'Auto-follow active node during run',
                                active: _autoFollowActiveNode,
                                onTap: () => setState(
                                  () => _autoFollowActiveNode =
                                      !_autoFollowActiveNode,
                                ),
                              ),
                              const SizedBox(width: 3),
                              // Search palette (Ctrl+K)
                              _ToolbarIconBtn(
                                icon: Codicons.search,
                                tooltip: isZh
                                    ? '搜索并定位节点 (Ctrl+K)'
                                    : 'Search nodes (Ctrl+K)',
                                onTap: () => unawaited(_openSearchPalette(isZh)),
                              ),
                              const SizedBox(width: 3),
                              // Portable JSON Import/Export
                              if (!isRunView) ...[
                                _ToolbarIconBtn(
                                  icon: Codicons.json,
                                  tooltip: isZh
                                      ? '导入 / 导出工作流 JSON'
                                      : 'Import / Export Workflow JSON',
                                  onTap: () => unawaited(_openJsonIoDialog(isZh)),
                                ),
                                const SizedBox(width: 3),
                              ],
                              // Minimap toggle
                              _ToolbarIconBtn(
                                icon: Codicons.map,
                                tooltip: isZh
                                    ? '显示 / 隐藏右下角小地图'
                                    : 'Toggle Minimap',
                                active: _showMinimap,
                                onTap: () => setState(
                                  () => _showMinimap = !_showMinimap,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Tooltip(
                                message: isZh
                                    ? '按 DAG 层级一键自动排版'
                                    : 'Auto-layout DAG cleanly',
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(7),
                                  onTap: () {
                                    if (isRunView) _ctrl.selectRun(null);
                                    _ctrl.autoLayout();
                                    WidgetsBinding.instance
                                        .addPostFrameCallback(
                                          (_) => _fitToView(),
                                        );
                                  },
                                  child: _ToolbarPill(
                                    icon: Codicons.layout,
                                    label: isZh ? '排版' : 'Layout',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 5),
                              Tooltip(
                                message: isZh
                                    ? '居中并缩放显示所有节点 (Shift+1)'
                                    : 'Fit all nodes (Shift+1)',
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(7),
                                  onTap: _fitToView,
                                  child: _ToolbarPill(
                                    icon: Codicons.screenFull,
                                    label: isZh ? '适配' : 'Fit',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 5),
                              InkWell(
                                borderRadius: BorderRadius.circular(7),
                                onTap: () => setState(
                                  () => _showLogDrawer = !_showLogDrawer,
                                ),
                                child: _ToolbarPill(
                                  icon: Codicons.output,
                                  label: isZh ? '日志' : 'Log',
                                  active: _showLogDrawer,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                height: 30,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: (dark ? Colors.white : Colors.black)
                                      .withValues(alpha: dark ? 0.05 : 0.035),
                                  borderRadius: BorderRadius.circular(7),
                                  border: Border.all(
                                    color: dark
                                        ? Colors.white.withValues(alpha: 0.1)
                                        : Colors.black.withValues(alpha: 0.08),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    InkWell(
                                      borderRadius: BorderRadius.circular(5),
                                      onTap: () => _zoomBy(0.85),
                                      child: Padding(
                                        padding: const EdgeInsets.all(5),
                                        child: Icon(
                                          Codicons.zoomOut,
                                          size: 13,
                                          color: colors['foreground'],
                                        ),
                                      ),
                                    ),
                                    Tooltip(
                                      message: isZh
                                          ? '重置缩放 100% (Ctrl+0)'
                                          : 'Reset zoom 100% (Ctrl+0)',
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(4),
                                        onTap: _resetZoom100,
                                        child: SizedBox(
                                          width: 40,
                                          child: ValueListenableBuilder<Matrix4>(
                                            valueListenable: _transform,
                                            builder: (context, m, _) {
                                              final pct =
                                                  (m.getMaxScaleOnAxis() * 100)
                                                      .round();
                                              return Text(
                                                '$pct%',
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w500,
                                                  color: colors[
                                                      'descriptionForeground'],
                                                  fontFeatures: const [
                                                    FontFeature.tabularFigures(),
                                                  ],
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                    InkWell(
                                      borderRadius: BorderRadius.circular(5),
                                      onTap: () => _zoomBy(1.15),
                                      child: Padding(
                                        padding: const EdgeInsets.all(5),
                                        child: Icon(
                                          Codicons.zoomIn,
                                          size: 13,
                                          color: colors['foreground'],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Concurrent Workflow Runs Switcher Bar (shown whenever ≥ 1 run exists)
              if (_ctrl.runs.isNotEmpty)
                _WorkflowRunsBar(
                  ctrl: _ctrl,
                  isZh: isZh,
                  onSelectRun: _selectRunAndFocus,
                ),

              // Background Approval Alert (when another concurrent workflow is waiting for approval)
              if (bgApprovalRun != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD97706).withValues(
                      alpha: dark ? 0.16 : 0.085,
                    ),
                    border: Border(
                      bottom: BorderSide(
                        color: const Color(0xFFD97706).withValues(alpha: 0.36),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Codicons.shield,
                        size: 13.5,
                        color: Color(0xFFD97706),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          isZh
                              ? '后台工作流 #${bgApprovalRun.id}「${bgApprovalRun.name}」正在等待您的人工决策'
                              : 'Background workflow #${bgApprovalRun.id} "${bgApprovalRun.name}" is awaiting approval',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.8,
                            fontWeight: FontWeight.w500,
                            color: colors['foreground'],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IdeButton(
                        label: isZh ? '立即切换处理' : 'Jump to Approval',
                        icon: Codicons.arrowRight,
                        onPressed: () => _selectRunAndFocus(bgApprovalRun.id),
                      ),
                    ],
                  ),
                ),

              // Connecting Mode Guided Banner
              if (_connecting case final conn?)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: _branchColor(conn.branch).withValues(alpha: 0.12),
                    border: Border(
                      bottom: BorderSide(
                        color: _branchColor(conn.branch).withValues(alpha: 0.35),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Codicons.gitCompare,
                        size: 14,
                        color: _branchColor(conn.branch),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isZh
                              ? '连线中：从「${_ctrl.nodeById(conn.fromId)?.title ?? conn.fromId}」的【${conn.branch.label(true)}】分支出发 — 点击任意目标卡片即可连接（Esc 取消）'
                              : 'Wiring (${conn.branch.label(false)}): click any target card to connect (Esc to cancel)',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors['foreground'],
                          ),
                        ),
                      ),
                      IdeButton(
                        label: isZh ? '取消' : 'Cancel',
                        secondary: true,
                        onPressed: () {
                          setState(() {
                            _connecting = null;
                            _dragWiring = false;
                          });
                          _wirePointerNotifier.value = null;
                        },
                      ),
                    ],
                  ),
                ),

              // Live Execution Monitor Strip (visible when viewing a run or running a single step)
              if (viewingRun != null || _ctrl.currentRunningNodeId != null)
                _ExecutionProgressStrip(
                  ctrl: _ctrl,
                  run: viewingRun,
                  isZh: isZh,
                  selectedNodeId: _primarySelectedNodeId,
                  showLogDrawer: _showLogDrawer,
                  onSelectAndFocus: (node) {
                    setState(() {
                      _selectedNodeIds = {node.id};
                      _selectedEdgeId = null;
                    });
                    _focusNode(node);
                  },
                  onResumeFromNode:
                      viewingRun != null &&
                          !viewingRun.running &&
                          viewingRun.resumableNodeId != null
                      ? () => _resumeRunFromNode(
                          viewingRun,
                          viewingRun.resumableNodeId!,
                        )
                      : null,
                  onToggleLog: () =>
                      setState(() => _showLogDrawer = !_showLogDrawer),
                ),

              // Human-in-the-Loop Active Approval Banner (Responsive Wrap for narrow side panels)
              if (approvalNode != null)
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD97706).withValues(
                      alpha: dark ? 0.18 : 0.1,
                    ),
                    border: Border(
                      bottom: BorderSide(
                        color: const Color(0xFFD97706).withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Codicons.shield,
                                size: 15,
                                color: Color(0xFFD97706),
                              ),
                              const SizedBox(width: 7),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 420,
                                ),
                                child: Text(
                                  isZh
                                      ? '⏸ ${viewingRun != null ? "#${viewingRun.id} " : ""}流程暂停在「${approvalNode.title}」等待您的决策'
                                      : '⏸ ${viewingRun != null ? "#${viewingRun.id} " : ""}Paused at "${approvalNode.title}" for decision',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: colors['foreground'],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          IdeButton(
                            label: isZh ? '查看研判详情' : 'Inspect',
                            secondary: true,
                            onPressed: () => setState(() {
                              _selectedNodeIds = {approvalNode.id};
                              _selectedEdgeId = null;
                            }),
                          ),
                          if (_resolveEvidenceDir() case final evDir?)
                            IdeButton(
                              label: isZh ? '打开留证目录' : 'Evidence',
                              icon: Codicons.folderOpened,
                              secondary: true,
                              onPressed: () {
                                unawaited(() async {
                                  final d = Directory(evDir);
                                  if (!await d.exists()) {
                                    await d.create(recursive: true);
                                  }
                                  await _openPathInOs(evDir);
                                }());
                              },
                            ),
                          IdeButton(
                            label: isZh ? '通过放行' : 'Approve',
                            icon: Codicons.check,
                            onPressed: () {
                              final note = _approvalNoteCtrl.text.trim();
                              _approvalNoteCtrl.clear();
                              _ctrl.approveNode(
                                approvalNode.id,
                                note: note,
                                runId: viewingRun?.id,
                              );
                            },
                          ),
                          IdeButton(
                            label: isZh ? '驳回 / 不改 / 转后端' : 'Reject',
                            icon: Codicons.close,
                            secondary: true,
                            onPressed: () {
                              final note = _approvalNoteCtrl.text.trim();
                              _approvalNoteCtrl.clear();
                              _ctrl.rejectNode(
                                approvalNode.id,
                                note: note,
                                runId: viewingRun?.id,
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 7),
                      IdeInputBox(
                        controller: _approvalNoteCtrl,
                        placeholder: isZh
                            ? '补充判断意见（将自动传入下游 {{approval.note}}，如：前端修改 / 只改 pdm / 补充清晰描述 / 转后端原因）'
                            : 'Optional human note passed to {{approval.note}}...',
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 5,
                        runSpacing: 5,
                        children: [
                          for (final preset in const [
                            '前端修改(置PR)',
                            '只改 pdm',
                            '转交后端 林泽世',
                            '描述不清退回补充',
                            '开发已确认(PRCFMD)',
                            '转交测试(QC)',
                          ])
                            InkWell(
                              borderRadius: BorderRadius.circular(6),
                              onTap: () {
                                final cur = _approvalNoteCtrl.text.trim();
                                _approvalNoteCtrl.text = cur.isEmpty
                                    ? preset
                                    : '$cur；$preset';
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: colors['editor.background'],
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: const Color(0xFFD97706)
                                        .withValues(alpha: 0.4),
                                  ),
                                ),
                                child: Text(
                                  preset,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: colors['foreground'],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),

              // Main Area: Responsive Canvas + Split / Slide-Over Inspector
              Expanded(
                child: LayoutBuilder(
                  builder: (context, areaBox) {
                    final narrow = areaBox.maxWidth < 740;
                    final boardBounds = CanvasController.computeBoardSize(
                      nodes,
                    );
                    final boardSize = Size(
                      boardBounds.width,
                      boardBounds.height,
                    );
                    final groupNodes = [
                      for (final n in nodes)
                        if (n.kind == CanvasNodeKind.group) n,
                    ];
                    final regularNodes = [
                      for (final n in nodes)
                        if (n.kind != CanvasNodeKind.group) n,
                    ];
                    final layoutVersion = Object.hashAll([
                      for (final n in nodes)
                        Object.hash(
                          n.id,
                          n.x.round(),
                          n.y.round(),
                          n.width.round(),
                          n.height.round(),
                          n.runStatus,
                        ),
                      for (final e in edges)
                        Object.hash(e.id, e.fromId, e.toId, e.branch),
                    ]);

                    final board = ColoredBox(
                      color: canvasBg,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          _viewportSize = constraints.biggest;
                          final allowPan =
                              !_marqueeMode ||
                              _spacePanning ||
                              _middleMousePanning;

                          return Stack(
                            children: [
                              ClipRect(
                                child: Listener(
                                  onPointerDown: (e) {
                                    _canvasFocusNode.requestFocus();
                                    if (e.buttons == kMiddleMouseButton) {
                                      setState(
                                        () => _middleMousePanning = true,
                                      );
                                      return;
                                    }
                                    final shiftHeld =
                                        HardwareKeyboard.instance.isShiftPressed;
                                    if ((_marqueeMode || shiftHeld) &&
                                        !_spacePanning &&
                                        e.buttons == kPrimaryMouseButton) {
                                      final scenePos = _transform.toScene(
                                        e.localPosition,
                                      );
                                      // Only start marquee if pointer is on empty canvas.
                                      final hitCard = regularNodes.any(
                                        (n) => Rect.fromLTWH(
                                          n.x,
                                          n.y,
                                          n.width,
                                          n.height,
                                        ).contains(scenePos),
                                      );
                                      if (!hitCard) {
                                        _marqueeOriginScene = scenePos;
                                        _marqueeRectNotifier.value =
                                            Rect.fromPoints(scenePos, scenePos);
                                      }
                                    }
                                  },
                                  onPointerMove: (e) {
                                    if (_marqueeOriginScene != null) {
                                      final cur = _transform.toScene(
                                        e.localPosition,
                                      );
                                      _marqueeRectNotifier.value =
                                          Rect.fromPoints(
                                            _marqueeOriginScene!,
                                            cur,
                                          );
                                    }
                                  },
                                  onPointerUp: (_) {
                                    if (_middleMousePanning) {
                                      setState(
                                        () => _middleMousePanning = false,
                                      );
                                    }
                                    final rect = _marqueeRectNotifier.value;
                                    if (_marqueeOriginScene != null &&
                                        rect != null) {
                                      _marqueeOriginScene = null;
                                      _marqueeRectNotifier.value = null;
                                      if (rect.width > 6 || rect.height > 6) {
                                        final picked = <String>{
                                          for (final n in nodes)
                                            if (rect.overlaps(
                                              Rect.fromLTWH(
                                                n.x,
                                                n.y,
                                                n.width,
                                                n.height,
                                              ),
                                            ))
                                              n.id,
                                        };
                                        setState(() {
                                          _selectedNodeIds = picked;
                                          _selectedEdgeId = null;
                                        });
                                      }
                                    }
                                  },
                                  child: MouseRegion(
                                    cursor: _spacePanning || _middleMousePanning
                                        ? SystemMouseCursors.grab
                                        : (_marqueeMode
                                              ? SystemMouseCursors.precise
                                              : MouseCursor.defer),
                                    onHover: (e) {
                                      if (_connecting != null && !_dragWiring) {
                                        _wirePointerNotifier.value = _transform
                                            .toScene(e.localPosition);
                                      }
                                    },
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.translucent,
                                      onTapUp: (d) {
                                        _canvasFocusNode.requestFocus();
                                        if (_connecting != null) {
                                          setState(() {
                                            _connecting = null;
                                            _dragWiring = false;
                                          });
                                          _wirePointerNotifier.value = null;
                                          return;
                                        }
                                        final scenePos = _transform.toScene(
                                          d.localPosition,
                                        );
                                        final hitEdge = _hitTestEdge(scenePos);
                                        if (hitEdge != null) {
                                          setState(() {
                                            _selectedEdgeId = hitEdge.id;
                                            _selectedNodeIds = {};
                                          });
                                        } else if (_selectedNodeIds
                                                .isNotEmpty ||
                                            _selectedEdgeId != null) {
                                          setState(() {
                                            _selectedNodeIds = {};
                                            _selectedEdgeId = null;
                                          });
                                        }
                                      },
                                      onSecondaryTapUp: (d) {
                                        _canvasFocusNode.requestFocus();
                                        final scenePos = _transform.toScene(
                                          d.localPosition,
                                        );
                                        final hitEdge = _hitTestEdge(scenePos);
                                        if (hitEdge != null && !isRunView) {
                                          setState(() {
                                            _selectedEdgeId = hitEdge.id;
                                            _selectedNodeIds = {};
                                          });
                                          unawaited(
                                            _handleEdgeContextMenu(
                                              d.globalPosition,
                                              hitEdge,
                                              isZh,
                                            ),
                                          );
                                          return;
                                        }
                                        unawaited(
                                          _handleBoardContextMenu(
                                            d.globalPosition,
                                            d.localPosition,
                                            isZh,
                                          ),
                                        );
                                      },
                                      child: InteractiveViewer(
                                        key: _boardKey,
                                        transformationController: _transform,
                                        constrained: false,
                                        panEnabled: allowPan,
                                        boundaryMargin: const EdgeInsets.all(
                                          1200,
                                        ),
                                        minScale: 0.25,
                                        maxScale: 2.5,
                                        child: SizedBox(
                                          width: boardSize.width,
                                          height: boardSize.height,
                                          child: Stack(
                                            clipBehavior: Clip.none,
                                            children: [
                                              // 1. Viewport-culled Dot Grid (RepaintBoundary)
                                              Positioned.fill(
                                                child: RepaintBoundary(
                                                  child: CustomPaint(
                                                    painter: _DotGridPainter(
                                                      dotColor:
                                                          (dark
                                                                  ? Colors.white
                                                                  : Colors
                                                                        .black)
                                                              .withValues(
                                                                alpha: dark
                                                                    ? 0.12
                                                                    : 0.1,
                                                              ),
                                                      transform: _transform,
                                                      viewportSize:
                                                          _viewportSize,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              // 2. Group Frames rendered behind edges & workflow cards
                                              for (final g in groupNodes)
                                                Positioned(
                                                  key: ValueKey(
                                                    '${viewingRun?.id ?? 'edit'}-grp-${g.id}',
                                                  ),
                                                  left: g.x,
                                                  top: g.y,
                                                  width: g.width,
                                                  height: g.height,
                                                  child: RepaintBoundary(
                                                    child:
                                                        _CanvasGroupFrameWidget(
                                                          node: g,
                                                          readOnly: isRunView,
                                                          selected:
                                                              _selectedNodeIds
                                                                  .contains(
                                                                    g.id,
                                                                  ),
                                                          scaleProvider: () =>
                                                              _currentScale,
                                                          onSelect:
                                                              (toggleMulti) {
                                                                _canvasFocusNode
                                                                    .requestFocus();
                                                                setState(() {
                                                                  _selectedEdgeId =
                                                                      null;
                                                                  if (toggleMulti) {
                                                                    final next =
                                                                        Set<
                                                                          String
                                                                        >.from(
                                                                          _selectedNodeIds,
                                                                        );
                                                                    if (!next
                                                                        .remove(
                                                                          g.id,
                                                                        )) {
                                                                      next.add(
                                                                        g.id,
                                                                      );
                                                                    }
                                                                    _selectedNodeIds =
                                                                        next;
                                                                  } else {
                                                                    _selectedNodeIds =
                                                                        {g.id};
                                                                  }
                                                                });
                                                              },
                                                          onDragStart: () =>
                                                              _handleNodeDragStart(
                                                                g,
                                                              ),
                                                          onDragUpdate:
                                                              (delta) =>
                                                                  _handleNodeDragUpdate(
                                                                    g,
                                                                    delta,
                                                                  ),
                                                          onDragEnd:
                                                              _handleNodeDragEnd,
                                                          onSecondaryTapUp:
                                                              (d) => unawaited(
                                                                _handleNodeContextMenu(
                                                                  d.globalPosition,
                                                                  g,
                                                                  isZh,
                                                                ),
                                                              ),
                                                        ),
                                                  ),
                                                ),
                                              // 3. Smart Hairpin-Free Bezier Edges (RepaintBoundary)
                                              Positioned.fill(
                                                child: IgnorePointer(
                                                  child: RepaintBoundary(
                                                    child: CustomPaint(
                                                      painter:
                                                          _WorkflowEdgesPainter(
                                                            nodes: nodes,
                                                            edges: edges,
                                                            selectedNodeIds:
                                                                _selectedNodeIds,
                                                            selectedEdgeId:
                                                                _selectedEdgeId,
                                                            layoutVersion:
                                                                layoutVersion,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              // 4. Live Connecting Wire Overlay (rebuilds only itself)
                                              if (_connecting case final conn?)
                                                Positioned.fill(
                                                  child: IgnorePointer(
                                                    child: ValueListenableBuilder<
                                                      Offset?
                                                    >(
                                                      valueListenable:
                                                          _wirePointerNotifier,
                                                      builder: (context, pt, _) =>
                                                          CustomPaint(
                                                            painter:
                                                                _LiveWirePainter(
                                                                  fromNode: _ctrl
                                                                      .displayNodeById(
                                                                        conn.fromId,
                                                                      ),
                                                                  branch:
                                                                      conn.branch,
                                                                  targetPos: pt,
                                                                ),
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              // 5. Figma Magnetic Alignment Guides Overlay
                                              Positioned.fill(
                                                child: IgnorePointer(
                                                  child: ValueListenableBuilder<
                                                    List<_SnapGuide>
                                                  >(
                                                    valueListenable:
                                                        _snapGuidesNotifier,
                                                    builder:
                                                        (context, guides, _) =>
                                                            CustomPaint(
                                                              painter:
                                                                  _SnapGuidesPainter(
                                                                    guides:
                                                                        guides,
                                                                  ),
                                                            ),
                                                  ),
                                                ),
                                              ),
                                              // 6. Marquee Multi-Select Rectangle Overlay
                                              Positioned.fill(
                                                child: IgnorePointer(
                                                  child: ValueListenableBuilder<
                                                    Rect?
                                                  >(
                                                    valueListenable:
                                                        _marqueeRectNotifier,
                                                    builder:
                                                        (context, rect, _) =>
                                                            CustomPaint(
                                                              painter:
                                                                  _MarqueePainter(
                                                                    rect: rect,
                                                                  ),
                                                            ),
                                                  ),
                                                ),
                                              ),
                                              // 7. Interactive Curve-Midpoint Edge Pills (+ Insert / Branch / Delete)
                                              if (!isRunView)
                                                for (final edge in edges)
                                                  if (edge.id ==
                                                          _selectedEdgeId ||
                                                      edge.branch ==
                                                          CanvasEdgeBranch
                                                              .onFail ||
                                                      _selectedNodeIds.contains(
                                                        edge.fromId,
                                                      ) ||
                                                      _selectedNodeIds.contains(
                                                        edge.toId,
                                                      ))
                                                    if (_edgeCurveMidpoint(edge)
                                                        case final mid?)
                                                      Positioned(
                                                        left: mid.dx - 34,
                                                        top: mid.dy - 11,
                                                        child: Container(
                                                          decoration: BoxDecoration(
                                                            color: dark
                                                                ? const Color(
                                                                    0xFF1F2228,
                                                                  )
                                                                : Colors.white,
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  11,
                                                                ),
                                                            border: Border.all(
                                                              color:
                                                                  _branchColor(
                                                                    edge.branch,
                                                                  ).withValues(
                                                                    alpha:
                                                                        edge.id ==
                                                                            _selectedEdgeId
                                                                        ? 1.0
                                                                        : 0.65,
                                                                  ),
                                                              width:
                                                                  edge.id ==
                                                                      _selectedEdgeId
                                                                  ? 1.4
                                                                  : 0.9,
                                                            ),
                                                            boxShadow: [
                                                              BoxShadow(
                                                                color: Colors
                                                                    .black
                                                                    .withValues(
                                                                      alpha:
                                                                          0.1,
                                                                    ),
                                                                blurRadius: 5,
                                                                offset:
                                                                    const Offset(
                                                                      0,
                                                                      1,
                                                                    ),
                                                              ),
                                                            ],
                                                          ),
                                                          child: Row(
                                                            mainAxisSize:
                                                                MainAxisSize
                                                                    .min,
                                                            children: [
                                                              Tooltip(
                                                                message: isZh
                                                                    ? '在线上插入节点或切换分支'
                                                                    : 'Insert node or change branch',
                                                                child: GestureDetector(
                                                                  onTapUp: (d) =>
                                                                      unawaited(
                                                                        _handleEdgeContextMenu(
                                                                          d.globalPosition,
                                                                          edge,
                                                                          isZh,
                                                                        ),
                                                                      ),
                                                                  child: Padding(
                                                                    padding:
                                                                        const EdgeInsets.fromLTRB(
                                                                          6,
                                                                          2.5,
                                                                          4,
                                                                          2.5,
                                                                        ),
                                                                    child: Row(
                                                                      mainAxisSize:
                                                                          MainAxisSize
                                                                              .min,
                                                                      children: [
                                                                        Icon(
                                                                          Codicons
                                                                              .add,
                                                                          size:
                                                                              9.5,
                                                                          color: _branchColor(
                                                                            edge.branch,
                                                                          ),
                                                                        ),
                                                                        const SizedBox(
                                                                          width:
                                                                              2,
                                                                        ),
                                                                        Text(
                                                                          edge.branch
                                                                              .label(
                                                                                isZh,
                                                                              ),
                                                                          style: TextStyle(
                                                                            fontSize:
                                                                                9.5,
                                                                            fontWeight:
                                                                                FontWeight.w600,
                                                                            color: _branchColor(
                                                                              edge.branch,
                                                                            ),
                                                                          ),
                                                                        ),
                                                                      ],
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                              Container(
                                                                width: 0.8,
                                                                height: 11,
                                                                color:
                                                                    (dark
                                                                            ? Colors.white
                                                                            : Colors.black)
                                                                        .withValues(
                                                                          alpha:
                                                                              0.12,
                                                                        ),
                                                              ),
                                                              Tooltip(
                                                                message: isZh
                                                                    ? '删除连线'
                                                                    : 'Delete edge',
                                                                child: InkWell(
                                                                  borderRadius:
                                                                      const BorderRadius.horizontal(
                                                                        right: Radius.circular(
                                                                          10,
                                                                        ),
                                                                      ),
                                                                  onTap: () {
                                                                    setState(
                                                                      () => _selectedEdgeId =
                                                                          null,
                                                                    );
                                                                    _ctrl
                                                                        .removeEdge(
                                                                          edge.id,
                                                                        );
                                                                  },
                                                                  child: Padding(
                                                                    padding:
                                                                        const EdgeInsets.fromLTRB(
                                                                          4,
                                                                          3,
                                                                          5.5,
                                                                          3,
                                                                        ),
                                                                    child: Icon(
                                                                      Codicons
                                                                          .close,
                                                                      size: 8.5,
                                                                      color: colors[
                                                                          'descriptionForeground'],
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                              if (nodes.isEmpty && !isRunView)
                                                Positioned(
                                                  left: 72,
                                                  top: 64,
                                                  child: _EmptyWorkflowHint(
                                                    isZh: isZh,
                                                    onLoadTemplateId: (id) {
                                                      _ctrl.loadBuiltInTemplate(
                                                        id,
                                                        defaultCwd: widget
                                                            .session
                                                            ?.root,
                                                      );
                                                      setState(() {
                                                        final first = _ctrl
                                                            .nodes
                                                            .firstOrNull
                                                            ?.id;
                                                        _selectedNodeIds =
                                                            first == null
                                                            ? {}
                                                            : {first};
                                                        _selectedEdgeId = null;
                                                      });
                                                      WidgetsBinding.instance
                                                          .addPostFrameCallback(
                                                            (_) => _fitToView(),
                                                          );
                                                    },
                                                    onAddNode: (k) =>
                                                        _addNode(k, isZh),
                                                  ),
                                                ),
                                              // 8. Workflow Node Cards (each isolated in RepaintBoundary)
                                              for (final node in regularNodes)
                                                Positioned(
                                                  key: ValueKey(
                                                    '${viewingRun?.id ?? 'edit'}-${node.id}',
                                                  ),
                                                  left: node.x,
                                                  top: node.y,
                                                  width: node.width,
                                                  height: node.height,
                                                  child: RepaintBoundary(
                                                    child: _CanvasCardWidget(
                                                      node: node,
                                                      run: viewingRun,
                                                      readOnly: isRunView,
                                                      scaleProvider: () =>
                                                          _currentScale,
                                                      isZh: isZh,
                                                      selected: _selectedNodeIds
                                                          .contains(node.id),
                                                      connectingFrom: isRunView
                                                          ? null
                                                          : _connecting,
                                                      onSelect: (toggleMulti) {
                                                        _canvasFocusNode
                                                            .requestFocus();
                                                        if (!isRunView &&
                                                            _connecting !=
                                                                null &&
                                                            _connecting!
                                                                    .fromId !=
                                                                node.id &&
                                                            node
                                                                .kind
                                                                .isExecutable) {
                                                          final conn =
                                                              _connecting!;
                                                          final edge = _ctrl
                                                              .connect(
                                                                conn.fromId,
                                                                node.id,
                                                                branch:
                                                                    conn.branch,
                                                              );
                                                          setState(() {
                                                            _connecting = null;
                                                            _dragWiring = false;
                                                            _selectedEdgeId =
                                                                null;
                                                            _selectedNodeIds = {
                                                              node.id,
                                                            };
                                                          });
                                                          _wirePointerNotifier
                                                                  .value =
                                                              null;
                                                          if (edge == null) {
                                                            _showToast(
                                                              isZh
                                                                  ? '无法连接：目标连线会形成环形依赖 (DAG 不允许成环)'
                                                                  : 'Cannot connect: edge would introduce a cycle.',
                                                            );
                                                          }
                                                          return;
                                                        }
                                                        setState(() {
                                                          _selectedEdgeId =
                                                              null;
                                                          if (toggleMulti) {
                                                            final next =
                                                                Set<
                                                                  String
                                                                >.from(
                                                                  _selectedNodeIds,
                                                                );
                                                            if (!next.remove(
                                                              node.id,
                                                            )) {
                                                              next.add(node.id);
                                                            }
                                                            _selectedNodeIds =
                                                                next;
                                                          } else {
                                                            _selectedNodeIds = {
                                                              node.id,
                                                            };
                                                          }
                                                        });
                                                      },
                                                      onDragStart: () =>
                                                          _handleNodeDragStart(
                                                            node,
                                                          ),
                                                      onDragUpdate: (delta) =>
                                                          _handleNodeDragUpdate(
                                                            node,
                                                            delta,
                                                          ),
                                                      onDragEnd:
                                                          _handleNodeDragEnd,
                                                      onSecondaryTapUp: (d) =>
                                                          unawaited(
                                                            _handleNodeContextMenu(
                                                              d.globalPosition,
                                                              node,
                                                              isZh,
                                                            ),
                                                          ),
                                                      onStartConnect: (branch) {
                                                        if (isRunView) return;
                                                        _dragWiring = false;
                                                        _wirePointerNotifier
                                                            .value = _outputPortOffset(
                                                          node,
                                                          branch,
                                                        );
                                                        setState(() {
                                                          _connecting = (
                                                            fromId: node.id,
                                                            branch: branch,
                                                          );
                                                          _selectedEdgeId =
                                                              null;
                                                        });
                                                      },
                                                      onPortDragStart:
                                                          (branch) =>
                                                              _startPortDrag(
                                                                node,
                                                                branch,
                                                              ),
                                                      onPortDragUpdate:
                                                          _updatePortDrag,
                                                      onPortDragEnd: (gPos) =>
                                                          unawaited(
                                                            _endPortDrag(
                                                              gPos,
                                                              isZh,
                                                            ),
                                                          ),
                                                      onQuickAppend:
                                                          (branch, kind) {
                                                            if (isRunView) {
                                                              return;
                                                            }
                                                            _quickAppendNode(
                                                              node.id,
                                                              branch,
                                                              kind,
                                                              isZh,
                                                            );
                                                          },
                                                      onDuplicate: () {
                                                        if (isRunView) return;
                                                        final copy = _ctrl
                                                            .duplicateNode(
                                                              node.id,
                                                            );
                                                        if (copy != null) {
                                                          setState(() {
                                                            _selectedNodeIds = {
                                                              copy.id,
                                                            };
                                                            _selectedEdgeId =
                                                                null;
                                                          });
                                                        }
                                                      },
                                                      onTestRun: () {
                                                        if (isRunView) return;
                                                        _startSingleStep(node);
                                                      },
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              // Multi-Select Floating Action Pill (when 2+ nodes selected)
                              if (_selectedNodeIds.length > 1 && !isRunView)
                                Positioned(
                                  top: 12,
                                  left: 0,
                                  right: 0,
                                  child: Center(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 5,
                                      ),
                                      decoration: BoxDecoration(
                                        color:
                                            (dark
                                                    ? const Color(0xFF1F2228)
                                                    : Colors.white)
                                                .withValues(alpha: 0.96),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: const Color(
                                            0xFF2563EB,
                                          ).withValues(alpha: 0.45),
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withValues(
                                              alpha: 0.14,
                                            ),
                                            blurRadius: 12,
                                            offset: const Offset(0, 4),
                                          ),
                                        ],
                                      ),
                                      child: Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          Text(
                                            isZh
                                                ? '已选 ${_selectedNodeIds.length} 个节点'
                                                : '${_selectedNodeIds.length} selected',
                                            style: const TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF2563EB),
                                            ),
                                          ),
                                          _MiniActionChip(
                                            label: isZh ? '左对齐' : 'Left',
                                            onTap: () => _ctrl.alignNodes(
                                              _selectedNodeIds,
                                              CanvasNodeAlignment.left,
                                            ),
                                          ),
                                          _MiniActionChip(
                                            label: isZh ? '顶对齐' : 'Top',
                                            onTap: () => _ctrl.alignNodes(
                                              _selectedNodeIds,
                                              CanvasNodeAlignment.top,
                                            ),
                                          ),
                                          if (_selectedNodeIds.length >= 3)
                                            _MiniActionChip(
                                              label: isZh ? '等距分布' : 'Distribute',
                                              onTap: () => _ctrl.alignNodes(
                                                _selectedNodeIds,
                                                CanvasNodeAlignment.distributeH,
                                              ),
                                            ),
                                          _MiniActionChip(
                                            label: isZh ? '副本' : 'Duplicate',
                                            onTap: _duplicateSelected,
                                          ),
                                          _MiniActionChip(
                                            label: isZh ? '删除' : 'Delete',
                                            danger: true,
                                            onTap: _deleteSelected,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              // Subtle Frosted Bottom-Left Canvas HUD
                              Positioned(
                                left: 12,
                                bottom: 12,
                                child: IgnorePointer(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color:
                                          (dark
                                                  ? const Color(0xFF1F2228)
                                                  : Colors.white)
                                              .withValues(alpha: 0.9),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: dark
                                            ? Colors.white.withValues(
                                                alpha: 0.09,
                                              )
                                            : Colors.black.withValues(
                                                alpha: 0.08,
                                              ),
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.06,
                                          ),
                                          blurRadius: 8,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Text(
                                      isRunView
                                          ? (isZh
                                                ? '运行实例 #${viewingRun.id}（只读监控）· ${nodes.length} 节点 · Ctrl+K 搜索'
                                                : 'Run #${viewingRun.id} (Read-only) · ${nodes.length} nodes · Ctrl+K search')
                                          : (isZh
                                                ? '${nodes.length} 节点 · ${edges.length} 连线  |  拖拽端口连线 · Shift+框选 · 右键菜单 · Ctrl+K 搜索'
                                                : '${nodes.length} nodes · ${edges.length} edges  |  Drag ports · Shift+Box select · Right-click · Ctrl+K'),
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        color: colors['descriptionForeground'],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              // Interactive Bottom-Right Minimap
                              if (_showMinimap &&
                                  _viewportSize.width >= 520 &&
                                  _viewportSize.height >= 300)
                                Positioned(
                                  right: 12,
                                  bottom: 12,
                                  child: CanvasMinimap(
                                    nodes: nodes,
                                    edges: edges,
                                    selectedNodeIds: _selectedNodeIds,
                                    boardSize: boardSize,
                                    viewportSize: _viewportSize,
                                    transform: _transform,
                                    isZh: isZh,
                                    onFitView: _fitToView,
                                    onClose: () =>
                                        setState(() => _showMinimap = false),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    );
                    if (selectedNode == null) return board;
                    final inspector = _NodeInspectorPanel(
                      key: ValueKey(
                        'inspector-${viewingRun?.id ?? 'edit'}-${selectedNode.id}',
                      ),
                      node: selectedNode,
                      run: viewingRun,
                      isZh: isZh,
                      cwd: widget.session?.root,
                      width: narrow
                          ? math.min(392.0, areaBox.maxWidth * 0.92)
                          : _inspectorWidth.clamp(
                              332.0,
                              math.max(360.0, areaBox.maxWidth * 0.58),
                            ),
                      onResizeWidth: narrow
                          ? null
                          : (delta) => setState(() {
                              final maxW = math.max(
                                360.0,
                                areaBox.maxWidth * 0.58,
                              );
                              _inspectorWidth = (_inspectorWidth - delta).clamp(
                                332.0,
                                math.min(600.0, maxW),
                              );
                            }),
                      onClose: () => setState(() => _selectedNodeIds = {}),
                      onSelectNode: (id) => setState(() {
                        _selectedNodeIds = {id};
                        _selectedEdgeId = null;
                      }),
                      onSwitchToEdit: isRunView
                          ? () {
                              final keepId = selectedNode.id;
                              _ctrl.selectRun(null);
                              setState(() {
                                final kept = _ctrl.nodeById(keepId)?.id;
                                _selectedNodeIds = kept == null ? {} : {kept};
                              });
                            }
                          : null,
                      onTestRun: () => _startSingleStep(selectedNode),
                      onResumeFromNode: selectedNode.kind.isExecutable
                          ? (isRunView
                                ? (!viewingRun.running
                                      ? () => _resumeRunFromNode(
                                          viewingRun,
                                          selectedNode.id,
                                        )
                                      : null)
                                : (selectedNode.kind != CanvasNodeKind.trigger
                                      ? () =>
                                            _runEditorFromNode(selectedNode.id)
                                      : null))
                          : null,
                      onDuplicate: () {
                        final copy = _ctrl.duplicateNode(selectedNode.id);
                        if (copy != null) {
                          setState(() => _selectedNodeIds = {copy.id});
                        }
                      },
                      onDelete: () {
                        final id = selectedNode.id;
                        setState(() => _selectedNodeIds = {});
                        _ctrl.removeNode(id);
                      },
                    );
                    if (narrow) {
                      return Stack(
                        children: [
                          Positioned.fill(child: board),
                          Positioned(
                            top: 0,
                            right: 0,
                            bottom: 0,
                            child: Material(
                              elevation: 14,
                              color: Colors.transparent,
                              child: inspector,
                            ),
                          ),
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: board),
                        inspector,
                      ],
                    );
                  },
                ),
              ),

              // Collapsible & Virtualized Smart-Scrolling Live Execution Console Drawer
              if (_showLogDrawer)
                Container(
                  height: _logExpanded ? 340 : 210,
                  decoration: BoxDecoration(
                    color: dark
                        ? const Color(0xFF13161B)
                        : const Color(0xFF1E222A),
                    border: Border(
                      top: BorderSide(
                        color: dark
                            ? Colors.white.withValues(alpha: 0.12)
                            : Colors.black.withValues(alpha: 0.2),
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        height: 34,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: dark
                              ? const Color(0xFF1B1F27)
                              : const Color(0xFF262B35),
                          border: Border(
                            bottom: BorderSide(
                              color: Colors.white.withValues(alpha: 0.08),
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            if (currentRunActive ||
                                (!isRunView &&
                                    _ctrl.currentRunningNodeId != null))
                              const SizedBox(
                                width: 11,
                                height: 11,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.8,
                                  color: Color(0xFF60A5FA),
                                ),
                              )
                            else
                              const Icon(
                                Codicons.terminal,
                                size: 13,
                                color: Color(0xFF9CA3AF),
                              ),
                            const SizedBox(width: 7),
                            Text(
                              viewingRun != null
                                  ? (isZh
                                        ? '执行控制台 · #${viewingRun.id}'
                                        : 'Console · #${viewingRun.id}')
                                  : (isZh ? '实时执行控制台' : 'Live Execution Console'),
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFF3F4F6),
                              ),
                            ),
                            if (viewingRun != null) ...[
                              const SizedBox(width: 6),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 180,
                                ),
                                child: Text(
                                  viewingRun.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF9CA3AF),
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(width: 10),
                            _ConsoleTabChip(
                              label: isZh ? '全部日志' : 'All Logs',
                              selected: !_logSelectedNodeOnly,
                              onTap: () =>
                                  setState(() => _logSelectedNodeOnly = false),
                            ),
                            if (selectedNode != null) ...[
                              const SizedBox(width: 4),
                              _ConsoleTabChip(
                                label: selectedNode.title,
                                selected: _logSelectedNodeOnly,
                                onTap: () =>
                                    setState(() => _logSelectedNodeOnly = true),
                              ),
                            ],
                            const Spacer(),
                            if (!_consolePinnedToBottom) ...[
                              InkWell(
                                borderRadius: BorderRadius.circular(4),
                                onTap: () {
                                  setState(() => _consolePinnedToBottom = true);
                                  if (_logScrollCtrl.hasClients) {
                                    _logScrollCtrl.jumpTo(
                                      _logScrollCtrl.position.maxScrollExtent,
                                    );
                                  }
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  margin: const EdgeInsets.only(right: 8),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFF2563EB,
                                    ).withValues(alpha: 0.25),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    isZh ? '↓ 回到底部' : '↓ Bottom',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF93C5FD),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            if (viewingRun != null)
                              Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: _LiveElapsedText(
                                  startedAt: viewingRun.startedAt,
                                  finishedAt: viewingRun.finishedAt,
                                  running: viewingRun.running,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF9CA3AF),
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                            Tooltip(
                              message: isZh ? '复制日志' : 'Copy log',
                              child: InkWell(
                                borderRadius: BorderRadius.circular(4),
                                onTap: () {
                                  final txt =
                                      _logSelectedNodeOnly &&
                                          selectedNode != null
                                      ? selectedNode.output
                                      : _ctrl.workflowLog;
                                  if (txt.isNotEmpty) {
                                    unawaited(
                                      Clipboard.setData(
                                        ClipboardData(text: txt),
                                      ),
                                    );
                                  }
                                },
                                child: const Padding(
                                  padding: EdgeInsets.all(4),
                                  child: Icon(
                                    Codicons.copy,
                                    size: 12,
                                    color: Color(0xFF9CA3AF),
                                  ),
                                ),
                              ),
                            ),
                            Tooltip(
                              message: isZh ? '清空日志' : 'Clear log',
                              child: InkWell(
                                borderRadius: BorderRadius.circular(4),
                                onTap: () => _ctrl.clearWorkflowLog(
                                  runId: viewingRun?.id,
                                ),
                                child: const Padding(
                                  padding: EdgeInsets.all(4),
                                  child: Icon(
                                    Codicons.clearAll,
                                    size: 12,
                                    color: Color(0xFF9CA3AF),
                                  ),
                                ),
                              ),
                            ),
                            Tooltip(
                              message: _logExpanded
                                  ? (isZh ? '还原高度' : 'Restore height')
                                  : (isZh ? '展开更高' : 'Expand console'),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(4),
                                onTap: () => setState(
                                  () => _logExpanded = !_logExpanded,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: Icon(
                                    _logExpanded
                                        ? Codicons.chevronDown
                                        : Codicons.chevronUp,
                                    size: 12,
                                    color: const Color(0xFF9CA3AF),
                                  ),
                                ),
                              ),
                            ),
                            InkWell(
                              borderRadius: BorderRadius.circular(4),
                              onTap: () =>
                                  setState(() => _showLogDrawer = false),
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(
                                  Codicons.close,
                                  size: 12,
                                  color: Color(0xFF9CA3AF),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: () {
                          final rawText =
                              _logSelectedNodeOnly && selectedNode != null
                              ? (selectedNode.output.isEmpty
                                    ? (selectedNode.running
                                          ? (isZh
                                                ? '正在执行「${selectedNode.title}」，等待输出流…'
                                                : 'Running "${selectedNode.title}", waiting for output...')
                                          : (isZh
                                                ? '节点「${selectedNode.title}」暂无输出'
                                                : 'No output for this node yet.'))
                                    : selectedNode.output)
                              : (_ctrl.workflowLog.isEmpty
                                    ? (isZh
                                          ? '点击左上角「运行工作流」或卡片上的 ▶ 单步试跑，实时日志与命令/Agent 流式输出将显示在此处。'
                                          : 'Click "Run Workflow" above to start.')
                                    : _ctrl.workflowLog);
                          final lines = rawText.split('\n');
                          return SelectionArea(
                            child: ListView.builder(
                              controller: _logScrollCtrl,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 9,
                              ),
                              itemCount: lines.length,
                              itemBuilder: (context, idx) {
                                final line = lines[idx];
                                final Color lineColor;
                                if (line.startsWith('✗') ||
                                    line.contains('[FAILED]') ||
                                    line.contains('ERROR')) {
                                  lineColor = const Color(0xFFFCA5A5);
                                } else if (line.startsWith('✓') ||
                                    line.contains('VERDICT: PASS')) {
                                  lineColor = const Color(0xFF86EFAC);
                                } else if (line.startsWith('▶') ||
                                    line.startsWith('===') ||
                                    line.startsWith('⏸')) {
                                  lineColor = const Color(0xFF93C5FD);
                                } else {
                                  lineColor = const Color(0xFFE5E7EB);
                                }
                                return Text(
                                  line,
                                  style: TextStyle(
                                    fontSize: 11.4,
                                    height: 1.46,
                                    fontFamily: AppFonts.mono,
                                    color: lineColor,
                                  ),
                                );
                              },
                            ),
                          );
                        }(),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  PopupMenuItem<String> _templateMenuItem({
    required String value,
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required Color fg,
    required Color muted,
  }) => PopupMenuItem<String>(
    value: value,
    height: 48,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
    child: Row(
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(icon, size: 14, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: muted),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Offset? _edgeCurveMidpoint(CanvasEdge edge) {
    final from = _ctrl.displayNodeById(edge.fromId);
    final to = _ctrl.displayNodeById(edge.toId);
    if (from == null || to == null) return null;
    final geom = _computeEdgeGeometry(from, to, edge.branch);
    return _cubicPoint(geom.p0, geom.c1, geom.c2, geom.p3, 0.5);
  }
}

/// Top switcher strip for concurrently running and recently finished
/// [WorkflowRun] instances, letting the user flip effortlessly between the
/// editable canvas and any live execution snapshot.
class _WorkflowRunsBar extends StatelessWidget {
  const _WorkflowRunsBar({
    required this.ctrl,
    required this.isZh,
    required this.onSelectRun,
  });

  final CanvasController ctrl;
  final bool isZh;
  final ValueChanged<int?> onSelectRun;

  Color _runTone(WorkflowRunStatus status) => switch (status) {
    WorkflowRunStatus.running => const Color(0xFF2563EB),
    WorkflowRunStatus.waitingApproval => const Color(0xFFD97706),
    WorkflowRunStatus.succeeded => const Color(0xFF16A34A),
    WorkflowRunStatus.failed => const Color(0xFFDC2626),
    WorkflowRunStatus.cancelled => const Color(0xFF6E7681),
  };

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final dark = colors.dark;
    final runs = ctrl.runs;
    final selectedId = ctrl.selectedRunId;
    final activeCount = ctrl.activeRunCount;
    final hasFinished = runs.any((r) => !r.running);
    final hairline = dark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.07);
    final barBg = dark ? const Color(0xFF191C22) : const Color(0xFFF8F9FB);

    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: barBg,
        border: Border(bottom: BorderSide(color: hairline)),
      ),
      child: Row(
        children: [
          // Editor Canvas Tab
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => onSelectRun(null),
            child: Container(
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: selectedId == null
                    ? (dark ? const Color(0xFF282D37) : Colors.white)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: selectedId == null
                      ? (dark
                            ? Colors.white.withValues(alpha: 0.16)
                            : Colors.black.withValues(alpha: 0.14))
                      : Colors.transparent,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Codicons.edit,
                    size: 11.5,
                    color: selectedId == null
                        ? colors['foreground']
                        : colors['descriptionForeground'],
                  ),
                  const SizedBox(width: 5),
                  Text(
                    isZh ? '编辑画布' : 'Editor',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: selectedId == null
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: selectedId == null
                          ? colors['foreground']
                          : colors['descriptionForeground'],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(
            width: 1,
            height: 16,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            color: hairline,
          ),
          // Scrollable Concurrent Run Pills
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: runs.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, idx) {
                final run = runs[idx];
                final selected = run.id == selectedId;
                final status = run.status;
                final tone = _runTone(status);
                final meta = run.running
                    ? '${run.execDone}/${run.execTotal}'
                    : _formatElapsed(run.duration);

                return Center(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => onSelectRun(run.id),
                    child: Container(
                      height: 24,
                      padding: const EdgeInsets.fromLTRB(7, 0, 4, 0),
                      decoration: BoxDecoration(
                        color: selected
                            ? tone.withValues(alpha: dark ? 0.22 : 0.12)
                            : (dark
                                  ? Colors.white.withValues(alpha: 0.04)
                                  : Colors.white),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: selected
                              ? tone.withValues(alpha: 0.72)
                              : (status == WorkflowRunStatus.waitingApproval
                                    ? tone.withValues(alpha: 0.55)
                                    : hairline),
                          width: selected ? 1.15 : 0.9,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (status == WorkflowRunStatus.running)
                            SizedBox(
                              width: 9,
                              height: 9,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.6,
                                color: tone,
                              ),
                            )
                          else
                            Icon(
                              switch (status) {
                                WorkflowRunStatus.waitingApproval =>
                                  Codicons.shield,
                                WorkflowRunStatus.succeeded =>
                                  Codicons.passFilled,
                                WorkflowRunStatus.failed => Codicons.error,
                                WorkflowRunStatus.cancelled =>
                                  Codicons.debugStop,
                                WorkflowRunStatus.running => Codicons.play,
                              },
                              size: 11,
                              color: tone,
                            ),
                          const SizedBox(width: 5),
                          Text(
                            '#${run.id}',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              fontFamily: AppFonts.mono,
                              color: tone,
                            ),
                          ),
                          const SizedBox(width: 4),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 138),
                            child: Text(
                              run.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: colors['foreground'],
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            status == WorkflowRunStatus.waitingApproval
                                ? (isZh ? '待审批' : 'Gate')
                                : meta,
                            style: TextStyle(
                              fontSize: 9.8,
                              fontWeight: FontWeight.w600,
                              color: tone,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          const SizedBox(width: 3),
                          Tooltip(
                            message: run.running
                                ? (isZh ? '停止此工作流' : 'Stop this run')
                                : (isZh ? '移除此记录' : 'Dismiss run'),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(4),
                              onTap: () => run.running
                                  ? ctrl.stopWorkflow(runId: run.id)
                                  : ctrl.dismissRun(run.id),
                              child: Padding(
                                padding: const EdgeInsets.all(2.5),
                                child: Icon(
                                  run.running
                                      ? Codicons.debugStop
                                      : Codicons.close,
                                  size: 10,
                                  color: run.running
                                      ? const Color(0xFFDC2626)
                                      : colors['descriptionForeground'],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          // Right Summary & Bulk Controls
          if (activeCount > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF2563EB).withValues(
                  alpha: dark ? 0.2 : 0.1,
                ),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                isZh ? '$activeCount 个并发运行' : '$activeCount active',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: dark
                      ? const Color(0xFF93C5FD)
                      : const Color(0xFF1D4ED8),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
          if (activeCount >= 2) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: isZh ? '停止全部正在运行的工作流' : 'Stop all active workflows',
              child: InkWell(
                borderRadius: BorderRadius.circular(5),
                onTap: ctrl.stopAllWorkflows,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2.5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDC2626).withValues(
                      alpha: dark ? 0.2 : 0.09,
                    ),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: const Color(0xFFDC2626).withValues(alpha: 0.35),
                    ),
                  ),
                  child: Text(
                    isZh ? '全部停止' : 'Stop All',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFDC2626),
                    ),
                  ),
                ),
              ),
            ),
          ],
          if (hasFinished) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: isZh ? '清理已结束的运行记录' : 'Clear finished runs',
              child: InkWell(
                borderRadius: BorderRadius.circular(5),
                onTap: ctrl.clearFinishedRuns,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Codicons.clearAll,
                    size: 12.5,
                    color: colors['descriptionForeground'],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RunWorkflowButton extends StatelessWidget {
  const _RunWorkflowButton({
    required this.running,
    required this.label,
    required this.onTap,
  });

  final bool running;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = running ? const Color(0xFFDC2626) : const Color(0xFF18181B);
    final dark = themeColors.dark;
    final effectiveBg = running
        ? const Color(0xFFDC2626)
        : (dark ? const Color(0xFF2563EB) : bg);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: effectiveBg,
            borderRadius: BorderRadius.circular(7),
            boxShadow: [
              BoxShadow(
                color: effectiveBg.withValues(alpha: 0.25),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (running)
                const SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: Colors.white,
                  ),
                )
              else
                const Icon(Codicons.play, size: 13, color: Colors.white),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatElapsed(Duration d) {
  final totalSec = d.inSeconds;
  if (totalSec < 60) {
    final tenths = (d.inMilliseconds % 1000) ~/ 100;
    return totalSec < 10 ? '$totalSec.${tenths}s' : '${totalSec}s';
  }
  final m = (totalSec ~/ 60).toString().padLeft(2, '0');
  final s = (totalSec % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

class _ConsoleTabChip extends StatelessWidget {
  const _ConsoleTabChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(5),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 160),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF2563EB).withValues(alpha: 0.28)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: selected
                ? const Color(0xFF60A5FA).withValues(alpha: 0.7)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? Colors.white : const Color(0xFF9CA3AF),
          ),
        ),
      ),
    );
  }
}

/// Live Execution Monitor Strip displayed directly beneath the canvas toolbar
/// whenever a workflow run is inspected or a single step is running, with
/// clickable step pills.
class _ExecutionProgressStrip extends StatelessWidget {
  const _ExecutionProgressStrip({
    required this.ctrl,
    required this.run,
    required this.isZh,
    required this.selectedNodeId,
    required this.showLogDrawer,
    required this.onSelectAndFocus,
    this.onResumeFromNode,
    required this.onToggleLog,
  });

  final CanvasController ctrl;
  final WorkflowRun? run;
  final bool isZh;
  final String? selectedNodeId;
  final bool showLogDrawer;
  final ValueChanged<CanvasNode> onSelectAndFocus;
  final VoidCallback? onResumeFromNode;
  final VoidCallback onToggleLog;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final dark = colors.dark;
    final activeRun = run;
    final running = activeRun != null
        ? activeRun.running
        : ctrl.currentRunningNodeId != null;
    final approvalId = activeRun != null
        ? activeRun.activeApprovalNodeId
        : ctrl.activeApprovalNodeId;
    final currentId = activeRun != null
        ? activeRun.currentRunningNodeId
        : ctrl.currentRunningNodeId;
    final approvalNode = approvalId == null
        ? null
        : (activeRun != null
              ? activeRun.nodeById(approvalId)
              : ctrl.nodeById(approvalId));
    final currentNode = currentId == null
        ? null
        : (activeRun != null
              ? activeRun.nodeById(currentId)
              : ctrl.nodeById(currentId));
    final sourceNodes = activeRun?.nodes ?? ctrl.nodes;
    final execNodes = [
      for (final n in sourceNodes)
        if (n.kind.isExecutable) n,
    ];
    final doneCount = execNodes
        .where(
          (n) =>
              n.runStatus == CanvasNodeRunStatus.succeeded ||
              n.runStatus == CanvasNodeRunStatus.failed ||
              n.runStatus == CanvasNodeRunStatus.skipped,
        )
        .length;
    final runPrefix = activeRun == null ? '' : '#${activeRun.id} ${activeRun.name} · ';
    final runOk = activeRun != null ? activeRun.ok : ctrl.lastRunOk;
    final runErr = activeRun != null ? activeRun.error : ctrl.lastRunError;

    final Color tone;
    final String headline;
    if (approvalNode != null) {
      tone = const Color(0xFFD97706);
      headline = isZh
          ? '$runPrefix等待人工决策：${approvalNode.title}'
          : '${runPrefix}Waiting approval: ${approvalNode.title}';
    } else if (running) {
      tone = const Color(0xFF2563EB);
      headline = currentNode != null
          ? (isZh
                ? '$runPrefix正在执行：${currentNode.title}'
                : '${runPrefix}Running: ${currentNode.title}')
          : (isZh ? '$runPrefix工作流执行中…' : '${runPrefix}Running workflow...');
    } else if (runOk == true) {
      tone = const Color(0xFF16A34A);
      headline = isZh ? '$runPrefix全部执行完成' : '${runPrefix}Completed';
    } else {
      tone = const Color(0xFFDC2626);
      headline =
          '$runPrefix${runErr ?? (isZh ? '工作流执行中止' : 'Workflow failed')}';
    }

    final dur = activeRun?.duration ?? ctrl.workflowDuration;
    final durText = dur == null ? '' : _formatElapsed(dur);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: dark ? 0.12 : 0.065),
        border: Border(
          bottom: BorderSide(color: tone.withValues(alpha: 0.28)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (running && approvalNode == null)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.9,
                    color: tone,
                  ),
                )
              else
                Icon(
                  approvalNode != null
                      ? Codicons.shield
                      : (runOk == true ? Codicons.passFilled : Codicons.error),
                  size: 13.5,
                  color: tone,
                ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  headline,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors['foreground'],
                  ),
                ),
              ),
              if (activeRun != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: tone.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: _LiveElapsedText(
                    startedAt: activeRun.startedAt,
                    finishedAt: activeRun.finishedAt,
                    running: activeRun.running,
                    suffix: ' · $doneCount/${execNodes.length}',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: tone,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                )
              else if (durText.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: tone.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    '$durText · $doneCount/${execNodes.length}',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: tone,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              if (!running &&
                  approvalNode == null &&
                  runOk != true &&
                  onResumeFromNode != null) ...[
                const SizedBox(width: 6),
                InkWell(
                  borderRadius: BorderRadius.circular(5),
                  onTap: onResumeFromNode,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2.5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2563EB).withValues(
                        alpha: dark ? 0.24 : 0.12,
                      ),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(
                        color: const Color(0xFF2563EB).withValues(alpha: 0.45),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Codicons.debugContinue,
                          size: 11.5,
                          color: dark
                              ? const Color(0xFF93C5FD)
                              : const Color(0xFF1D4ED8),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          activeRun?.cancelRequested == true
                              ? (isZh ? '从断点续跑' : 'Resume')
                              : (isZh ? '从失败节点续跑' : 'Resume Failed'),
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: dark
                                ? const Color(0xFFDBEAFE)
                                : const Color(0xFF1D4ED8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (CanvasController.resolveEvidenceDirFromNodes(
                    sourceNodes,
                    capturedVars: activeRun?.capturedVars ?? const {},
                  )
                  case final evDir?
                  when _CanvasFsCache.existsCached(
                        evDir,
                        () => (context as Element).markNeedsBuild(),
                      ) ==
                      true) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: evDir,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(5),
                    onTap: () => unawaited(_openPathInOs(evDir)),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2.5,
                      ),
                      decoration: BoxDecoration(
                        color: colors['editor.background'],
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(
                          color: colors['widget.border'].withValues(alpha: 0.5),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Codicons.folderOpened,
                            size: 11,
                            color: colors['foreground'],
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isZh ? '留证目录' : 'Evidence',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w500,
                              color: colors['foreground'],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              if (!running && approvalNode == null && runOk == true) ...[
                const SizedBox(width: 6),
                InkWell(
                  borderRadius: BorderRadius.circular(5),
                  onTap: () => ctrl.replayLastCelebration(runId: activeRun?.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2.5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF59E0B).withValues(
                        alpha: dark ? 0.18 : 0.12,
                      ),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.36),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Codicons.sparkle,
                          size: 11.5,
                          color: dark
                              ? const Color(0xFFFBBF24)
                              : const Color(0xFFD97706),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isZh ? '再放烟花' : 'Fireworks',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: dark
                                ? const Color(0xFFFDE68A)
                                : const Color(0xFFB45309),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (currentNode != null) ...[
                const SizedBox(width: 6),
                InkWell(
                  borderRadius: BorderRadius.circular(5),
                  onTap: () => onSelectAndFocus(currentNode),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2.5,
                    ),
                    decoration: BoxDecoration(
                      color: colors['editor.background'],
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(
                        color: tone.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Text(
                      isZh ? '定位节点' : 'Focus',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        color: colors['foreground'],
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 6),
              InkWell(
                borderRadius: BorderRadius.circular(5),
                onTap: onToggleLog,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2.5,
                  ),
                  decoration: BoxDecoration(
                    color: colors['editor.background'],
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: colors['widget.border'].withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(
                    showLogDrawer
                        ? (isZh ? '收起控制台' : 'Hide Console')
                        : (isZh ? '查看实时输出' : 'Show Console'),
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                      color: colors['foreground'],
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (execNodes.isNotEmpty) ...[
            const SizedBox(height: 6),
            SizedBox(
              height: 24,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: execNodes.length,
                separatorBuilder: (_, _) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Icon(
                    Codicons.chevronRight,
                    size: 11,
                    color: colors['descriptionForeground']
                        .withValues(alpha: 0.5),
                  ),
                ),
                itemBuilder: (_, idx) {
                  final n = execNodes[idx];
                  final stColor = _statusColor(n.runStatus);
                  final isSel = n.id == selectedNodeId;
                  final stepDur = n.runDuration;
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => onSelectAndFocus(n),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isSel
                            ? stColor.withValues(alpha: dark ? 0.24 : 0.16)
                            : colors['editor.background'],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSel
                              ? stColor
                              : stColor.withValues(alpha: 0.35),
                          width: isSel ? 1.2 : 0.85,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (n.runStatus == CanvasNodeRunStatus.running)
                            SizedBox(
                              width: 8,
                              height: 8,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: stColor,
                              ),
                            )
                          else
                            Container(
                              width: 6.5,
                              height: 6.5,
                              decoration: BoxDecoration(
                                color: stColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                          const SizedBox(width: 5),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 150),
                            child: Text(
                              n.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight:
                                    n.runStatus ==
                                            CanvasNodeRunStatus.running ||
                                        isSel
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: colors['foreground'],
                              ),
                            ),
                          ),
                          if (stepDur != null &&
                              n.runStatus != CanvasNodeRunStatus.queued &&
                              n.runStatus != CanvasNodeRunStatus.idle) ...[
                            const SizedBox(width: 4),
                            Text(
                              _formatElapsed(stepDur),
                              style: TextStyle(
                                fontSize: 9.5,
                                color: stColor,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ToolbarPill extends StatelessWidget {
  const _ToolbarPill({
    required this.icon,
    required this.label,
    this.chevron = false,
    this.active = false,
    this.maxWidth,
  });

  final IconData icon;
  final String label;
  final bool chevron;
  final bool active;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final dark = colors.dark;
    final labelText = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w500,
        color: colors['foreground'],
      ),
    );
    return Container(
      height: 30,
      constraints: maxWidth != null
          ? BoxConstraints(maxWidth: maxWidth!)
          : null,
      clipBehavior: Clip.hardEdge,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: active
            ? colors['button.background'].withValues(alpha: 0.14)
            : (dark ? Colors.white : Colors.black).withValues(
                alpha: dark ? 0.05 : 0.035,
              ),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: active
              ? colors['button.background'].withValues(alpha: 0.55)
              : (dark
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.black.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 13,
            color: active ? colors['button.background'] : colors['foreground'],
          ),
          const SizedBox(width: 5),
          if (maxWidth != null) Flexible(child: labelText) else labelText,
          if (chevron) ...[
            const SizedBox(width: 3),
            Icon(
              Codicons.chevronDown,
              size: 11,
              color: colors['descriptionForeground'],
            ),
          ],
        ],
      ),
    );
  }
}

class _ToolbarIconBtn extends StatelessWidget {
  const _ToolbarIconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.enabled = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final dark = colors.dark;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: enabled ? onTap : null,
        child: Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? colors['button.background'].withValues(alpha: 0.16)
                : (dark ? Colors.white : Colors.black).withValues(
                    alpha: dark ? 0.05 : 0.035,
                  ),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: active
                  ? colors['button.background'].withValues(alpha: 0.55)
                  : (dark
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.black.withValues(alpha: 0.08)),
            ),
          ),
          child: Icon(
            icon,
            size: 13.5,
            color: !enabled
                ? colors['descriptionForeground'].withValues(alpha: 0.35)
                : (active ? colors['button.background'] : colors['foreground']),
          ),
        ),
      ),
    );
  }
}

class _MiniActionChip extends StatelessWidget {
  const _MiniActionChip({
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final dark = colors.dark;
    final fg = danger ? const Color(0xFFEF4444) : colors['foreground'];
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: danger
              ? const Color(0xFFEF4444).withValues(alpha: 0.12)
              : (dark ? Colors.white : Colors.black).withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10.8,
            fontWeight: FontWeight.w500,
            color: fg,
          ),
        ),
      ),
    );
  }
}

// --- Smart Edge Geometry (Zero Backward Hairpin Loops!) ---------------------

typedef _EdgeGeometry = ({
  Offset p0,
  Offset c1,
  Offset c2,
  Offset p3,
  double endAngle,
});

Offset _outputPortOffset(CanvasNode node, CanvasEdgeBranch branch) {
  final yFactor = branch == CanvasEdgeBranch.onFail ? 0.74 : 0.42;
  return Offset(node.x + node.width, node.y + node.height * yFactor);
}

Offset _inputPortOffset(CanvasNode node) =>
    Offset(node.x, node.y + node.height * 0.42);

Offset _topInputPortOffset(CanvasNode node) =>
    Offset(node.x + node.width * 0.5, node.y);

_EdgeGeometry _computeEdgeGeometry(
  CanvasNode from,
  CanvasNode to,
  CanvasEdgeBranch branch,
) {
  // Lower-lane failure handlers (or targets sitting below & to the left):
  // exit cleanly downward from the bottom-right of source and sweep smoothly
  // into the TOP-CENTER of the target node — zero hairpin loops!
  final isDownwardBranch =
      branch == CanvasEdgeBranch.onFail && to.y > from.y + from.height * 0.5;
  if (isDownwardBranch) {
    final p0 = Offset(from.x + from.width * 0.72, from.y + from.height);
    final p3 = _topInputPortOffset(to);
    final dy = math.max(48.0, (p3.dy - p0.dy).abs() * 0.55);
    final c1 = Offset(p0.dx, p0.dy + dy);
    final c2 = Offset(p3.dx, p3.dy - dy);
    return (p0: p0, c1: c1, c2: c2, p3: p3, endAngle: math.pi / 2);
  }

  final p0 = _outputPortOffset(from, branch);
  final p3 = _inputPortOffset(to);
  final dx = math.max(48.0, (p3.dx - p0.dx).abs() * 0.45);
  final c1 = Offset(p0.dx + dx, p0.dy);
  final c2 = Offset(p3.dx - dx, p3.dy);
  return (p0: p0, c1: c1, c2: c2, p3: p3, endAngle: 0.0);
}

Offset _cubicPoint(Offset p0, Offset c1, Offset c2, Offset p3, double t) {
  final u = 1.0 - t;
  final tt = t * t;
  final uu = u * u;
  final uuu = uu * u;
  final ttt = tt * t;
  return Offset(
    uuu * p0.dx + 3 * uu * t * c1.dx + 3 * u * tt * c2.dx + ttt * p3.dx,
    uuu * p0.dy + 3 * uu * t * c1.dy + 3 * u * tt * c2.dy + ttt * p3.dy,
  );
}

Color _branchColor(CanvasEdgeBranch branch) => switch (branch) {
  CanvasEdgeBranch.onPass => const Color(0xFF16A34A),
  CanvasEdgeBranch.onFail => const Color(0xFFEF4444),
  CanvasEdgeBranch.always => const Color(0xFF3B82F6),
};

Color _statusColor(CanvasNodeRunStatus status) => switch (status) {
  CanvasNodeRunStatus.idle => const Color(0xFF8B949E),
  CanvasNodeRunStatus.queued => const Color(0xFF8B949E),
  CanvasNodeRunStatus.running => const Color(0xFF2563EB),
  CanvasNodeRunStatus.waitingApproval => const Color(0xFFD97706),
  CanvasNodeRunStatus.succeeded => const Color(0xFF16A34A),
  CanvasNodeRunStatus.failed => const Color(0xFFDC2626),
  CanvasNodeRunStatus.skipped => const Color(0xFF6E7681),
};

IconData _kindIcon(CanvasNodeKind kind) => switch (kind) {
  CanvasNodeKind.trigger => Codicons.symbolEvent,
  CanvasNodeKind.command => Codicons.terminal,
  CanvasNodeKind.agent => Codicons.sparkle,
  CanvasNodeKind.http => Codicons.globe,
  CanvasNodeKind.condition => Codicons.gitCompare,
  CanvasNodeKind.approval => Codicons.shield,
  CanvasNodeKind.note => Codicons.note,
  CanvasNodeKind.chat => Codicons.commentDiscussion,
  CanvasNodeKind.file => Codicons.file,
  CanvasNodeKind.group => Codicons.layout,
};

String _kindSubtitle(CanvasNodeKind kind, bool isZh) => switch (kind) {
  CanvasNodeKind.trigger => isZh ? '定义单号、仓库、环境等输入变量' : 'Define run inputs',
  CanvasNodeKind.command => isZh ? '执行本地构建、单测、Git 脚本' : 'Run shell script',
  CanvasNodeKind.agent => isZh ? '调用 agy / CodeBuddy / Claude / Codex' : 'Run AI kernel',
  CanvasNodeKind.http => isZh ? '调用问题单或 Webhook HTTP 接口' : 'Send HTTP request',
  CanvasNodeKind.condition => isZh ? '按输出内容或退出码决定通过/失败分支' : 'Branch on output',
  CanvasNodeKind.approval => isZh ? '暂停流程等待人工决策并填写意见' : 'Human decision gate',
  CanvasNodeKind.note => isZh ? '画布注释便签（不参与执行）' : 'Documentation note',
  CanvasNodeKind.chat => isZh ? '会话引用卡片' : 'Pinned chat',
  CanvasNodeKind.file => isZh ? '文件预览卡片' : 'File preview',
  CanvasNodeKind.group => isZh ? '分组框（视觉归类节点）' : 'Visual group frame',
};

class _EmptyWorkflowHint extends StatelessWidget {
  const _EmptyWorkflowHint({
    required this.isZh,
    required this.onLoadTemplateId,
    required this.onAddNode,
  });

  final bool isZh;
  final ValueChanged<String> onLoadTemplateId;
  final ValueChanged<CanvasNodeKind> onAddNode;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final dark = colors.dark;
    return Container(
      width: 580,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF1D2026) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: dark
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.black.withValues(alpha: 0.08),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.3 : 0.08),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFF2563EB).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Codicons.sparkle,
                  size: 16,
                  color: Color(0xFF2563EB),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                isZh ? '可执行工作流画布 · 内置工程流水线' : 'Executable Workflow Canvas',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: colors['foreground'],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            isZh
                ? '一键载入内置模板即可运行，或自由拼装节点，并可在「任务队列」里按单号串行执行：'
                : 'Load a built-in pipeline below or build from scratch:',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: colors['descriptionForeground'],
            ),
          ),
          const SizedBox(height: 16),
          for (final (id, icon, color, title, desc) in [
            (
              CanvasController.plmLocalRebuildTemplateId,
              Codicons.rocket,
              const Color(0xFF8B5CF6),
              '本地一键重建启动（LC → BC → PDM/PPM/UMC + SSO 常驻）',
              '打包 lc/bc、同步至三大业务应用清缓存、tmux 重启 4200/4203/4205 并校验四端口 200',
            ),
            (
              CanvasController.refreshModelTemplateId,
              Codicons.sync,
              const Color(0xFFD97706),
              '刷新模型（CSC CSV 编码校验 → 上传 → 全量重建缓存）',
              '自动扫描 csc 改动 CSV 并校验 GBK → SSO 登录 admin 上传 → POST /admin/model/refresh（无改动则直接纯刷新）',
            ),
            (
              CanvasController.deploy69TemplateId,
              Codicons.cloudUpload,
              const Color(0xFF16A34A),
              'Jenkins 69-sts 串行部署（LC → BC → 业务应用）',
              '扫仓库并记录 4873 私服基线 → 自动 Git Push → 串行发布 LC → BC → 取消重复检查部署 69-sts → 核对版本递进',
            ),
            (
              CanvasController.bugVerifyTemplateId,
              Codicons.bug,
              const Color(0xFF2563EB),
              'Bug 自动筛单 → 研判 → PR → 4200/69 图文视频留证 → 改单',
              '免手填单号：自动在 pomeloc.top/bugs 按条件选单，全程同步 PLM/本地状态、保存 diff/截图/录屏与 trace.md',
            ),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => onLoadTemplateId(id),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: dark ? 0.09 : 0.045),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: color.withValues(alpha: 0.28)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(icon, size: 15, color: color),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: colors['foreground'],
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              desc,
                              style: TextStyle(
                                fontSize: 11,
                                color: colors['descriptionForeground'],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Codicons.chevronRight,
                        size: 14,
                        color: colors['descriptionForeground'],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 4),
          IdeButton(
            label: isZh ? '从空白触发节点新建工作流' : 'Start from Blank Trigger',
            icon: Codicons.add,
            secondary: true,
            onPressed: () => onAddNode(CanvasNodeKind.trigger),
          ),
        ],
      ),
    );
  }
}

/// Visual Group Frame container rendered behind workflow cards; dragging its
/// header moves all enclosed cards together.
class _CanvasGroupFrameWidget extends StatelessWidget {
  const _CanvasGroupFrameWidget({
    required this.node,
    required this.readOnly,
    required this.selected,
    required this.scaleProvider,
    required this.onSelect,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onSecondaryTapUp,
  });

  final CanvasNode node;
  final bool readOnly;
  final bool selected;
  final double Function() scaleProvider;
  final ValueChanged<bool> onSelect;
  final VoidCallback onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final GestureTapUpCallback onSecondaryTapUp;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final dark = colors.dark;
    final ctrl = CanvasController.instance;
    final accent = Color(node.colorValue);

    return GestureDetector(
      onTap: () => onSelect(
        HardwareKeyboard.instance.isShiftPressed ||
            HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed,
      ),
      onSecondaryTapUp: onSecondaryTapUp,
      child: Container(
        decoration: BoxDecoration(
          color: accent.withValues(alpha: dark ? 0.08 : 0.055),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? accent : accent.withValues(alpha: 0.36),
            width: selected ? 1.7 : 1.1,
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              right: 0,
              child: GestureDetector(
                onPanStart: readOnly ? null : (_) => onDragStart(),
                onPanUpdate: readOnly ? null : (d) => onDragUpdate(d.delta),
                onPanEnd: readOnly ? null : (_) => onDragEnd(),
                child: MouseRegion(
                  cursor: readOnly
                      ? MouseCursor.defer
                      : SystemMouseCursors.grab,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 8, 10, 7),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: dark ? 0.14 : 0.09),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(13),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(Codicons.layers, size: 13, color: accent),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            node.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: colors['foreground'],
                            ),
                          ),
                        ),
                        if (!readOnly)
                          InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () => ctrl.removeNode(node.id),
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: Icon(
                                Codicons.close,
                                size: 11,
                                color: colors['descriptionForeground'],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (!readOnly)
              Positioned(
                right: 4,
                bottom: 4,
                child: GestureDetector(
                  onPanStart: (_) => ctrl.pushUndoSnapshot(),
                  onPanUpdate: (d) {
                    final s = scaleProvider();
                    ctrl.resizeNode(node.id, d.delta.dx / s, d.delta.dy / s);
                  },
                  onPanEnd: (_) => ctrl.commitLayout(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeUpLeftDownRight,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Codicons.gripper,
                        size: 11,
                        color: colors['descriptionForeground'].withValues(
                          alpha: 0.55,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CanvasCardWidget extends StatefulWidget {
  const _CanvasCardWidget({
    required this.node,
    this.run,
    this.readOnly = false,
    required this.scaleProvider,
    required this.isZh,
    required this.selected,
    required this.connectingFrom,
    required this.onSelect,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onSecondaryTapUp,
    required this.onStartConnect,
    required this.onPortDragStart,
    required this.onPortDragUpdate,
    required this.onPortDragEnd,
    required this.onQuickAppend,
    required this.onDuplicate,
    required this.onTestRun,
  });

  final CanvasNode node;
  final WorkflowRun? run;
  final bool readOnly;
  final double Function() scaleProvider;
  final bool isZh;
  final bool selected;
  final ({String fromId, CanvasEdgeBranch branch})? connectingFrom;
  final ValueChanged<bool> onSelect;
  final VoidCallback onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final GestureTapUpCallback onSecondaryTapUp;
  final ValueChanged<CanvasEdgeBranch> onStartConnect;
  final ValueChanged<CanvasEdgeBranch> onPortDragStart;
  final ValueChanged<Offset> onPortDragUpdate;
  final ValueChanged<Offset> onPortDragEnd;
  final void Function(CanvasEdgeBranch branch, CanvasNodeKind kind) onQuickAppend;
  final VoidCallback onDuplicate;
  final VoidCallback onTestRun;

  @override
  State<_CanvasCardWidget> createState() => _CanvasCardWidgetState();
}

class _CanvasCardWidgetState extends State<_CanvasCardWidget> {
  bool _hovered = false;

  void _triggerSelect() {
    final toggleMulti =
        HardwareKeyboard.instance.isShiftPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    widget.onSelect(toggleMulti);
  }

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final dark = colors.dark;
    final ctrl = CanvasController.instance;
    final node = widget.node;
    final accent = Color(node.colorValue);
    final statusTone = _statusColor(node.runStatus);
    final isConnectTarget =
        widget.connectingFrom != null &&
        widget.connectingFrom!.fromId != node.id &&
        node.kind.isExecutable;

    final cardSurface = dark ? const Color(0xFF1E2128) : Colors.white;
    final subtleBorder = dark
        ? Colors.white.withValues(alpha: 0.11)
        : Colors.black.withValues(alpha: 0.085);

    final borderColor = switch (node.runStatus) {
      CanvasNodeRunStatus.running ||
      CanvasNodeRunStatus.waitingApproval ||
      CanvasNodeRunStatus.failed ||
      CanvasNodeRunStatus.succeeded => statusTone,
      _ => isConnectTarget
          ? const Color(0xFF2563EB)
          : widget.selected
          ? accent
          : _hovered
          ? accent.withValues(alpha: 0.48)
          : subtleBorder,
    };

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            onTap: _triggerSelect,
            onSecondaryTapUp: widget.onSecondaryTapUp,
            child: MouseRegion(
              cursor: isConnectTarget
                  ? SystemMouseCursors.click
                  : MouseCursor.defer,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                decoration: BoxDecoration(
                  color: cardSurface,
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(
                    color: borderColor,
                    width:
                        widget.selected ||
                            isConnectTarget ||
                            node.runStatus == CanvasNodeRunStatus.running ||
                            node.runStatus ==
                                CanvasNodeRunStatus.waitingApproval
                        ? 1.7
                        : 1.0,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: dark ? 0.34 : (widget.selected ? 0.11 : 0.06),
                      ),
                      blurRadius: widget.selected ? 18 : 10,
                      offset: const Offset(0, 4),
                    ),
                    if (widget.selected ||
                        node.runStatus == CanvasNodeRunStatus.running ||
                        node.runStatus == CanvasNodeRunStatus.waitingApproval)
                      BoxShadow(
                        color: borderColor.withValues(alpha: 0.18),
                        blurRadius: 12,
                      ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Elevated Card Header (Multi-Select & Magnetic-Snap Drag Handle)
                    GestureDetector(
                      onTap: _triggerSelect,
                      onPanStart: widget.readOnly
                          ? null
                          : (_) => widget.onDragStart(),
                      onPanUpdate: widget.readOnly
                          ? null
                          : (d) => widget.onDragUpdate(d.delta),
                      onPanEnd: widget.readOnly
                          ? null
                          : (_) => widget.onDragEnd(),
                      child: Container(
                        height: 38,
                        padding: const EdgeInsets.fromLTRB(10, 0, 8, 0),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: dark ? 0.08 : 0.045),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(12),
                          ),
                          border: Border(
                            bottom: BorderSide(
                              color: dark
                                  ? Colors.white.withValues(alpha: 0.06)
                                  : Colors.black.withValues(alpha: 0.055),
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: accent.withValues(
                                  alpha: dark ? 0.22 : 0.14,
                                ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Icon(
                                _kindIcon(node.kind),
                                size: 12.5,
                                color: accent,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                node.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.2,
                                  fontWeight: FontWeight.w600,
                                  color: colors['foreground'],
                                ),
                              ),
                            ),
                            if (node.kind.isExecutable &&
                                node.runStatus != CanvasNodeRunStatus.idle) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: statusTone.withValues(alpha: 0.16),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (node.runStatus ==
                                        CanvasNodeRunStatus.running) ...[
                                      SizedBox(
                                        width: 8,
                                        height: 8,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 1.6,
                                          color: statusTone,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                    ],
                                    if (node.startedAt != null &&
                                        node.runStatus !=
                                            CanvasNodeRunStatus.queued)
                                      _LiveElapsedText(
                                        startedAt: node.startedAt,
                                        finishedAt: node.finishedAt,
                                        running: node.running,
                                        prefix:
                                            '${node.runStatus.label(widget.isZh)} ',
                                        style: TextStyle(
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w600,
                                          color: statusTone,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      )
                                    else
                                      Text(
                                        node.runStatus.label(widget.isZh),
                                        style: TextStyle(
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w600,
                                          color: statusTone,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 4),
                            ],
                            if (!widget.readOnly)
                              AnimatedOpacity(
                                opacity: _hovered || widget.selected ? 1.0 : 0.42,
                                duration: const Duration(milliseconds: 120),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (node.kind == CanvasNodeKind.command ||
                                        node.kind == CanvasNodeKind.agent ||
                                        node.kind == CanvasNodeKind.http)
                                      Tooltip(
                                        message: widget.isZh
                                            ? '单步试跑'
                                            : 'Test step',
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(
                                            5,
                                          ),
                                          onTap: widget.onTestRun,
                                          child: const Padding(
                                            padding: EdgeInsets.all(3),
                                            child: Icon(
                                              Codicons.play,
                                              size: 12,
                                              color: Color(0xFF16A34A),
                                            ),
                                          ),
                                        ),
                                      ),
                                    Tooltip(
                                      message:
                                          widget.isZh ? '复制节点' : 'Duplicate',
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(5),
                                        onTap: widget.onDuplicate,
                                        child: Padding(
                                          padding: const EdgeInsets.all(3),
                                          child: Icon(
                                            Codicons.copy,
                                            size: 11,
                                            color: colors[
                                                'descriptionForeground'],
                                          ),
                                        ),
                                      ),
                                    ),
                                    InkWell(
                                      borderRadius: BorderRadius.circular(5),
                                      onTap: () => ctrl.removeNode(node.id),
                                      child: Padding(
                                        padding: const EdgeInsets.all(3),
                                        child: Icon(
                                          Codicons.close,
                                          size: 11.5,
                                          color:
                                              colors['descriptionForeground'],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    // Tailored Per-Kind Body
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(11, 8, 11, 4),
                        child: _buildTailoredBody(colors, dark, ctrl, accent),
                      ),
                    ),
                    // Clean Footer: Kind Pill + Policy Badges + Hover Quick-Next + Resize Handle
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 6, 5),
                      child: Row(
                        children: [
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color: accent.withValues(
                                  alpha: dark ? 0.14 : 0.08,
                                ),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                () {
                                  if (node.kind != CanvasNodeKind.agent) {
                                    return node.kind.label(widget.isZh);
                                  }
                                  final cfg = ctrl.effectiveAgentConfig(
                                    node,
                                    run: widget.run,
                                  );
                                  final modelTxt = cfg.model.isEmpty
                                      ? (widget.isZh ? '默认' : 'default')
                                      : AcpAgentService.instance.modelLabel(
                                          cfg.agentId,
                                          cfg.model,
                                        );
                                  final eff = cfg.effort.isEmpty
                                      ? ''
                                      : ' · ${cfg.effort}';
                                  return '${cfg.agentId} · $modelTxt$eff';
                                }(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w500,
                                  color: accent,
                                ),
                              ),
                            ),
                          ),
                          if (node.maxRetries > 0) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4.5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFFD97706,
                                ).withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '↻${node.maxRetries}',
                                style: const TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFD97706),
                                ),
                              ),
                            ),
                          ],
                          if (!widget.readOnly) ...[
                            const SizedBox(width: 6),
                            if (node.kind.isExecutable &&
                                (_hovered || widget.selected))
                              _QuickNextFooterMenu(
                                isZh: widget.isZh,
                                onPick: (k) => widget.onQuickAppend(
                                  CanvasEdgeBranch.onPass,
                                  k,
                                ),
                              ),
                            const SizedBox(width: 4),
                            GestureDetector(
                              onPanStart: (_) => ctrl.pushUndoSnapshot(),
                              onPanUpdate: (d) {
                                final s = widget.scaleProvider();
                                ctrl.resizeNode(
                                  node.id,
                                  d.delta.dx / s,
                                  d.delta.dy / s,
                                );
                              },
                              onPanEnd: (_) => ctrl.commitLayout(),
                              child: MouseRegion(
                                cursor: SystemMouseCursors.resizeUpLeftDownRight,
                                child: Padding(
                                  padding: const EdgeInsets.all(2),
                                  child: Icon(
                                    Codicons.gripper,
                                    size: 10,
                                    color: colors['descriptionForeground']
                                        .withValues(alpha: 0.45),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Left Input Port (20x20 hit target around crisp 10px socket)
          if (node.kind.isExecutable && !widget.readOnly)
            Positioned(
              left: -10,
              top: node.height * 0.42 - 10,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: isConnectTarget ? _triggerSelect : null,
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      width: isConnectTarget ? 13 : 10,
                      height: isConnectTarget ? 13 : 10,
                      decoration: BoxDecoration(
                        color: isConnectTarget
                            ? const Color(0xFF2563EB)
                            : cardSurface,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF2563EB),
                          width: isConnectTarget ? 2.4 : 1.7,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Right Output Port: On Pass (20x20 hit target — Click OR Drag to Wire / Drop-to-Create!)
          if (node.kind.isExecutable && !widget.readOnly)
            Positioned(
              right: -10,
              top: node.height * 0.42 - 10,
              child: Tooltip(
                message: widget.isZh
                    ? '拖拽或点击拉出「通过」连线（拖到空白处可快速新建节点）'
                    : 'Drag or click to wire On-Pass (drop on canvas to create)',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.onStartConnect(CanvasEdgeBranch.onPass),
                  onPanStart: (_) =>
                      widget.onPortDragStart(CanvasEdgeBranch.onPass),
                  onPanUpdate: (d) => widget.onPortDragUpdate(d.globalPosition),
                  onPanEnd: (d) => widget.onPortDragEnd(d.globalPosition),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: Center(
                        child: Container(
                          width: _hovered || widget.selected ? 11.5 : 10,
                          height: _hovered || widget.selected ? 11.5 : 10,
                          decoration: BoxDecoration(
                            color: const Color(0xFF16A34A),
                            shape: BoxShape.circle,
                            border: Border.all(color: cardSurface, width: 1.8),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Right Output Port: On Fail (20x20 hit target — Click OR Drag to Wire / Drop-to-Create!)
          if (node.kind.isExecutable &&
              node.kind != CanvasNodeKind.trigger &&
              !widget.readOnly)
            Positioned(
              right: -10,
              top: node.height * 0.74 - 10,
              child: Tooltip(
                message: widget.isZh
                    ? '拖拽或点击拉出「失败」连线（拖到空白处可快速新建节点）'
                    : 'Drag or click to wire On-Fail (drop on canvas to create)',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.onStartConnect(CanvasEdgeBranch.onFail),
                  onPanStart: (_) =>
                      widget.onPortDragStart(CanvasEdgeBranch.onFail),
                  onPanUpdate: (d) => widget.onPortDragUpdate(d.globalPosition),
                  onPanEnd: (d) => widget.onPortDragEnd(d.globalPosition),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: Center(
                        child: Container(
                          width: _hovered || widget.selected ? 11.5 : 10,
                          height: _hovered || widget.selected ? 11.5 : 10,
                          decoration: BoxDecoration(
                            color: const Color(0xFFEF4444),
                            shape: BoxShape.circle,
                            border: Border.all(color: cardSurface, width: 1.8),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTailoredBody(
    dynamic colors,
    bool dark,
    CanvasController ctrl,
    Color accent,
  ) {
    final fg = colors['foreground'] as Color;
    final muted = colors['descriptionForeground'] as Color;
    final node = widget.node;

    if (node.kind == CanvasNodeKind.approval &&
        node.runStatus == CanvasNodeRunStatus.waitingApproval) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Text(
                node.output.isNotEmpty ? node.output : node.content,
                style: TextStyle(fontSize: 11, color: fg, height: 1.4),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: IdeButton(
                  label: widget.isZh ? '通过放行' : 'Approve',
                  icon: Codicons.check,
                  onPressed: () =>
                      ctrl.approveNode(node.id, runId: widget.run?.id),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: IdeButton(
                  label: widget.isZh ? '驳回' : 'Reject',
                  icon: Codicons.close,
                  secondary: true,
                  onPressed: () =>
                      ctrl.rejectNode(node.id, runId: widget.run?.id),
                ),
              ),
            ],
          ),
        ],
      );
    }

    // Live streaming view right on the card while executing
    if (node.runStatus == CanvasNodeRunStatus.running) {
      final rawLines = node.output
          .trim()
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      final tail = rawLines.isEmpty
          ? (widget.isZh ? '正在启动进程，等待实时输出…' : 'Starting process, awaiting output...')
          : rawLines
                .sublist(math.max(0, rawLines.length - 4))
                .join('\n');
      return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF151921),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: const Color(0xFF3B82F6).withValues(alpha: 0.45),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 9,
                  height: 9,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: Color(0xFF60A5FA),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  widget.isZh ? '实时输出流' : 'Live Output',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF60A5FA),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Expanded(
              child: Text(
                tail,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.38,
                  fontFamily: AppFonts.mono,
                  color: const Color(0xFFE5E7EB),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Trigger: crisp Key : Value chips instead of raw text
    if (node.kind == CanvasNodeKind.trigger) {
      final pairs = CanvasController.parseKeyValueLines(node.content);
      if (pairs.isNotEmpty) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final e in pairs.entries.take(4))
              Padding(
                padding: const EdgeInsets.only(bottom: 3.5),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: dark ? 0.16 : 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        e.key,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: accent,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        e.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: fg),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      }
    }

    // Command: clean tinted terminal snippet box
    if (node.kind == CanvasNodeKind.command) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: dark
                    ? Colors.black.withValues(alpha: 0.28)
                    : const Color(0xFFF6F6F8),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color: dark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.black.withValues(alpha: 0.05),
                ),
              ),
              child: Text(
                node.content.trim().isEmpty
                    ? (widget.isZh ? '点击配置 Shell 脚本…' : 'Configure command...')
                    : '\$ ${node.content.trim()}',
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: fg.withValues(alpha: 0.9),
                ),
              ),
            ),
          ),
          if (node.output.isNotEmpty) _outputPreviewChip(node.output, muted),
        ],
      );
    }

    // HTTP: colored Method badge + URL
    if (node.kind == CanvasNodeKind.http) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFF16A34A).withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  node.httpMethod,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF16A34A),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  node.httpUrl.isEmpty ? '(未配置 URL)' : node.httpUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Expanded(
            child: Text(
              node.content,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, height: 1.38, color: muted),
            ),
          ),
          if (node.output.isNotEmpty) _outputPreviewChip(node.output, muted),
        ],
      );
    }

    // Default clean sans-serif body (Agent / Approval / Condition / Note)
    final summary = switch (node.kind) {
      CanvasNodeKind.condition => _humanCondition(
        node.conditionExpr,
        widget.isZh,
      ),
      CanvasNodeKind.file =>
        _CanvasFsCache.filePreviewCached(node.refId, () {
              if (mounted) setState(() {});
            }) ??
            node.content,
      _ => node.content,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Text(
            summary.isEmpty
                ? (widget.isZh ? '点击卡片在右侧编辑参数…' : 'Click card to edit...')
                : summary,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.45,
              color: fg.withValues(alpha: 0.88),
            ),
          ),
        ),
        if (node.output.isNotEmpty) _outputPreviewChip(node.output, muted),
      ],
    );
  }

  Widget _outputPreviewChip(String out, Color muted) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.code,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        out.replaceAll('\n', ' '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 10, color: muted),
      ),
    ),
  );
}

class _QuickNextFooterMenu extends StatelessWidget {
  const _QuickNextFooterMenu({required this.isZh, required this.onPick});

  final bool isZh;
  final ValueChanged<CanvasNodeKind> onPick;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final dark = colors.dark;
    return PopupMenuButton<CanvasNodeKind>(
      tooltip: isZh ? '一键新建并连接下游节点' : 'Quick-append next step',
      color: dark ? const Color(0xFF1F2228) : Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 10,
      constraints: const BoxConstraints(minWidth: 168, maxWidth: 200),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: dark
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.black.withValues(alpha: 0.08),
        ),
      ),
      onSelected: onPick,
      itemBuilder: (_) => [
        for (final kind in const [
          CanvasNodeKind.command,
          CanvasNodeKind.agent,
          CanvasNodeKind.http,
          CanvasNodeKind.condition,
          CanvasNodeKind.approval,
        ])
          PopupMenuItem(
            value: kind,
            height: 34,
            child: Row(
              children: [
                Icon(
                  _kindIcon(kind),
                  size: 13,
                  color: Color(kind.defaultColorValue),
                ),
                const SizedBox(width: 8),
                Text(
                  kind.label(isZh),
                  style: TextStyle(fontSize: 12, color: colors['foreground']),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
        decoration: BoxDecoration(
          color: const Color(0xFF16A34A).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Codicons.add, size: 9.5, color: Color(0xFF16A34A)),
            const SizedBox(width: 2),
            Text(
              isZh ? '下一步' : 'Next',
              style: const TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF16A34A),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _humanCondition(String expr, bool isZh) {
  final trimmed = expr.trim();
  if (trimmed == 'exitZero' || trimmed.isEmpty) {
    return isZh ? '当上一步退出码为 0 时通过' : 'Pass when exit code == 0';
  }
  final idx = trimmed.indexOf(':');
  if (idx <= 0) return trimmed;
  final op = trimmed.substring(0, idx);
  final val = trimmed.substring(idx + 1);
  return switch (op) {
    'contains' => isZh ? '输出包含「$val」→ 通过' : 'Output contains "$val"',
    'notContains' =>
      isZh ? '输出不包含「$val」→ 通过' : 'Output does not contain "$val"',
    'regex' => isZh ? '输出匹配正则 /$val/ → 通过' : 'Matches regex /$val/',
    'equals' => isZh ? '输出等于「$val」→ 通过' : 'Output equals "$val"',
    _ => trimmed,
  };
}

/// Architectural, card-free Right-hand Node Inspector with Swiss editorial
/// typographic sectioning, hairline dividers, recessed code/input surfaces,
/// resizable left edge, and a streamlined sticky footer.
class _NodeInspectorPanel extends StatefulWidget {
  const _NodeInspectorPanel({
    super.key,
    required this.node,
    this.run,
    required this.isZh,
    this.cwd,
    this.width = 400,
    this.onResizeWidth,
    required this.onClose,
    required this.onSelectNode,
    this.onSwitchToEdit,
    required this.onTestRun,
    this.onResumeFromNode,
    required this.onDuplicate,
    required this.onDelete,
  });

  final CanvasNode node;
  final WorkflowRun? run;
  final bool isZh;
  final String? cwd;
  final double width;
  final ValueChanged<double>? onResizeWidth;
  final VoidCallback onClose;
  final ValueChanged<String> onSelectNode;
  final VoidCallback? onSwitchToEdit;
  final VoidCallback onTestRun;
  final VoidCallback? onResumeFromNode;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  @override
  State<_NodeInspectorPanel> createState() => _NodeInspectorPanelState();
}

class _NodeInspectorPanelState extends State<_NodeInspectorPanel> {
  late final _titleCtrl = TextEditingController(text: widget.node.title);
  late final _contentCtrl = TextEditingController(text: widget.node.content);
  late final _refCtrl = TextEditingController(text: widget.node.refId);
  late final _urlCtrl = TextEditingController(text: widget.node.httpUrl);
  late final _headersCtrl = TextEditingController(
    text: widget.node.httpHeaders,
  );
  late final _approvalInputCtrl = TextEditingController();
  late String _condOp;
  late final TextEditingController _condValCtrl;
  int _tabIndex = 0; // 0 = Config, 1 = Output
  bool _triggerRawMode = false;
  bool _resizingHover = false;
  bool _resizingActive = false;

  void _parseConditionExpr(String raw, {bool initController = false}) {
    final expr = raw.trim();
    String op;
    String val;
    if (expr == 'exitZero' || expr.isEmpty) {
      op = 'exitZero';
      val = '';
    } else if (expr.contains(':')) {
      final idx = expr.indexOf(':');
      final candidate = expr.substring(0, idx).trim();
      op = const {'contains', 'notContains', 'regex', 'equals'}.contains(
        candidate,
      )
          ? candidate
          : 'contains';
      val = expr.substring(idx + 1);
    } else {
      op = 'contains';
      val = expr;
    }
    _condOp = op;
    if (initController) {
      _condValCtrl = TextEditingController(text: val);
    } else {
      _syncTextController(_condValCtrl, val);
    }
  }

  void _syncTextController(TextEditingController c, String next) {
    if (c.text == next) return;
    c.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  @override
  void initState() {
    super.initState();
    if (widget.run != null &&
        widget.node.runStatus != CanvasNodeRunStatus.waitingApproval &&
        (widget.node.output.isNotEmpty ||
            widget.node.runStatus != CanvasNodeRunStatus.idle)) {
      _tabIndex = 1;
    }
    _parseConditionExpr(widget.node.conditionExpr, initController: true);
  }

  @override
  void didUpdateWidget(covariant _NodeInspectorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep text controllers synchronized when Undo/Redo or AI Assist mutates
    // the node externally without disturbing active typing.
    _syncTextController(_titleCtrl, widget.node.title);
    _syncTextController(_contentCtrl, widget.node.content);
    _syncTextController(_refCtrl, widget.node.refId);
    _syncTextController(_urlCtrl, widget.node.httpUrl);
    _syncTextController(_headersCtrl, widget.node.httpHeaders);
    final currentExpr = _condOp == 'exitZero'
        ? 'exitZero'
        : '$_condOp:${_condValCtrl.text}';
    if (widget.node.conditionExpr.trim() != currentExpr.trim()) {
      _parseConditionExpr(widget.node.conditionExpr);
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _contentCtrl.dispose();
    _refCtrl.dispose();
    _urlCtrl.dispose();
    _headersCtrl.dispose();
    _approvalInputCtrl.dispose();
    _condValCtrl.dispose();
    super.dispose();
  }

  List<({String label, String token, Color tone})> _dynamicVarChips(
    List<CanvasNode> allNodes,
    bool isZh,
  ) {
    final chips = <({String label, String token, Color tone})>[
      (
        label: isZh ? '上游输出' : 'Prev Output',
        token: '{{prev.output}}',
        tone: const Color(0xFF2563EB),
      ),
      (
        label: isZh ? '退出码' : 'Exit Code',
        token: '{{prev.exitCode}}',
        tone: const Color(0xFF7C3AED),
      ),
      (
        label: isZh ? '人工意见' : 'Approval Note',
        token: '{{approval.note ?? 无}}',
        tone: const Color(0xFFD97706),
      ),
      (
        label: isZh ? '问题单号' : 'Bug ID',
        token: '{{bug.id}}',
        tone: const Color(0xFFDC2626),
      ),
      (
        label: isZh ? '工作区路径' : 'Root Path',
        token: '{{input.root}}',
        tone: const Color(0xFF0891B2),
      ),
    ];
    final seen = {for (final c in chips) c.token};
    for (final n in allNodes) {
      if (n.kind == CanvasNodeKind.trigger) {
        final pairs = CanvasController.parseKeyValueLines(n.content);
        for (final key in pairs.keys) {
          final tok = '{{input.$key}}';
          if (seen.add(tok)) {
            chips.add((label: key, token: tok, tone: const Color(0xFF16A34A)));
          }
        }
      } else if (n.kind.isExecutable &&
          n.id != widget.node.id &&
          n.kind != CanvasNodeKind.approval) {
        final tok = '{{${n.id}.output}}';
        if (seen.add(tok)) {
          chips.add((
            label: '${n.id}.output',
            token: tok,
            tone: const Color(0xFF6366F1),
          ));
        }
      }
    }
    return chips;
  }

  Future<void> _openAiAssist(List<CanvasNode> allNodes) async {
    final vars = [
      for (final c in _dynamicVarChips(allNodes, widget.isZh)) c.token,
    ];
    final generated = await showCanvasNodeAiAssistDialog(
      context,
      node: widget.node,
      availableVars: vars,
      isZh: widget.isZh,
      cwd: widget.cwd,
    );
    if (!mounted || generated == null) return;
    if (widget.node.kind == CanvasNodeKind.condition) {
      final expr = generated.trim();
      _parseConditionExpr(expr);
      setState(() {});
      CanvasController.instance.updateNode(
        widget.node.id,
        conditionExpr: expr,
      );
    } else {
      _syncTextController(_contentCtrl, generated);
      CanvasController.instance.updateNode(
        widget.node.id,
        content: generated,
      );
    }
  }

  void _syncCondition() {
    final expr = _condOp == 'exitZero'
        ? 'exitZero'
        : '$_condOp:${_condValCtrl.text}';
    CanvasController.instance.updateNode(widget.node.id, conditionExpr: expr);
  }

  void _insertVar(String token) {
    final text = _contentCtrl.text;
    final sel = _contentCtrl.selection;
    final String next;
    final int nextOffset;
    if (sel.isValid && sel.start >= 0 && sel.end <= text.length) {
      next = text.replaceRange(sel.start, sel.end, token);
      nextOffset = sel.start + token.length;
    } else {
      next = text.isEmpty ? token : '$text $token';
      nextOffset = next.length;
    }
    _contentCtrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: nextOffset),
    );
    CanvasController.instance.updateNode(widget.node.id, content: next);
  }

  void _updateTriggerKey(String key, String newValue) {
    final lines = const LineSplitter().convert(_contentCtrl.text);
    final updated = <String>[];
    var replaced = false;
    for (final line in lines) {
      final idx = line.indexOf('=');
      if (idx > 0 && line.substring(0, idx).trim() == key && !replaced) {
        updated.add('$key=$newValue');
        replaced = true;
      } else {
        updated.add(line);
      }
    }
    if (!replaced) updated.add('$key=$newValue');
    final next = updated.join('\n');
    _contentCtrl.text = next;
    CanvasController.instance.updateNode(widget.node.id, content: next);
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = CanvasController.instance;
    final run = widget.run;
    final isReadOnly = run != null;
    final node = widget.node;
    final isZh = widget.isZh;
    final colors = themeColors;
    final dark = colors.dark;
    final accent = Color(node.colorValue);
    final statusTone = _statusColor(node.runStatus);
    final agents = AcpAgentService.instance.selectableAgents;
    final allEdges = run?.edges ?? ctrl.edges;
    final allNodes = run?.nodes ?? ctrl.nodes;
    final outgoing = allEdges.where((e) => e.fromId == node.id).toList();
    final otherTargets = allNodes
        .where((n) => n.id != node.id && n.kind.isExecutable)
        .toList();

    // Unified serene canvas surface — no nested card boxes.
    final panelBg = dark ? const Color(0xFF191C22) : const Color(0xFFFFFFFF);
    final fieldFill = dark ? const Color(0xFF21252E) : const Color(0xFFF5F6F8);
    final codeFill = dark ? const Color(0xFF14171D) : const Color(0xFFF6F7FA);
    final hairline = dark
        ? Colors.white.withValues(alpha: 0.075)
        : Colors.black.withValues(alpha: 0.068);
    final subtleBorder = dark
        ? Colors.white.withValues(alpha: 0.055)
        : Colors.black.withValues(alpha: 0.05);
    final borderLine = (_resizingHover || _resizingActive)
        ? accent.withValues(alpha: 0.55)
        : hairline;

    final hasRunActivity =
        node.output.isNotEmpty || node.runStatus != CanvasNodeRunStatus.idle;

    // Sequential Swiss-index counter for visible editorial sections.
    var sectionOrder = 0;
    String nextIndex() => (++sectionOrder).toString().padLeft(2, '0');

    final isCodeContent =
        node.kind == CanvasNodeKind.command || node.kind == CanvasNodeKind.http;

    final sections = <Widget>[
      // Section 01: Basic Info
      _editorialSection(
        index: nextIndex(),
        title: isZh ? '基本信息' : 'GENERAL',
        accent: accent,
        colors: colors,
        showTopDivider: false,
        hairline: hairline,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _subLabel(isZh ? '节点名称' : 'Node Title'),
            _studioField(
              controller: _titleCtrl,
              accent: accent,
              fillColor: fieldFill,
              borderColor: subtleBorder,
              colors: colors,
              readOnly: isReadOnly,
              onChanged: isReadOnly
                  ? null
                  : (v) => ctrl.updateNode(node.id, title: v),
            ),
            if (node.kind == CanvasNodeKind.command ||
                node.kind == CanvasNodeKind.agent ||
                node.kind == CanvasNodeKind.trigger) ...[
              const SizedBox(height: 12),
              _subLabel(
                isZh ? '工作目录（留空继承当前项目）' : 'Working Directory',
              ),
              _studioField(
                controller: _refCtrl,
                accent: accent,
                fillColor: fieldFill,
                borderColor: subtleBorder,
                colors: colors,
                mono: true,
                fontSize: 11.5,
                readOnly: isReadOnly,
                placeholder: '{{input.root}}',
                onChanged: isReadOnly
                    ? null
                    : (v) => ctrl.updateNode(node.id, refId: v),
              ),
            ],
          ],
        ),
      ),

      // Agent only: Model & Kernel Routing
      if (node.kind == CanvasNodeKind.agent)
        _editorialSection(
          index: nextIndex(),
          title: isZh ? '模型与推理' : 'KERNEL & MODEL',
          accent: const Color(0xFF2563EB),
          colors: colors,
          hairline: hairline,
          child: IgnorePointer(
            ignoring: isReadOnly,
            child: _AgentModelSelectorSection(
              ctrl: ctrl,
              run: run,
              node: node,
              agents: agents,
              isZh: isZh,
            ),
          ),
        ),

      // HTTP only: Method, URL, Headers
      if (node.kind == CanvasNodeKind.http)
        _editorialSection(
          index: nextIndex(),
          title: isZh ? 'HTTP 请求' : 'HTTP REQUEST',
          accent: const Color(0xFF16A34A),
          colors: colors,
          hairline: hairline,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final m in const ['GET', 'POST', 'PUT', 'PATCH'])
                    _pillChoice(
                      label: m,
                      selected: node.httpMethod == m,
                      accent: const Color(0xFF16A34A),
                      fillColor: fieldFill,
                      borderColor: subtleBorder,
                      colors: colors,
                      mono: true,
                      onTap: isReadOnly
                          ? () {}
                          : () => ctrl.updateNode(node.id, httpMethod: m),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              _studioField(
                controller: _urlCtrl,
                accent: const Color(0xFF16A34A),
                fillColor: fieldFill,
                borderColor: subtleBorder,
                colors: colors,
                mono: true,
                fontSize: 11.5,
                readOnly: isReadOnly,
                placeholder: 'http://pomeloc.top/bugs/...',
                onChanged: isReadOnly
                    ? null
                    : (v) => ctrl.updateNode(node.id, httpUrl: v),
              ),
              const SizedBox(height: 12),
              _subLabel(isZh ? '请求头（每行 Key: Value）' : 'Headers'),
              _studioField(
                controller: _headersCtrl,
                accent: const Color(0xFF16A34A),
                fillColor: codeFill,
                borderColor: subtleBorder,
                colors: colors,
                mono: true,
                fontSize: 11.5,
                minLines: 2,
                maxLines: 5,
                readOnly: isReadOnly,
                placeholder: 'Authorization: Bearer ...',
                onChanged: isReadOnly
                    ? null
                    : (v) => ctrl.updateNode(node.id, httpHeaders: v),
              ),
            ],
          ),
        ),

      // Condition only: Rule Builder
      if (node.kind == CanvasNodeKind.condition)
        _editorialSection(
          index: nextIndex(),
          title: isZh ? '条件判断规则' : 'CONDITION RULE',
          accent: const Color(0xFFD97706),
          colors: colors,
          hairline: hairline,
          trailing: isReadOnly
              ? null
              : _ghostAction(
                  label: isZh ? '✨ AI 帮写' : '✨ AI Assist',
                  accent: const Color(0xFF8B5CF6),
                  onTap: () => unawaited(_openAiAssist(allNodes)),
                ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final (op, label) in [
                    ('contains', isZh ? '包含文本' : 'Contains'),
                    ('notContains', isZh ? '不包含文本' : 'Not Contains'),
                    ('regex', isZh ? '正则匹配' : 'Regex'),
                    ('equals', isZh ? '完全等于' : 'Equals'),
                    ('exitZero', isZh ? '退出码 = 0' : 'Exit == 0'),
                  ])
                    _pillChoice(
                      label: label,
                      selected: _condOp == op,
                      accent: const Color(0xFFD97706),
                      fillColor: fieldFill,
                      borderColor: subtleBorder,
                      colors: colors,
                      onTap: isReadOnly
                          ? () {}
                          : () {
                              setState(() => _condOp = op);
                              _syncCondition();
                            },
                    ),
                ],
              ),
              if (_condOp != 'exitZero') ...[
                const SizedBox(height: 10),
                _studioField(
                  controller: _condValCtrl,
                  accent: const Color(0xFFD97706),
                  fillColor: fieldFill,
                  borderColor: subtleBorder,
                  colors: colors,
                  mono: true,
                  readOnly: isReadOnly,
                  placeholder: isZh
                      ? '匹配值（支持 {{input.xxx}} 变量）'
                      : 'Match value (supports {{input.xxx}})...',
                  onChanged: isReadOnly ? null : (_) => _syncCondition(),
                ),
              ],
            ],
          ),
        ),

      // Payload / Prompt / Script / Trigger KV Editor
      if (node.kind != CanvasNodeKind.condition)
        _editorialSection(
          index: nextIndex(),
          title: switch (node.kind) {
            CanvasNodeKind.trigger =>
              isZh ? '筛选条件与输入参数' : 'TRIGGER INPUTS',
            CanvasNodeKind.command => isZh ? 'Shell 执行脚本' : 'SHELL SCRIPT',
            CanvasNodeKind.agent => isZh ? 'Agent 执行提示词' : 'AGENT PROMPT',
            CanvasNodeKind.http => isZh ? 'JSON 请求体' : 'JSON BODY',
            CanvasNodeKind.approval =>
              isZh ? '审批引导与展示内容' : 'APPROVAL BRIEF',
            CanvasNodeKind.group => isZh ? '分组说明' : 'GROUP DESCRIPTION',
            _ => isZh ? '内容' : 'CONTENT',
          },
          accent: accent,
          colors: colors,
          hairline: hairline,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isReadOnly &&
                  node.kind != CanvasNodeKind.group &&
                  node.kind != CanvasNodeKind.trigger)
                _ghostAction(
                  label: isZh ? '✨ AI 帮写' : '✨ AI Assist',
                  accent: const Color(0xFF8B5CF6),
                  onTap: () => unawaited(_openAiAssist(allNodes)),
                ),
              if (node.kind == CanvasNodeKind.trigger)
                _ghostAction(
                  label: _triggerRawMode
                      ? (isZh ? '键值视图' : 'KV View')
                      : (isZh ? '源码模式' : 'Raw'),
                  accent: accent,
                  onTap: () =>
                      setState(() => _triggerRawMode = !_triggerRawMode),
                ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (node.kind == CanvasNodeKind.trigger && !_triggerRawMode)
                _buildTriggerKvEditor(
                  accent: accent,
                  fillColor: fieldFill,
                  borderColor: subtleBorder,
                  colors: colors,
                  readOnly: isReadOnly,
                )
              else
                _studioField(
                  controller: _contentCtrl,
                  accent: accent,
                  fillColor: isCodeContent ? codeFill : fieldFill,
                  borderColor: subtleBorder,
                  colors: colors,
                  mono: isCodeContent,
                  accentRail: isCodeContent,
                  fontSize: isCodeContent ? 11.5 : 12.2,
                  lineHeight: 1.55,
                  minLines: isCodeContent ? 6 : 5,
                  maxLines: isCodeContent ? 15 : 12,
                  readOnly: isReadOnly,
                  onChanged: isReadOnly
                      ? null
                      : (v) => ctrl.updateNode(node.id, content: v),
                ),
              if (node.kind.isExecutable &&
                  node.kind != CanvasNodeKind.trigger &&
                  !isReadOnly) ...[
                const SizedBox(height: 11),
                Row(
                  children: [
                    Icon(
                      Codicons.symbolVariable,
                      size: 11,
                      color: colors['descriptionForeground'].withValues(
                        alpha: 0.78,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      isZh
                          ? '插入上下文变量（支持 ?? 默认值 与 | shell / json）'
                          : 'Insert variable (supports ?? fallback & | shell/json)',
                      style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 0.15,
                        color: colors['descriptionForeground'].withValues(
                          alpha: 0.82,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final chip in _dynamicVarChips(allNodes, isZh))
                      Tooltip(
                        message: chip.token,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(5),
                          onTap: () => _insertVar(chip.token),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: fieldFill,
                              borderRadius: BorderRadius.circular(5),
                              border: Border.all(color: subtleBorder),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 5,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    color: chip.tone,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 5.5),
                                Text(
                                  chip.label,
                                  style: TextStyle(
                                    fontSize: 10.8,
                                    fontWeight: FontWeight.w500,
                                    color: colors['foreground'],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),

      // Execution Policy: Timeout, Automatic Retries & Failure Recovery Flag
      if (node.kind.isExecutable && node.kind != CanvasNodeKind.trigger)
        _editorialSection(
          index: nextIndex(),
          title: isZh ? '执行策略与容错' : 'EXECUTION POLICY',
          accent: const Color(0xFF0891B2),
          colors: colors,
          hairline: hairline,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _subLabel(
                isZh
                    ? '单步超时时间（当前 ${node.timeoutSeconds <= 0 ? "不限时" : "${node.timeoutSeconds}s"}）'
                    : 'Timeout (${node.timeoutSeconds <= 0 ? "No limit" : "${node.timeoutSeconds}s"})',
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final sec in (node.kind == CanvasNodeKind.approval
                      ? const [0, 300, 600, 1800, 3600]
                      : const [60, 180, 300, 600, 1800]))
                    _pillChoice(
                      label: sec <= 0
                          ? (isZh ? '不限时' : '∞')
                          : (sec >= 60 ? '${sec ~/ 60}m' : '${sec}s'),
                      selected: node.timeoutSeconds == sec,
                      accent: const Color(0xFF0891B2),
                      fillColor: fieldFill,
                      borderColor: subtleBorder,
                      colors: colors,
                      mono: sec > 0,
                      onTap: isReadOnly
                          ? () {}
                          : () => ctrl.updateNode(
                              node.id,
                              timeoutSeconds: sec,
                            ),
                    ),
                ],
              ),
              const SizedBox(height: 11),
              _subLabel(
                isZh ? '失败自动重试次数' : 'Auto Retries on Failure',
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in const [0, 1, 2, 3])
                    _pillChoice(
                      label: r == 0
                          ? (isZh ? '不重试' : 'Off')
                          : (isZh ? '重试 $r 次' : '${r}x'),
                      selected: node.maxRetries == r,
                      accent: const Color(0xFFD97706),
                      fillColor: fieldFill,
                      borderColor: subtleBorder,
                      colors: colors,
                      onTap: isReadOnly
                          ? () {}
                          : () => ctrl.updateNode(node.id, maxRetries: r),
                    ),
                ],
              ),
              if (node.maxRetries > 0) ...[
                const SizedBox(height: 9),
                _subLabel(
                  isZh
                      ? '重试退避间隔（当前 ${node.retryDelaySeconds}s）'
                      : 'Retry Backoff (${node.retryDelaySeconds}s)',
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final d in const [1, 2, 5, 10, 30])
                      _pillChoice(
                        label: '${d}s',
                        selected: node.retryDelaySeconds == d,
                        accent: const Color(0xFFD97706),
                        fillColor: fieldFill,
                        borderColor: subtleBorder,
                        colors: colors,
                        mono: true,
                        onTap: isReadOnly
                            ? () {}
                            : () => ctrl.updateNode(
                                node.id,
                                retryDelaySeconds: d,
                              ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 11),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: isReadOnly
                    ? null
                    : () => ctrl.updateNode(
                        node.id,
                        recoversFailure: !node.recoversFailure,
                      ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: Checkbox(
                          value: node.recoversFailure,
                          onChanged: isReadOnly
                              ? null
                              : (v) => ctrl.updateNode(
                                  node.id,
                                  recoversFailure: v ?? false,
                                ),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isZh
                                  ? '作为失败恢复节点（成功后将工作流标记为通过）'
                                  : 'Marks workflow recovered when run via onFail',
                              style: TextStyle(
                                fontSize: 11.2,
                                fontWeight: FontWeight.w500,
                                color: colors['foreground'],
                              ),
                            ),
                            Text(
                              isZh
                                  ? '关闭时：诊断/告警等 onFail 节点执行完毕仍保留整条流程的失败状态'
                                  : 'When off, diagnostic/alert fail handlers preserve failure status.',
                              style: TextStyle(
                                fontSize: 10.2,
                                color: colors['descriptionForeground'],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

      // Downstream Branch Routing
      if (node.kind.isExecutable)
        _editorialSection(
          index: nextIndex(),
          title: isZh
              ? '下游分支连线 (${outgoing.length})'
              : 'DOWNSTREAM (${outgoing.length})',
          accent: const Color(0xFF16A34A),
          colors: colors,
          hairline: hairline,
          trailing: isReadOnly || otherTargets.isEmpty
              ? null
              : PopupMenuButton<(String, CanvasEdgeBranch)>(
                  color: dark ? const Color(0xFF1F2228) : Colors.white,
                  surfaceTintColor: Colors.transparent,
                  elevation: 10,
                  constraints: const BoxConstraints(
                    minWidth: 230,
                    maxWidth: 320,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: hairline),
                  ),
                  onSelected: (pair) =>
                      ctrl.connect(node.id, pair.$1, branch: pair.$2),
                  itemBuilder: (_) => [
                    for (final t in otherTargets) ...[
                      PopupMenuItem(
                        value: (t.id, CanvasEdgeBranch.onPass),
                        height: 32,
                        child: Text(
                          '✓ 通过 → ${t.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: Color(0xFF16A34A),
                          ),
                        ),
                      ),
                      if (node.kind != CanvasNodeKind.trigger)
                        PopupMenuItem(
                          value: (t.id, CanvasEdgeBranch.onFail),
                          height: 32,
                          child: Text(
                            '✗ 失败 → ${t.title}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFFEF4444),
                            ),
                          ),
                        ),
                    ],
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Codicons.add,
                          size: 10.5,
                          color: Color(0xFF16A34A),
                        ),
                        const SizedBox(width: 3),
                        Text(
                          isZh ? '添加连线' : 'Connect',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF16A34A),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
          child: outgoing.isEmpty
              ? Text(
                  isZh
                      ? '暂无下游节点，点击右侧「+ 添加连线」或拖动卡片右侧端口连接。'
                      : 'No downstream edges yet.',
                  style: TextStyle(
                    fontSize: 11.2,
                    height: 1.5,
                    color: colors['descriptionForeground'],
                  ),
                )
              : Column(
                  children: [
                    for (var i = 0; i < outgoing.length; i++) ...[
                      if (i > 0)
                        Container(
                          height: 1,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          color: hairline,
                        ),
                      _buildEdgeRow(
                        ctrl: ctrl,
                        edge: outgoing[i],
                        isZh: isZh,
                        colors: colors,
                      ),
                    ],
                  ],
                ),
        ),
    ];

    return SizedBox(
      width: widget.width,
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              color: panelBg,
              border: Border(left: BorderSide(color: borderLine)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.22 : 0.035),
                  blurRadius: 18,
                  offset: const Offset(-4, 0),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Delicate 2px accent horizon bar at the top edge
                Container(
                  height: 2,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        accent.withValues(alpha: dark ? 0.78 : 0.65),
                        accent.withValues(alpha: 0.08),
                      ],
                    ),
                  ),
                ),

                // 1. Minimal Editorial Header + Flush Underline Tabs
                Container(
                  padding: const EdgeInsets.fromLTRB(18, 14, 12, 0),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: hairline)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Container(
                            width: 28,
                            height: 28,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: accent.withValues(
                                alpha: dark ? 0.18 : 0.10,
                              ),
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Icon(
                              _kindIcon(node.kind),
                              size: 14.5,
                              color: accent,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  node.title.isEmpty
                                      ? node.kind.label(isZh)
                                      : node.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: -0.1,
                                    color: colors['foreground'],
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    Text(
                                      node.kind.label(isZh),
                                      style: TextStyle(
                                        fontSize: 10.8,
                                        fontWeight: FontWeight.w500,
                                        color: accent,
                                      ),
                                    ),
                                    if (node.kind.isExecutable) ...[
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                        ),
                                        child: Text(
                                          '·',
                                          style: TextStyle(
                                            fontSize: 10.8,
                                            color:
                                                colors['descriptionForeground'],
                                          ),
                                        ),
                                      ),
                                      Container(
                                        width: 6,
                                        height: 6,
                                        decoration: BoxDecoration(
                                          color: statusTone,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 4.5),
                                      Text(
                                        () {
                                          final lbl = node.runStatus.label(
                                            isZh,
                                          );
                                          final d = node.runDuration;
                                          if (d != null &&
                                              node.runStatus !=
                                                  CanvasNodeRunStatus.idle &&
                                              node.runStatus !=
                                                  CanvasNodeRunStatus.queued) {
                                            return '$lbl · ${_formatElapsed(d)}';
                                          }
                                          return lbl;
                                        }(),
                                        style: TextStyle(
                                          fontSize: 10.8,
                                          color:
                                              colors['descriptionForeground'],
                                          fontFeatures: const [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                          InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: widget.onClose,
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Icon(
                                Codicons.close,
                                size: 13.5,
                                color: colors['descriptionForeground'],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // Flush Architectural Underline Tabs
                      Row(
                        children: [
                          _underlineTab(
                            label: isZh ? '节点配置' : 'Configure',
                            icon: Codicons.settingsGear,
                            selected: _tabIndex == 0,
                            accent: accent,
                            colors: colors,
                            onTap: () => setState(() => _tabIndex = 0),
                          ),
                          const SizedBox(width: 20),
                          _underlineTab(
                            label: isZh ? '运行输出' : 'Output',
                            icon: Codicons.terminal,
                            selected: _tabIndex == 1,
                            accent: accent,
                            dotColor: hasRunActivity ? statusTone : null,
                            colors: colors,
                            onTap: () => setState(() => _tabIndex = 1),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Optional slim read-only snapshot bar when inspecting a WorkflowRun
                if (isReadOnly)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2563EB).withValues(
                        alpha: dark ? 0.12 : 0.06,
                      ),
                      border: Border(bottom: BorderSide(color: hairline)),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Codicons.eye,
                          size: 12,
                          color: Color(0xFF2563EB),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            isZh
                                ? '正在查看运行实例 #${run.id}（只读快照）'
                                : 'Inspecting Run #${run.id} (Read-only)',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: colors['foreground'],
                            ),
                          ),
                        ),
                        if (widget.onSwitchToEdit != null)
                          _ghostAction(
                            label: isZh ? '切回编辑画布' : 'Edit Canvas',
                            accent: const Color(0xFF2563EB),
                            onTap: widget.onSwitchToEdit!,
                          ),
                      ],
                    ),
                  ),

                // 2. Tab Body
                Expanded(
                  child: _tabIndex == 1
                      ? _buildOutputTab(
                          node: node,
                          isZh: isZh,
                          dark: dark,
                          colors: colors,
                          statusTone: statusTone,
                          hairline: hairline,
                        )
                      : SingleChildScrollView(
                          padding: const EdgeInsets.only(bottom: 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Full-bleed Left-Rail Active Approval Banner
                              if (node.kind == CanvasNodeKind.approval &&
                                  node.runStatus ==
                                      CanvasNodeRunStatus.waitingApproval)
                                Container(
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    14,
                                    18,
                                    16,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFD97706).withValues(
                                      alpha: dark ? 0.11 : 0.06,
                                    ),
                                    border: Border(
                                      left: const BorderSide(
                                        color: Color(0xFFD97706),
                                        width: 3,
                                      ),
                                      bottom: BorderSide(color: hairline),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(
                                            Codicons.shield,
                                            size: 13.5,
                                            color: Color(0xFFD97706),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            isZh
                                                ? '当前暂停，等待您的决策'
                                                : 'Awaiting Decision',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color: colors['foreground'],
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 9),
                                      _studioField(
                                        controller: _approvalInputCtrl,
                                        accent: const Color(0xFFD97706),
                                        fillColor: dark
                                            ? const Color(0xFF1D2027)
                                            : Colors.white,
                                        borderColor: subtleBorder,
                                        colors: colors,
                                        minLines: 2,
                                        maxLines: 3,
                                        placeholder: isZh
                                            ? '填写决策意见（传入 {{approval.note}}）…'
                                            : 'Decision note for {{approval.note}}...',
                                      ),
                                      const SizedBox(height: 9),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: IdeButton(
                                              label: isZh ? '通过放行' : 'Approve',
                                              icon: Codicons.check,
                                              onPressed: () {
                                                final note = _approvalInputCtrl
                                                    .text
                                                    .trim();
                                                _approvalInputCtrl.clear();
                                                ctrl.approveNode(
                                                  node.id,
                                                  note: note,
                                                  runId: run?.id,
                                                );
                                              },
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: IdeButton(
                                              label: isZh ? '驳回' : 'Reject',
                                              icon: Codicons.close,
                                              secondary: true,
                                              onPressed: () {
                                                final note = _approvalInputCtrl
                                                    .text
                                                    .trim();
                                                _approvalInputCtrl.clear();
                                                ctrl.rejectNode(
                                                  node.id,
                                                  note: note,
                                                  runId: run?.id,
                                                );
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              // Read-only snapshots remain selectable & copyable via readOnly fields!
                              if (isReadOnly)
                                Opacity(
                                  opacity: 0.92,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: sections,
                                  ),
                                )
                              else
                                ...sections,
                            ],
                          ),
                        ),
                ),

                // 3. Streamlined Responsive Sticky Footer Bar
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: panelBg,
                    border: Border(top: BorderSide(color: hairline)),
                  ),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (!isReadOnly) ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Tooltip(
                              message: isZh ? '复制节点' : 'Duplicate node',
                              child: InkWell(
                                borderRadius: BorderRadius.circular(6),
                                onTap: widget.onDuplicate,
                                child: Padding(
                                  padding: const EdgeInsets.all(6),
                                  child: Icon(
                                    Codicons.copy,
                                    size: 13.5,
                                    color: colors['descriptionForeground'],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 2),
                            Tooltip(
                              message: isZh ? '删除节点' : 'Delete node',
                              child: InkWell(
                                borderRadius: BorderRadius.circular(6),
                                onTap: widget.onDelete,
                                child: const Padding(
                                  padding: EdgeInsets.all(6),
                                  child: Icon(
                                    Codicons.trash,
                                    size: 13.5,
                                    color: Color(0xFFEF4444),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            if (widget.onResumeFromNode != null)
                              IdeButton(
                                label: isZh ? '从此节点运行' : 'Run Here',
                                icon: Codicons.debugContinue,
                                secondary: true,
                                onPressed: node.running
                                    ? null
                                    : widget.onResumeFromNode,
                              ),
                            if (node.kind == CanvasNodeKind.command ||
                                node.kind == CanvasNodeKind.agent ||
                                node.kind == CanvasNodeKind.http)
                              IdeButton(
                                label: node.running
                                    ? (isZh ? '执行中…' : 'Running...')
                                    : (isZh ? '单步试跑' : 'Test Step'),
                                icon: Codicons.play,
                                onPressed: node.running
                                    ? null
                                    : () {
                                        setState(() => _tabIndex = 1);
                                        widget.onTestRun();
                                      },
                              )
                            else
                              IdeButton(
                                label: isZh ? '完成' : 'Done',
                                secondary: true,
                                onPressed: widget.onClose,
                              ),
                          ],
                        ),
                      ] else ...[
                        if (widget.onSwitchToEdit != null)
                          IdeButton(
                            label: isZh ? '切回编辑' : 'Edit',
                            icon: Codicons.edit,
                            secondary: true,
                            onPressed: widget.onSwitchToEdit,
                          ),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            if (widget.onResumeFromNode != null)
                              IdeButton(
                                label: isZh ? '从本节点续跑' : 'Resume Here',
                                icon: Codicons.debugContinue,
                                onPressed: widget.onResumeFromNode,
                              ),
                            IdeButton(
                              label: isZh ? '关闭' : 'Close',
                              secondary: true,
                              onPressed: widget.onClose,
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Left-edge drag handle for effortless width adjustment
          if (widget.onResizeWidth != null)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 6,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeLeftRight,
                onEnter: (_) => setState(() => _resizingHover = true),
                onExit: (_) => setState(() => _resizingHover = false),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragStart: (_) =>
                      setState(() => _resizingActive = true),
                  onHorizontalDragEnd: (_) =>
                      setState(() => _resizingActive = false),
                  onHorizontalDragCancel: () =>
                      setState(() => _resizingActive = false),
                  onHorizontalDragUpdate: (d) =>
                      widget.onResizeWidth?.call(d.delta.dx),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTriggerKvEditor({
    required Color accent,
    required Color fillColor,
    required Color borderColor,
    required dynamic colors,
    bool readOnly = false,
  }) {
    final pairs = CanvasController.parseKeyValueLines(_contentCtrl.text);
    if (pairs.isEmpty) {
      return _studioField(
        controller: _contentCtrl,
        accent: accent,
        fillColor: fillColor,
        borderColor: borderColor,
        colors: colors,
        mono: true,
        minLines: 4,
        maxLines: 10,
        readOnly: readOnly,
        onChanged: readOnly
            ? null
            : (v) => CanvasController.instance.updateNode(
                widget.node.id,
                content: v,
              ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in pairs.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.key,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    fontFamily: AppFonts.mono,
                    color: accent.withValues(alpha: 0.9),
                  ),
                ),
                const SizedBox(height: 4),
                TextFormField(
                  key: ValueKey(
                    'kv-${widget.node.id}-${entry.key}-${entry.value}',
                  ),
                  initialValue: entry.value,
                  readOnly: readOnly,
                  onChanged: readOnly
                      ? null
                      : (v) => _updateTriggerKey(entry.key, v),
                  style: TextStyle(
                    fontSize: 11.8,
                    fontFamily: AppFonts.mono,
                    color: colors['foreground'] as Color,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    filled: true,
                    fillColor: fillColor,
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(color: borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(color: accent, width: 1.2),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildEdgeRow({
    required CanvasController ctrl,
    required CanvasEdge edge,
    required bool isZh,
    required dynamic colors,
  }) {
    final target = widget.run?.nodeById(edge.toId) ?? ctrl.nodeById(edge.toId);
    final bColor = _branchColor(edge.branch);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => widget.onSelectNode(edge.toId),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: bColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                edge.branch.label(isZh),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: bColor,
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (target != null) ...[
              Icon(
                _kindIcon(target.kind),
                size: 12.5,
                color: Color(target.colorValue),
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                target?.title ?? edge.toId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: colors['foreground'] as Color,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Codicons.chevronRight,
              size: 12,
              color: (colors['descriptionForeground'] as Color).withValues(
                alpha: 0.7,
              ),
            ),
            if (widget.run == null) ...[
              const SizedBox(width: 2),
              InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () => ctrl.removeEdge(edge.id),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Codicons.close,
                    size: 11.5,
                    color: (colors['descriptionForeground'] as Color)
                        .withValues(alpha: 0.75),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildOutputTab({
    required CanvasNode node,
    required bool isZh,
    required bool dark,
    required dynamic colors,
    required Color statusTone,
    required Color hairline,
  }) {
    final dur = node.runDuration;
    final evidencePaths = CanvasController.extractEvidencePaths(node.output);
    final evDir = CanvasController.resolveEvidenceDirFromNodes(
      widget.run?.nodes ?? CanvasController.instance.nodes,
      capturedVars: widget.run?.capturedVars ?? const {},
    );
    final hasExistingEvDir =
        evDir != null &&
        _CanvasFsCache.existsCached(evDir, () {
              if (mounted) setState(() {});
            }) ==
            true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Flat Editorial Status Strip (no card wrapper)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: hairline)),
          ),
          child: Row(
            children: [
              if (node.runStatus == CanvasNodeRunStatus.running)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: statusTone,
                  ),
                )
              else
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: statusTone,
                    shape: BoxShape.circle,
                  ),
                ),
              const SizedBox(width: 8),
              Text(
                node.runStatus.label(isZh),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: statusTone,
                ),
              ),
              if (dur != null &&
                  node.runStatus != CanvasNodeRunStatus.idle &&
                  node.runStatus != CanvasNodeRunStatus.queued) ...[
                const SizedBox(width: 8),
                Text(
                  _formatElapsed(dur),
                  style: TextStyle(
                    fontSize: 11,
                    color: colors['descriptionForeground'] as Color,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
              if (node.exitCode != null) ...[
                const SizedBox(width: 8),
                Text(
                  'exit ${node.exitCode}',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontFamily: AppFonts.mono,
                    fontWeight: FontWeight.w600,
                    color: statusTone.withValues(alpha: 0.9),
                  ),
                ),
              ],
              const Spacer(),
              if (node.output.isNotEmpty)
                Tooltip(
                  message: isZh ? '复制输出' : 'Copy output',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(5),
                    onTap: () => unawaited(
                      Clipboard.setData(ClipboardData(text: node.output)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Codicons.copy,
                        size: 13,
                        color: colors['descriptionForeground'] as Color,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        // Evidence & Media Quick-Access Strip (screenshots, videos, trace.md, git.diff)
        if (evidencePaths.isNotEmpty || hasExistingEvDir)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 9),
            decoration: BoxDecoration(
              color: (dark ? Colors.white : Colors.black).withValues(
                alpha: dark ? 0.03 : 0.02,
              ),
              border: Border(bottom: BorderSide(color: hairline)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Codicons.fileMedia,
                      size: 11.5,
                      color: const Color(0xFF16A34A),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      isZh ? '留证与媒体快捷回看' : 'Evidence & Media',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: colors['descriptionForeground'] as Color,
                      ),
                    ),
                    const Spacer(),
                    if (hasExistingEvDir)
                      InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => unawaited(_openPathInOs(evDir)),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Codicons.folderOpened,
                                size: 11,
                                color: Color(0xFF2563EB),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                isZh ? '打开留证目录' : 'Open Folder',
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF2563EB),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                if (evidencePaths.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final fp in evidencePaths.take(10))
                        _buildEvidenceChip(
                          path: fp,
                          dark: dark,
                          colors: colors,
                          hairline: hairline,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        // Full-bleed Terminal Output Viewport
        Expanded(
          child: node.output.isEmpty && !node.running
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Codicons.terminal,
                          size: 22,
                          color: (colors['descriptionForeground'] as Color)
                              .withValues(alpha: 0.45),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          isZh ? '尚未产生运行输出' : 'No Output Yet',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: colors['foreground'] as Color,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          isZh
                              ? '运行整条工作流或点击下方「单步试跑」，此处将实时呈现该节点的流式输出。'
                              : 'Run the workflow or test this step to inspect live output here.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11.2,
                            height: 1.55,
                            color: colors['descriptionForeground'] as Color,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : Container(
                  color: dark
                      ? const Color(0xFF12151B)
                      : const Color(0xFF161A22),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      node.output.isEmpty
                          ? (isZh ? '正在启动进程，等待实时输出…' : 'Starting process...')
                          : node.output,
                      style: TextStyle(
                        fontSize: 11.4,
                        height: 1.55,
                        fontFamily: AppFonts.mono,
                        color: const Color(0xFFE5E7EB),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildEvidenceChip({
    required String path,
    required bool dark,
    required dynamic colors,
    required Color hairline,
  }) {
    final lower = path.toLowerCase();
    final exists =
        _CanvasFsCache.existsCached(path, () {
          if (mounted) setState(() {});
        }) ==
        true;
    final baseName = p.basename(path);
    final IconData icon;
    final Color tone;
    if (lower.endsWith('.webm') ||
        lower.endsWith('.mp4') ||
        lower.endsWith('.mov')) {
      icon = Codicons.playCircle;
      tone = const Color(0xFF8B5CF6);
    } else if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif')) {
      icon = Codicons.fileMedia;
      tone = const Color(0xFF16A34A);
    } else if (lower.endsWith('.diff')) {
      icon = Codicons.diff;
      tone = const Color(0xFFD97706);
    } else {
      icon = Codicons.markdown;
      tone = const Color(0xFF2563EB);
    }
    return Tooltip(
      message: exists ? path : '$path (文件不存在)',
      child: Container(
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF21252E) : Colors.white,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: exists ? tone.withValues(alpha: 0.4) : hairline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(5),
              ),
              onTap: exists
                  ? () => unawaited(_openPathInOs(path))
                  : () =>
                        unawaited(Clipboard.setData(ClipboardData(text: path))),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(7, 4, 5, 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      icon,
                      size: 11.5,
                      color: exists
                          ? tone
                          : (colors['descriptionForeground'] as Color),
                    ),
                    const SizedBox(width: 5),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 160),
                      child: Text(
                        baseName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontFamily: AppFonts.mono,
                          fontWeight: FontWeight.w500,
                          color: exists
                              ? colors['foreground'] as Color
                              : (colors['descriptionForeground'] as Color),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (exists)
              InkWell(
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(5),
                ),
                onTap: () => unawaited(_openPathInOs(path, reveal: true)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(3, 4, 6, 4),
                  child: Icon(
                    Codicons.folderOpened,
                    size: 10.5,
                    color: colors['descriptionForeground'] as Color,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _underlineTab({
    required String label,
    required IconData icon,
    required bool selected,
    required Color accent,
    required dynamic colors,
    Color? dotColor,
    required VoidCallback onTap,
  }) => InkWell(
    borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.only(bottom: 9, top: 2),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: selected ? accent : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 12,
            color: selected
                ? colors['foreground'] as Color
                : (colors['descriptionForeground'] as Color).withValues(
                    alpha: 0.78,
                  ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.8,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected
                  ? colors['foreground'] as Color
                  : colors['descriptionForeground'] as Color,
            ),
          ),
          if (dotColor != null) ...[
            const SizedBox(width: 5.5),
            Container(
              width: 5.5,
              height: 5.5,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    ),
  );

  /// Card-free editorial section block: Swiss numeric eyebrow + hairline rule.
  Widget _editorialSection({
    required String index,
    required String title,
    required Color accent,
    required Color hairline,
    required dynamic colors,
    bool showTopDivider = true,
    Widget? trailing,
    required Widget child,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (showTopDivider)
        Container(
          height: 1,
          margin: const EdgeInsets.symmetric(horizontal: 18),
          color: hairline,
        ),
      Padding(
        padding: EdgeInsets.fromLTRB(18, showTopDivider ? 16 : 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  index,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    fontFamily: AppFonts.mono,
                    letterSpacing: 0.4,
                    color: accent.withValues(alpha: 0.8),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Container(
                  width: 1,
                  height: 9,
                  margin: const EdgeInsets.symmetric(horizontal: 7),
                  color: hairline,
                ),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                      color: colors['foreground'] as Color,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 11),
            child,
          ],
        ),
      ),
    ],
  );

  Widget _studioField({
    required TextEditingController controller,
    required Color accent,
    required Color fillColor,
    required Color borderColor,
    required dynamic colors,
    String? placeholder,
    bool mono = false,
    bool accentRail = false,
    bool readOnly = false,
    double fontSize = 12.2,
    double lineHeight = 1.45,
    int minLines = 1,
    int maxLines = 1,
    ValueChanged<String>? onChanged,
  }) {
    final field = TextField(
      controller: controller,
      readOnly: readOnly,
      minLines: minLines,
      maxLines: maxLines,
      onChanged: onChanged,
      style: TextStyle(
        fontSize: fontSize,
        height: lineHeight,
        fontFamily: mono ? AppFonts.mono : null,
        color: colors['foreground'] as Color,
      ),
      decoration: InputDecoration(
        isDense: true,
        hintText: placeholder,
        hintStyle: TextStyle(
          fontSize: fontSize,
          fontFamily: mono ? AppFonts.mono : null,
          color: (colors['descriptionForeground'] as Color).withValues(
            alpha: 0.55,
          ),
        ),
        contentPadding: EdgeInsets.symmetric(
          horizontal: accentRail ? 12 : 10,
          vertical: minLines > 1 ? 10 : 8.5,
        ),
        filled: true,
        fillColor: fillColor,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(accentRail ? 6 : 6),
          borderSide: BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(accentRail ? 6 : 6),
          borderSide: BorderSide(color: accent, width: 1.2),
        ),
      ),
    );
    if (!accentRail) return field;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Stack(
        children: [
          field,
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 2.5,
            child: IgnorePointer(
              child: Container(color: accent.withValues(alpha: 0.65)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pillChoice({
    required String label,
    required bool selected,
    required Color accent,
    required Color fillColor,
    required Color borderColor,
    required dynamic colors,
    bool mono = false,
    required VoidCallback onTap,
  }) => InkWell(
    borderRadius: BorderRadius.circular(5),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
      decoration: BoxDecoration(
        color: selected ? accent.withValues(alpha: 0.13) : fillColor,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: selected ? accent.withValues(alpha: 0.7) : borderColor,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontFamily: mono ? AppFonts.mono : null,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? accent : colors['foreground'] as Color,
        ),
      ),
    ),
  );

  Widget _ghostAction({
    required String label,
    required Color accent,
    required VoidCallback onTap,
  }) => InkWell(
    borderRadius: BorderRadius.circular(5),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: accent,
        ),
      ),
    ),
  );

  Widget _subLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10.8,
        fontWeight: FontWeight.w500,
        color: themeColors['descriptionForeground'].withValues(alpha: 0.88),
      ),
    ),
  );
}

/// Per-node Agent Kernel / Model / Reasoning Effort selector in the Inspector.
class _AgentModelSelectorSection extends StatelessWidget {
  const _AgentModelSelectorSection({
    required this.ctrl,
    this.run,
    required this.node,
    required this.agents,
    required this.isZh,
  });

  final CanvasController ctrl;
  final WorkflowRun? run;
  final CanvasNode node;
  final List<AcpAgentProfile> agents;
  final bool isZh;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final dark = colors.dark;
    final cfg = ctrl.effectiveAgentConfig(node, run: run);
    final models = AcpAgentService.instance.modelsForAgent(cfg.agentId);
    final selectedModelObj = models
        .where((m) => m.id == cfg.model)
        .firstOrNull;
    final effortChoices =
        selectedModelObj != null && selectedModelObj.effortLevels.isNotEmpty
        ? selectedModelObj.effortLevels
        : const ['low', 'medium', 'high', 'xhigh'];
    final menuBg = dark ? const Color(0xFF1F2228) : Colors.white;
    final menuBorder = dark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.09);
    final fieldFill = dark ? const Color(0xFF21252E) : const Color(0xFFF5F6F8);
    final subtleBorder = dark
        ? Colors.white.withValues(alpha: 0.055)
        : Colors.black.withValues(alpha: 0.05);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              isZh ? '执行内核（覆盖全局默认）' : 'Native Kernel',
              style: TextStyle(
                fontSize: 10.8,
                fontWeight: FontWeight.w500,
                color: colors['descriptionForeground'],
              ),
            ),
            const Spacer(),
            if (cfg.inheritedAgent)
              Text(
                isZh ? '跟随全局 · ${cfg.agentId}' : 'Inherits · ${cfg.agentId}',
                style: TextStyle(
                  fontSize: 10,
                  fontFamily: AppFonts.mono,
                  color: colors['descriptionForeground'],
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _selectableChip(
              label: isZh ? '跟随工作流默认' : 'Inherit Default',
              selected: node.agentId.isEmpty,
              accent: const Color(0xFF2563EB),
              fillColor: fieldFill,
              borderColor: subtleBorder,
              colors: colors,
              onTap: () => ctrl.updateNode(
                node.id,
                agentId: '',
                model: '',
                effort: '',
              ),
            ),
            for (final a in agents)
              _selectableChip(
                label: a.name,
                selected: node.agentId == a.id,
                accent: const Color(0xFF2563EB),
                fillColor: fieldFill,
                borderColor: subtleBorder,
                colors: colors,
                onTap: () => ctrl.updateNode(
                  node.id,
                  agentId: a.id,
                  model: node.agentId == a.id ? node.model : '',
                  effort: node.agentId == a.id ? node.effort : '',
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          isZh ? '节点模型' : 'Model',
          style: TextStyle(
            fontSize: 10.8,
            fontWeight: FontWeight.w500,
            color: colors['descriptionForeground'],
          ),
        ),
        const SizedBox(height: 6),
        PopupMenuButton<String>(
          color: menuBg,
          surfaceTintColor: Colors.transparent,
          elevation: 10,
          constraints: const BoxConstraints(minWidth: 280, maxWidth: 340),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: menuBorder),
          ),
          onSelected: (val) => ctrl.updateNode(
            node.id,
            model: val == '__default__' ? '' : val,
            effort: '',
          ),
          itemBuilder: (_) => [
            PopupMenuItem(
              value: '__default__',
              height: 36,
              child: Text(
                isZh
                    ? (node.agentId.isEmpty && ctrl.defaultModel.isNotEmpty
                          ? '跟随工作流默认（${AcpAgentService.instance.modelLabel(ctrl.defaultAgentId, ctrl.defaultModel)}）'
                          : '使用内核默认模型')
                    : 'Use default model',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: node.model.isEmpty
                      ? FontWeight.w600
                      : FontWeight.w400,
                  color: colors['foreground'],
                ),
              ),
            ),
            const PopupMenuDivider(height: 8),
            for (final m in models)
              PopupMenuItem(
                value: m.id,
                height: 44,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      m.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: node.model == m.id
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: node.model == m.id
                            ? const Color(0xFF2563EB)
                            : colors['foreground'],
                      ),
                    ),
                    if (m.description.isNotEmpty)
                      Text(
                        m.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: colors['descriptionForeground'],
                        ),
                      ),
                  ],
                ),
              ),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: fieldFill,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: subtleBorder),
            ),
            child: Row(
              children: [
                const Icon(Codicons.hubot, size: 13, color: Color(0xFF2563EB)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    () {
                      if (node.model.isEmpty) {
                        if (cfg.model.isNotEmpty) {
                          return isZh
                              ? '跟随默认：${AcpAgentService.instance.modelLabel(cfg.agentId, cfg.model)}'
                              : 'Inherited: ${cfg.model}';
                        }
                        return isZh ? '内核默认模型' : 'Kernel Default';
                      }
                      return AcpAgentService.instance.modelLabel(
                        cfg.agentId,
                        node.model,
                      );
                    }(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: colors['foreground'],
                    ),
                  ),
                ),
                Icon(
                  Codicons.chevronDown,
                  size: 12,
                  color: colors['descriptionForeground'],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          isZh ? '思考强度（Effort）' : 'Reasoning Effort',
          style: TextStyle(
            fontSize: 10.8,
            fontWeight: FontWeight.w500,
            color: colors['descriptionForeground'],
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _selectableChip(
              label: isZh ? '默认' : 'Default',
              selected: node.effort.isEmpty,
              accent: const Color(0xFF7C3AED),
              fillColor: fieldFill,
              borderColor: subtleBorder,
              colors: colors,
              onTap: () => ctrl.updateNode(node.id, effort: ''),
            ),
            for (final e in effortChoices)
              _selectableChip(
                label: e,
                selected: node.effort == e,
                accent: const Color(0xFF7C3AED),
                fillColor: fieldFill,
                borderColor: subtleBorder,
                colors: colors,
                onTap: () => ctrl.updateNode(node.id, effort: e),
              ),
          ],
        ),
      ],
    );
  }

  Widget _selectableChip({
    required String label,
    required bool selected,
    required Color accent,
    required Color fillColor,
    required Color borderColor,
    required dynamic colors,
    required VoidCallback onTap,
  }) => InkWell(
    borderRadius: BorderRadius.circular(5),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
      decoration: BoxDecoration(
        color: selected ? accent.withValues(alpha: 0.13) : fillColor,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: selected ? accent.withValues(alpha: 0.7) : borderColor,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? accent : colors['foreground'] as Color,
        ),
      ),
    ),
  );
}

/// Unified Dialog for configuring the Workflow's Default Kernel/Model/Effort
/// AND viewing/overriding every Agent node's model on the canvas in one place.
class _WorkflowModelConfigDialog extends StatefulWidget {
  const _WorkflowModelConfigDialog({
    required this.ctrl,
    required this.isZh,
    required this.onSelectNode,
  });

  final CanvasController ctrl;
  final bool isZh;
  final ValueChanged<String> onSelectNode;

  @override
  State<_WorkflowModelConfigDialog> createState() =>
      _WorkflowModelConfigDialogState();
}

class _WorkflowModelConfigDialogState
    extends State<_WorkflowModelConfigDialog> {
  late final TextEditingController _customModelCtrl = TextEditingController(
    text: widget.ctrl.defaultModel,
  );

  @override
  void dispose() {
    _customModelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isZh = widget.isZh;
    final colors = themeColors;
    final dark = colors.dark;
    final surface = dark ? const Color(0xFF1D2027) : Colors.white;
    final border = dark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.09);

    return ListenableBuilder(
      listenable: widget.ctrl,
      builder: (context, _) {
        final ctrl = widget.ctrl;
        final agents = AcpAgentService.instance.selectableAgents;
        final defaultModels = AcpAgentService.instance.modelsForAgent(
          ctrl.defaultAgentId,
        );
        final selectedDefaultModelObj = defaultModels
            .where((m) => m.id == ctrl.defaultModel)
            .firstOrNull;
        final effortChoices =
            selectedDefaultModelObj != null &&
                selectedDefaultModelObj.effortLevels.isNotEmpty
            ? selectedDefaultModelObj.effortLevels
            : const ['low', 'medium', 'high', 'xhigh'];
        final agentNodes = [
          for (final n in ctrl.nodes)
            if (n.kind == CanvasNodeKind.agent) n,
        ];

        return Dialog(
          backgroundColor: surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: border),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680, maxHeight: 620),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.fromLTRB(18, 14, 14, 12),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: border)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2563EB).withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: const Icon(
                          Codicons.hubot,
                          size: 15,
                          color: Color(0xFF2563EB),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isZh
                                  ? '工作流模型路由配置'
                                  : 'Workflow Model Routing',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: colors['foreground'],
                              ),
                            ),
                            Text(
                              isZh
                                  ? '先设置全局默认内核与模型，再按需为单个 Agent 节点单独指定模型（如：研判用轻量模型，修代码用强推理模型）'
                                  : 'Set workflow default kernel/model, and override per Agent node below.',
                              style: TextStyle(
                                fontSize: 11,
                                color: colors['descriptionForeground'],
                              ),
                            ),
                          ],
                        ),
                      ),
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => Navigator.of(context).pop(),
                        child: Padding(
                          padding: const EdgeInsets.all(5),
                          child: Icon(
                            Codicons.close,
                            size: 14,
                            color: colors['descriptionForeground'],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Content
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Section 1: Global Default
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: (dark ? Colors.white : Colors.black)
                                .withValues(alpha: dark ? 0.035 : 0.025),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: border),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    isZh
                                        ? '1. 工作流全局默认内核 & 模型'
                                        : '1. Workflow Default Kernel & Model',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                      color: colors['foreground'],
                                    ),
                                  ),
                                  const Spacer(),
                                  if (agentNodes.isNotEmpty)
                                    TextButton(
                                      onPressed:
                                          ctrl.applyWorkflowDefaultsToAllAgents,
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        minimumSize: Size.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      child: Text(
                                        isZh
                                            ? '全部节点重置为跟随默认'
                                            : 'Reset all nodes to default',
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final a in agents)
                                    _dialogChip(
                                      label: a.name,
                                      selected: ctrl.defaultAgentId == a.id,
                                      accent: const Color(0xFF2563EB),
                                      colors: colors,
                                      onTap: () {
                                        ctrl.setWorkflowDefaults(
                                          agentId: a.id,
                                          model: '',
                                          effort: '',
                                        );
                                        _customModelCtrl.text = '';
                                      },
                                    ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  _dialogChip(
                                    label: isZh ? '内核默认模型' : 'CLI Default',
                                    selected: ctrl.defaultModel.isEmpty,
                                    accent: const Color(0xFF16A34A),
                                    colors: colors,
                                    onTap: () {
                                      ctrl.setWorkflowDefaults(
                                        model: '',
                                        effort: '',
                                      );
                                      _customModelCtrl.text = '';
                                    },
                                  ),
                                  for (final m in defaultModels)
                                    _dialogChip(
                                      label: m.label,
                                      selected: ctrl.defaultModel == m.id,
                                      accent: const Color(0xFF16A34A),
                                      colors: colors,
                                      onTap: () {
                                        ctrl.setWorkflowDefaults(
                                          model: m.id,
                                          effort: '',
                                        );
                                        _customModelCtrl.text = m.id;
                                      },
                                    ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: IdeInputBox(
                                      controller: _customModelCtrl,
                                      placeholder: isZh
                                          ? '或直接输入自定义模型 ID（留空使用内核默认）'
                                          : 'Or enter custom model ID...',
                                      onChanged: (v) =>
                                          ctrl.setWorkflowDefaults(
                                            model: v.trim(),
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  for (final eff in ['', ...effortChoices])
                                    Padding(
                                      padding: const EdgeInsets.only(left: 4),
                                      child: _dialogChip(
                                        label: eff.isEmpty
                                            ? (isZh ? '默认强度' : 'Auto')
                                            : eff,
                                        selected: ctrl.defaultEffort == eff,
                                        accent: const Color(0xFF7C3AED),
                                        colors: colors,
                                        onTap: () => ctrl.setWorkflowDefaults(
                                          effort: eff,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 16),

                        // Section 2: Per-Node Agent Routing Table
                        Text(
                          isZh
                              ? '2. 当前画布各 Agent 节点模型分配（共 ${agentNodes.length} 个）'
                              : '2. Per-Node Agent Model Assignment (${agentNodes.length})',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: colors['foreground'],
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (agentNodes.isEmpty)
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(color: border),
                            ),
                            child: Text(
                              isZh
                                  ? '当前画布暂无 AI Agent 节点（纯 Shell / HTTP 流程无需模型）。'
                                  : 'No AI Agent nodes on the current canvas.',
                              style: TextStyle(
                                fontSize: 12,
                                color: colors['descriptionForeground'],
                              ),
                            ),
                          )
                        else
                          for (final node in agentNodes)
                            _buildNodeRoutingRow(
                              ctrl: ctrl,
                              node: node,
                              agents: agents,
                              colors: colors,
                              border: border,
                              dark: dark,
                              isZh: isZh,
                            ),
                      ],
                    ),
                  ),
                ),

                // Footer
                Container(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: border)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IdeButton(
                        label: isZh ? '完成' : 'Done',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildNodeRoutingRow({
    required CanvasController ctrl,
    required CanvasNode node,
    required List<AcpAgentProfile> agents,
    required dynamic colors,
    required Color border,
    required bool dark,
    required bool isZh,
  }) {
    final cfg = ctrl.effectiveAgentConfig(node);
    final models = AcpAgentService.instance.modelsForAgent(cfg.agentId);
    final menuBg = dark ? const Color(0xFF1F2228) : Colors.white;

    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: colors['editor.background'] as Color,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: InkWell(
              onTap: () {
                widget.onSelectNode(node.id);
                Navigator.of(context).pop();
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    node.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colors['foreground'] as Color,
                    ),
                  ),
                  Text(
                    cfg.inheritedAgent && cfg.inheritedModel
                        ? (isZh ? '跟随工作流全局默认' : 'Inherits workflow default')
                        : (isZh ? '已单独指定' : 'Custom override'),
                    style: TextStyle(
                      fontSize: 10,
                      color: cfg.inheritedAgent && cfg.inheritedModel
                          ? colors['descriptionForeground'] as Color
                          : const Color(0xFF2563EB),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Kernel Picker
          PopupMenuButton<String>(
            color: menuBg,
            surfaceTintColor: Colors.transparent,
            elevation: 8,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9),
              side: BorderSide(color: border),
            ),
            onSelected: (v) => ctrl.updateNode(
              node.id,
              agentId: v == '__inherit__' ? '' : v,
              model: '',
              effort: '',
            ),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: '__inherit__',
                height: 32,
                child: Text(
                  isZh
                      ? '跟随全局 (${ctrl.defaultAgentId})'
                      : 'Inherit (${ctrl.defaultAgentId})',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: colors['foreground'] as Color,
                  ),
                ),
              ),
              const PopupMenuDivider(height: 6),
              for (final a in agents)
                PopupMenuItem(
                  value: a.id,
                  height: 32,
                  child: Text(
                    a.name,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: colors['foreground'] as Color,
                    ),
                  ),
                ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF2563EB).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: const Color(0xFF2563EB).withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    node.agentId.isEmpty
                        ? (isZh ? '默认(${cfg.agentId})' : cfg.agentId)
                        : cfg.agentId,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF2563EB),
                    ),
                  ),
                  const SizedBox(width: 3),
                  const Icon(
                    Codicons.chevronDown,
                    size: 10,
                    color: Color(0xFF2563EB),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Model Picker
          PopupMenuButton<String>(
            color: menuBg,
            surfaceTintColor: Colors.transparent,
            elevation: 8,
            constraints: const BoxConstraints(minWidth: 240, maxWidth: 320),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9),
              side: BorderSide(color: border),
            ),
            onSelected: (v) => ctrl.updateNode(
              node.id,
              model: v == '__default__' ? '' : v,
            ),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: '__default__',
                height: 34,
                child: Text(
                  isZh ? '跟随默认模型' : 'Default model',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: colors['foreground'] as Color,
                  ),
                ),
              ),
              const PopupMenuDivider(height: 6),
              for (final m in models)
                PopupMenuItem(
                  value: m.id,
                  height: 38,
                  child: Text(
                    m.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: node.model == m.id
                          ? const Color(0xFF16A34A)
                          : colors['foreground'] as Color,
                      fontWeight: node.model == m.id
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
            ],
            child: Container(
              constraints: const BoxConstraints(minWidth: 130, maxWidth: 190),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: (dark ? Colors.white : Colors.black).withValues(
                  alpha: dark ? 0.05 : 0.035,
                ),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Expanded(
                    child: Text(
                      cfg.model.isEmpty
                          ? (isZh ? '内核默认模型' : 'CLI Default')
                          : AcpAgentService.instance.modelLabel(
                              cfg.agentId,
                              cfg.model,
                            ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors['foreground'] as Color,
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Icon(
                    Codicons.chevronDown,
                    size: 10,
                    color: colors['descriptionForeground'] as Color,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dialogChip({
    required String label,
    required bool selected,
    required Color accent,
    required dynamic colors,
    required VoidCallback onTap,
  }) => InkWell(
    borderRadius: BorderRadius.circular(6),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4.5),
      decoration: BoxDecoration(
        color: selected
            ? accent.withValues(alpha: 0.14)
            : colors['editor.background'] as Color,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: selected
              ? accent
              : (colors['widget.border'] as Color).withValues(alpha: 0.45),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? accent : colors['foreground'] as Color,
        ),
      ),
    ),
  );
}

class _WorkflowEdgesPainter extends CustomPainter {
  const _WorkflowEdgesPainter({
    required this.nodes,
    required this.edges,
    required this.selectedNodeIds,
    this.selectedEdgeId,
    required this.layoutVersion,
  });

  final List<CanvasNode> nodes;
  final List<CanvasEdge> edges;
  final Set<String> selectedNodeIds;
  final String? selectedEdgeId;
  final int layoutVersion;

  @override
  void paint(Canvas canvas, Size size) {
    final byId = {for (final n in nodes) n.id: n};
    final linePaint = Paint()
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final arrowPaint = Paint()..style = PaintingStyle.fill;

    for (final edge in edges) {
      final from = byId[edge.fromId];
      final to = byId[edge.toId];
      if (from == null || to == null) continue;

      final geom = _computeEdgeGeometry(from, to, edge.branch);
      final color = _branchColor(edge.branch);
      final isSelectedEdge = edge.id == selectedEdgeId;
      final isHot =
          isSelectedEdge ||
          (from.runStatus == CanvasNodeRunStatus.succeeded &&
              edge.branch == CanvasEdgeBranch.onPass) ||
          (from.runStatus == CanvasNodeRunStatus.failed &&
              edge.branch == CanvasEdgeBranch.onFail) ||
          selectedNodeIds.contains(edge.fromId) ||
          selectedNodeIds.contains(edge.toId);

      final alpha = isSelectedEdge
          ? 1.0
          : isHot
          ? 0.9
          : (edge.branch == CanvasEdgeBranch.onFail ? 0.48 : 0.55);

      _drawStyledEdge(
        canvas,
        geom: geom,
        color: color.withValues(alpha: alpha),
        strokeWidth: isSelectedEdge ? 2.8 : (isHot ? 2.2 : 1.5),
        linePaint: linePaint,
        arrowPaint: arrowPaint,
      );
    }
  }

  static void _drawStyledEdge(
    Canvas canvas, {
    required _EdgeGeometry geom,
    required Color color,
    required double strokeWidth,
    required Paint linePaint,
    required Paint arrowPaint,
  }) {
    linePaint
      ..color = color
      ..strokeWidth = strokeWidth;

    final path = Path()
      ..moveTo(geom.p0.dx, geom.p0.dy)
      ..cubicTo(
        geom.c1.dx,
        geom.c1.dy,
        geom.c2.dx,
        geom.c2.dy,
        geom.p3.dx,
        geom.p3.dy,
      );
    canvas.drawPath(path, linePaint);

    canvas.save();
    canvas.translate(geom.p3.dx, geom.p3.dy);
    canvas.rotate(geom.endAngle);
    arrowPaint.color = color;
    const s = 5.5;
    final arrow = Path()
      ..moveTo(0, 0)
      ..lineTo(-s * 1.45, -s * 0.65)
      ..lineTo(-s * 1.45, s * 0.65)
      ..close();
    canvas.drawPath(arrow, arrowPaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WorkflowEdgesPainter oldDelegate) =>
      oldDelegate.layoutVersion != layoutVersion ||
      oldDelegate.selectedEdgeId != selectedEdgeId ||
      oldDelegate.selectedNodeIds.length != selectedNodeIds.length ||
      !oldDelegate.selectedNodeIds.containsAll(selectedNodeIds) ||
      oldDelegate.edges.length != edges.length ||
      oldDelegate.nodes.length != nodes.length;
}

class _LiveWirePainter extends CustomPainter {
  const _LiveWirePainter({
    required this.fromNode,
    required this.branch,
    required this.targetPos,
  });

  final CanvasNode? fromNode;
  final CanvasEdgeBranch branch;
  final Offset? targetPos;

  @override
  void paint(Canvas canvas, Size size) {
    final from = fromNode;
    final target = targetPos;
    if (from == null || target == null) return;
    final p0 = _outputPortOffset(from, branch);
    final dx = math.max(48.0, (target.dx - p0.dx).abs() * 0.45);
    final linePaint = Paint()
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final arrowPaint = Paint()..style = PaintingStyle.fill;
    _WorkflowEdgesPainter._drawStyledEdge(
      canvas,
      geom: (
        p0: p0,
        c1: Offset(p0.dx + dx, p0.dy),
        c2: Offset(target.dx - dx, target.dy),
        p3: target,
        endAngle: 0.0,
      ),
      color: _branchColor(branch).withValues(alpha: 0.9),
      strokeWidth: 2.2,
      linePaint: linePaint,
      arrowPaint: arrowPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _LiveWirePainter oldDelegate) =>
      oldDelegate.targetPos != targetPos ||
      oldDelegate.fromNode?.id != fromNode?.id ||
      oldDelegate.branch != branch;
}

class _SnapGuidesPainter extends CustomPainter {
  const _SnapGuidesPainter({required this.guides});

  final List<_SnapGuide> guides;

  @override
  void paint(Canvas canvas, Size size) {
    if (guides.isEmpty) return;
    final paint = Paint()
      ..color = const Color(0xFF3B82F6).withValues(alpha: 0.85)
      ..strokeWidth = 1.15
      ..style = PaintingStyle.stroke;
    for (final g in guides) {
      if (g.vertical) {
        canvas.drawLine(Offset(g.pos, g.start), Offset(g.pos, g.end), paint);
      } else {
        canvas.drawLine(Offset(g.start, g.pos), Offset(g.end, g.pos), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SnapGuidesPainter oldDelegate) =>
      oldDelegate.guides != guides;
}

class _MarqueePainter extends CustomPainter {
  const _MarqueePainter({required this.rect});

  final Rect? rect;

  @override
  void paint(Canvas canvas, Size size) {
    final r = rect;
    if (r == null || r.isEmpty) return;
    canvas.drawRect(
      r,
      Paint()
        ..color = const Color(0xFF2563EB).withValues(alpha: 0.12)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      r,
      Paint()
        ..color = const Color(0xFF3B82F6).withValues(alpha: 0.85)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _MarqueePainter oldDelegate) =>
      oldDelegate.rect != rect;
}

/// High-performance viewport-culled dot grid using batched `drawPoints`
/// instead of 24,000+ individual `drawCircle` calls.
class _DotGridPainter extends CustomPainter {
  _DotGridPainter({
    required this.dotColor,
    required this.transform,
    required this.viewportSize,
  }) : super(repaint: transform);

  final Color dotColor;
  final TransformationController transform;
  final Size viewportSize;

  @override
  void paint(Canvas canvas, Size size) {
    const step = 22.0;
    final m = transform.value;
    final scale = m.getMaxScaleOnAxis().clamp(0.15, 5.0);
    // Double grid spacing when zoomed far out to avoid moire & save GPU points.
    final effectiveStep = scale < 0.48 ? step * 2 : step;
    final tx = m.storage[12];
    final ty = m.storage[13];

    final minX = math.max(0.0, (-tx / scale) - effectiveStep * 2);
    final minY = math.max(0.0, (-ty / scale) - effectiveStep * 2);
    final maxX = math.min(
      size.width,
      ((viewportSize.width - tx) / scale) + effectiveStep * 2,
    );
    final maxY = math.min(
      size.height,
      ((viewportSize.height - ty) / scale) + effectiveStep * 2,
    );
    if (maxX <= minX || maxY <= minY) return;

    final startX = (minX / effectiveStep).floor() * effectiveStep;
    final startY = (minY / effectiveStep).floor() * effectiveStep;

    final points = <Offset>[];
    for (double x = startX; x <= maxX; x += effectiveStep) {
      for (double y = startY; y <= maxY; y += effectiveStep) {
        points.add(Offset(x, y));
      }
    }
    if (points.isEmpty) return;

    final paint = Paint()
      ..color = dotColor
      ..strokeWidth = scale < 0.55 ? 2.4 : 1.9
      ..strokeCap = StrokeCap.round;
    canvas.drawPoints(ui.PointMode.points, points, paint);
  }

  @override
  bool shouldRepaint(covariant _DotGridPainter oldDelegate) =>
      oldDelegate.dotColor != dotColor ||
      oldDelegate.viewportSize != viewportSize;
}

/// Lightweight Pre-Run Parameter Dialog opened before starting an editor
/// workflow that defines Trigger `key=value` inputs. Lets users tweak
/// runtime parameters (e.g., `deployMode`, `targetApps`, `filterStatus`,
/// `apiUrl`) in 2 seconds without opening the right-hand Inspector.
class _PreRunWorkflowDialog extends StatefulWidget {
  const _PreRunWorkflowDialog({
    required this.ctrl,
    required this.workflowName,
    required this.initialParams,
    required this.modelSummaryBuilder,
    required this.isZh,
    required this.onConfigureModels,
  });

  final CanvasController ctrl;
  final String workflowName;
  final Map<String, String> initialParams;
  final String Function() modelSummaryBuilder;
  final bool isZh;
  final VoidCallback onConfigureModels;

  @override
  State<_PreRunWorkflowDialog> createState() => _PreRunWorkflowDialogState();
}

class _PreRunWorkflowDialogState extends State<_PreRunWorkflowDialog> {
  late final Map<String, TextEditingController> _controllers;
  bool _saveToCanvas = true;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final e in widget.initialParams.entries)
        e.key: TextEditingController(text: e.value),
    };
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  static String? _hintForKey(String key, bool isZh) {
    if (!isZh) return null;
    return switch (key) {
      'bugsUrl' => '问题单平台地址（推荐 https://pomeloc.top/bugs/）',
      'bugId' => '可选：指定单号（如 I2611000627）；留空则自动按规则筛单',
      'deployMode' => 'smart（极速精准）或 all（全量并行）',
      'targetApps' => '空格分隔应用名，如 pdm 或 pdm umc',
      'filterStatus' => '问题单状态筛选（逗号分隔，如 REOPENED,PR,ASSIGN,NEW）',
      'filterModule' => '模块筛选（默认 全部）',
      'filterSeverity' => '严重程度筛选（默认 全部）',
      'apiUrl' => '目标 PLM 后端地址',
      'uploadModified' => 'true 上传本地改动 CSV / false 纯刷新',
      'apps' => '需要同步重启的应用（如 pdm umc ppm）',
      'branch' => '目标 Git 分支名',
      'deployTarget' => '部署目标环境（如 69-sts）',
      _ => null,
    };
  }

  void _submit() {
    final out = <String, String>{
      for (final e in _controllers.entries) e.key: e.value.text.trim(),
    };
    Navigator.of(context).pop((params: out, save: _saveToCanvas));
  }

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final dark = colors.dark;
    final isZh = widget.isZh;
    final bg = dark ? const Color(0xFF1A1D24) : Colors.white;
    final fieldFill = dark ? const Color(0xFF222630) : const Color(0xFFF5F6F8);
    final hairline = dark
        ? Colors.white.withValues(alpha: 0.09)
        : Colors.black.withValues(alpha: 0.08);
    final hasAgentNodes = widget.ctrl.nodes.any(
      (n) => n.kind == CanvasNodeKind.agent,
    );

    return Dialog(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: hairline),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 14),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: hairline)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2563EB).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Codicons.play,
                      size: 14,
                      color: Color(0xFF2563EB),
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isZh ? '确认运行参数' : 'Run Parameters',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: colors['foreground'],
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.workflowName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.2,
                            color: colors['descriptionForeground'],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (hasAgentNodes)
                    ListenableBuilder(
                      listenable: widget.ctrl,
                      builder: (context, _) => InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: widget.onConfigureModels,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: fieldFill,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: hairline),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Codicons.hubot,
                                size: 12,
                                color: Color(0xFF2563EB),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                widget.modelSummaryBuilder(),
                                style: TextStyle(
                                  fontSize: 10.8,
                                  fontWeight: FontWeight.w500,
                                  color: colors['foreground'],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Parameter rows
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final entry in _controllers.entries) ...[
                      Row(
                        children: [
                          Text(
                            entry.key,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              fontFamily: AppFonts.mono,
                              color: const Color(0xFF0891B2),
                            ),
                          ),
                          if (_hintForKey(entry.key, isZh) case final hint?) ...[
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                hint,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: colors['descriptionForeground'],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: entry.value,
                        onSubmitted: (_) => _submit(),
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: AppFonts.mono,
                          color: colors['foreground'],
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          filled: true,
                          fillColor: fieldFill,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8.5,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: BorderSide(color: hairline),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: const BorderSide(
                              color: Color(0xFF2563EB),
                              width: 1.2,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                ),
              ),
            ),

            // Footer
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: hairline)),
              ),
              child: Row(
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(5),
                    onTap: () =>
                        setState(() => _saveToCanvas = !_saveToCanvas),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: Checkbox(
                              value: _saveToCanvas,
                              onChanged: (v) =>
                                  setState(() => _saveToCanvas = v ?? true),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                          const SizedBox(width: 7),
                          Text(
                            isZh ? '同步写回画布触发节点' : 'Save changes to canvas',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: colors['descriptionForeground'],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  IdeButton(
                    label: isZh ? '取消' : 'Cancel',
                    secondary: true,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  IdeButton(
                    label: isZh ? '立即运行' : 'Run Now',
                    icon: Codicons.play,
                    onPressed: _submit,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
