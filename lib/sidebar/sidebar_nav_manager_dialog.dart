import 'package:flutter/material.dart';

import '../ide/ide_button.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import 'sidebar_nav_config.dart';

/// Opens the Left Sidebar Navigation Manager dialog to add, remove, and
/// drag-reorder top navigation entries.
Future<void> showSidebarNavManagerDialog(BuildContext context) =>
    showDialog<void>(
      context: context,
      builder: (_) => const _SidebarNavManagerDialog(),
    );

class _SidebarNavManagerDialog extends StatelessWidget {
  const _SidebarNavManagerDialog();

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final colors = themeColors;
    final config = SidebarNavConfig.instance;

    return Dialog(
      backgroundColor: colors['editor.background'],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors['widget.border'].withValues(alpha: 0.7)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 540),
        child: ListenableBuilder(
          listenable: config,
          builder: (context, _) {
            final visible = config.visibleItems;
            final hidden = config.hiddenItems;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
                  child: Row(
                    children: [
                      Icon(
                        Codicons.layoutSidebarLeft,
                        size: 16,
                        color: colors['foreground'],
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isZh ? '管理左侧导航入口' : 'Customize Sidebar Navigation',
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: colors['foreground'],
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              isZh
                                  ? '拖拽或点箭头调整顺序，移除的入口会收进「更多」菜单随时打开'
                                  : 'Drag to reorder; hidden items stay accessible under "More"',
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
                          padding: const EdgeInsets.all(4),
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
                Divider(
                  height: 1,
                  color: colors['widget.border'].withValues(alpha: 0.45),
                ),
                // Body
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          isZh
                              ? '已固定在侧边栏 (${visible.length})'
                              : 'Pinned in Sidebar (${visible.length})',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: colors['descriptionForeground'],
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (visible.isEmpty)
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: colors['widget.border'].withValues(
                                  alpha: 0.4,
                                ),
                              ),
                            ),
                            child: Text(
                              isZh
                                  ? '侧边栏暂无固定入口，可在下方点击「添加」恢复任意入口。'
                                  : 'No pinned entries. Add any item below.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: colors['descriptionForeground'],
                              ),
                            ),
                          )
                        else
                          ReorderableListView.builder(
                            shrinkWrap: true,
                            buildDefaultDragHandles: false,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: visible.length,
                            onReorderItem: config.reorderVisible,
                            itemBuilder: (context, index) {
                              final item = visible[index];
                              return Container(
                                key: ValueKey(item.name),
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: colors['sideBar.background']
                                      .withValues(alpha: 0.7),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: colors['widget.border'].withValues(
                                      alpha: 0.45,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    ReorderableDragStartListener(
                                      index: index,
                                      child: MouseRegion(
                                        cursor: SystemMouseCursors.grab,
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                            right: 8,
                                          ),
                                          child: Icon(
                                            Codicons.gripper,
                                            size: 13,
                                            color:
                                                colors['descriptionForeground'],
                                          ),
                                        ),
                                      ),
                                    ),
                                    Icon(
                                      item.icon,
                                      size: 14,
                                      color: colors['foreground'],
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.label(isZh),
                                            style: TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w500,
                                              color: colors['foreground'],
                                            ),
                                          ),
                                          Text(
                                            item.description(isZh),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: colors[
                                                  'descriptionForeground'],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      iconSize: 13,
                                      visualDensity: VisualDensity.compact,
                                      tooltip: isZh ? '上移' : 'Move Up',
                                      onPressed: index > 0
                                          ? () => config.moveUp(item)
                                          : null,
                                      icon: const Icon(Codicons.arrowUp),
                                    ),
                                    IconButton(
                                      iconSize: 13,
                                      visualDensity: VisualDensity.compact,
                                      tooltip: isZh ? '下移' : 'Move Down',
                                      onPressed: index < visible.length - 1
                                          ? () => config.moveDown(item)
                                          : null,
                                      icon: const Icon(Codicons.arrowDown),
                                    ),
                                    IconButton(
                                      iconSize: 13,
                                      visualDensity: VisualDensity.compact,
                                      tooltip: isZh
                                          ? '移入「更多」'
                                          : 'Move to More',
                                      onPressed: () => config.hideItem(item),
                                      icon: const Icon(
                                        Codicons.close,
                                        color: Color(0xFFE5534B),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        const SizedBox(height: 14),
                        Text(
                          isZh
                              ? '收起在「更多」中的入口 (${hidden.length})'
                              : 'Hidden in "More" (${hidden.length})',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: colors['descriptionForeground'],
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (hidden.isEmpty)
                          Text(
                            isZh
                                ? '所有入口都已显示在侧边栏，点上方 × 可随时收起精简。'
                                : 'All items are visible. Click × above to tuck any away.',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: colors['descriptionForeground'],
                            ),
                          )
                        else
                          for (final item in hidden)
                            Container(
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: colors['widget.border'].withValues(
                                    alpha: 0.35,
                                  ),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    item.icon,
                                    size: 14,
                                    color: colors['descriptionForeground'],
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.label(isZh),
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            color: colors['foreground'],
                                          ),
                                        ),
                                        Text(
                                          item.description(isZh),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            color:
                                                colors['descriptionForeground'],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IdeButton(
                                    label: isZh ? '添加' : 'Add',
                                    icon: Codicons.add,
                                    secondary: true,
                                    onPressed: () => config.showItem(item),
                                  ),
                                ],
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
                Divider(
                  height: 1,
                  color: colors['widget.border'].withValues(alpha: 0.45),
                ),
                // Footer
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Row(
                    children: [
                      IdeButton(
                        label: isZh ? '恢复默认' : 'Reset Defaults',
                        secondary: true,
                        onPressed: config.resetDefaults,
                      ),
                      const Spacer(),
                      IdeButton(
                        label: isZh ? '完成' : 'Done',
                        onPressed: () => Navigator.of(context).pop(),
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
