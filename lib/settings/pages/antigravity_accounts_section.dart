import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/widgets/hover_builder.dart';
import '../../icons/brand_logos.dart';
import '../../ide/ide_button.dart';
import '../../ide/ide_dialog.dart';
import '../../ide/ide_hover.dart';
import '../../ide/ide_input.dart';
import '../../ide/ide_menu.dart';
import '../../ide/ide_spinning.dart';
import '../../kernel/antigravity/antigravity_account_models.dart';
import '../../kernel/antigravity/antigravity_accounts.dart';
import '../../kernel/antigravity/antigravity_oauth.dart';
import '../../kernel/antigravity/antigravity_switcher.dart';
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import '../../workspace/editor_launcher.dart' show openExternal;
import '../../workspace/window_controls.dart';
import 'settings_widgets.dart';

/// Antigravity Google multi-account manager, real-time quota monitor, and
/// smart auto-switch panel embedded at the top of Settings → Accounts.
class AntigravityAccountsSection extends StatefulWidget {
  const AntigravityAccountsSection({super.key, this.store});

  final AntigravityAccounts? store;

  @override
  State<AntigravityAccountsSection> createState() =>
      _AntigravityAccountsSectionState();
}

class _AntigravityAccountsSectionState
    extends State<AntigravityAccountsSection> {
  final TextEditingController _searchController = TextEditingController();
  AntigravityTier? _tierFilter;
  String? _bannerMessage;
  bool _bannerError = false;

  AntigravityAccounts get _store =>
      widget.store ?? AntigravityAccounts.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_store.ensureInitialized());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _showStatus(String msg, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _bannerMessage = msg;
      _bannerError = error;
    });
  }

  List<AntigravityAccount> _filtered(List<AntigravityAccount> all) {
    final q = _searchController.text.trim().toLowerCase();
    return [
      for (final a in all)
        if ((_tierFilter == null || a.tier == _tierFilter) &&
            (q.isEmpty ||
                a.email.toLowerCase().contains(q) ||
                (a.name?.toLowerCase().contains(q) ?? false) ||
                (a.customLabel?.toLowerCase().contains(q) ?? false)))
          a,
    ];
  }

  Future<void> _switchAccount(AntigravityAccount account) async {
    try {
      await _store.switchAccount(account.id);
      _showStatus('已切换至账号 ${account.email}（钥匙串与 agy CLI 已同步更新）');
    } on Object catch (e) {
      _showStatus('切换账号失败：$e', error: true);
    }
  }

  Future<void> _exportBackup() async {
    if (_store.accounts.isEmpty) {
      _showStatus('当前暂无可导出的账号', error: true);
      return;
    }
    final jsonText = _store.exportAccountsJson();
    final savePath = await WindowControls.pickSaveFile(
      name: 'antigravity-accounts.json',
    );
    if (savePath != null && savePath.isNotEmpty) {
      await AntigravityCredentialSwitcher.writeAtomicSecure(savePath, jsonText);
      _showStatus('已将 ${_store.accounts.length} 个账号导出保存至 $savePath');
      return;
    }
    await Clipboard.setData(ClipboardData(text: jsonText));
    _showStatus('已将 ${_store.accounts.length} 个账号的备份 JSON 复制到剪贴板');
  }

  Future<void> _deleteAccount(AntigravityAccount account) async {
    final choice = await showIdeDialog(
      context,
      message: '移除账号 ${account.email}？',
      detail: '这将从 Ayte 本地账号库中移除该账号记录，不会影响 Google 远端账户本身。',
      buttons: const ['移除账号'],
    );
    if (choice == 0) {
      await _store.deleteAccount(account.id);
      _showStatus('已移除账号 ${account.email}');
    }
  }

  Future<void> _editLabel(AntigravityAccount account) async {
    final updated = await showGeneralDialog<String?>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: const Color(0x70000000),
      transitionDuration: Duration.zero,
      pageBuilder: (context, _, _) =>
          _EditLabelDialog(initialLabel: account.customLabel ?? ''),
    );
    if (updated != null) {
      await _store.setCustomLabel(account.id, updated);
    }
  }

  Future<void> _openAddDialog() async {
    final msg = await showGeneralDialog<String?>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Dismiss',
      barrierColor: const Color(0x78000000),
      transitionDuration: Duration.zero,
      pageBuilder: (context, _, _) => _AddAntigravityAccountDialog(store: _store),
    );
    if (msg != null && msg.isNotEmpty) {
      _showStatus(msg);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final all = _store.accounts;
        final filtered = _filtered(all);
        final window = _store.quotaWindow;
        final auto = _store.autoSwitch;

        final proCount = all.where((a) => a.tier == AntigravityTier.pro).length;
        final ultraCount =
            all.where((a) => a.tier == AntigravityTier.ultra).length;
        final freeCount =
            all.where((a) => a.tier == AntigravityTier.free).length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsGroup(
              title: 'Antigravity 账号与配额管理',
              description:
                  '一键切换 Google Antigravity 账号，实时查看 Gemini / Claude / GPT 5 小时与周配额，数据独立保存在 ~/.ayte/antigravity_accounts',
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SizedBox(
                            width: 220,
                            child: IdeInputBox(
                              controller: _searchController,
                              placeholder: '搜索邮箱、名称或备注...',
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _WindowSegmentedToggle(
                                current: window,
                                onChanged: _store.setQuotaWindow,
                              ),
                              const SizedBox(width: 8),
                              IdeButton(
                                label: '添加账号',
                                icon: Codicons.add,
                                onPressed: () => unawaited(_openAddDialog()),
                              ),
                              const SizedBox(width: 6),
                              IdeButton(
                                label: '刷新配额',
                                icon: Codicons.refresh,
                                spinning: _store.isRefreshingAll,
                                secondary: true,
                                onPressed: _store.isRefreshingAll
                                    ? null
                                    : () => unawaited(_store.refreshAllQuotas()),
                              ),
                              const SizedBox(width: 6),
                              IdeButton(
                                label: '导出备份',
                                icon: Codicons.exportIcon,
                                secondary: true,
                                onPressed: () => unawaited(_exportBackup()),
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (all.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            _FilterChip(
                              label: '全部 (${all.length})',
                              selected: _tierFilter == null,
                              onTap: () => setState(() => _tierFilter = null),
                            ),
                            if (proCount > 0 ||
                                _tierFilter == AntigravityTier.pro)
                              _FilterChip(
                                label: 'PRO ($proCount)',
                                selected: _tierFilter == AntigravityTier.pro,
                                onTap: () => setState(
                                  () => _tierFilter = AntigravityTier.pro,
                                ),
                              ),
                            if (ultraCount > 0 ||
                                _tierFilter == AntigravityTier.ultra)
                              _FilterChip(
                                label: 'ULTRA ($ultraCount)',
                                selected: _tierFilter == AntigravityTier.ultra,
                                onTap: () => setState(
                                  () => _tierFilter = AntigravityTier.ultra,
                                ),
                              ),
                            if (freeCount > 0 ||
                                _tierFilter == AntigravityTier.free)
                              _FilterChip(
                                label: 'FREE ($freeCount)',
                                selected: _tierFilter == AntigravityTier.free,
                                onTap: () => setState(
                                  () => _tierFilter = AntigravityTier.free,
                                ),
                              ),
                          ],
                        ),
                      ],
                      if (_bannerMessage case final banner?) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: (_bannerError
                                    ? const Color(0xFFDC3E3E)
                                    : const Color(0xFF22A35A))
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: (_bannerError
                                      ? const Color(0xFFDC3E3E)
                                      : const Color(0xFF22A35A))
                                  .withValues(alpha: 0.35),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _bannerError
                                    ? Codicons.warning
                                    : Codicons.check,
                                size: 14,
                                color: _bannerError
                                    ? const Color(0xFFDC3E3E)
                                    : const Color(0xFF22A35A),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  banner,
                                  style: SettingsText.description.copyWith(
                                    color: SettingsColors.textPrimary,
                                  ),
                                ),
                              ),
                              GestureDetector(
                                onTap: () =>
                                    setState(() => _bannerMessage = null),
                                child: Icon(
                                  Codicons.close,
                                  size: 13,
                                  color: SettingsColors.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (filtered.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 22,
                    ),
                    child: Center(
                      child: Text(
                        all.isEmpty
                            ? '尚未添加 Antigravity 账号，点击右上角「添加账号」支持 Google OAuth 登录、Refresh Token / JSON 导入或本机自动扫描。'
                            : '没有符合筛选条件的账号。',
                        textAlign: TextAlign.center,
                        style: SettingsText.description,
                      ),
                    ),
                  )
                else
                  for (final account in filtered)
                    _AntigravityAccountTile(
                      account: account,
                      isActive: account.id == _store.currentAccountId,
                      isSwitching: _store.switchingId == account.id,
                      isRefreshing: _store.isRefreshing(account.id),
                      window: window,
                      onSwitch: () => unawaited(_switchAccount(account)),
                      onRefresh: () => unawaited(_store.refreshQuota(account.id)),
                      onEditLabel: () => unawaited(_editLabel(account)),
                      onToggleDisabled: () => unawaited(
                        _store.setDisabled(account.id, !account.disabled),
                      ),
                      onDelete: () => unawaited(_deleteAccount(account)),
                    ),
              ],
            ),
            const SizedBox(height: 20),
            SettingsGroup(
              title: '智能切号与外部客户端同步',
              children: [
                SettingsRow(
                  label: '限额 / 低配额自动切换备用账号',
                  description:
                      '当前账号在对话中触发额度耗尽或低于保留阈值时，自动切换到配额最高的可用备用账号继续执行',
                  trailing: SettingsSwitch(
                    value: auto.enabled,
                    semanticLabel: '限额自动切换备用账号',
                    onChanged: (v) => unawaited(
                      _store.updateAutoSwitch(auto.copyWith(enabled: v)),
                    ),
                  ),
                  onTap: () => unawaited(
                    _store.updateAutoSwitch(
                      auto.copyWith(enabled: !auto.enabled),
                    ),
                  ),
                ),
                if (auto.enabled)
                  SettingsRow(
                    label: '最低候选配额要求',
                    description: '自动切换时仅选择剩余配额不低于该比例的备用账号',
                    trailing: _ThresholdDropdown(
                      value: auto.candidateMinPercentage,
                      options: const [15, 25, 40, 60],
                      onChanged: (v) => unawaited(
                        _store.updateAutoSwitch(
                          auto.copyWith(candidateMinPercentage: v),
                        ),
                      ),
                    ),
                  ),
                SettingsRow(
                  label: '切号时同步写入外部 Antigravity 客户端数据库',
                  description:
                      '默认始终更新系统钥匙串与 agy CLI 凭据；开启后还会同步注入 Antigravity / Antigravity IDE 的 state.vscdb 与独立设备指纹',
                  trailing: SettingsSwitch(
                    value: auto.syncExternalClients,
                    semanticLabel: '同步写入外部客户端数据库',
                    onChanged: (v) => unawaited(
                      _store.updateAutoSwitch(
                        auto.copyWith(syncExternalClients: v),
                      ),
                    ),
                  ),
                  onTap: () => unawaited(
                    _store.updateAutoSwitch(
                      auto.copyWith(
                        syncExternalClients: !auto.syncExternalClients,
                      ),
                    ),
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

class _AntigravityAccountTile extends StatelessWidget {
  const _AntigravityAccountTile({
    required this.account,
    required this.isActive,
    required this.isSwitching,
    required this.isRefreshing,
    required this.window,
    required this.onSwitch,
    required this.onRefresh,
    required this.onEditLabel,
    required this.onToggleDisabled,
    required this.onDelete,
  });

  final AntigravityAccount account;
  final bool isActive;
  final bool isSwitching;
  final bool isRefreshing;
  final AntigravityQuotaWindow window;
  final VoidCallback onSwitch;
  final VoidCallback onRefresh;
  final VoidCallback onEditLabel;
  final VoidCallback onToggleDisabled;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final pools = account.quota?.poolDisplays(window) ?? const [];
    final tier = account.tier;
    final (Color tierColor, String tierText) = switch (tier) {
      AntigravityTier.ultra => (const Color(0xFF9B6BFF), 'ULTRA'),
      AntigravityTier.pro => (const Color(0xFF0EA5E9), 'PRO'),
      AntigravityTier.free => (SettingsColors.textTertiary, 'FREE'),
      AntigravityTier.unknown => (SettingsColors.textQuaternary, '未同步'),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const BrandLogo('google', size: 15),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  account.email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SettingsText.label.copyWith(
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                    color: account.disabled
                        ? SettingsColors.textTertiary
                        : SettingsColors.textPrimary,
                  ),
                ),
              ),
              if (account.name case final name?
                  when name.trim().isNotEmpty && name.trim() != account.email) ...[
                const SizedBox(width: 6),
                Text(
                  '(${name.trim()})',
                  style: SettingsText.description,
                ),
              ],
              if (account.customLabel case final label?
                  when label.trim().isNotEmpty) ...[
                const SizedBox(width: 6),
                _Badge(
                  text: label.trim(),
                  color: AppColors.accent,
                ),
              ],
              const SizedBox(width: 6),
              _Badge(text: tierText, color: tierColor),
              if (isActive) ...[
                const SizedBox(width: 6),
                const _Badge(text: '当前使用', color: Color(0xFF22A35A)),
              ],
              if (account.disabled) ...[
                const SizedBox(width: 6),
                const _Badge(text: '已停用', color: Color(0xFFDC3E3E)),
              ] else if (account.quota?.isForbidden == true) ...[
                const SizedBox(width: 6),
                const _Badge(text: '403 受限', color: Color(0xFFDC3E3E)),
              ] else if (account.validationBlocked) ...[
                const SizedBox(width: 6),
                const _Badge(text: '需验证/限流', color: Color(0xFFD98B1C)),
              ],
              const Spacer(),
              IdeButton(
                label: isActive ? '已激活' : '切换使用',
                spinning: isSwitching,
                secondary: isActive,
                onPressed: (isActive || isSwitching || account.disabled)
                    ? null
                    : onSwitch,
              ),
              const SizedBox(width: 6),
              _IconAction(
                icon: Codicons.refresh,
                tooltip: '刷新配额',
                spinning: isRefreshing,
                onTap: isRefreshing ? null : onRefresh,
              ),
              _IconAction(
                icon: Codicons.tag,
                tooltip: '设置备注标签',
                onTap: onEditLabel,
              ),
              _IconAction(
                icon: account.disabled ? Codicons.play : Codicons.circleSlash,
                tooltip: account.disabled ? '启用账号' : '停用账号',
                onTap: onToggleDisabled,
              ),
              _IconAction(
                icon: Codicons.trash,
                tooltip: '移除账号',
                onTap: onDelete,
              ),
            ],
          ),
          if (pools.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in pools) _QuotaPoolBar(display: p),
              ],
            ),
          ] else if (account.disabledReason case final reason?
              when reason.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              reason,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: SettingsText.description.copyWith(
                color: const Color(0xFFDC3E3E),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _QuotaPoolBar extends StatelessWidget {
  const _QuotaPoolBar({required this.display});

  final AntigravityPoolDisplay display;

  @override
  Widget build(BuildContext context) {
    final pct = display.percentage.clamp(0, 100);
    final barColor = pct >= 60
        ? const Color(0xFF22A35A)
        : pct >= 20
        ? const Color(0xFFD98B1C)
        : const Color(0xFFDC3E3E);
    final resetLabel = formatQuotaResetTime(display.resetTime);
    final title = display.windowLabel != null
        ? '${display.pool.shortLabel} (${display.windowLabel})'
        : display.pool.shortLabel;

    return Container(
      width: 195,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: SettingsColors.hover,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: SettingsColors.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: SettingsColors.textSecondary,
                  ),
                ),
              ),
              Text(
                '$pct%',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: barColor,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: pct / 100.0,
              minHeight: 4.5,
              backgroundColor: SettingsColors.stroke,
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
          if (resetLabel.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              resetLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                color: SettingsColors.textTertiary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.spinning = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool spinning;

  @override
  Widget build(BuildContext context) {
    return IdeHover(
      message: tooltip,
      child: HoverBuilder(
        cursor: onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        builder: (context, hovered) => GestureDetector(
          onTap: onTap,
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hovered ? SettingsColors.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: spinning
                ? IdeSpinning(
                    Icon(
                      Codicons.loading,
                      size: 14,
                      color: SettingsColors.textSecondary,
                    ),
                  )
                : Icon(
                    icon,
                    size: 14,
                    color: hovered
                        ? SettingsColors.textPrimary
                        : SettingsColors.textSecondary,
                  ),
          ),
        ),
      ),
    );
  }
}

class _WindowSegmentedToggle extends StatelessWidget {
  const _WindowSegmentedToggle({
    required this.current,
    required this.onChanged,
  });

  final AntigravityQuotaWindow current;
  final ValueChanged<AntigravityQuotaWindow> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: SettingsColors.hover,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: SettingsColors.stroke),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final w in AntigravityQuotaWindow.values)
            GestureDetector(
              onTap: () => onChanged(w),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: current == w
                        ? SettingsColors.card
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    w.label,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: current == w
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: current == w
                          ? SettingsColors.textPrimary
                          : SettingsColors.textSecondary,
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

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accent.withValues(alpha: 0.16)
                : (hovered ? SettingsColors.hover : Colors.transparent),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.45)
                  : SettingsColors.stroke,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? AppColors.accent : SettingsColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _ThresholdDropdown extends StatelessWidget {
  const _ThresholdDropdown({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final int value;
  final List<int> options;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (btnCtx) => IdeButton(
        label: '$value%',
        secondary: true,
        onPressed: () {
          final box = btnCtx.findRenderObject() as RenderBox?;
          if (box == null) return;
          final rect = box.localToGlobal(Offset.zero) & box.size;
          unawaited(
            showIdeMenu(
              btnCtx,
              anchor: rect,
              entries: [
                for (final opt in options)
                  IdeMenuAction(
                    '$opt%',
                    checked: opt == value,
                    onSelected: () => onChanged(opt),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// --- Dialogs ----------------------------------------------------------------

class _EditLabelDialog extends StatefulWidget {
  const _EditLabelDialog({required this.initialLabel});

  final String initialLabel;

  @override
  State<_EditLabelDialog> createState() => _EditLabelDialogState();
}

class _EditLabelDialogState extends State<_EditLabelDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialLabel,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 380,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: themeColors['editorWidget.background'],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: SettingsColors.stroke),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('设置账号备注标签', style: SettingsText.label),
              const SizedBox(height: 6),
              Text('最多 15 个字符，留空可清除备注。', style: SettingsText.description),
              const SizedBox(height: 12),
              IdeInputBox(
                controller: _controller,
                placeholder: '例如：主力 Pro / 备用号',
                autofocus: true,
                onSubmitted: (v) => Navigator.of(context).pop(v),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IdeButton(
                    label: '取消',
                    secondary: true,
                    onPressed: () => Navigator.of(context).pop(null),
                  ),
                  const SizedBox(width: 8),
                  IdeButton(
                    label: '保存',
                    onPressed: () =>
                        Navigator.of(context).pop(_controller.text),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddAntigravityAccountDialog extends StatefulWidget {
  const _AddAntigravityAccountDialog({required this.store});

  final AntigravityAccounts store;

  @override
  State<_AddAntigravityAccountDialog> createState() =>
      _AddAntigravityAccountDialogState();
}

class _AddAntigravityAccountDialogState
    extends State<_AddAntigravityAccountDialog> {
  int _tab = 0; // 0: OAuth, 1: Token/JSON, 2: Local Scan
  PendingOAuthFlow? _oauthFlow;
  final TextEditingController _manualCodeController = TextEditingController();
  final TextEditingController _importTextController = TextEditingController();

  bool _busy = false;
  String? _error;
  List<String> _scanLogs = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_prepareOAuth());
  }

  @override
  void dispose() {
    _oauthFlow?.cancel();
    _manualCodeController.dispose();
    _importTextController.dispose();
    super.dispose();
  }

  Future<void> _prepareOAuth() async {
    try {
      final flow = await AntigravityOAuth.startOAuthFlow();
      if (!mounted) {
        flow.cancel();
        return;
      }
      setState(() => _oauthFlow = flow);
      unawaited(
        flow.result.then(
          (res) async {
            if (!mounted) return;
            setState(() => _busy = true);
            final acc = await widget.store.upsertAuthorizedAccount(
              token: res.token,
              email: res.email,
              name: res.name,
              makeActive: widget.store.accounts.isEmpty,
            );
            if (mounted) {
              Navigator.of(context).pop('已成功授权并添加账号 ${acc.email}');
            }
          },
          onError: (Object e) {
            if (!mounted) return;
            final msg = '$e';
            if (!msg.contains('已取消')) {
              setState(() {
                _busy = false;
                _error = msg;
              });
            }
          },
        ),
      );
    } on Object catch (e) {
      if (mounted) setState(() => _error = '初始化本地 OAuth 回调监听失败：$e');
    }
  }

  Future<void> _pickJsonFile() async {
    final paths = await WindowControls.pickOpenFiles(multiple: false);
    final filePath = paths.firstOrNull;
    if (filePath == null) return;
    final content = await File(filePath).readAsString();
    setState(() => _importTextController.text = content);
  }

  Future<void> _runTransferImport() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await widget.store.importFromTransferText(
        _importTextController.text,
      );
      if (!mounted) return;
      if (res.imported > 0 && res.failed == 0) {
        Navigator.of(context).pop('已成功导入 ${res.imported} 个账号');
        return;
      }
      setState(() {
        _busy = false;
        _error =
            '成功导入 ${res.imported} 个，失败 ${res.failed} 个：\n${res.errors.join('\n')}';
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _runLocalScan() async {
    setState(() {
      _busy = true;
      _error = null;
      _scanLogs = const [];
    });
    try {
      final res = await widget.store.scanAndImportLocalAccounts();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _scanLogs = res.details.isEmpty
            ? const ['未在本机钥匙串或客户端目录中发现可导入的新凭据']
            : res.details;
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 500,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: themeColors['editorWidget.background'],
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: SettingsColors.stroke),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    '添加 Antigravity 账号',
                    style: SettingsText.title.copyWith(fontSize: 16),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(null),
                    child: Icon(
                      Codicons.close,
                      size: 16,
                      color: SettingsColors.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  _FilterChip(
                    label: 'Google OAuth 登录',
                    selected: _tab == 0,
                    onTap: () => setState(() {
                      _tab = 0;
                      _error = null;
                    }),
                  ),
                  const SizedBox(width: 8),
                  _FilterChip(
                    label: 'Token / JSON 批量导入',
                    selected: _tab == 1,
                    onTap: () => setState(() {
                      _tab = 1;
                      _error = null;
                    }),
                  ),
                  const SizedBox(width: 8),
                  _FilterChip(
                    label: '扫描本机登录',
                    selected: _tab == 2,
                    onTap: () => setState(() {
                      _tab = 2;
                      _error = null;
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (_tab == 0) _buildOAuthTab(),
              if (_tab == 1) _buildImportTab(),
              if (_tab == 2) _buildScanTab(),
              if (_error case final err?) ...[
                const SizedBox(height: 12),
                Text(
                  err,
                  style: SettingsText.description.copyWith(
                    color: const Color(0xFFDC3E3E),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOAuthTab() {
    final flow = _oauthFlow;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '点击下方按钮在默认浏览器中完成 Google 账号授权，授权完成后会自动回到 Ayte 添加账号并拉取实时配额。',
          style: SettingsText.description,
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            IdeButton(
              label: '在浏览器中打开 Google 授权',
              leading: const BrandLogo('google', size: 14),
              spinning: _busy,
              onPressed: (flow == null || _busy)
                  ? null
                  : () => unawaited(openExternal(flow.authorizationUrl)),
            ),
            const SizedBox(width: 8),
            IdeButton(
              label: '复制授权链接',
              secondary: true,
              onPressed: flow == null
                  ? null
                  : () => unawaited(
                      Clipboard.setData(
                        ClipboardData(text: flow.authorizationUrl),
                      ),
                    ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          '若在远程环境或无本地回调的浏览器中完成授权，可将浏览器跳转后的完整回调 URL 粘贴到下方：',
          style: SettingsText.headingDescription,
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: IdeInputBox(
                controller: _manualCodeController,
                placeholder: '粘贴 http://localhost:.../oauth-callback?code=...',
              ),
            ),
            const SizedBox(width: 8),
            IdeButton(
              label: '提交回调',
              secondary: true,
              onPressed: flow == null
                  ? null
                  : () {
                      try {
                        flow.submitManualInput(_manualCodeController.text);
                      } on Object catch (e) {
                        setState(() => _error = '$e');
                      }
                    },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildImportTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '支持直接粘贴单个或多个 Refresh Token（1//...），或粘贴导出的备份 JSON：',
          style: SettingsText.description,
        ),
        const SizedBox(height: 10),
        IdeInputBox(
          controller: _importTextController,
          placeholder: '粘贴 1//0g... 或 {"schema_version": 2, "accounts": [...]}',
          minLines: 4,
          maxLines: 7,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            IdeButton(
              label: '选择 JSON 文件...',
              secondary: true,
              onPressed: _busy ? null : () => unawaited(_pickJsonFile()),
            ),
            const Spacer(),
            IdeButton(
              label: '开始导入',
              spinning: _busy,
              onPressed: _busy ? null : () => unawaited(_runTransferImport()),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildScanTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '自动扫描本机 macOS 钥匙串、Antigravity CLI (agy)、VS Code 插件以及客户端数据库中的已登录账号：',
          style: SettingsText.description,
        ),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: IdeButton(
            label: '立即扫描并导入',
            icon: Codicons.search,
            spinning: _busy,
            onPressed: _busy ? null : () => unawaited(_runLocalScan()),
          ),
        ),
        if (_scanLogs.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: SettingsColors.hover,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in _scanLogs)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(line, style: SettingsText.description),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
