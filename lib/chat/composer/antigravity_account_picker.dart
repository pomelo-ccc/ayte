import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ide/ide_hover.dart';
import '../../ide/ide_spinning.dart';
import '../../kernel/antigravity/antigravity_account_models.dart';
import '../../kernel/antigravity/antigravity_accounts.dart';
import '../../kernel/antigravity/antigravity_cli.dart';
import '../../kernel/antigravity/antigravity_usage_widgets.dart';
import '../../settings/settings_dialog.dart'
    show SettingsOpener, SettingsSection;
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import '../widgets/hover_builder.dart';

/// Compact composer-toolbar pill showing the active Antigravity Google account
/// and current model pool quota, opening an official-style `Usage` + 1-click
/// Account Switcher popover when clicked.
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

  /// Finds the `5h` and `weekly` buckets matching [bareModel] on [account].
  ({AntigravityQuotaBucket? fiveHour, AntigravityQuotaBucket? weekly})
  _bucketsForModel(AntigravityAccount? account, String bareModel) {
    final groups = account?.quota?.resolvedUsageGroups ?? const [];
    final pool =
        AntigravityQuotaPool.ofModel(bareModel) ?? AntigravityQuotaPool.gemini;
    AntigravityQuotaBucket? fiveHour;
    AntigravityQuotaBucket? weekly;
    for (final g in groups) {
      for (final b in g.buckets) {
        if (AntigravityQuotaPool.classify(b.bucketId, g.displayName) != pool) {
          continue;
        }
        if (b.window == '5h') fiveHour = b;
        if (b.window == 'weekly') weekly = b;
      }
    }
    return (fiveHour: fiveHour, weekly: weekly);
  }

  static bool _hasExpiredResetWindow(AntigravityAccount? account) {
    final now = DateTime.now().toUtc();
    for (final group in account?.quota?.resolvedUsageGroups ?? const []) {
      for (final b in group.buckets) {
        if (b.resetTime.isEmpty) continue;
        final dt = DateTime.tryParse(b.resetTime)?.toUtc();
        if (dt != null && !dt.isAfter(now)) return true;
      }
    }
    return false;
  }

  void _openUsagePopover(BuildContext pillContext) {
    final box = pillContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final openSettings = SettingsOpener.maybeOf(pillContext);

    // Refresh active (or all stale) accounts on open, especially whenever any
    // bucket's reset timestamp has passed (`Resets soon`).
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final anyOtherStale = _store.accounts.any(
      (a) =>
          !a.disabled &&
          a.id != _store.currentAccountId &&
          nowSec - (a.quota?.lastUpdated ?? 0) > 120,
    );
    if (anyOtherStale) {
      unawaited(_store.refreshAllQuotas(silent: true));
    } else if (_store.currentAccount case final active?) {
      final last = active.quota?.lastUpdated ?? 0;
      if (nowSec - last > 30 || _hasExpiredResetWindow(active)) {
        unawaited(_store.refreshQuota(active.id));
      }
    }

    unawaited(
      showGeneralDialog<void>(
        context: pillContext,
        barrierDismissible: true,
        barrierLabel: 'Dismiss',
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 120),
        pageBuilder: (dialogCtx, _, _) => _AntigravityUsagePopover(
          anchor: anchor,
          store: _store,
          onManageAccounts: openSettings == null
              ? null
              : () {
                  Navigator.of(dialogCtx).pop();
                  openSettings(SettingsSection.antigravityAccounts);
                },
        ),
        transitionBuilder: (context, anim, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
          child: child,
        ),
      ),
    );
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
        final (:fiveHour, :weekly) = _bucketsForModel(active, bareModel);
        final primaryBucket = fiveHour ?? weekly;
        final strictestFraction = switch ((fiveHour, weekly)) {
          (final f?, final w?) => math.min(
            f.remainingFraction,
            w.remainingFraction,
          ),
          (final f?, null) => f.remainingFraction,
          (null, final w?) => w.remainingFraction,
          (null, null) => null,
        };

        String? quotaSummary;
        if (fiveHour != null && weekly != null) {
          quotaSummary = fiveHour.percentage == 100 && weekly.percentage == 100
              ? '100%'
              : '5h ${fiveHour.percentage}% · W ${weekly.percentage}%';
        } else if (primaryBucket != null) {
          quotaSummary = '${primaryBucket.percentage}%';
        }

        final label = active == null ? '添加账号' : active.shortLabel;
        final busy = _store.switchingId != null;

        return Builder(
          builder: (pillCtx) => IdeHover(
            message: active == null
                ? '添加或管理 Antigravity 账号'
                : '当前账号：${active.email}（点击查看 Usage 详情或一键切号）',
            child: HoverBuilder(
              cursor: SystemMouseCursors.click,
              builder: (context, hovered) => GestureDetector(
                onTap: () => _openUsagePopover(pillCtx),
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
                      Flexible(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 110),
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
                      ),
                      if (quotaSummary != null &&
                          strictestFraction != null) ...[
                        const SizedBox(width: 5),
                        AntigravityQuotaRing(
                          fraction: strictestFraction,
                          size: 12,
                          strokeWidth: 1.7,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          quotaSummary,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: hovered
                                ? AppColors.text
                                : AppColors.textMuted,
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

class _AntigravityUsagePopover extends StatefulWidget {
  const _AntigravityUsagePopover({
    required this.anchor,
    required this.store,
    required this.onManageAccounts,
  });

  final Rect anchor;
  final AntigravityAccounts store;
  final VoidCallback? onManageAccounts;

  @override
  State<_AntigravityUsagePopover> createState() =>
      _AntigravityUsagePopoverState();
}

class _AntigravityUsagePopoverState extends State<_AntigravityUsagePopover> {
  Timer? _countdownTicker;
  int _lastAutoResetRefreshSec = 0;

  @override
  void initState() {
    super.initState();
    _countdownTicker = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!mounted) return;
      final active = widget.store.currentAccount;
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (active != null &&
          !widget.store.isRefreshing(active.id) &&
          !widget.store.isRefreshingAll &&
          nowSec - _lastAutoResetRefreshSec >= 25 &&
          _AntigravityAccountPickerState._hasExpiredResetWindow(active)) {
        _lastAutoResetRefreshSec = nowSec;
        unawaited(widget.store.refreshQuota(active.id));
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _countdownTicker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final onManageAccounts = widget.onManageAccounts;
    final screen = MediaQuery.sizeOf(context);
    const width = 320.0;
    final left = widget.anchor.left
        .clamp(12.0, math.max(12.0, screen.width - width - 12.0))
        .toDouble();
    final bottom = (screen.height - widget.anchor.top + 8.0)
        .clamp(12.0, math.max(12.0, screen.height - 80.0))
        .toDouble();
    final dark = themeColors.dark;
    final bg = dark ? const Color(0xFF1E222A) : Colors.white;
    final border = dark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.10);
    final titleColor = dark ? const Color(0xFFF3F4F6) : const Color(0xFF111827);
    final subColor = dark ? const Color(0xFF9CA3AF) : const Color(0xFF4B5563);
    final trackColor = dark
        ? Colors.white.withValues(alpha: 0.16)
        : Colors.black.withValues(alpha: 0.14);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => Navigator.of(context).pop(),
          ),
        ),
        Positioned(
          left: left,
          bottom: bottom,
          width: width,
          child: Material(
            color: Colors.transparent,
            child: ListenableBuilder(
              listenable: store,
              builder: (context, _) {
                final active = store.currentAccount;
                final groups = active?.quota?.resolvedUsageGroups ?? const [];
                final refreshing =
                    store.isRefreshingAll ||
                    (active != null && store.isRefreshing(active.id));
                final err = store.lastRefreshError;

                return Container(
                  constraints: BoxConstraints(
                    maxHeight: math.min(520, screen.height - 48),
                  ),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: border),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: dark ? 0.42 : 0.12,
                        ),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Text(
                              'Usage',
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: subColor,
                              ),
                            ),
                            if (active != null &&
                                active.tier != AntigravityTier.unknown) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5.5,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: titleColor.withValues(alpha: 0.07),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  active.tier.badge,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: subColor,
                                  ),
                                ),
                              ),
                            ],
                            const Spacer(),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: refreshing
                                  ? null
                                  : () => unawaited(store.refreshAllQuotas()),
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: Padding(
                                  padding: const EdgeInsets.all(5),
                                  child: refreshing
                                      ? IdeSpinning(
                                          Icon(
                                            Codicons.sync,
                                            size: 13.5,
                                            color: subColor,
                                          ),
                                        )
                                      : Icon(
                                          Codicons.refresh,
                                          size: 13.5,
                                          color: subColor,
                                        ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (err != null && !refreshing) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0x18DF4B44),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              err,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFFDF4B44),
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        if (groups.isNotEmpty)
                          AntigravityUsageGroupsStack(
                            groups: groups,
                            titleColor: titleColor,
                            secondaryColor: subColor,
                            trackColor: trackColor,
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              refreshing ? '正在同步实时配额...' : '暂无配额数据，点击右上角刷新',
                              style: TextStyle(fontSize: 12, color: subColor),
                            ),
                          ),
                        if (store.accounts.length > 1) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Divider(height: 1, color: border),
                          ),
                          Text(
                            '切换账号',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: subColor,
                            ),
                          ),
                          const SizedBox(height: 4),
                          for (final acc in store.accounts)
                            if (!acc.disabled)
                              _PopoverAccountRow(
                                account: acc,
                                isActive: acc.id == store.currentAccountId,
                                titleColor: titleColor,
                                subColor: subColor,
                                onTap: () {
                                  if (acc.id != store.currentAccountId) {
                                    unawaited(store.switchAccount(acc.id));
                                  }
                                },
                              ),
                        ],
                        if (onManageAccounts != null) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 8, bottom: 4),
                            child: Divider(height: 1, color: border),
                          ),
                          HoverBuilder(
                            cursor: SystemMouseCursors.click,
                            builder: (context, hovered) => GestureDetector(
                              onTap: onManageAccounts,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: hovered
                                      ? titleColor.withValues(alpha: 0.05)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Codicons.settingsGear,
                                      size: 13,
                                      color: subColor,
                                    ),
                                    const SizedBox(width: 7),
                                    Text(
                                      '管理 Antigravity 账号...',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: titleColor,
                                      ),
                                    ),
                                  ],
                                ),
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
        ),
      ],
    );
  }
}

class _PopoverAccountRow extends StatelessWidget {
  const _PopoverAccountRow({
    required this.account,
    required this.isActive,
    required this.titleColor,
    required this.subColor,
    required this.onTap,
  });

  final AntigravityAccount account;
  final bool isActive;
  final Color titleColor;
  final Color subColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pct = account.quota?.lowestPrimaryPercentage;
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5.5),
          decoration: BoxDecoration(
            color: hovered
                ? titleColor.withValues(alpha: 0.05)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                child: isActive
                    ? Icon(Codicons.check, size: 13, color: titleColor)
                    : null,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  account.customLabel?.trim().isNotEmpty == true
                      ? '${account.email} (${account.customLabel!.trim()})'
                      : account.email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                    color: titleColor,
                  ),
                ),
              ),
              if (account.tier != AntigravityTier.unknown) ...[
                const SizedBox(width: 6),
                Text(
                  account.tier.badge,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                    color: subColor,
                  ),
                ),
              ],
              if (pct != null) ...[
                const SizedBox(width: 6),
                AntigravityQuotaRing(
                  fraction: pct / 100.0,
                  size: 13,
                  strokeWidth: 1.8,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
