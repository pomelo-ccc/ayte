import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../browser/browser_bridge.dart';
import '../../browser/browser_tools.dart' show BrowserHistory;
import '../../browser/embedded/embedded_browser_controller.dart';
import '../../browser/embedded/embedded_browser_settings.dart';
import '../../browser/extension_store.dart';
import '../../ide/ide_button.dart';
import '../../ide/ide_dialog.dart';
import '../../ide/ide_input.dart';
import '../../ide/ide_menu.dart';
import '../../l10n/l10n.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import '../user_settings.dart';
import 'data_dir_page.dart';
import 'settings_dropdown.dart';
import 'settings_widgets.dart';

/// Settings → Browser: configures both Ayte's Built-in Workspace Browser
/// (embedded WKWebView tabs, link open routing, site rules, per-site share
/// permissions, JS execution policy, profiles) and the external Chrome
/// extension bridge ([BrowserBridge]).
class BrowserSettingsPage extends StatefulWidget {
  const BrowserSettingsPage({
    super.key,
    this.settings,
    this.browsers,
    this.history,
  });

  /// settings.json; none under test, where the choice is not kept.
  final UserSettings? settings;

  /// The bridge to the browsers; the app's by default.
  final BrowserBridge? browsers;
  BrowserBridge get bridge => browsers ?? BrowserBridge.instance;

  /// The debugging history; the app's by default.
  final BrowserHistory? history;
  BrowserHistory get kept => history ?? BrowserHistory.instance;

  /// Asks, then deletes the history.
  static Future<void> clearHistory(
    BuildContext context,
    BrowserHistory history,
  ) async {
    final l10n = context.l10n;
    final chosen = await showIdeDialog(
      context,
      message: l10n.browserHistoryClearConfirm,
      detail: l10n.browserHistoryClearDetail,
      buttons: [l10n.browserHistoryClear],
    );
    if (chosen == 0) await history.clear();
  }

  /// What the status group says, a row each: the browsers connected and
  /// those whose extension speaks another protocol, or why there is none.
  @visibleForTesting
  static List<(String, String?)> status(
    AppLocalizations l10n,
    BrowserBridge bridge,
  ) {
    if (bridge.otherApp) return [(l10n.browserOtherApp, null)];
    final browsers = bridge.browsers;
    final mismatched = bridge.mismatched;
    if (browsers.isEmpty && mismatched.isEmpty) {
      return [
        bridge.connectedBefore
            ? (
                l10n.browserSettingsNotRunning,
                l10n.browserSettingsNotRunningDescription,
              )
            : (
                l10n.browserSettingsNotInstalled,
                l10n.browserSettingsNotInstalledDescription,
              ),
        if (bridge.sandboxedBrowsers)
          (
            l10n.browserSettingsSandboxed,
            l10n.browserSettingsSandboxedDescription,
          ),
      ];
    }
    return [
      for (final browser in browsers)
        (
          l10n.browserSettingsConnected(browser.browser ?? ''),
          l10n.browserSettingsExtensionVersion(browser.version ?? '?'),
        ),
      for (final browser in browsers)
        if (browser.fileAccess == false)
          (
            l10n.browserSettingsNoFileAccess,
            l10n.browserSettingsNoFileAccessDescription,
          ),
      for (final browser in mismatched)
        (
          l10n.browserSettingsIncompatible(browser.browser ?? ''),
          browser.protocol < BrowserBridge.protocol
              ? l10n.browserSettingsExtensionOld
              : l10n.browserSettingsAppOld,
        ),
    ];
  }

  @override
  State<BrowserSettingsPage> createState() => _BrowserSettingsPageState();
}

class _BrowserSettingsPageState extends State<BrowserSettingsPage> {
  final _rulePatternController = TextEditingController();
  final _profileNameController = TextEditingController();
  SiteRuleAction _newRuleAction = SiteRuleAction.embedded;
  String? _ruleError;
  String? _profileError;

  BrowserBridge get bridge => widget.bridge;
  BrowserHistory get kept => widget.kept;
  EmbeddedBrowserController get _embedded => EmbeddedBrowserController.instance;

  @override
  void dispose() {
    _rulePatternController.dispose();
    _profileNameController.dispose();
    super.dispose();
  }

  Future<void> _updateEmbedded(EmbeddedBrowserConfig next) =>
      _embedded.saveConfig(next, settings: widget.settings);

  void _detailed(bool on) {
    kept.detailed = on;
    final settings = widget.settings;
    if (settings == null) return;
    unawaited(
      settings.update(BrowserHistory.detailedKey, on ? true : null).catchError((
        Object error,
      ) {
        debugPrint('${BrowserHistory.detailedKey} not kept: $error');
      }),
    );
  }

  void _enableBridge(bool on) {
    bridge.enabled = on;
    final settings = widget.settings;
    if (settings == null) return;
    unawaited(
      settings.update(BrowserBridge.settingKey, on ? null : false).catchError((
        Object error,
      ) {
        debugPrint('${BrowserBridge.settingKey} not kept: $error');
      }),
    );
  }

  void _addSiteRule(bool isZh) {
    final pat = _rulePatternController.text.trim().toLowerCase();
    if (!SiteRule.isValidPattern(pat)) {
      setState(() {
        _ruleError = isZh
            ? '无效模式（示例：localhost:3000、*.example.com、*）'
            : 'Invalid pattern (e.g. localhost:3000, *.example.com, *)';
      });
      return;
    }
    if (_embedded.config.siteRules.any((r) => r.pattern == pat)) {
      setState(() {
        _ruleError = isZh ? '规则模式已存在' : 'Pattern already exists';
      });
      return;
    }
    setState(() => _ruleError = null);
    final next = [
      ..._embedded.config.siteRules,
      SiteRule(pattern: pat, action: _newRuleAction),
    ];
    _rulePatternController.clear();
    unawaited(_updateEmbedded(_embedded.config.copyWith(siteRules: next)));
  }

  void _addProfile(bool isZh) {
    final name = _profileNameController.text.trim();
    if (name.isEmpty) return;
    if (_embedded.config.profiles.any(
      (p) => p.name.toLowerCase() == name.toLowerCase(),
    )) {
      setState(() {
        _profileError = isZh ? '配置文件名称不能重复' : 'Profile name already exists';
      });
      return;
    }
    setState(() => _profileError = null);
    final id = 'profile_${DateTime.now().millisecondsSinceEpoch}';
    final next = [
      ..._embedded.config.profiles,
      BrowserProfile(id: id, name: name),
    ];
    _profileNameController.clear();
    unawaited(_updateEmbedded(_embedded.config.copyWith(profiles: next)));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([bridge, kept, _embedded]),
    builder: (context, _) => _page(context),
  );

  Widget _page(BuildContext context) {
    final l10n = context.l10n;
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final cfg = _embedded.config;

    return SettingsPage(
      title: l10n.settingsSectionBrowser,
      description: isZh
          ? '管理工作区内置浏览器标签页（共享权限、站点规则、配置文件）及外部 Chrome 扩展桥接。'
          : 'Configure Ayte\'s built-in workspace browser tabs and external Chrome extension bridge.',
      children: [
        // ── Existing External Browser Extension Bridge Section ──
        if (!bridge.supported)
          SettingsCard(
            children: [SettingsRow(label: l10n.browserSettingsUnsupported)],
          )
        else ...[
          SettingsCard(
            children: [
              SettingsSwitchRow(
                label: l10n.browserSettingsEnabled,
                description: l10n.browserSettingsEnabledDescription,
                value: bridge.enabled,
                onChanged: _enableBridge,
              ),
            ],
          ),
          if (bridge.enabled)
            SettingsGroup(
              title: l10n.browserSettingsStatus,
              children: [
                for (final (label, description)
                    in BrowserSettingsPage.status(l10n, bridge))
                  SettingsRow(label: label, description: description),
              ],
            ),
          if (bridge.enabled)
            SettingsGroup(
              title: l10n.browserHistoryTitle,
              description: l10n.browserHistoryDescription,
              children: [
                SettingsSwitchRow(
                  label: l10n.browserHistoryDetailed,
                  description: l10n.browserHistoryDetailedDescription,
                  value: kept.detailed,
                  onChanged: _detailed,
                ),
                SettingsRow(
                  label: l10n.browserHistorySize(
                    BrowserHistory.sizeText(kept.size ?? 0),
                  ),
                  description: kept.folder,
                  trailing: SettingsButtons(
                    children: [
                      if (DataDirectoryPage.canReveal)
                        IdeButton(
                          label: l10n.revealInFileManager,
                          secondary: true,
                          onPressed: () {
                            Directory(kept.folder).createSync(recursive: true);
                            unawaited(
                              DataDirectoryPage.revealFolder(kept.folder),
                            );
                          },
                        ),
                      IdeButton(
                        label: l10n.browserHistoryClear,
                        secondary: true,
                        onPressed: (kept.size ?? 0) == 0
                            ? null
                            : () => unawaited(
                                BrowserSettingsPage.clearHistory(context, kept),
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
        ],
        SettingsGroup(
          title: l10n.browserSettingsInstall,
          children: [
            SettingsRow(
              label: l10n.browserSettingsStore,
              description: l10n.browserSettingsStoreDescription,
              trailing: IdeButton(
                label: l10n.browserSettingsStoreOpen,
                icon: Codicons.linkExternal,
                onPressed: () => unawaited(ExtensionStore.openPage()),
              ),
            ),
            SettingsRow(
              label: l10n.browserSettingsUnpacked,
              description: l10n.browserSettingsUnpackedDescription,
              trailing: IdeButton(
                label: l10n.browserSettingsUnpackedDownload,
                icon: Codicons.cloudDownload,
                secondary: true,
                onPressed: () => unawaited(ExtensionStore.openZip()),
              ),
            ),
          ],
        ),

        // ── Built-in Embedded Browser Section ──
        SettingsGroup(
          title: isZh ? '工作区内置浏览器' : 'Built-in Workspace Browser',
          description: isZh
              ? '从会话、工具结果和终端打开的网页会直接显示在工作区右侧「浏览器」标签页中。'
              : 'Links from chat, tools, and terminal can open directly as tabs in Ayte\'s workspace Browser panel.',
          children: [
            SettingsSwitchRow(
              label: isZh ? '启用内置浏览器' : 'Enable Built-in Browser',
              description: isZh
                  ? '在工作区面板中提供原生 WKWebView 网页标签页（按住 ⌘ 点击链接可临时切换打开方式）。'
                  : 'Provides native WKWebView tabs inside the workspace panel (hold ⌘/Ctrl to invert link target).',
              value: cfg.enabled,
              onChanged: (v) =>
                  unawaited(_updateEmbedded(cfg.copyWith(enabled: v))),
            ),
            Opacity(
              opacity: cfg.enabled ? 1 : 0.45,
              child: IgnorePointer(
                ignoring: !cfg.enabled,
                child: SettingsSwitchRow(
                  label: isZh
                      ? '允许智能体读取和操作内置浏览器'
                      : 'Allow Agents to Read & Operate Built-in Browser',
                  description: isZh
                      ? '向智能体注入 embedded_browser_* 工具（受每个标签页的共享权限约束）。'
                      : 'Exposes embedded_browser_* tools to agents, bounded by per-tab permissions.',
                  value: cfg.agentReadWriteEnabled,
                  onChanged: (v) => unawaited(
                    _updateEmbedded(cfg.copyWith(agentReadWriteEnabled: v)),
                  ),
                ),
              ),
            ),
            Opacity(
              opacity: (cfg.enabled && cfg.agentReadWriteEnabled) ? 1 : 0.45,
              child: IgnorePointer(
                ignoring: !(cfg.enabled && cfg.agentReadWriteEnabled),
                child: SettingsSwitchRow(
                  label: isZh
                      ? '允许智能体在内置浏览器中执行代码（JS）'
                      : 'Allow Agents to Execute JavaScript',
                  description: isZh
                      ? '默认关闭。依赖上方「读取和操作」开关，且标签页需处于「读取并操作」权限。'
                      : 'Off by default. Requires Read & Operate enabled above and per-tab operate permission.',
                  value: cfg.agentEvalJsEnabled,
                  onChanged: (v) => unawaited(
                    _updateEmbedded(cfg.copyWith(agentEvalJsEnabled: v)),
                  ),
                ),
              ),
            ),
            SettingsRow(
              label: isZh ? '默认共享权限' : 'Default Share Permission',
              description: isZh
                  ? '新打开的内置浏览器标签页默认对智能体开放的权限（工具栏可逐页修改）。'
                  : 'Default permission granted to agents on newly opened tabs.',
              trailing: SettingsDropdown(
                current: cfg.defaultSharePermission.label(zh: isZh),
                semanticLabel: isZh ? '默认共享权限' : 'Default Share Permission',
                entries: () => [
                  for (final perm in EmbeddedSharePermission.values)
                    IdeMenuAction(
                      perm.label(zh: isZh),
                      checked: cfg.defaultSharePermission == perm,
                      onSelected: () => unawaited(
                        _updateEmbedded(
                          cfg.copyWith(defaultSharePermission: perm),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SettingsRow(
              label: isZh ? '在页面上运行代码策略' : 'JavaScript Execution Policy',
              description: isZh
                  ? '「每次都问我」会把脚本原文弹到会话里等你确认。'
                  : '"Ask every time" prompts you with the full JS snippet before running.',
              trailing: SettingsDropdown(
                current: cfg.jsExecutionPolicy == JsExecutionPolicy.ask
                    ? (isZh ? '每次都问我' : 'Ask Every Time')
                    : (isZh ? '静默执行（默认）' : 'Run Silently (Default)'),
                semanticLabel: isZh ? '在页面上运行代码策略' : 'JavaScript Execution Policy',
                entries: () => [
                  IdeMenuAction(
                    isZh ? '静默执行（默认）' : 'Run Silently (Default)',
                    checked: cfg.jsExecutionPolicy == JsExecutionPolicy.silent,
                    onSelected: () => unawaited(
                      _updateEmbedded(
                        cfg.copyWith(
                          jsExecutionPolicy: JsExecutionPolicy.silent,
                        ),
                      ),
                    ),
                  ),
                  IdeMenuAction(
                    isZh ? '每次都问我' : 'Ask Every Time',
                    checked: cfg.jsExecutionPolicy == JsExecutionPolicy.ask,
                    onSelected: () => unawaited(
                      _updateEmbedded(
                        cfg.copyWith(jsExecutionPolicy: JsExecutionPolicy.ask),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SettingsRow(
              label: isZh ? '标签页承载方式' : 'Tab Hosting Mode',
              trailing: SettingsDropdown(
                current: switch (cfg.tabHostMode) {
                  BrowserTabHostMode.auto => isZh ? '自动（默认）' : 'Auto (Default)',
                  BrowserTabHostMode.embedded =>
                    isZh ? '嵌入工作区' : 'Embedded in Workspace',
                  BrowserTabHostMode.detached =>
                    isZh ? '独立窗口' : 'Separate Window',
                },
                semanticLabel: isZh ? '标签页承载方式' : 'Tab Hosting Mode',
                entries: () => [
                  for (final mode in BrowserTabHostMode.values)
                    IdeMenuAction(
                      switch (mode) {
                        BrowserTabHostMode.auto =>
                          isZh ? '自动（默认）' : 'Auto (Default)',
                        BrowserTabHostMode.embedded =>
                          isZh ? '嵌入工作区' : 'Embedded in Workspace',
                        BrowserTabHostMode.detached =>
                          isZh ? '独立窗口' : 'Separate Window',
                      },
                      checked: cfg.tabHostMode == mode,
                      onSelected: () => unawaited(
                        _updateEmbedded(cfg.copyWith(tabHostMode: mode)),
                      ),
                    ),
                ],
              ),
            ),
            SettingsRow(
              label: isZh ? '本机服务地址' : 'Local Dev Server URLs',
              trailing: SettingsDropdown(
                current: switch (cfg.localServerAction) {
                  LocalServerAction.ignore => isZh ? '什么都不做' : 'Do Nothing',
                  LocalServerAction.notify =>
                    isZh ? '通知我（默认）' : 'Notify Me (Default)',
                  LocalServerAction.openTab =>
                    isZh ? '直接打开标签页' : 'Open Tab Automatically',
                },
                semanticLabel: isZh ? '本机服务地址' : 'Local Dev Server URLs',
                entries: () => [
                  for (final act in LocalServerAction.values)
                    IdeMenuAction(
                      switch (act) {
                        LocalServerAction.ignore =>
                          isZh ? '什么都不做' : 'Do Nothing',
                        LocalServerAction.notify =>
                          isZh ? '通知我（默认）' : 'Notify Me (Default)',
                        LocalServerAction.openTab =>
                          isZh ? '直接打开标签页' : 'Open Tab Automatically',
                      },
                      checked: cfg.localServerAction == act,
                      onSelected: () => unawaited(
                        _updateEmbedded(cfg.copyWith(localServerAction: act)),
                      ),
                    ),
                ],
              ),
            ),
            SettingsSwitchRow(
              label: isZh ? 'HTML 文件走内置预览' : 'Preview HTML Files in Built-in Browser',
              value: cfg.htmlPreviewInEmbedded,
              onChanged: (v) => unawaited(
                _updateEmbedded(cfg.copyWith(htmlPreviewInEmbedded: v)),
              ),
            ),
            SettingsSwitchRow(
              label: isZh ? '网页检查器（DevTools）' : 'Web Inspector',
              description: isZh
                  ? '对此后打开的标签页生效，支持右键检查元素。'
                  : 'Takes effect for newly opened tabs.',
              value: cfg.inspectorEnabled,
              onChanged: (v) =>
                  unawaited(_updateEmbedded(cfg.copyWith(inspectorEnabled: v))),
            ),
            SettingsSwitchRow(
              label: isZh ? 'Google 登录兼容' : 'Google Sign-in Compatibility',
              description: isZh
                  ? '仅在 accounts.google.com / accounts.youtube.com 登录页自动切换兼容 UA。'
                  : 'Uses compatible UA only on Google sign-in hosts.',
              value: cfg.googleSignInCompat,
              onChanged: (v) => unawaited(
                _updateEmbedded(cfg.copyWith(googleSignInCompat: v)),
              ),
            ),
          ],
        ),
        if (cfg.enabled)
          SettingsGroup(
            title: isZh ? '链接在哪里打开' : 'Where Links Open',
            description: isZh
                ? '按链接来源选择默认打开方式；按住 ⌘/Ctrl 点击可临时切换。'
                : 'Choose default browser per link source; hold ⌘/Ctrl to invert.',
            children: [
              for (final src in LinkSource.values)
                SettingsRow(
                  label: src.label(zh: isZh),
                  trailing: SettingsDropdown(
                    current:
                        (cfg.linkTargets[src] ?? LinkOpenTarget.embedded) ==
                            LinkOpenTarget.embedded
                        ? (isZh ? '内置浏览器' : 'Built-in Browser')
                        : (isZh ? '系统浏览器' : 'System Browser'),
                    semanticLabel: src.label(zh: isZh),
                    entries: () => [
                      IdeMenuAction(
                        isZh ? '内置浏览器' : 'Built-in Browser',
                        checked:
                            (cfg.linkTargets[src] ?? LinkOpenTarget.embedded) ==
                            LinkOpenTarget.embedded,
                        onSelected: () {
                          final next = {
                            ...cfg.linkTargets,
                            src: LinkOpenTarget.embedded,
                          };
                          unawaited(
                            _updateEmbedded(cfg.copyWith(linkTargets: next)),
                          );
                        },
                      ),
                      IdeMenuAction(
                        isZh ? '系统浏览器' : 'System Browser',
                        checked:
                            (cfg.linkTargets[src] ?? LinkOpenTarget.embedded) ==
                            LinkOpenTarget.system,
                        onSelected: () {
                          final next = {
                            ...cfg.linkTargets,
                            src: LinkOpenTarget.system,
                          };
                          unawaited(
                            _updateEmbedded(cfg.copyWith(linkTargets: next)),
                          );
                        },
                      ),
                    ],
                  ),
                ),
            ],
          ),
        if (cfg.enabled)
          SettingsGroup(
            title: isZh ? '站点规则' : 'Site Rules',
            description: isZh
                ? '按主机名、*.example.com 或 *（可带 :端口）覆盖默认打开方式，最具体的规则优先。'
                : 'Override link behavior by host, *.example.com, or * (optional :port). Most specific match wins.',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: IdeInputBox(
                            controller: _rulePatternController,
                            placeholder: 'localhost:3000 / *.example.com',
                            onSubmitted: (_) => _addSiteRule(isZh),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SettingsDropdown(
                          current: _newRuleAction.label(zh: isZh),
                          semanticLabel: isZh ? '站点规则动作' : 'Site Rule Action',
                          entries: () => [
                            for (final a in SiteRuleAction.values)
                              IdeMenuAction(
                                a.label(zh: isZh),
                                checked: _newRuleAction == a,
                                onSelected: () =>
                                    setState(() => _newRuleAction = a),
                              ),
                          ],
                        ),
                        const SizedBox(width: 8),
                        IdeButton(
                          label: isZh ? '添加' : 'Add',
                          onPressed: () => _addSiteRule(isZh),
                        ),
                      ],
                    ),
                    if (_ruleError != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        _ruleError!,
                        style: TextStyle(
                          color: themeColors['editorError.foreground'],
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              for (final rule in cfg.siteRules)
                SettingsRow(
                  label: rule.pattern,
                  description: rule.action.label(zh: isZh),
                  trailing: IdeButton(
                    label: isZh ? '删除' : 'Remove',
                    secondary: true,
                    onPressed: () {
                      final next = [
                        for (final r in cfg.siteRules)
                          if (r.pattern != rule.pattern) r,
                      ];
                      unawaited(
                        _updateEmbedded(cfg.copyWith(siteRules: next)),
                      );
                    },
                  ),
                ),
            ],
          ),
        if (cfg.enabled)
          SettingsGroup(
            title: isZh ? '配置文件与浏览数据' : 'Profiles & Browsing Data',
            description: isZh
                ? '每个配置文件拥有独立的 Cookie 与站点登录态（macOS 14+ 支持独立存储）。'
                : 'Each profile keeps isolated cookies and site storage (macOS 14+).',
            children: [
              SettingsRow(
                label: isZh ? '新标签页默认配置文件' : 'Default Profile for New Tabs',
                trailing: SettingsDropdown(
                  current: () {
                    final found = cfg.profiles.firstWhere(
                      (p) => p.id == cfg.defaultProfileId,
                      orElse: () => cfg.profiles.first,
                    );
                    return found.isDefault
                        ? (isZh ? '默认' : 'Default')
                        : found.name;
                  }(),
                  semanticLabel: isZh
                      ? '新标签页默认配置文件'
                      : 'Default Profile for New Tabs',
                  entries: () => [
                    for (final p in cfg.profiles)
                      IdeMenuAction(
                        p.isDefault ? (isZh ? '默认' : 'Default') : p.name,
                        checked: cfg.defaultProfileId == p.id,
                        onSelected: () => unawaited(
                          _updateEmbedded(
                            cfg.copyWith(defaultProfileId: p.id),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: IdeInputBox(
                            controller: _profileNameController,
                            placeholder: isZh
                                ? '新建配置文件名称（如：工作、测试号）'
                                : 'New profile name (e.g. Work, Staging)',
                            onSubmitted: (_) => _addProfile(isZh),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IdeButton(
                          label: isZh ? '添加配置文件' : 'Add Profile',
                          onPressed: () => _addProfile(isZh),
                        ),
                      ],
                    ),
                    if (_profileError != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        _profileError!,
                        style: TextStyle(
                          color: themeColors['editorError.foreground'],
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              for (final prof in cfg.profiles)
                SettingsRow(
                  label: prof.isDefault
                      ? (isZh ? '默认' : 'Default')
                      : prof.name,
                  trailing: SettingsButtons(
                    children: [
                      IdeButton(
                        label: isZh ? '清除数据' : 'Clear Data',
                        secondary: true,
                        onPressed: () async {
                          final ok = await showIdeDialog(
                            context,
                            message: isZh
                                ? '清除此配置文件的浏览数据？'
                                : 'Clear browsing data for this profile?',
                            detail: isZh
                                ? '会删除 Cookie、缓存与站点存储，各网站登录状态将失效。'
                                : 'Deletes cookies, cache, and site storage. Active logins will be signed out.',
                            buttons: [isZh ? '清除' : 'Clear'],
                          );
                          if (ok == 0) _embedded.clearProfileData(prof.id);
                        },
                      ),
                      if (!prof.isDefault)
                        IdeButton(
                          label: isZh ? '删除' : 'Delete',
                          secondary: true,
                          onPressed: () => unawaited(
                            _embedded.deleteProfile(
                              prof.id,
                              settings: widget.settings,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// Said above every settings page while the debugging history is over
/// [BrowserHistory.warnSize]: how much it takes, to clear it, or to open
/// [open] (Settings → Browser).
class BrowserHistoryNotice extends StatelessWidget {
  const BrowserHistoryNotice({super.key, required this.open, this.history});

  final VoidCallback open;

  /// The debugging history; the app's by default.
  final BrowserHistory? history;

  @override
  Widget build(BuildContext context) {
    final kept = history ?? BrowserHistory.instance;
    return ListenableBuilder(
      listenable: kept,
      builder: (context, _) {
        if (!kept.tooLarge) return const SizedBox.shrink();
        final l10n = context.l10n;
        final colors = themeColors;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
            decoration: BoxDecoration(
              color: colors['inputValidation.warningBackground'],
              border: Border.all(
                color: colors['inputValidation.warningBorder'],
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Icon(
                  Codicons.warning,
                  size: 14,
                  color: colors['editorWarning.foreground'],
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.browserHistoryTooLarge(
                          BrowserHistory.sizeText(kept.size ?? 0),
                        ),
                        style: TextStyle(
                          color: colors['foreground'],
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        l10n.browserHistoryTooLargeDetail,
                        style: TextStyle(
                          color: colors['descriptionForeground'],
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IdeButton(
                  label: l10n.browserHistoryClear,
                  secondary: true,
                  onPressed: () =>
                      unawaited(BrowserSettingsPage.clearHistory(context, kept)),
                ),
                const SizedBox(width: 6),
                IdeButton(
                  label: l10n.browserHistoryOpenSettings,
                  secondary: true,
                  onPressed: open,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
