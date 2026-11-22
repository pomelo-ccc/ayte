import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import 'canvas_controller.dart';

/// Interactive Figma/n8n-style minimap overlay anchored in the canvas corner.
///
/// Subscribes directly to [transform] via [ValueListenableBuilder] so panning
/// and zooming repaint only this lightweight 200x128 card without rebuilding
/// the workflow node stack. Clicking or dragging anywhere on the minimap pans
/// the viewport smoothly to that region.
class CanvasMinimap extends StatelessWidget {
  const CanvasMinimap({
    super.key,
    required this.nodes,
    required this.edges,
    required this.selectedNodeIds,
    required this.boardSize,
    required this.viewportSize,
    required this.transform,
    required this.isZh,
    required this.onFitView,
    required this.onClose,
  });

  final List<CanvasNode> nodes;
  final List<CanvasEdge> edges;
  final Set<String> selectedNodeIds;
  final Size boardSize;
  final Size viewportSize;
  final TransformationController transform;
  final bool isZh;
  final VoidCallback onFitView;
  final VoidCallback onClose;

  static const double _mapWidth = 204.0;
  static const double _mapHeight = 122.0;

  Rect _contentWorldRect() {
    if (nodes.isEmpty) {
      return Rect.fromLTWH(
        0,
        0,
        math.max(1200.0, boardSize.width),
        math.max(720.0, boardSize.height),
      );
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
    const pad = 220.0;
    final left = math.max(0.0, minX - pad);
    final top = math.max(0.0, minY - pad);
    final right = math.max(left + 900.0, maxX + pad);
    final bottom = math.max(top + 560.0, maxY + pad);
    return Rect.fromLTRB(left, top, right, bottom);
  }

  void _panToLocal(Offset localPos, Rect worldRect) {
    final mapScale = math.min(
      (_mapWidth - 12) / worldRect.width,
      (_mapHeight - 12) / worldRect.height,
    );
    final drawW = worldRect.width * mapScale;
    final drawH = worldRect.height * mapScale;
    final ox = (_mapWidth - drawW) / 2;
    final oy = (_mapHeight - drawH) / 2;

    final sceneX = worldRect.left + (localPos.dx - ox) / mapScale;
    final sceneY = worldRect.top + (localPos.dy - oy) / mapScale;

    final curScale = transform.value.getMaxScaleOnAxis().clamp(0.25, 2.5);
    final tx = viewportSize.width / 2 - sceneX * curScale;
    final ty = viewportSize.height / 2 - sceneY * curScale;
    final next = Matrix4.identity()
      ..setEntry(0, 0, curScale)
      ..setEntry(1, 1, curScale)
      ..setEntry(0, 3, tx)
      ..setEntry(1, 3, ty);
    transform.value = next;
  }

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final dark = colors.dark;
    final worldRect = _contentWorldRect();
    final bg = (dark ? const Color(0xFF1B1E24) : Colors.white).withValues(
      alpha: 0.94,
    );
    final border = dark
        ? Colors.white.withValues(alpha: 0.11)
        : Colors.black.withValues(alpha: 0.09);

    return Container(
      width: _mapWidth,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.34 : 0.09),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: border)),
            ),
            child: Row(
              children: [
                Icon(
                  Codicons.map,
                  size: 11,
                  color: colors['descriptionForeground'],
                ),
                const SizedBox(width: 5),
                Text(
                  isZh ? '小地图' : 'Minimap',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: colors['descriptionForeground'],
                  ),
                ),
                const Spacer(),
                Tooltip(
                  message: isZh ? '适配全图 (Shift+1)' : 'Fit View (Shift+1)',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: onFitView,
                    child: Padding(
                      padding: const EdgeInsets.all(2.5),
                      child: Icon(
                        Codicons.screenFull,
                        size: 11,
                        color: colors['descriptionForeground'],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Tooltip(
                  message: isZh ? '隐藏小地图' : 'Hide minimap',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: onClose,
                    child: Padding(
                      padding: const EdgeInsets.all(2.5),
                      child: Icon(
                        Codicons.close,
                        size: 11,
                        color: colors['descriptionForeground'],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: _mapWidth,
            height: _mapHeight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _panToLocal(d.localPosition, worldRect),
              onPanUpdate: (d) => _panToLocal(d.localPosition, worldRect),
              child: RepaintBoundary(
                child: ValueListenableBuilder<Matrix4>(
                  valueListenable: transform,
                  builder: (context, matrix, _) => CustomPaint(
                    painter: _MinimapPainter(
                      nodes: nodes,
                      edges: edges,
                      selectedNodeIds: selectedNodeIds,
                      worldRect: worldRect,
                      viewportSize: viewportSize,
                      matrix: matrix,
                      dark: dark,
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
}

class _MinimapPainter extends CustomPainter {
  const _MinimapPainter({
    required this.nodes,
    required this.edges,
    required this.selectedNodeIds,
    required this.worldRect,
    required this.viewportSize,
    required this.matrix,
    required this.dark,
  });

  final List<CanvasNode> nodes;
  final List<CanvasEdge> edges;
  final Set<String> selectedNodeIds;
  final Rect worldRect;
  final Size viewportSize;
  final Matrix4 matrix;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || worldRect.width <= 0 || worldRect.height <= 0) return;

    final mapScale = math.min(
      (size.width - 12) / worldRect.width,
      (size.height - 12) / worldRect.height,
    );
    final drawW = worldRect.width * mapScale;
    final drawH = worldRect.height * mapScale;
    final ox = (size.width - drawW) / 2;
    final oy = (size.height - drawH) / 2;

    Offset toMap(double x, double y) => Offset(
      ox + (x - worldRect.left) * mapScale,
      oy + (y - worldRect.top) * mapScale,
    );

    final byId = {for (final n in nodes) n.id: n};

    // 1. Group frames behind regular cards
    final groupFill = Paint()..style = PaintingStyle.fill;
    final groupStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    for (final n in nodes) {
      if (n.kind != CanvasNodeKind.group) continue;
      final tl = toMap(n.x, n.y);
      final rect = Rect.fromLTWH(
        tl.dx,
        tl.dy,
        math.max(4.0, n.width * mapScale),
        math.max(4.0, n.height * mapScale),
      );
      final c = Color(n.colorValue);
      groupFill.color = c.withValues(alpha: dark ? 0.14 : 0.1);
      groupStroke.color = c.withValues(alpha: 0.45);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        groupFill,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        groupStroke,
      );
    }

    // 2. Edges
    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.85;
    for (final e in edges) {
      final f = byId[e.fromId];
      final t = byId[e.toId];
      if (f == null || t == null) continue;
      edgePaint.color =
          (e.branch == CanvasEdgeBranch.onFail
                  ? const Color(0xFFEF4444)
                  : const Color(0xFF60A5FA))
              .withValues(alpha: dark ? 0.52 : 0.45);
      final p0 = toMap(f.x + f.width, f.y + f.height * 0.5);
      final p1 = toMap(t.x, t.y + t.height * 0.5);
      canvas.drawLine(p0, p1, edgePaint);
    }

    // 3. Nodes
    final nodeFill = Paint()..style = PaintingStyle.fill;
    final selStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFF3B82F6);
    for (final n in nodes) {
      if (n.kind == CanvasNodeKind.group) continue;
      final tl = toMap(n.x, n.y);
      final rect = Rect.fromLTWH(
        tl.dx,
        tl.dy,
        math.max(4.5, n.width * mapScale),
        math.max(3.5, n.height * mapScale),
      );
      final fillColor = switch (n.runStatus) {
        CanvasNodeRunStatus.running => const Color(0xFF2563EB),
        CanvasNodeRunStatus.waitingApproval => const Color(0xFFD97706),
        CanvasNodeRunStatus.succeeded => const Color(0xFF16A34A),
        CanvasNodeRunStatus.failed => const Color(0xFFDC2626),
        _ => Color(n.colorValue).withValues(alpha: dark ? 0.82 : 0.78),
      };
      nodeFill.color = fillColor;
      final rr = RRect.fromRectAndRadius(rect, const Radius.circular(1.8));
      canvas.drawRRect(rr, nodeFill);
      if (selectedNodeIds.contains(n.id)) {
        canvas.drawRRect(rr, selStroke);
      }
    }

    // 4. Current Viewport Rect
    final s = matrix.getMaxScaleOnAxis().clamp(0.1, 10.0);
    final tx = matrix.storage[12];
    final ty = matrix.storage[13];
    final viewLeft = -tx / s;
    final viewTop = -ty / s;
    final viewRight = (viewportSize.width - tx) / s;
    final viewBottom = (viewportSize.height - ty) / s;

    final vTL = toMap(viewLeft, viewTop);
    final vBR = toMap(viewRight, viewBottom);
    final vRect = Rect.fromPoints(
      vTL,
      vBR,
    ).intersect(Rect.fromLTWH(2, 2, size.width - 4, size.height - 4));
    if (!vRect.isEmpty) {
      canvas.drawRect(
        vRect,
        Paint()
          ..color = const Color(0xFF2563EB).withValues(alpha: dark ? 0.16 : 0.1)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        vRect,
        Paint()
          ..color = const Color(0xFF3B82F6).withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.15,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MinimapPainter oldDelegate) =>
      oldDelegate.nodes != nodes ||
      oldDelegate.edges != edges ||
      oldDelegate.selectedNodeIds != selectedNodeIds ||
      oldDelegate.worldRect != worldRect ||
      oldDelegate.viewportSize != viewportSize ||
      oldDelegate.matrix != matrix ||
      oldDelegate.dark != dark;
}
