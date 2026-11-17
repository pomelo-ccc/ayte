import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'antigravity_account_models.dart';

/// Circular remaining-quota ring matching the official Antigravity `Usage` UI.
class AntigravityQuotaRing extends StatelessWidget {
  const AntigravityQuotaRing({
    super.key,
    required this.fraction,
    this.size = 18,
    this.strokeWidth = 2.2,
    this.trackColor,
  });

  final double fraction;
  final double size;
  final double strokeWidth;
  final Color? trackColor;

  static Color colorForPercentage(int pct) => pct >= 25
      ? const Color(0xFF439847)
      : pct >= 10
      ? const Color(0xFFD98B1C)
      : const Color(0xFFDC3E3E);

  @override
  Widget build(BuildContext context) {
    final clamped = fraction.clamp(0.0, 1.0);
    final pct = (clamped * 100).round();
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _QuotaRingPainter(
          fraction: clamped,
          strokeWidth: strokeWidth,
          activeColor: colorForPercentage(pct),
          trackColor:
              trackColor ??
              Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.16),
        ),
      ),
    );
  }
}

class _QuotaRingPainter extends CustomPainter {
  const _QuotaRingPainter({
    required this.fraction,
    required this.strokeWidth,
    required this.activeColor,
    required this.trackColor,
  });

  final double fraction;
  final double strokeWidth;
  final Color activeColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, trackPaint);

    if (fraction <= 0.0) return;
    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    if (fraction >= 0.995) {
      canvas.drawCircle(center, radius, activePaint);
      return;
    }
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * fraction,
      false,
      activePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _QuotaRingPainter old) =>
      old.fraction != fraction ||
      old.strokeWidth != strokeWidth ||
      old.activeColor != activeColor ||
      old.trackColor != trackColor;
}

/// Renders one `AntigravityQuotaBucket` row (`Weekly limit` / `5h limit`,
/// optional `Resets in ...` when `< 100%`, `<pct>% left` + circular ring).
class AntigravityUsageBucketRow extends StatelessWidget {
  const AntigravityUsageBucketRow({
    super.key,
    required this.bucket,
    required this.primaryColor,
    required this.secondaryColor,
    this.trackColor,
  });

  final AntigravityQuotaBucket bucket;
  final Color primaryColor;
  final Color secondaryColor;
  final Color? trackColor;

  String get _windowTitle => switch (bucket.window) {
    'weekly' => 'Weekly limit',
    '5h' => '5h limit',
    _ => bucket.displayName.isNotEmpty ? bucket.displayName : bucket.bucketId,
  };

  @override
  Widget build(BuildContext context) {
    final pct = bucket.percentage.clamp(0, 100);
    final reset = pct < 100 ? formatUsageResetIn(bucket.resetTime) : '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _windowTitle,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w400,
                    color: secondaryColor,
                    height: 1.3,
                  ),
                ),
                if (reset.isNotEmpty) ...[
                  const SizedBox(height: 1.5),
                  Text(
                    reset,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: secondaryColor.withValues(alpha: 0.85),
                      height: 1.25,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '$pct% left',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w400,
              color: secondaryColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 8),
          AntigravityQuotaRing(
            fraction: bucket.remainingFraction,
            size: 18,
            strokeWidth: 2.1,
            trackColor: trackColor,
          ),
        ],
      ),
    );
  }
}

/// Stacked vertical `Usage` groups list matching the Antigravity Usage popover.
class AntigravityUsageGroupsStack extends StatelessWidget {
  const AntigravityUsageGroupsStack({
    super.key,
    required this.groups,
    required this.titleColor,
    required this.secondaryColor,
    this.trackColor,
  });

  final List<AntigravityQuotaGroup> groups;
  final Color titleColor;
  final Color secondaryColor;
  final Color? trackColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (idx, group) in groups.indexed) ...[
          if (idx > 0) const SizedBox(height: 12),
          Text(
            group.displayName,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: titleColor,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 4),
          for (final bucket in group.buckets)
            AntigravityUsageBucketRow(
              bucket: bucket,
              primaryColor: titleColor,
              secondaryColor: secondaryColor,
              trackColor: trackColor,
            ),
        ],
      ],
    );
  }
}
