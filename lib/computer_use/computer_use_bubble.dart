import 'dart:async';

import 'package:flutter/material.dart';

import '../ide/ide_button.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import 'computer_use_controller.dart';
import 'computer_use_native.dart';
import 'computer_use_settings.dart';

/// Compact status pill shown in the workspace bar when Computer Use is enabled.
/// Clicking it opens the desktop window sharing picker.
class ComputerUsePill extends StatelessWidget {
  const ComputerUsePill({super.key, this.onOpenSettings});

  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final controller = ComputerUseController.instance;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.config.enabled) return const SizedBox.shrink();
        final isZh = Localizations.localeOf(context).languageCode == 'zh';
        final active = controller.hasActiveShares;
        final colors = themeColors;
        final accent = active
            ? const Color(0xFFE5534B)
            : colors['descriptionForeground'];
        final label = controller.fullScreenShared
            ? (isZh ? '整屏共享中' : 'Full Screen')
            : controller.sharedCount > 0
            ? (isZh
                  ? '电脑操作 (${controller.sharedCount})'
                  : 'Computer (${controller.sharedCount})')
            : (isZh ? '共享窗口…' : 'Share Window…');

        return Tooltip(
          message: isZh
              ? '管理共享给智能体的桌面窗口'
              : 'Manage desktop windows shared with agents',
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => unawaited(
              showComputerUseShareDialog(
                context,
                onOpenSettings: onOpenSettings,
              ),
            ),
            child: Container(
              height: 22,
              padding: const EdgeInsets.symmetric(horizontal: 7),
              decoration: BoxDecoration(
                color: active
                    ? const Color(0x26E5534B)
                    : colors['toolbar.hoverBackground'].withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: active
                      ? const Color(0x88E5534B)
                      : colors['widget.border'].withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    active ? Codicons.record : Codicons.vm,
                    size: 12,
                    color: accent,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: active ? accent : colors['foreground'],
                      fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Dialog for picking which desktop windows to share (`Read Only` / `Interactive`)
/// or stopping all sharing immediately.
Future<void> showComputerUseShareDialog(
  BuildContext context, {
  VoidCallback? onOpenSettings,
}) async {
  final controller = ComputerUseController.instance;
  controller.refreshPermissions();
  controller.refreshWindows();
  await showDialog<void>(
    context: context,
    builder: (context) => _ComputerUseShareDialog(
      controller: controller,
      onOpenSettings: onOpenSettings,
    ),
  );
}

class _ComputerUseShareDialog extends StatelessWidget {
  const _ComputerUseShareDialog({
    required this.controller,
    this.onOpenSettings,
  });

  final ComputerUseController controller;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final colors = themeColors;
    return Dialog(
      backgroundColor: colors['editor.background'],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colors['widget.border']),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 540),
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final windows = controller.windows;
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(Codicons.vm, size: 16, color: colors['foreground']),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isZh ? '电脑操作 · 共享桌面窗口' : 'Computer Use · Share Windows',
                          style: TextStyle(
                            color: colors['foreground'],
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IdeButton(
                        label: isZh ? '刷新' : 'Refresh',
                        icon: Codicons.refresh,
                        secondary: true,
                        onPressed: () {
                          controller.refreshPermissions();
                          controller.refreshWindows();
                        },
                      ),
                      if (onOpenSettings != null) ...[
                        const SizedBox(width: 6),
                        IdeButton(
                          label: isZh ? '设置' : 'Settings',
                          icon: Codicons.settingsGear,
                          secondary: true,
                          onPressed: () {
                            Navigator.of(context).pop();
                            onOpenSettings!();
                          },
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isZh
                        ? '只有你明确共享的窗口，智能体才能看到或操作。Ayte 自身与隐私黑名单应用始终不可共享。'
                        : 'Agents can only view or interact with windows you explicitly share. Ayte itself and blacklisted privacy apps are always protected.',
                    style: TextStyle(
                      color: colors['descriptionForeground'],
                      fontSize: 12,
                    ),
                  ),
                  if (controller.config.allowFullScreen) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: colors['sideBar.background'],
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: colors['widget.border']),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Codicons.deviceDesktop,
                            size: 14,
                            color: colors['foreground'],
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              isZh ? '共享整个屏幕' : 'Share Entire Screen',
                              style: TextStyle(
                                color: colors['foreground'],
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          IdeButton(
                            label: controller.fullScreenShared
                                ? (isZh ? '停止整屏共享' : 'Stop Full Screen')
                                : (isZh ? '开启整屏共享' : 'Share Screen'),
                            secondary: !controller.fullScreenShared,
                            onPressed: () => controller.setFullScreenShared(
                              !controller.fullScreenShared,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Flexible(
                    child: windows.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                ComputerUseNative.supported
                                    ? (isZh
                                          ? '未检测到可共享的桌面窗口（请确认已授予屏幕录制权限）。'
                                          : 'No shareable windows found. Ensure Screen Recording permission is granted.')
                                    : (isZh
                                          ? '当前平台或构建未加载 macOS 原生桥接库。'
                                          : 'Native desktop window bridge is unavailable on this platform.'),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: colors['descriptionForeground'],
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: windows.length,
                            separatorBuilder: (_, _) => Divider(
                              height: 1,
                              color: colors['widget.border'].withValues(
                                alpha: 0.4,
                              ),
                            ),
                            itemBuilder: (context, index) {
                              final w = windows[index];
                              final blocked = controller.isWindowBlocked(w);
                              final level = controller.shareLevelOf(w.windowId);
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                  horizontal: 4,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            w.displayLabel,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: blocked
                                                  ? colors['descriptionForeground']
                                                  : colors['foreground'],
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          Text(
                                            blocked
                                                ? (w.isSelf
                                                      ? (isZh
                                                            ? 'Ayte 自身窗口（不可共享）'
                                                            : 'Ayte window (protected)')
                                                      : (isZh
                                                            ? '永不共享名单（已保护）'
                                                            : 'Blocked by never-share list'))
                                                : '${w.bundleId.isEmpty ? w.appName : w.bundleId} · ${w.width.round()}×${w.height.round()}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color:
                                                  colors['descriptionForeground'],
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    if (!blocked) ...[
                                      _LevelChip(
                                        label: isZh ? '只读' : 'Read',
                                        selected:
                                            level == WindowShareLevel.readOnly,
                                        onTap: () => controller.shareWindow(
                                          w,
                                          level == WindowShareLevel.readOnly
                                              ? WindowShareLevel.none
                                              : WindowShareLevel.readOnly,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      _LevelChip(
                                        label: isZh ? '可操作' : 'Control',
                                        selected:
                                            level ==
                                            WindowShareLevel.interactive,
                                        accent: true,
                                        onTap: () => controller.shareWindow(
                                          w,
                                          level == WindowShareLevel.interactive
                                              ? WindowShareLevel.none
                                              : WindowShareLevel.interactive,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (controller.hasActiveShares)
                        IdeButton(
                          label: isZh ? '停止共享全部窗口' : 'Stop All Sharing',
                          icon: Codicons.debugStop,
                          onPressed: controller.stopAllSharing,
                        )
                      else
                        const SizedBox.shrink(),
                      IdeButton(
                        label: isZh ? '关闭' : 'Close',
                        secondary: true,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _LevelChip extends StatelessWidget {
  const _LevelChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.accent = false,
  });

  final String label;
  final bool selected;
  final bool accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final bg = selected
        ? (accent ? const Color(0xFFE5534B) : colors['button.background'])
        : colors['sideBar.background'];
    final fg = selected
        ? Colors.white
        : colors['foreground'];
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: selected ? bg : colors['widget.border'],
          ),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 11.5, color: fg),
        ),
      ),
    );
  }
}
