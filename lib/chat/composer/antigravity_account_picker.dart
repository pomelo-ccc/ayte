import 'dart:async';

import 'package:flutter/material.dart';

import '../../ide/ide_hover.dart';
import '../../ide/ide_menu.dart';
import '../../ide/ide_spinning.dart';
import '../../kernel/antigravity/antigravity_account_models.dart';
import '../../kernel/antigravity/antigravity_accounts.dart';
import '../../kernel/antigravity/antigravity_cli.dart';
import '../../settings/settings_dialog.dart'
    show SettingsOpener, SettingsSection;
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../widgets/hover_builder.dart';

/// Compact composer-toolbar pill showing the active Antigravity Google account
/// and remaining quota for [modelId], with a 1-click account switcher menu.
class AntigravityAccountPicker extends StatefulWidget {
  const AntigravityAccountPicker({super.key, required this.modelId});

  final String? modelId;

  @override
  State<AntigravityAccountPicker> createState() =>
      _AntigravityAccountPickerState();
}

class _AntigravityAccountPickerState extends State<AntigravityAccountPicker> {
  final AntigravityAccounts _store = AntigravityAccounts.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_store.ensureInitialized());
  }

  Color _quotaColor(int pct) => pct >= 60
      ? const Color(0xFF22A35A)
      : pct >= 20
      ? const Color(0xFFD98B1C)
      : const Color(0xFFDC3E3E);

  void _openMenu(BuildContext pillContext) {
    final box = pillContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final openSettings = SettingsOpener.maybeOf(pillContext);
    final bareModel = AntigravityModels.bareModelId(widget.modelId);

    unawaited(
      showIdeMenu(
        pillContext,
        anchor: rect,
        entries: [
          if (_store.accounts.isEmpty)
            const IdeMenuAction('暂无已添加账号', enabled: false)
          else
            for (final acc in _store.accounts)
              IdeMenuAction(
                _menuLabelFor(acc, bareModel),
                checked: acc.id == _store.currentAccountId,
                enabled: !acc.disabled && _store.switchingId == null,
                onSelected: () {
                  if (acc.id != _store.currentAccountId) {
                    unawaited(_store.switchAccount(acc.id));
                  }
                },
              ),
          const IdeMenuSeparator(),
          IdeMenuAction(
            _store.isRefreshingAll ? '正在刷新配额...' : '刷新全部账号配额',
            enabled: !_store.isRefreshingAll && _store.accounts.isNotEmpty,
            onSelected: () => unawaited(_store.refreshAllQuotas()),
          ),
          if (openSettings != null)
            IdeMenuAction(
              '管理账号与配额...',
              onSelected: () => openSettings(SettingsSection.accounts),
            ),
        ],
      ),
    );
  }

  String _menuLabelFor(AntigravityAccount acc, String bareModel) {
    final pct =
        acc.quota?.effectivePercentageForModel(bareModel) ??
        acc.quota?.lowestPrimaryPercentage;
    final tier = acc.tier;
    final parts = <String>[
      acc.customLabel?.trim().isNotEmpty == true
          ? '${acc.email} (${acc.customLabel!.trim()})'
          : acc.email,
      if (tier != AntigravityTier.unknown) tier.badge,
      if (pct != null) '$pct%',
      if (acc.disabled) '已停用',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    if (!AntigravityModels.isAntigravityModel(widget.modelId)) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final active = _store.currentAccount;
        final bareModel = AntigravityModels.bareModelId(widget.modelId);
        final pct =
            active?.quota?.effectivePercentageForModel(bareModel) ??
            active?.quota?.lowestPrimaryPercentage;
        final label = active == null ? '添加账号' : active.shortLabel;
        final busy = _store.switchingId != null;

        return Builder(
          builder: (pillCtx) => IdeHover(
            message: active == null
                ? '添加或管理 Antigravity 账号'
                : '当前账号：${active.email}${pct != null ? ' · 当前模型池剩余 $pct%' : ''}（点击快速切换）',
            child: HoverBuilder(
              cursor: SystemMouseCursors.click,
              builder: (context, hovered) => GestureDetector(
                onTap: () => _openMenu(pillCtx),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  height: 22,
                  padding: const EdgeInsets.symmetric(horizontal: 7.5),
                  decoration: BoxDecoration(
                    color: hovered
                        ? AppColors.textFaint.withValues(alpha: 0.14)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (busy)
                        IdeSpinning(
                          Icon(
                            Codicons.loading,
                            size: 12,
                            color: AppColors.textMuted,
                          ),
                        )
                      else
                        Icon(
                          Codicons.account,
                          size: 12.5,
                          color: AppColors.textMuted,
                        ),
                      const SizedBox(width: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 115),
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: hovered
                                ? AppColors.text
                                : AppColors.textMuted,
                          ),
                        ),
                      ),
                      if (pct != null) ...[
                        const SizedBox(width: 5),
                        Container(
                          width: 5.5,
                          height: 5.5,
                          decoration: BoxDecoration(
                            color: _quotaColor(pct),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '$pct%',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: _quotaColor(pct),
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                      const SizedBox(width: 2),
                      Icon(
                        Codicons.chevronDown,
                        size: 11,
                        color: AppColors.textFaint,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
