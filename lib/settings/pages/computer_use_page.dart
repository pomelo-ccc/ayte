import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../computer_use/computer_use_bubble.dart';
import '../../computer_use/computer_use_controller.dart';
import '../../computer_use/computer_use_native.dart';
import '../../computer_use/computer_use_settings.dart';
import '../../computer_use/cua_driver_service.dart';
import '../../ide/ide_button.dart';
import '../../ide/ide_dialog.dart';
import '../../ide/ide_input.dart';
import '../../ide/ide_menu.dart';
import '../../theme/codicons.dart';
import '../user_settings.dart';
import 'settings_dropdown.dart';
import 'settings_widgets.dart';

/// Settings → Computer Use: full control panel for open-source `cua-driver`,
/// macOS permissions, per-window share boundaries, never-share blacklist,
/// global emergency stop hotkey, floating stop bar, and input delivery policy.
class ComputerUseSettingsPage extends StatefulWidget {
  const ComputerUseSettingsPage({super.key, this.settings});

  final UserSettings? settings;

  @override
  State<ComputerUseSettingsPage> createState() =>
      _ComputerUseSettingsPageState();
}

class _ComputerUseSettingsPageState extends State<ComputerUseSettingsPage> {
  final _addAppController = TextEditingController();
  final _hotkeyController = TextEditingController();
  Timer? _permTimer;

  ComputerUseController get _ctrl => ComputerUseController.instance;
  CuaDriverService get _driver => CuaDriverService.instance;

  @override
  void initState() {
    super.initState();
    _hotkeyController.text = _ctrl.config.stopHotkey;
    _ctrl.refreshPermissions();
    unawaited(_driver.refresh());
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      _permTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _ctrl.refreshPermissions(),
      );
    }
  }

  @override
  void dispose() {
    _permTimer?.cancel();
    _addAppController.dispose();
    _hotkeyController.dispose();
    super.dispose();
  }

  Future<void> _update(ComputerUseConfig next) =>
      _ctrl.saveConfig(next, settings: widget.settings);

  void _addNeverShare() {
    final raw = _addAppController.text.trim();
    if (raw.isEmpty) return;
    final list = [..._ctrl.config.neverShareApps];
    if (!list.any((e) => e.toLowerCase() == raw.toLowerCase())) {
      list.add(raw);
      unawaited(_update(_ctrl.config.copyWith(neverShareApps: list)));
    }
    _addAppController.clear();
  }

  Future<void> _restoreDefaults(BuildContext context, bool isZh) async {
    final current = _ctrl.config.neverShareApps.toSet();
    final defaults = defaultMacNeverShareApps.toSet();
    final removedCustom = current.difference(defaults).length;
    final restoredBuiltIn = defaults.difference(current).length;
    final chosen = await showIdeDialog(
      context,
      message: isZh ? '恢复默认永不共享名单？' : 'Restore default never-share list?',
      detail: isZh
          ? '将清除 $removedCustom 条自定义项，并恢复 $restoredBuiltIn 条内置保护项。'
          : 'This will remove $removedCustom custom item(s) and restore $restoredBuiltIn built-in protected app(s).',
      buttons: [isZh ? '恢复默认' : 'Restore'],
    );
    if (chosen == 0) {
      await _update(
        _ctrl.config.copyWith(neverShareApps: defaultMacNeverShareApps),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    return ListenableBuilder(
      listenable: Listenable.merge([_ctrl, _driver]),
      builder: (context, _) {
        final cfg = _ctrl.config;
        final perms = _ctrl.permissions;
        return SettingsPage(
          title: isZh ? '电脑操作' : 'Computer Use',
          description: isZh
              ? '让智能体查看并操作你明确共享给它的桌面窗口（底层基于开源 cua-driver）。'
              : 'Let agents inspect and operate desktop windows you explicitly share (powered by open-source cua-driver).',
          children: [
            SettingsCard(
              children: [
                SettingsSwitchRow(
                  label: isZh ? '启用电脑操作' : 'Enable Computer Use',
                  description: isZh
                      ? '开启后可从状态栏选择要共享的窗口；未共享的窗口智能体永远无法读取。'
                      : 'Allows sharing specific windows with agents. Unshared windows stay invisible.',
                  value: cfg.enabled,
                  onChanged: (v) =>
                      unawaited(_update(cfg.copyWith(enabled: v))),
                ),
                Opacity(
                  opacity: cfg.enabled ? 1 : 0.45,
                  child: IgnorePointer(
                    ignoring: !cfg.enabled,
                    child: SettingsSwitchRow(
                      label: isZh
                          ? '向智能体注入「查看和操作桌面窗口」工具'
                          : 'Expose Desktop Window Tools to Agents',
                      description: isZh
                          ? '需与上方总开关同时开启，下次启动会话时向智能体注入 computer_* 工具。'
                          : 'Requires Computer Use enabled above. Takes effect on next agent session start.',
                      value: cfg.agentToolEnabled,
                      onChanged: (v) => unawaited(
                        _update(cfg.copyWith(agentToolEnabled: v)),
                      ),
                    ),
                  ),
                ),
                if (cfg.enabled)
                  SettingsRow(
                    label: isZh ? '共享窗口管理' : 'Shared Windows',
                    description: _ctrl.hasActiveShares
                        ? (isZh
                              ? '当前已共享 ${_ctrl.sharedCount} 个窗口${_ctrl.fullScreenShared ? " + 整屏" : ""}。'
                              : '${_ctrl.sharedCount} window(s) currently shared${_ctrl.fullScreenShared ? " + full screen" : ""}.')
                        : (isZh
                              ? '当前未共享任何桌面窗口。'
                              : 'No desktop windows are currently shared.'),
                    trailing: SettingsButtons(
                      children: [
                        IdeButton(
                          label: isZh ? '共享窗口…' : 'Share Windows…',
                          icon: Codicons.vm,
                          onPressed: () =>
                              unawaited(showComputerUseShareDialog(context)),
                        ),
                        if (_ctrl.hasActiveShares)
                          IdeButton(
                            label: isZh ? '停止共享' : 'Stop Sharing',
                            secondary: true,
                            onPressed: _ctrl.stopAllSharing,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
            SettingsGroup(
              title: isZh ? '开源驱动（cua-driver）' : 'Open-Source Driver (cua-driver)',
              description: isZh
                  ? '电脑操作使用开源项目 trycua/cua 的 cua-driver 执行后台无抢占读取与输入。'
                  : 'Powered by the open-source trycua/cua driver for background window inspection and input delivery.',
              children: [
                SettingsRow(
                  label: switch (_driver.state) {
                    CuaDriverState.installed =>
                      isZh
                          ? '已安装 (${_driver.version ?? "ready"}) · ${_driver.daemonRunning ? "服务运行中" : "按需启动"}'
                          : 'Installed (${_driver.version ?? "ready"}) · ${_driver.daemonRunning ? "Daemon running" : "Starts on demand"}',
                    CuaDriverState.installing =>
                      isZh ? '正在安装 cua-driver…' : 'Installing cua-driver…',
                    CuaDriverState.error =>
                      isZh
                          ? '驱动异常：${_driver.lastError ?? ""}'
                          : 'Driver error: ${_driver.lastError ?? ""}',
                    _ => isZh ? '未安装' : 'Not installed',
                  },
                  description:
                      _driver.binaryPath ??
                      (isZh
                          ? '点击安装会自动从官方开源源下载到 ~/.local/bin/cua-driver。'
                          : 'Click Install to fetch the open-source binary into ~/.local/bin/cua-driver.'),
                  trailing: SettingsButtons(
                    children: [
                      if (_driver.isInstalled) ...[
                        IdeButton(
                          label: _driver.daemonRunning
                              ? (isZh ? '停止服务' : 'Stop Daemon')
                              : (isZh ? '启动服务' : 'Start Daemon'),
                          secondary: true,
                          onPressed: () => unawaited(
                            _driver.daemonRunning
                                ? _driver.stopDaemon()
                                : _driver.ensureDaemonRunning(),
                          ),
                        ),
                        IdeButton(
                          label: isZh ? '卸载' : 'Uninstall',
                          secondary: true,
                          onPressed: () => unawaited(_driver.uninstall()),
                        ),
                      ] else
                        IdeButton(
                          label: _driver.state == CuaDriverState.installing
                              ? (isZh ? '安装中…' : 'Installing…')
                              : (isZh ? '一键安装' : 'Install'),
                          icon: Codicons.cloudDownload,
                          onPressed: _driver.state == CuaDriverState.installing
                              ? null
                              : () => unawaited(_driver.install()),
                        ),
                      IdeButton(
                        label: isZh ? '检测' : 'Check',
                        secondary: true,
                        onPressed: () => unawaited(_driver.refresh()),
                      ),
                    ],
                  ),
                ),
                if (_driver.installLog.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                    child: Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 110),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: SettingsColors.hover,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: SingleChildScrollView(
                        reverse: true,
                        child: Text(
                          _driver.installLog.trim(),
                          style: SettingsText.path.copyWith(fontSize: 11),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (Platform.isMacOS)
              SettingsGroup(
                title: isZh ? '系统权限（macOS）' : 'System Permissions (macOS)',
                description: isZh
                    ? '授权状态会自动刷新，无需重启应用。'
                    : 'Permission states refresh automatically without restarting Ayte.',
                children: [
                  SettingsRow(
                    label: isZh
                        ? '辅助功能：Ayte ${perms.accessibility ? "已授权" : "未授权"}${_driver.driverAccessibility != null ? " · CuaDriver ${_driver.driverAccessibility! ? "已授权" : "未授权"}" : ""}'
                        : 'Accessibility: Ayte ${perms.accessibility ? "Granted" : "Not Granted"}${_driver.driverAccessibility != null ? " · CuaDriver ${_driver.driverAccessibility! ? "Granted" : "Not Granted"}" : ""}',
                    description: isZh
                        ? '用于读取窗口控件树并发送点击与输入。建议把 /Applications/CuaDriver.app 加入系统设置，重编译 Ayte 后无需重新授权。'
                        : 'Required to inspect UI trees and send inputs. Granting /Applications/CuaDriver.app persists across Ayte rebuilds.',
                    trailing: SettingsButtons(
                      children: [
                        if (Directory('/Applications/CuaDriver.app').existsSync())
                          IdeButton(
                            label: isZh ? '在访达中显示驱动' : 'Reveal CuaDriver',
                            secondary: true,
                            onPressed: () => unawaited(
                              Process.run('open', [
                                '-R',
                                '/Applications/CuaDriver.app',
                              ]),
                            ),
                          ),
                        if (!perms.accessibility)
                          IdeButton(
                            label: isZh ? '请求授权' : 'Request',
                            onPressed: () {
                              ComputerUseNative.requestAccessibility();
                              _ctrl.refreshPermissions();
                              unawaited(_driver.refreshDaemonAndPermissions());
                            },
                          ),
                        IdeButton(
                          label: isZh ? '打开系统设置' : 'Open Settings',
                          secondary: true,
                          onPressed: () => ComputerUseNative.openPrivacyPane(
                            'accessibility',
                          ),
                        ),
                      ],
                    ),
                  ),
                  SettingsRow(
                    label: isZh
                        ? '屏幕录制：Ayte ${perms.screenRecording ? "已授权" : "未授权"}${_driver.driverScreenRecording != null ? " · CuaDriver ${_driver.driverScreenRecording! ? "已授权" : "未授权"}" : ""}'
                        : 'Screen Recording: Ayte ${perms.screenRecording ? "Granted" : "Not Granted"}${_driver.driverScreenRecording != null ? " · CuaDriver ${_driver.driverScreenRecording! ? "Granted" : "Not Granted"}" : ""}',
                    description: isZh
                        ? '用于截取共享窗口画面及读取窗口标题。'
                        : 'Required to capture screenshots and read window titles.',
                    trailing: SettingsButtons(
                      children: [
                        if (!perms.screenRecording)
                          IdeButton(
                            label: isZh ? '请求授权' : 'Request',
                            onPressed: () {
                              ComputerUseNative.requestScreenRecording();
                              _ctrl.refreshPermissions();
                              unawaited(_driver.refreshDaemonAndPermissions());
                            },
                          ),
                        IdeButton(
                          label: isZh ? '打开系统设置' : 'Open Settings',
                          secondary: true,
                          onPressed: () => ComputerUseNative.openPrivacyPane(
                            'screenRecording',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            if (cfg.enabled)
              SettingsGroup(
                title: isZh ? '共享、输入与紧急停止' : 'Sharing, Input & Emergency Stop',
                children: [
                  SettingsRow(
                    label: isZh ? '窗口闲置多久后停止共享' : 'Idle Auto-Stop Timeout',
                    description: isZh
                        ? '按智能体最后一次读取该窗口的时间计时。'
                        : 'Measured from the last time an agent read the window.',
                    trailing: SettingsDropdown(
                      current: cfg.idleTimeoutMinutes == 0
                          ? (isZh ? '永不（直到我停止）' : 'Never (until stopped)')
                          : (isZh
                                ? '${cfg.idleTimeoutMinutes} 分钟'
                                : '${cfg.idleTimeoutMinutes} min'),
                      semanticLabel: isZh
                          ? '窗口闲置多久后停止共享'
                          : 'Idle Auto-Stop Timeout',
                      entries: () => [
                        for (final m in ComputerUseConfig.idleTimeoutOptions)
                          IdeMenuAction(
                            m == 0
                                ? (isZh ? '永不（直到我停止）' : 'Never (until stopped)')
                                : (isZh ? '$m 分钟' : '$m min'),
                            checked: cfg.idleTimeoutMinutes == m,
                            onSelected: () => unawaited(
                              _update(cfg.copyWith(idleTimeoutMinutes: m)),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SettingsSwitchRow(
                    label: isZh ? '悬浮停止条' : 'Floating Stop Bar',
                    description: isZh
                        ? '共享期间在所有窗口最顶层悬浮提示条，可随时一键停止共享。'
                        : 'Displays an always-on-top capsule bar with a Stop Sharing button while active.',
                    value: cfg.floatingStopBar,
                    onChanged: (v) =>
                        unawaited(_update(cfg.copyWith(floatingStopBar: v))),
                  ),
                  SettingsRow(
                    label: isZh ? '全局紧急停止快捷键' : 'Global Emergency Stop Hotkey',
                    description: switch (_ctrl.hotkeyStatus) {
                      StopHotkeyStatus.active =>
                        isZh
                            ? '已生效（${cfg.stopHotkey}）：任意应用中按下立即停止共享全部窗口。'
                            : 'Active (${cfg.stopHotkey}): stops all sharing from any app.',
                      StopHotkeyStatus.disabled =>
                        isZh ? '已关闭（仅通过按钮停止）' : 'Disabled (use buttons to stop)',
                      StopHotkeyStatus.conflict =>
                        isZh
                            ? '未生效：格式无效或已被其他应用占用（需至少两个修饰键且含 Ctrl/Cmd）。'
                            : 'Inactive: invalid format or taken by another app (requires 2+ modifiers incl. Ctrl/Cmd).',
                      StopHotkeyStatus.inactive =>
                        isZh ? '开启电脑操作后生效' : 'Activates when Computer Use is enabled',
                    },
                    trailing: SizedBox(
                      width: 240,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Expanded(
                            child: IdeInputBox(
                              controller: _hotkeyController,
                              placeholder: 'Ctrl+Cmd+Escape',
                              onSubmitted: (val) => unawaited(
                                _update(
                                  cfg.copyWith(
                                    stopHotkeyEnabled: true,
                                    stopHotkey: val.trim(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          IdeButton(
                            label: isZh ? '应用' : 'Set',
                            secondary: true,
                            onPressed: () => unawaited(
                              _update(
                                cfg.copyWith(
                                  stopHotkeyEnabled: true,
                                  stopHotkey: _hotkeyController.text.trim(),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SettingsSwitchRow(
                    label: isZh ? '允许智能体把窗口切到前台' : 'Allow Bringing Windows to Front',
                    description: isZh
                        ? '部分应用在后台无法接收按键，开启后允许临时切到前台完成操作。'
                        : 'Some apps ignore background keystrokes; allows briefly focusing interactive windows.',
                    value: cfg.allowBringToFront,
                    onChanged: (v) =>
                        unawaited(_update(cfg.copyWith(allowBringToFront: v))),
                  ),
                  SettingsRow(
                    label: isZh ? '默认操作方式' : 'Default Input Delivery',
                    description: cfg.allowBringToFront
                        ? (isZh
                              ? '后台方式不打断你当前的鼠标键盘使用。'
                              : 'Background keeps your cursor and keyboard free.')
                        : (isZh
                              ? '不允许切到前台时，始终为后台。'
                              : 'Locked to Background while Bring to Front is off.'),
                    trailing: Opacity(
                      opacity: cfg.allowBringToFront ? 1 : 0.45,
                      child: IgnorePointer(
                        ignoring: !cfg.allowBringToFront,
                        child: SettingsDropdown(
                          current:
                              cfg.effectiveDeliveryMode ==
                                  ComputerUseDeliveryMode.foreground
                              ? (isZh ? '前台' : 'Foreground')
                              : (isZh ? '后台（默认）' : 'Background (Default)'),
                          semanticLabel: isZh
                              ? '默认操作方式'
                              : 'Default Input Delivery',
                          entries: () => [
                            IdeMenuAction(
                              isZh ? '后台（默认）' : 'Background (Default)',
                              checked:
                                  cfg.effectiveDeliveryMode ==
                                  ComputerUseDeliveryMode.background,
                              onSelected: () => unawaited(
                                _update(
                                  cfg.copyWith(
                                    defaultDeliveryMode:
                                        ComputerUseDeliveryMode.background,
                                  ),
                                ),
                              ),
                            ),
                            if (cfg.allowBringToFront)
                              IdeMenuAction(
                                isZh ? '前台' : 'Foreground',
                                checked:
                                    cfg.effectiveDeliveryMode ==
                                    ComputerUseDeliveryMode.foreground,
                                onSelected: () => unawaited(
                                  _update(
                                    cfg.copyWith(
                                      defaultDeliveryMode:
                                          ComputerUseDeliveryMode.foreground,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  SettingsSwitchRow(
                    label: isZh ? '允许智能体打开应用和移动窗口' : 'Allow Launching Apps & Moving Windows',
                    description: isZh
                        ? '默认关闭。启动应用不等于自动共享该应用窗口。'
                        : 'Off by default. Launching an app never automatically shares its window.',
                    value: cfg.allowLaunchAndMove,
                    onChanged: (v) => unawaited(
                      _update(cfg.copyWith(allowLaunchAndMove: v)),
                    ),
                  ),
                  SettingsSwitchRow(
                    label: isZh ? '允许智能体使用剪贴板' : 'Allow Controlled Clipboard Access',
                    description: isZh
                        ? '允许智能体借助剪贴板粘贴文本，不读取你私自复制的内容。'
                        : 'Allows pasting text via clipboard for shared windows.',
                    value: cfg.allowClipboard,
                    onChanged: (v) =>
                        unawaited(_update(cfg.copyWith(allowClipboard: v))),
                  ),
                  SettingsSwitchRow(
                    label: isZh ? '允许共享整个屏幕' : 'Allow Sharing Entire Screen',
                    description: isZh
                        ? '默认关闭。开启后可在「共享窗口」弹窗中手动开启整屏共享；关掉会立即结束。'
                        : 'Off by default. Adds an Entire Screen option in the Share Windows dialog.',
                    value: cfg.allowFullScreen,
                    onChanged: (v) =>
                        unawaited(_update(cfg.copyWith(allowFullScreen: v))),
                  ),
                ],
              ),
            if (cfg.enabled)
              SettingsGroup(
                title: isZh ? '永不共享的应用名单' : 'Never-Share Protected Apps',
                description: isZh
                    ? '名单中的应用不可被选择共享；Ayte 自身窗口在底层硬性保护，始终不可共享。'
                    : 'Apps listed here cannot be shared. Ayte itself is always hard-protected.',
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: IdeInputBox(
                            controller: _addAppController,
                            placeholder: isZh
                                ? '输入 Bundle ID（如 com.example.app）或应用名'
                                : 'Bundle ID (e.g. com.example.app) or app name',
                            onSubmitted: (_) => _addNeverShare(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IdeButton(
                          label: isZh ? '添加' : 'Add',
                          onPressed: _addNeverShare,
                        ),
                        const SizedBox(width: 6),
                        IdeButton(
                          label: isZh ? '恢复默认' : 'Reset Defaults',
                          secondary: true,
                          onPressed: () =>
                              unawaited(_restoreDefaults(context, isZh)),
                        ),
                      ],
                    ),
                  ),
                  for (final item in cfg.neverShareApps)
                    SettingsRow(
                      label: neverShareAppLabels[item] != null
                          ? (isZh
                                ? '${neverShareAppLabels[item]!.$1} ($item)'
                                : '${neverShareAppLabels[item]!.$2} ($item)')
                          : item,
                      trailing: IdeButton(
                        label: isZh ? '移除' : 'Remove',
                        secondary: true,
                        onPressed: () {
                          final next = [
                            for (final e in cfg.neverShareApps)
                              if (e != item) e,
                          ];
                          unawaited(
                            _update(cfg.copyWith(neverShareApps: next)),
                          );
                        },
                      ),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }
}
