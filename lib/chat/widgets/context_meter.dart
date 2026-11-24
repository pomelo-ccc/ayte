// How full the conversation's context is: a ring, as upstream's context
// usage widget, and, in the row under the conversation's card, how many
// tokens of how many. A click toggles the context panel.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ide/ide_hover.dart';
import '../../kernel/kernel_types.dart';
import '../../theme/app_theme.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import 'hover_builder.dart';

class ContextMeter extends StatelessWidget {
  const ContextMeter({
    super.key,
    required this.usage,
    required this.active,
    required this.tooltip,
    required this.onTap,
    this.labeled = false,
    this.compactPercent = false,
  });

  final ContextUsage usage;

  /// Whether the context panel is open.
  final bool active;
  final String tooltip;
  final VoidCallback onTap;

  /// With how many tokens of how many after the ring (`100K / 200K`),
  /// in [AppColors.caution] once [warnAt] of it is used.
  final bool labeled;

  /// Compact ghost-pill style next to the composer's model picker: a crisp
  /// 13px ring paired with a subtle tabular percentage (e.g. `34%`).
  final bool compactPercent;

  /// Thresholds for caution (amber) and critical (coral-red) states.
  static const cautionAt = 0.65;
  static const warnAt = 0.85;

  static Color _arcColorFor(double fraction) {
    if (fraction >= warnAt) return const Color(0xFFDC3E3E);
    if (fraction >= cautionAt) return const Color(0xFFD98B1C);
    return AppColors.accent.withValues(alpha: 1.0);
  }

  /// Shared TapRegion group ID between [ContextMeter] and [ContextUsagePanel].
  static const tapRegionGroupId = 'context-usage-popover';

  /// [tokens] short: `1.2M`, `100K`, `12.5K`, `800`.
  static String format(int tokens) {
    String short(double value) => value >= 100 || value == value.roundToDouble()
        ? value.round().toString()
        : value.toStringAsFixed(1);
    if (tokens >= 1000000) return '${short(tokens / 1000000)}M';
    if (tokens >= 1000) return '${short(tokens / 1000)}K';
    return '$tokens';
  }

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final dark = colors.dark;
    final fraction = usage.fraction;
    final warn = fraction >= warnAt;
    final caution = fraction >= cautionAt;
    final arcColor = _arcColorFor(fraction);
    final trackColor = (dark ? Colors.white : Colors.black).withValues(
      alpha: dark ? 0.22 : 0.14,
    );
    final showPercent = compactPercent && !labeled;
    final ringDim = showPercent ? 13.0 : 16.0;
    final strokeWidth = showPercent ? 1.9 : 2.35;
    final ring = SizedBox.square(
      dimension: ringDim,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: fraction),
        duration: const Duration(milliseconds: 400),
        builder: (context, value, _) => CustomPaint(
          painter: _RingPainter(
            value,
            track: trackColor,
            arc: arcColor,
            strokeWidth: strokeWidth,
          ),
        ),
      ),
    );
    final pct = (fraction * 100).round().clamp(0, 100);
    final summary = usage.window == 0
        ? format(usage.used)
        : '$pct% (${format(usage.used)} / ${format(usage.window)})';
    final hoverContent = tooltip.contains(' · ')
        ? null
        : Text('$tooltip · $summary');
    final ghostBgActive = (dark ? Colors.white : Colors.black).withValues(
      alpha: dark ? 0.10 : 0.065,
    );
    final ghostBgHover = (dark ? Colors.white : Colors.black).withValues(
      alpha: dark ? 0.07 : 0.045,
    );
    return TapRegion(
      groupId: tapRegionGroupId,
      child: IdeHover(
        position: IdeHoverPosition.above,
        message: tooltip,
        content: hoverContent,
        child: HoverBuilder(
          cursor: SystemMouseCursors.click,
          builder: (context, hovered) {
            final compactTextColor = warn
                ? const Color(0xFFDC3E3E)
                : caution
                ? const Color(0xFFD98B1C)
                : (active || hovered ? AppColors.textMuted : AppColors.textFaint);
            return GestureDetector(
              // Keeps editor focus while opening the popover.
              onTapDown: (_) {},
              onTap: onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: (labeled || showPercent) ? null : 26,
                height: showPercent ? 25 : 26,
                padding: (labeled || showPercent)
                    ? const EdgeInsets.symmetric(horizontal: 6)
                    : EdgeInsets.zero,
                // The ring keeps its square: the box is taller than it.
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: showPercent
                      ? (active
                            ? ghostBgActive
                            : hovered
                            ? ghostBgHover
                            : Colors.transparent)
                      : (active
                            ? colors['toolbar.activeBackground']
                            : hovered
                            ? colors['toolbar.hoverBackground']
                            : Colors.transparent),
                  borderRadius: BorderRadius.circular(
                    showPercent ? 7 : (labeled ? 5 : 13),
                  ),
                ),
                child: labeled
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ring,
                          const SizedBox(width: 5),
                          Text(
                            usage.window == 0
                                ? format(usage.used)
                                : '${format(usage.used)} / ${format(usage.window)}',
                            maxLines: 1,
                            style: TextStyle(
                              color: warn
                                  ? AppColors.caution
                                  : AppColors.textFaint,
                              fontSize: 12,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      )
                    : showPercent
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ring,
                          const SizedBox(width: 5),
                          Text(
                            usage.window == 0 ? format(usage.used) : '$pct%',
                            maxLines: 1,
                            style: TextStyle(
                              color: compactTextColor,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      )
                    : ring,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// As upstream's context usage widget: the track `disabledForeground`, the
/// arc `icon.foreground`.
class _RingPainter extends CustomPainter {
  _RingPainter(
    this.fraction, {
    required this.track,
    required this.arc,
    this.strokeWidth = 2.35,
  });

  final double fraction;
  final Color track;
  final Color arc;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, stroke..color = track);
    if (fraction <= 0) return;
    final clamped = fraction.clamp(0.0, 1.0);
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * clamped,
      false,
      stroke..color = arc,
    );
    if (fraction >= 0.95) {
      canvas.drawCircle(
        center,
        2.0,
        Paint()
          ..style = PaintingStyle.fill
          ..color = arc,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.fraction != fraction ||
      oldDelegate.track != track ||
      oldDelegate.arc != arc ||
      oldDelegate.strokeWidth != strokeWidth;
}
