import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import 'canvas_controller.dart';

/// Opens a Figma/VS Code-style quick node search & jump palette (`Ctrl+K`).
Future<CanvasNode?> showCanvasSearchPalette(
  BuildContext context, {
  required List<CanvasNode> nodes,
  required bool isZh,
  required IconData Function(CanvasNodeKind) kindIcon,
}) {
  return showDialog<CanvasNode>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    builder: (_) => _CanvasSearchPaletteDialog(
      nodes: nodes,
      isZh: isZh,
      kindIcon: kindIcon,
    ),
  );
}

enum _SearchFilter { all, failed, running, approval, agent, command }

class _CanvasSearchPaletteDialog extends StatefulWidget {
  const _CanvasSearchPaletteDialog({
    required this.nodes,
    required this.isZh,
    required this.kindIcon,
  });

  final List<CanvasNode> nodes;
  final bool isZh;
  final IconData Function(CanvasNodeKind) kindIcon;

  @override
  State<_CanvasSearchPaletteDialog> createState() =>
      _CanvasSearchPaletteDialogState();
}

class _CanvasSearchPaletteDialogState
    extends State<_CanvasSearchPaletteDialog> {
  final _queryCtrl = TextEditingController();
  final _focusNode = FocusNode();
  _SearchFilter _filter = _SearchFilter.all;
  int _activeIdx = 0;

  @override
  void dispose() {
    _queryCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  List<CanvasNode> _filteredNodes() {
    final q = _queryCtrl.text.trim().toLowerCase();
    return [
      for (final n in widget.nodes)
        if (_matchesFilter(n) && _matchesQuery(n, q)) n,
    ];
  }

  bool _matchesFilter(CanvasNode n) => switch (_filter) {
    _SearchFilter.all => true,
    _SearchFilter.failed => n.runStatus == CanvasNodeRunStatus.failed,
    _SearchFilter.running => n.runStatus == CanvasNodeRunStatus.running,
    _SearchFilter.approval =>
      n.runStatus == CanvasNodeRunStatus.waitingApproval ||
          n.kind == CanvasNodeKind.approval,
    _SearchFilter.agent => n.kind == CanvasNodeKind.agent,
    _SearchFilter.command => n.kind == CanvasNodeKind.command,
  };

  bool _matchesQuery(CanvasNode n, String q) {
    if (q.isEmpty) return true;
    return n.title.toLowerCase().contains(q) ||
        n.kind.label(true).toLowerCase().contains(q) ||
        n.kind.label(false).toLowerCase().contains(q) ||
        n.content.toLowerCase().contains(q) ||
        n.httpUrl.toLowerCase().contains(q) ||
        n.id.toLowerCase().contains(q);
  }

  Color _statusTone(CanvasNodeRunStatus s) => switch (s) {
    CanvasNodeRunStatus.running => const Color(0xFF2563EB),
    CanvasNodeRunStatus.waitingApproval => const Color(0xFFD97706),
    CanvasNodeRunStatus.succeeded => const Color(0xFF16A34A),
    CanvasNodeRunStatus.failed => const Color(0xFFDC2626),
    _ => const Color(0xFF8B949E),
  };

  @override
  Widget build(BuildContext context) {
    final isZh = widget.isZh;
    final colors = themeColors;
    final dark = colors.dark;
    final surface = dark ? const Color(0xFF1B1F27) : Colors.white;
    final border = dark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.09);
    final matches = _filteredNodes();
    if (_activeIdx >= matches.length) {
      _activeIdx = matches.isEmpty ? 0 : matches.length - 1;
    }

    return KeyboardListener(
      focusNode: FocusNode(),
      onKeyEvent: (event) {
        if (event is! KeyDownEvent) return;
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          if (matches.isNotEmpty) {
            setState(() => _activeIdx = (_activeIdx + 1) % matches.length);
          }
        } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          if (matches.isNotEmpty) {
            setState(
              () => _activeIdx =
                  (_activeIdx - 1 + matches.length) % matches.length,
            );
          }
        } else if (event.logicalKey == LogicalKeyboardKey.enter) {
          if (matches.isNotEmpty) {
            Navigator.of(context).pop(matches[_activeIdx]);
          }
        } else if (event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
        }
      },
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.fromLTRB(24, 68, 24, 24),
        alignment: Alignment.topCenter,
        child: Container(
          width: 540,
          constraints: const BoxConstraints(maxHeight: 480),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.5 : 0.16),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Search input bar
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 12, 8),
                child: Row(
                  children: [
                    Icon(
                      Codicons.search,
                      size: 15,
                      color: colors['descriptionForeground'],
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _queryCtrl,
                        focusNode: _focusNode,
                        autofocus: true,
                        onChanged: (_) => setState(() => _activeIdx = 0),
                        onSubmitted: (_) {
                          if (matches.isNotEmpty) {
                            Navigator.of(context).pop(matches[_activeIdx]);
                          }
                        },
                        style: TextStyle(
                          fontSize: 13.5,
                          color: colors['foreground'],
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: isZh
                              ? '搜索节点名称、命令、Prompt、URL 或 ID…'
                              : 'Search node title, command, prompt, URL, or ID...',
                          hintStyle: TextStyle(
                            fontSize: 13,
                            color: colors['descriptionForeground'].withValues(
                              alpha: 0.7,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: (dark ? Colors.white : Colors.black).withValues(
                          alpha: 0.06,
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'ESC',
                        style: TextStyle(
                          fontSize: 10,
                          fontFamily: AppFonts.mono,
                          color: colors['descriptionForeground'],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Filter pills
              Container(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: border)),
                ),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 5,
                  children: [
                    for (final (f, lbl) in [
                      (_SearchFilter.all, isZh ? '全部' : 'All'),
                      (_SearchFilter.failed, isZh ? '失败' : 'Failed'),
                      (_SearchFilter.running, isZh ? '执行中' : 'Running'),
                      (_SearchFilter.approval, isZh ? '审批' : 'Approval'),
                      (_SearchFilter.agent, 'AI Agent'),
                      (_SearchFilter.command, 'Shell'),
                    ])
                      InkWell(
                        borderRadius: BorderRadius.circular(5),
                        onTap: () => setState(() {
                          _filter = f;
                          _activeIdx = 0;
                        }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: _filter == f
                                ? const Color(0xFF2563EB).withValues(
                                    alpha: dark ? 0.25 : 0.13,
                                  )
                                : (dark ? Colors.white : Colors.black)
                                      .withValues(alpha: 0.045),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                              color: _filter == f
                                  ? const Color(0xFF2563EB)
                                  : Colors.transparent,
                            ),
                          ),
                          child: Text(
                            lbl,
                            style: TextStyle(
                              fontSize: 10.8,
                              fontWeight: _filter == f
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: _filter == f
                                  ? (dark
                                        ? const Color(0xFF93C5FD)
                                        : const Color(0xFF1D4ED8))
                                  : colors['descriptionForeground'],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // Matches list
              Flexible(
                child: matches.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: Text(
                            isZh ? '没有匹配的画布节点' : 'No matching canvas nodes',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors['descriptionForeground'],
                            ),
                          ),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: matches.length,
                        itemBuilder: (context, idx) {
                          final node = matches[idx];
                          final active = idx == _activeIdx;
                          final accent = Color(node.colorValue);
                          final snippet =
                              (node.kind == CanvasNodeKind.http &&
                                          node.httpUrl.isNotEmpty
                                      ? '${node.httpMethod} ${node.httpUrl}'
                                      : node.content)
                                  .replaceAll(RegExp(r'\s+'), ' ')
                                  .trim();
                          return InkWell(
                            onTap: () => Navigator.of(context).pop(node),
                            onHover: (h) {
                              if (h && _activeIdx != idx) {
                                setState(() => _activeIdx = idx);
                              }
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              color: active
                                  ? const Color(0xFF2563EB).withValues(
                                      alpha: dark ? 0.18 : 0.09,
                                    )
                                  : Colors.transparent,
                              child: Row(
                                children: [
                                  Container(
                                    width: 26,
                                    height: 26,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: accent.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Icon(
                                      widget.kindIcon(node.kind),
                                      size: 13.5,
                                      color: accent,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                node.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 12.5,
                                                  fontWeight: FontWeight.w600,
                                                  color: colors['foreground'],
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              node.kind.label(isZh),
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: accent,
                                              ),
                                            ),
                                          ],
                                        ),
                                        if (snippet.isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            snippet,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontFamily: AppFonts.mono,
                                              color:
                                                  colors['descriptionForeground'],
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  if (node.runStatus !=
                                      CanvasNodeRunStatus.idle) ...[
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _statusTone(
                                          node.runStatus,
                                        ).withValues(alpha: 0.16),
                                        borderRadius: BorderRadius.circular(5),
                                      ),
                                      child: Text(
                                        node.runStatus.label(isZh),
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                          color: _statusTone(node.runStatus),
                                        ),
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
              // Footer shortcut hints
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: border)),
                ),
                child: Row(
                  children: [
                    Text(
                      isZh
                          ? '共 ${matches.length} 个节点 · ↑↓ 选择 · Enter 定位跳转'
                          : '${matches.length} nodes · ↑↓ navigate · Enter to focus',
                      style: TextStyle(
                        fontSize: 10.5,
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
    );
  }
}
