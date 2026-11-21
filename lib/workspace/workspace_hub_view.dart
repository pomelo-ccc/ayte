import 'package:flutter/material.dart';

import '../automations/automations_view.dart';
import '../canvas/infinite_canvas_view.dart';
import '../chat/chat_session.dart';
import '../ide/ide_back_button.dart';
import '../library/library_view.dart';
import '../tasks/task_queue_view.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import 'islands.dart' show Island, Islands;
import 'title_bar_double_click.dart';

/// Top-level workspace pages opened from the left sidebar alongside
/// Customize ("插件") and Stash.
enum WorkspacePage {
  tasks,
  automations,
  library,
  canvas;

  IconData get icon => switch (this) {
    WorkspacePage.tasks => Codicons.checklist,
    WorkspacePage.automations => Codicons.clock,
    WorkspacePage.library => Codicons.library,
    WorkspacePage.canvas => Codicons.layout,
  };

  String label(bool isZh) => switch (this) {
    WorkspacePage.tasks => isZh ? '任务队列' : 'Tasks',
    WorkspacePage.automations => isZh ? '自动化' : 'Automations',
    WorkspacePage.library => isZh ? '资料库' : 'Library',
    WorkspacePage.canvas => isZh ? '画布' : 'Canvas',
  };

  String subtitle(bool isZh) => switch (this) {
    WorkspacePage.tasks =>
      isZh ? '无人值守 Worktree 并行执行与审查合并' : 'Unattended Worktree tasks & review',
    WorkspacePage.automations =>
      isZh ? '定时 Cron 自动触发本地内核任务' : 'Scheduled Cron automation rules',
    WorkspacePage.library =>
      isZh ? '会话产物与本地 PDF / Office 文档即时预览' : 'Session artifacts & Office/PDF preview',
    WorkspacePage.canvas =>
      isZh ? '2D 无限自由画布，编排笔记与可执行命令卡片' : '2D infinite canvas for notes & commands',
  };
}

/// Full-width main-area shell hosting a [WorkspacePage], matching the chrome
/// and island styling of CustomizeView and StashView.
class WorkspacePageView extends StatelessWidget {
  const WorkspacePageView({
    super.key,
    required this.page,
    required this.session,
    required this.onClose,
    this.leading,
    this.titleBarInset = 12.0,
    this.island,
  });

  final WorkspacePage page;
  final ChatSession? session;
  final VoidCallback onClose;
  final Widget? leading;
  final double titleBarInset;
  final Color? island;

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final colors = themeColors;
    final surface = island ?? AppColors.conversationSurface;
    final islands = Islands.on(context);
    final cwd = session?.root;

    final Widget body = switch (page) {
      WorkspacePage.tasks => TaskQueueView(defaultRepoPath: cwd),
      WorkspacePage.automations => AutomationsView(defaultCwd: cwd),
      WorkspacePage.library => session == null
          ? Center(
              child: Text(
                isZh ? '请先打开或创建一个会话以浏览资料库' : 'Open a conversation to browse Library',
                style: TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
            )
          : LibraryView(session: session!),
      WorkspacePage.canvas => InfiniteCanvasView(session: session),
    };

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TitleBarDoubleClick(
          child: Container(
            height: AppMetrics.titleBarHeight,
            padding: EdgeInsets.only(left: titleBarInset, right: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: colors['widget.border'].withValues(alpha: 0.45),
                ),
              ),
            ),
            child: Row(
              children: [
                if (leading != null) ...[
                  leading!,
                  const SizedBox(width: 6),
                ],
                IdeBackButton(
                  label: isZh ? '返回对话' : 'Back',
                  onTap: onClose,
                ),
                const SizedBox(width: 8),
                Icon(page.icon, size: 15, color: colors['foreground']),
                const SizedBox(width: 7),
                Text(
                  page.label(isZh),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: colors['foreground'],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    page.subtitle(isZh),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: body),
      ],
    );

    if (islands) {
      return Padding(
        padding: const EdgeInsets.all(Islands.gap),
        child: Island(color: surface, child: content),
      );
    }
    return ColoredBox(color: surface, child: content);
  }
}
