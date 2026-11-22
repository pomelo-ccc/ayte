import 'package:flutter/material.dart';

import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import 'canvas_controller.dart';

/// Right-click and drop-to-create studio context menus for Ayte Workflow Canvas.
abstract final class CanvasContextMenu {
  static RelativeRect _positionFromGlobal(
    BuildContext context,
    Offset globalPos,
  ) {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    return RelativeRect.fromRect(
      Rect.fromLTWH(globalPos.dx, globalPos.dy, 1, 1),
      Offset.zero & overlay.size,
    );
  }

  static PopupMenuItem<T> _item<T>({
    required T value,
    required IconData icon,
    required String label,
    String? shortcut,
    Color? color,
  }) {
    final colors = themeColors;
    final fg = color ?? colors['foreground'];
    return PopupMenuItem<T>(
      value: value,
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(icon, size: 13.5, color: fg),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: fg),
            ),
          ),
          if (shortcut != null) ...[
            const SizedBox(width: 14),
            Text(
              shortcut,
              style: TextStyle(
                fontSize: 10.5,
                color: colors['descriptionForeground'],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static ShapeBorder _menuShape(bool dark) => RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(10),
    side: BorderSide(
      color: dark
          ? Colors.white.withValues(alpha: 0.12)
          : Colors.black.withValues(alpha: 0.09),
    ),
  );

  static Color _menuBg(bool dark) =>
      dark ? const Color(0xFF1F2228) : Colors.white;

  /// Context menu shown when right-clicking on blank canvas background.
  static Future<String?> showBoardMenu(
    BuildContext context, {
    required Offset globalPos,
    required bool isZh,
    required bool hasClipboard,
    required bool snapToGrid,
    required bool showMinimap,
    required bool readOnly,
  }) {
    final dark = themeColors.dark;
    return showMenu<String>(
      context: context,
      position: _positionFromGlobal(context, globalPos),
      color: _menuBg(dark),
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: _menuShape(dark),
      items: [
        if (!readOnly) ...[
          _item(
            value: 'add:command',
            icon: Codicons.terminal,
            label: isZh ? '在此添加 Shell 命令' : 'Add Shell Node',
            color: const Color(0xFFA371F7),
          ),
          _item(
            value: 'add:agent',
            icon: Codicons.sparkle,
            label: isZh ? '在此添加 AI Agent' : 'Add AI Agent',
            color: const Color(0xFF58A6FF),
          ),
          _item(
            value: 'add:http',
            icon: Codicons.globe,
            label: isZh ? '在此添加 HTTP 接口' : 'Add HTTP Node',
            color: const Color(0xFF2EA043),
          ),
          _item(
            value: 'add:condition',
            icon: Codicons.gitCompare,
            label: isZh ? '在此添加条件门禁' : 'Add Condition',
            color: const Color(0xFFD29922),
          ),
          _item(
            value: 'add:approval',
            icon: Codicons.shield,
            label: isZh ? '在此添加人工确认' : 'Add Approval Gate',
            color: const Color(0xFFF0883E),
          ),
          _item(
            value: 'add:trigger',
            icon: Codicons.symbolEvent,
            label: isZh ? '在此添加触发输入' : 'Add Trigger',
            color: const Color(0xFF39C5CF),
          ),
          _item(
            value: 'add:group',
            icon: Codicons.layers,
            label: isZh ? '在此添加分组框' : 'Add Group Frame',
            color: const Color(0xFF8B949E),
          ),
          _item(
            value: 'add:note',
            icon: Codicons.note,
            label: isZh ? '在此添加便签' : 'Add Note',
            color: const Color(0xFFD29922),
          ),
          const PopupMenuDivider(height: 8),
          if (hasClipboard)
            _item(
              value: 'paste',
              icon: Codicons.clippy,
              label: isZh ? '粘贴到此位置' : 'Paste Here',
              shortcut: 'Ctrl+V',
            ),
          _item(
            value: 'ai_generate',
            icon: Codicons.wand,
            label: isZh ? 'AI 生成 / 修改工作流…' : 'AI Generate Workflow...',
            color: const Color(0xFF8B5CF6),
          ),
          _item(
            value: 'auto_layout',
            icon: Codicons.layout,
            label: isZh ? '自动排版 DAG' : 'Auto-Layout DAG',
          ),
        ],
        _item(
          value: 'select_all',
          icon: Codicons.selection,
          label: isZh ? '全选节点' : 'Select All',
          shortcut: 'Ctrl+A',
        ),
        _item(
          value: 'search',
          icon: Codicons.search,
          label: isZh ? '搜索节点…' : 'Find Node...',
          shortcut: 'Ctrl+K',
        ),
        _item(
          value: 'fit_view',
          icon: Codicons.screenFull,
          label: isZh ? '适配全图' : 'Fit to View',
          shortcut: 'Shift+1',
        ),
        const PopupMenuDivider(height: 8),
        _item(
          value: 'toggle_snap',
          icon: Codicons.magnet,
          label: snapToGrid
              ? (isZh ? '✓ 网格吸附 (22px)' : '✓ Snap to Grid')
              : (isZh ? '网格吸附 (22px)' : 'Snap to Grid'),
        ),
        _item(
          value: 'toggle_minimap',
          icon: Codicons.map,
          label: showMinimap
              ? (isZh ? '✓ 显示小地图' : '✓ Show Minimap')
              : (isZh ? '显示小地图' : 'Show Minimap'),
        ),
        if (!readOnly)
          _item(
            value: 'json_io',
            icon: Codicons.json,
            label: isZh ? '导入 / 导出 JSON…' : 'Import / Export JSON...',
          ),
      ],
    );
  }

  /// Context menu shown when right-clicking on a single or multi-selected node.
  static Future<String?> showNodeMenu(
    BuildContext context, {
    required Offset globalPos,
    required CanvasNode node,
    required int selectionCount,
    required bool isZh,
    required bool readOnly,
  }) {
    final dark = themeColors.dark;
    final multi = selectionCount > 1;
    return showMenu<String>(
      context: context,
      position: _positionFromGlobal(context, globalPos),
      color: _menuBg(dark),
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: _menuShape(dark),
      items: [
        if (!multi &&
            !readOnly &&
            (node.kind == CanvasNodeKind.command ||
                node.kind == CanvasNodeKind.agent ||
                node.kind == CanvasNodeKind.http))
          _item(
            value: 'test_step',
            icon: Codicons.play,
            label: isZh ? '单步试跑' : 'Test Step',
            color: const Color(0xFF16A34A),
          ),
        if (!multi &&
            node.kind.isExecutable &&
            node.kind != CanvasNodeKind.trigger)
          _item(
            value: 'run_from_here',
            icon: Codicons.debugContinue,
            label: readOnly
                ? (isZh ? '从本节点断点续跑' : 'Resume From Here')
                : (isZh ? '从此节点开始运行' : 'Run From Here'),
            color: const Color(0xFF2563EB),
          ),
        if (!multi && !readOnly && node.kind != CanvasNodeKind.group)
          _item(
            value: 'ai_assist',
            icon: Codicons.wand,
            label: isZh ? 'AI 帮写 / 优化内容…' : 'AI Assist Content...',
            color: const Color(0xFF8B5CF6),
          ),
        if (!readOnly) ...[
          const PopupMenuDivider(height: 8),
          _item(
            value: 'copy',
            icon: Codicons.copy,
            label: multi
                ? (isZh ? '复制 $selectionCount 个节点' : 'Copy $selectionCount Nodes')
                : (isZh ? '复制节点' : 'Copy'),
            shortcut: 'Ctrl+C',
          ),
          _item(
            value: 'duplicate',
            icon: Codicons.layers,
            label: multi
                ? (isZh
                      ? '创建 $selectionCount 个副本'
                      : 'Duplicate $selectionCount')
                : (isZh ? '创建副本' : 'Duplicate'),
            shortcut: 'Ctrl+D',
          ),
        ],
        if (multi && !readOnly) ...[
          const PopupMenuDivider(height: 8),
          _item(
            value: 'align:left',
            icon: Codicons.layout,
            label: isZh ? '左对齐' : 'Align Left',
          ),
          _item(
            value: 'align:top',
            icon: Codicons.layout,
            label: isZh ? '顶对齐' : 'Align Top',
          ),
          _item(
            value: 'align:centerV',
            icon: Codicons.layout,
            label: isZh ? '水平居中对齐' : 'Align Middle Horizontally',
          ),
          if (selectionCount >= 3)
            _item(
              value: 'align:distributeH',
              icon: Codicons.layout,
              label: isZh ? '水平等距分布' : 'Distribute Horizontally',
            ),
        ],
        if (!readOnly) ...[
          const PopupMenuDivider(height: 8),
          _item(
            value: 'delete',
            icon: Codicons.trash,
            label: multi
                ? (isZh ? '删除 $selectionCount 个节点' : 'Delete $selectionCount')
                : (isZh ? '删除节点' : 'Delete'),
            shortcut: 'Del',
            color: const Color(0xFFEF4444),
          ),
        ],
      ],
    );
  }

  /// Context menu shown when clicking an edge's `+` insert button or
  /// right-clicking an edge pill.
  static Future<String?> showEdgeMenu(
    BuildContext context, {
    required Offset globalPos,
    required CanvasEdge edge,
    required bool isZh,
  }) {
    final dark = themeColors.dark;
    return showMenu<String>(
      context: context,
      position: _positionFromGlobal(context, globalPos),
      color: _menuBg(dark),
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: _menuShape(dark),
      items: [
        _item(
          value: 'insert:command',
          icon: Codicons.terminal,
          label: isZh ? '在线上插入 Shell 命令' : 'Insert Shell Step',
          color: const Color(0xFFA371F7),
        ),
        _item(
          value: 'insert:agent',
          icon: Codicons.sparkle,
          label: isZh ? '在线上插入 AI Agent' : 'Insert AI Agent',
          color: const Color(0xFF58A6FF),
        ),
        _item(
          value: 'insert:condition',
          icon: Codicons.gitCompare,
          label: isZh ? '在线上插入条件门禁' : 'Insert Condition',
          color: const Color(0xFFD29922),
        ),
        _item(
          value: 'insert:http',
          icon: Codicons.globe,
          label: isZh ? '在线上插入 HTTP 接口' : 'Insert HTTP Step',
          color: const Color(0xFF2EA043),
        ),
        _item(
          value: 'insert:approval',
          icon: Codicons.shield,
          label: isZh ? '在线上插入人工确认' : 'Insert Approval Gate',
          color: const Color(0xFFF0883E),
        ),
        const PopupMenuDivider(height: 8),
        if (edge.branch != CanvasEdgeBranch.onPass)
          _item(
            value: 'branch:onPass',
            icon: Codicons.arrowSwap,
            label: isZh ? '改为「通过」分支' : 'Switch to On Pass',
            color: const Color(0xFF16A34A),
          ),
        if (edge.branch != CanvasEdgeBranch.onFail)
          _item(
            value: 'branch:onFail',
            icon: Codicons.arrowSwap,
            label: isZh ? '改为「失败」分支' : 'Switch to On Fail',
            color: const Color(0xFFEF4444),
          ),
        if (edge.branch != CanvasEdgeBranch.always)
          _item(
            value: 'branch:always',
            icon: Codicons.arrowSwap,
            label: isZh ? '改为「总是」分支' : 'Switch to Always',
            color: const Color(0xFF3B82F6),
          ),
        const PopupMenuDivider(height: 8),
        _item(
          value: 'delete',
          icon: Codicons.trash,
          label: isZh ? '删除连线' : 'Delete Edge',
          color: const Color(0xFFEF4444),
        ),
      ],
    );
  }

  /// Menu popped right at the release cursor when dragging a wire from an
  /// output port and dropping it on empty canvas (Figma/n8n drop-to-create!).
  static Future<CanvasNodeKind?> showDropCreateNodeMenu(
    BuildContext context, {
    required Offset globalPos,
    required bool isZh,
  }) {
    final dark = themeColors.dark;
    return showMenu<CanvasNodeKind>(
      context: context,
      position: _positionFromGlobal(context, globalPos),
      color: _menuBg(dark),
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: _menuShape(dark),
      items: [
        _item(
          value: CanvasNodeKind.command,
          icon: Codicons.terminal,
          label: isZh ? '新建并连接：Shell 命令' : 'Create & Connect: Shell',
          color: const Color(0xFFA371F7),
        ),
        _item(
          value: CanvasNodeKind.agent,
          icon: Codicons.sparkle,
          label: isZh ? '新建并连接：AI Agent' : 'Create & Connect: AI Agent',
          color: const Color(0xFF58A6FF),
        ),
        _item(
          value: CanvasNodeKind.http,
          icon: Codicons.globe,
          label: isZh ? '新建并连接：HTTP 接口' : 'Create & Connect: HTTP',
          color: const Color(0xFF2EA043),
        ),
        _item(
          value: CanvasNodeKind.condition,
          icon: Codicons.gitCompare,
          label: isZh ? '新建并连接：条件门禁' : 'Create & Connect: Condition',
          color: const Color(0xFFD29922),
        ),
        _item(
          value: CanvasNodeKind.approval,
          icon: Codicons.shield,
          label: isZh ? '新建并连接：人工确认' : 'Create & Connect: Approval',
          color: const Color(0xFFF0883E),
        ),
      ],
    );
  }
}
