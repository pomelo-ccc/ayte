import 'dart:async';

import 'package:flutter/material.dart';

import '../../ide/ide_button.dart';
import '../../ide/ide_input.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import '../../workspace/editor_launcher.dart' show openExternal;
import 'embedded_browser_controller.dart';
import 'embedded_browser_native.dart';
import 'embedded_browser_settings.dart';

/// Workspace Embedded Browser view rendered inside `SidePanelSection.browser`.
/// Renders the tab bar, navigation toolbar, per-tab permission switcher, and
/// hosts the native macOS WKWebView aligned to the viewport rect.
class EmbeddedBrowserView extends StatefulWidget {
  const EmbeddedBrowserView({super.key, this.onOpenSettings});

  final VoidCallback? onOpenSettings;

  @override
  State<EmbeddedBrowserView> createState() => _EmbeddedBrowserViewState();
}

class _EmbeddedBrowserViewState extends State<EmbeddedBrowserView> {
  final _urlController = TextEditingController();
  final _viewportKey = GlobalKey();
  String? _syncedTabId;
  String _lastSyncedUrl = '';
  bool _showActivity = false;

  EmbeddedBrowserController get _ctrl => EmbeddedBrowserController.instance;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onControllerChanged);
    _syncAddressBar();
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onControllerChanged);
    EmbeddedBrowserNative.hideAll();
    _urlController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    _syncAddressBar();
    setState(() {});
    _scheduleFrameSync();
  }

  void _syncAddressBar() {
    final tab = _ctrl.activeTab;
    if (tab == null) {
      if (_syncedTabId != null) {
        _syncedTabId = null;
        _lastSyncedUrl = '';
        _urlController.clear();
      }
      return;
    }
    if (tab.id != _syncedTabId || tab.url != _lastSyncedUrl) {
      _syncedTabId = tab.id;
      _lastSyncedUrl = tab.url;
      _urlController.text = tab.url;
    }
  }

  void _scheduleFrameSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tab = _ctrl.activeTab;
      if (tab == null ||
          tab.detached ||
          _ctrl.overlayActive ||
          _showActivity ||
          !EmbeddedBrowserNative.supported) {
        EmbeddedBrowserNative.hideAll();
        return;
      }
      final box =
          _viewportKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize || !box.attached) {
        EmbeddedBrowserNative.hideAll();
        return;
      }
      final topLeft = box.localToGlobal(Offset.zero);
      final size = box.size;
      // Hide other tabs first, then position active tab.
      for (final other in _ctrl.tabs) {
        if (other.id != tab.id && !other.detached) {
          EmbeddedBrowserNative.setFrame(
            tabId: other.id,
            x: 0,
            y: 0,
            width: 0,
            height: 0,
            visible: false,
          );
        }
      }
      EmbeddedBrowserNative.setFrame(
        tabId: tab.id,
        x: topLeft.dx,
        y: topLeft.dy,
        width: size.width,
        height: size.height,
        visible: size.width > 10 && size.height > 10,
      );
    });
  }

  void _submitUrl(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;
    final tab = _ctrl.activeTab;
    if (tab == null) {
      _ctrl.openTab(text, revealPanel: false);
    } else {
      _ctrl.navigateTab(tab.id, text);
    }
  }

  void _cyclePermission(EmbeddedBrowserTab tab) {
    final next = switch (tab.permission) {
      EmbeddedSharePermission.readWrite => EmbeddedSharePermission.read,
      EmbeddedSharePermission.read => EmbeddedSharePermission.none,
      EmbeddedSharePermission.none => EmbeddedSharePermission.readWrite,
    };
    _ctrl.setTabPermission(tab.id, next);
  }

  @override
  Widget build(BuildContext context) {
    _scheduleFrameSync();
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final colors = themeColors;
    final tabs = _ctrl.tabs;
    final active = _ctrl.activeTab;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Tab strip
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: colors['editorGroupHeader.tabsBackground'],
            border: Border(
              bottom: BorderSide(
                color: colors['widget.border'].withValues(alpha: 0.4),
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final tab in tabs)
                      _BrowserTabChip(
                        tab: tab,
                        selected: tab.id == active?.id,
                        onSelect: () => _ctrl.selectTab(tab.id),
                        onClose: () => _ctrl.closeTab(tab.id),
                      ),
                  ],
                ),
              ),
              _ToolbarIcon(
                icon: Codicons.add,
                tooltip: isZh ? '新建标签页' : 'New Tab',
                onTap: () => _ctrl.openTab(
                  'https://www.google.com',
                  revealPanel: false,
                ),
              ),
              if (widget.onOpenSettings != null)
                _ToolbarIcon(
                  icon: Codicons.settingsGear,
                  tooltip: isZh ? '浏览器设置' : 'Browser Settings',
                  onTap: widget.onOpenSettings!,
                ),
            ],
          ),
        ),
        // Navigation + permission toolbar
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: colors['editor.background'],
            border: Border(
              bottom: BorderSide(
                color: colors['widget.border'].withValues(alpha: 0.4),
              ),
            ),
          ),
          child: Row(
            children: [
              _ToolbarIcon(
                icon: Codicons.arrowLeft,
                tooltip: isZh ? '后退' : 'Back',
                enabled: active != null && active.canGoBack,
                onTap: () {
                  if (active != null) _ctrl.goBack(active.id);
                },
              ),
              _ToolbarIcon(
                icon: Codicons.arrowRight,
                tooltip: isZh ? '前进' : 'Forward',
                enabled: active != null && active.canGoForward,
                onTap: () {
                  if (active != null) _ctrl.goForward(active.id);
                },
              ),
              _ToolbarIcon(
                icon: (active?.loading ?? false)
                    ? Codicons.close
                    : Codicons.refresh,
                tooltip: (active?.loading ?? false)
                    ? (isZh ? '停止' : 'Stop')
                    : (isZh ? '刷新' : 'Reload'),
                enabled: active != null,
                onTap: () {
                  if (active == null) return;
                  if (active.loading) {
                    _ctrl.stopLoading(active.id);
                  } else {
                    _ctrl.reload(active.id);
                  }
                },
              ),
              const SizedBox(width: 4),
              Expanded(
                child: IdeInputBox(
                  controller: _urlController,
                  placeholder: isZh
                      ? '输入网址（如 http://localhost:3000 或 https://...）'
                      : 'Enter URL (e.g. http://localhost:3000 or https://...)',
                  onSubmitted: _submitUrl,
                ),
              ),
              if (active != null) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: isZh
                      ? '点击切换此标签页对智能体的共享权限'
                      : 'Click to cycle agent permission for this tab',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () => _cyclePermission(active),
                    child: Container(
                      height: 24,
                      padding: const EdgeInsets.symmetric(horizontal: 7),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: active.permission == EmbeddedSharePermission.none
                            ? colors['sideBar.background']
                            : colors['button.background'].withValues(
                                alpha: 0.18,
                              ),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: colors['widget.border'].withValues(alpha: 0.6),
                        ),
                      ),
                      child: Text(
                        active.permission.label(zh: isZh),
                        style: TextStyle(
                          fontSize: 11,
                          color: colors['foreground'],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                _ToolbarIcon(
                  icon: active.detached
                      ? Codicons.screenNormal
                      : Codicons.linkExternal,
                  tooltip: active.detached
                      ? (isZh ? '放回工作区' : 'Attach to Workspace')
                      : (isZh ? '弹出独立窗口' : 'Detach Window'),
                  onTap: () => _ctrl.toggleDetach(active.id),
                ),
                if (_ctrl.config.inspectorEnabled)
                  _ToolbarIcon(
                    icon: Codicons.inspect,
                    tooltip: isZh ? '打开网页检查器' : 'Open Web Inspector',
                    onTap: () => _ctrl.openInspector(active.id),
                  ),
                _ToolbarIcon(
                  icon: Codicons.history,
                  tooltip: isZh ? '智能体活动记录' : 'Agent Activity',
                  active: _showActivity,
                  onTap: () {
                    setState(() => _showActivity = !_showActivity);
                    _scheduleFrameSync();
                  },
                ),
              ],
            ],
          ),
        ),
        // Viewport or empty / detached / activity state
        Expanded(
          child: LayoutBuilder(
            builder: (context, _) {
              _scheduleFrameSync();
              if (active == null) {
                return _EmptyBrowserState(
                  isZh: isZh,
                  onOpen: (url) => _ctrl.openTab(url, revealPanel: false),
                );
              }
              if (_showActivity) {
                return _ActivityPanel(tab: active, isZh: isZh);
              }
              if (active.detached) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Codicons.globe,
                        size: 28,
                        color: colors['descriptionForeground'],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        isZh
                            ? '此标签页正在独立窗口中运行'
                            : 'This tab is open in a separate window',
                        style: TextStyle(
                          color: colors['foreground'],
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 10),
                      IdeButton(
                        label: isZh ? '放回工作区' : 'Attach Back',
                        onPressed: () => _ctrl.toggleDetach(active.id),
                      ),
                    ],
                  ),
                );
              }
              if (!EmbeddedBrowserNative.supported) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          active.url,
                          style: TextStyle(
                            color: colors['foreground'],
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          isZh
                              ? '嵌入式 WKWebView 需要运行在已打包 libAyteNative.dylib 的 macOS 构建中。'
                              : 'Embedded WKWebView requires the macOS build with libAyteNative.dylib.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colors['descriptionForeground'],
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 12),
                        IdeButton(
                          label: isZh ? '在系统浏览器打开' : 'Open in System Browser',
                          icon: Codicons.linkExternal,
                          onPressed: () => unawaited(openExternal(active.url)),
                        ),
                      ],
                    ),
                  ),
                );
              }
              return Container(
                key: _viewportKey,
                color: colors['editor.background'],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _BrowserTabChip extends StatelessWidget {
  const _BrowserTabChip({
    required this.tab,
    required this.selected,
    required this.onSelect,
    required this.onClose,
  });

  final EmbeddedBrowserTab tab;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    return GestureDetector(
      onTap: onSelect,
      child: Container(
        margin: const EdgeInsets.only(right: 4, top: 3, bottom: 3),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        constraints: const BoxConstraints(maxWidth: 180),
        decoration: BoxDecoration(
          color: selected ? colors['editor.background'] : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: selected
                ? colors['widget.border'].withValues(alpha: 0.7)
                : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Codicons.globe,
              size: 12,
              color: selected
                  ? colors['foreground']
                  : colors['descriptionForeground'],
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                tab.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: selected
                      ? colors['foreground']
                      : colors['descriptionForeground'],
                ),
              ),
            ),
            const SizedBox(width: 4),
            InkWell(
              onTap: onClose,
              child: Icon(
                Codicons.close,
                size: 11,
                color: colors['descriptionForeground'],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolbarIcon extends StatelessWidget {
  const _ToolbarIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: enabled ? onTap : null,
        child: Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? colors['toolbar.hoverBackground']
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            icon,
            size: 14,
            color: enabled
                ? colors['foreground']
                : colors['descriptionForeground'].withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}

class _EmptyBrowserState extends StatelessWidget {
  const _EmptyBrowserState({required this.isZh, required this.onOpen});

  final bool isZh;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Codicons.globe,
              size: 32,
              color: colors['descriptionForeground'],
            ),
            const SizedBox(height: 10),
            Text(
              isZh ? 'Ayte 内置浏览器' : 'Ayte Built-in Browser',
              style: TextStyle(
                color: colors['foreground'],
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              isZh
                  ? '在地址栏输入网址，或点击下方快捷入口打开预览页；智能体可直接读取与操作已共享标签页。'
                  : 'Enter a URL above or pick a quick shortcut. Agents can inspect and interact with shared tabs.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors['descriptionForeground'],
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                IdeButton(
                  label: 'localhost:3000',
                  secondary: true,
                  onPressed: () => onOpen('http://localhost:3000'),
                ),
                IdeButton(
                  label: 'localhost:5173',
                  secondary: true,
                  onPressed: () => onOpen('http://localhost:5173'),
                ),
                IdeButton(
                  label: 'Google',
                  secondary: true,
                  onPressed: () => onOpen('https://www.google.com'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivityPanel extends StatelessWidget {
  const _ActivityPanel({required this.tab, required this.isZh});

  final EmbeddedBrowserTab tab;
  final bool isZh;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    if (tab.activities.isEmpty) {
      return Center(
        child: Text(
          isZh ? '此标签页暂无智能体操作记录。' : 'No agent activity recorded on this tab yet.',
          style: TextStyle(color: colors['descriptionForeground'], fontSize: 12),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: tab.activities.length,
      separatorBuilder: (_, _) => Divider(
        height: 1,
        color: colors['widget.border'].withValues(alpha: 0.4),
      ),
      itemBuilder: (context, i) {
        final item = tab.activities[i];
        final hh = item.at.hour.toString().padLeft(2, '0');
        final mm = item.at.minute.toString().padLeft(2, '0');
        final ss = item.at.second.toString().padLeft(2, '0');
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Text(
                '$hh:$mm:$ss',
                style: TextStyle(
                  color: colors['descriptionForeground'],
                  fontSize: 11,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.summary,
                  style: TextStyle(color: colors['foreground'], fontSize: 12),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
