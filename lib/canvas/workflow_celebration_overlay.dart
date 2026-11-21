import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import 'canvas_controller.dart';

/// Full-window celebratory fireworks & floating status banner overlay that
/// reacts whenever [CanvasController] finishes a workflow run.
///
/// - On successful completion: launches multi-wave physical fireworks bursts
///   (rising trails, shockwave rings, dual-ring glowing sparks with trails &
///   twinkle, plus 3D tumbling confetti ribbons) across the window while
///   remaining completely click-through (`IgnorePointer`), accompanied by a
///   high-contrast floating completion banner at top-center.
/// - On failure (non-cancelled): skips fireworks and shows a prominent crimson
///   failure banner so the user never misses a failed step.
class WorkflowCelebrationOverlay extends StatefulWidget {
  const WorkflowCelebrationOverlay({
    super.key,
    required this.child,
    this.controller,
  });

  final Widget child;
  final CanvasController? controller;

  @override
  State<WorkflowCelebrationOverlay> createState() =>
      _WorkflowCelebrationOverlayState();
}

class _WorkflowCelebrationOverlayState extends State<WorkflowCelebrationOverlay>
    with TickerProviderStateMixin {
  CanvasController get _ctrl => widget.controller ?? CanvasController.instance;

  late final AnimationController _fireworksCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4600),
  );

  late final AnimationController _bannerCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    reverseDuration: const Duration(milliseconds: 260),
  );

  late final AnimationController _countdownCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 6200),
  );

  WorkflowCompletionEvent? _activeEvent;
  int _lastHandledRunId = 0;
  List<_FireworkBurst> _bursts = const [];
  List<_ConfettiPiece> _confetti = const [];
  int _seedCounter = 0;
  bool _hoveringBanner = false;
  bool _showFireworks = false;

  @override
  void initState() {
    super.initState();
    _lastHandledRunId = _ctrl.lastCompletionEvent?.runId ?? 0;
    _ctrl.addListener(_onControllerChanged);
    _fireworksCtrl.addStatusListener(_onFireworksStatus);
    _countdownCtrl.addStatusListener(_onCountdownStatus);
  }

  @override
  void didUpdateWidget(covariant WorkflowCelebrationOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? CanvasController.instance).removeListener(
        _onControllerChanged,
      );
      _ctrl.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onControllerChanged);
    _fireworksCtrl.removeStatusListener(_onFireworksStatus);
    _countdownCtrl.removeStatusListener(_onCountdownStatus);
    _fireworksCtrl.dispose();
    _bannerCtrl.dispose();
    _countdownCtrl.dispose();
    super.dispose();
  }

  void _onFireworksStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() => _showFireworks = false);
    }
  }

  void _onCountdownStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && !_hoveringBanner && mounted) {
      unawaited(_dismissBanner());
    }
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final ev = _ctrl.lastCompletionEvent;
    if (ev == null || ev.runId <= _lastHandledRunId) return;
    _lastHandledRunId = ev.runId;
    if (ev.cancelled) return;
    _presentEvent(ev);
  }

  void _presentEvent(WorkflowCompletionEvent ev) {
    final reduceMotion = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;

    setState(() {
      _activeEvent = ev;
      _hoveringBanner = false;
      if (ev.ok && !reduceMotion) {
        _generateShow();
        _showFireworks = true;
      } else {
        _showFireworks = false;
      }
    });

    if (ev.ok && !reduceMotion) {
      _fireworksCtrl.forward(from: 0);
    } else {
      _fireworksCtrl.stop();
    }

    _bannerCtrl.forward(from: 0);
    _countdownCtrl.forward(from: 0);
  }

  void _replayFireworks() {
    final reduceMotion = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
    if (reduceMotion) return;
    setState(() {
      _generateShow();
      _showFireworks = true;
    });
    _fireworksCtrl.forward(from: 0);
    _countdownCtrl.forward(from: 0);
  }

  Future<void> _dismissBanner() async {
    _countdownCtrl.stop();
    await _bannerCtrl.reverse();
    if (!mounted) return;
    setState(() {
      _activeEvent = null;
    });
  }

  void _generateShow() {
    _seedCounter++;
    final rng = math.Random(
      DateTime.now().microsecondsSinceEpoch ^ (_seedCounter * 7919),
    );

    const palettes = <List<Color>>[
      // Warm Gold & Sunset Coral
      [Color(0xFFF59E0B), Color(0xFFFBBF24), Color(0xFFF43F5E), Color(0xFFFFEDD5)],
      // Emerald Mint & Sky Cyan
      [Color(0xFF10B981), Color(0xFF34D399), Color(0xFF38BDF8), Color(0xFFD1FAE5)],
      // Electric Violet & Rose Pink
      [Color(0xFFA855F7), Color(0xFFEC4899), Color(0xFFF472B6), Color(0xFFFDE68A)],
      // Royal Azure & Champagne Gold
      [Color(0xFF3B82F6), Color(0xFF38BDF8), Color(0xFFFBBF24), Color(0xFFE0F2FE)],
      // Festive Crimson & Amber Spark
      [Color(0xFFEF4444), Color(0xFFF97316), Color(0xFFFACC15), Color(0xFFFFF7ED)],
      // Aurora Teal & Orchid
      [Color(0xFF14B8A6), Color(0xFF6366F1), Color(0xFFE879F9), Color(0xFFFEF08A)],
    ];

    // 6 choreographed bursts across the upper sky with gentle organic jitter.
    const baseCoords = <(double x, double y, double start, double scale)>[
      (0.24, 0.28, 0.00, 1.02),
      (0.76, 0.25, 0.07, 1.05),
      (0.50, 0.19, 0.16, 1.22), // Centerpiece grand burst
      (0.18, 0.38, 0.27, 0.92),
      (0.82, 0.36, 0.35, 0.96),
      (0.46, 0.27, 0.45, 1.12),
    ];

    final bursts = <_FireworkBurst>[];
    for (var i = 0; i < baseCoords.length; i++) {
      final (bx, by, start, scale) = baseCoords[i];
      final palette = palettes[(i + rng.nextInt(palettes.length)) % palettes.length];
      final cx = (bx + (rng.nextDouble() - 0.5) * 0.08).clamp(0.12, 0.88);
      final cy = (by + (rng.nextDouble() - 0.5) * 0.07).clamp(0.13, 0.46);
      final launchX = (cx + (rng.nextDouble() - 0.5) * 0.12).clamp(0.08, 0.92);

      final sparks = <_SparkParticle>[];
      final outerCount = 34 + rng.nextInt(10);
      for (var k = 0; k < outerCount; k++) {
        final angle =
            (k / outerCount) * math.pi * 2 + (rng.nextDouble() - 0.5) * 0.14;
        final speed = (185 + rng.nextDouble() * 145) * scale;
        sparks.add(
          _SparkParticle(
            vx: math.cos(angle) * speed,
            vy: math.sin(angle) * speed,
            color: palette[k % palette.length],
            radius: 2.0 + rng.nextDouble() * 1.8,
            drag: 1.45 + rng.nextDouble() * 0.45,
            gravity: 118 + rng.nextDouble() * 48,
            lifeSpan: 0.72 + rng.nextDouble() * 0.28,
            twinklePhase: rng.nextDouble() * math.pi * 2,
            isInner: false,
          ),
        );
      }

      // Warm inner ring for richer chrysanthemum depth.
      final innerCount = 16 + rng.nextInt(6);
      for (var k = 0; k < innerCount; k++) {
        final angle =
            (k / innerCount) * math.pi * 2 + (rng.nextDouble() - 0.5) * 0.2;
        final speed = (75 + rng.nextDouble() * 70) * scale;
        sparks.add(
          _SparkParticle(
            vx: math.cos(angle) * speed,
            vy: math.sin(angle) * speed,
            color: k.isEven ? palette.last : palette.first,
            radius: 1.6 + rng.nextDouble() * 1.2,
            drag: 1.6 + rng.nextDouble() * 0.35,
            gravity: 95 + rng.nextDouble() * 35,
            lifeSpan: 0.55 + rng.nextDouble() * 0.25,
            twinklePhase: rng.nextDouble() * math.pi * 2,
            isInner: true,
          ),
        );
      }

      bursts.add(
        _FireworkBurst(
          launchX: launchX,
          targetX: cx,
          targetY: cy,
          startFrac: start,
          ascendFrac: 0.065,
          burstDurationFrac: 0.44,
          primaryColor: palette.first,
          accentColor: palette[1],
          sparks: sparks,
        ),
      );
    }

    // 52 festive confetti ribbons streaming from top corners.
    const confettiColors = <Color>[
      Color(0xFFF59E0B),
      Color(0xFF10B981),
      Color(0xFF38BDF8),
      Color(0xFFF43F5E),
      Color(0xFFA855F7),
      Color(0xFFFACC15),
      Color(0xFFEC4899),
    ];
    final confetti = <_ConfettiPiece>[];
    for (var i = 0; i < 52; i++) {
      final fromLeft = i.isEven;
      confetti.add(
        _ConfettiPiece(
          startX: fromLeft
              ? 0.04 + rng.nextDouble() * 0.24
              : 0.72 + rng.nextDouble() * 0.24,
          startY: -0.02 - rng.nextDouble() * 0.06,
          vx: (fromLeft ? 1 : -1) * (60 + rng.nextDouble() * 190),
          vy: 75 + rng.nextDouble() * 145,
          startFrac: 0.02 + rng.nextDouble() * 0.26,
          swayAmp: 18 + rng.nextDouble() * 34,
          swayFreq: 2.2 + rng.nextDouble() * 2.8,
          spinSpeed: 3.5 + rng.nextDouble() * 5.5,
          flipSpeed: 4.5 + rng.nextDouble() * 6.0,
          phase: rng.nextDouble() * math.pi * 2,
          width: 6.5 + rng.nextDouble() * 5.0,
          height: 3.2 + rng.nextDouble() * 2.8,
          color: confettiColors[i % confettiColors.length],
        ),
      );
    }

    _bursts = bursts;
    _confetti = confetti;
  }

  @override
  Widget build(BuildContext context) {
    final ev = _activeEvent;
    final colors = themeColors;
    final dark = colors.dark;
    final isZh = Localizations.localeOf(context).languageCode == 'zh';

    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (_showFireworks)
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _fireworksCtrl,
                  builder: (context, _) => CustomPaint(
                    painter: _FireworksPainter(
                      progress: _fireworksCtrl.value,
                      bursts: _bursts,
                      confetti: _confetti,
                      dark: dark,
                    ),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),
          ),
        if (ev != null)
          Positioned(
            top: 52,
            left: 20,
            right: 20,
            child: Align(
              alignment: Alignment.topCenter,
              child: FadeTransition(
                opacity: CurvedAnimation(
                  parent: _bannerCtrl,
                  curve: Curves.easeOutCubic,
                ),
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, -0.35),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: _bannerCtrl,
                      curve: Curves.easeOutBack,
                      reverseCurve: Curves.easeInCubic,
                    ),
                  ),
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.92, end: 1.0).animate(
                      CurvedAnimation(
                        parent: _bannerCtrl,
                        curve: Curves.easeOutBack,
                        reverseCurve: Curves.easeIn,
                      ),
                    ),
                    child: MouseRegion(
                      onEnter: (_) {
                        _hoveringBanner = true;
                        _countdownCtrl.stop();
                      },
                      onExit: (_) {
                        _hoveringBanner = false;
                        if (_activeEvent != null &&
                            !_countdownCtrl.isCompleted) {
                          _countdownCtrl.forward();
                        }
                      },
                      child: _CompletionBannerCard(
                        event: ev,
                        dark: dark,
                        isZh: isZh,
                        countdown: _countdownCtrl,
                        onReplay: ev.ok ? _replayFireworks : null,
                        onDismiss: () => unawaited(_dismissBanner()),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _CompletionBannerCard extends StatelessWidget {
  const _CompletionBannerCard({
    required this.event,
    required this.dark,
    required this.isZh,
    required this.countdown,
    required this.onDismiss,
    this.onReplay,
  });

  final WorkflowCompletionEvent event;
  final bool dark;
  final bool isZh;
  final Animation<double> countdown;
  final VoidCallback? onReplay;
  final VoidCallback onDismiss;

  String _formatDuration(Duration d) {
    final ms = d.inMilliseconds;
    if (ms < 1000) return '${ms}ms';
    final secs = ms / 1000;
    if (secs < 60) return '${secs.toStringAsFixed(1)}s';
    final m = d.inMinutes;
    final rem = d.inSeconds % 60;
    return '${m}m ${rem}s';
  }

  @override
  Widget build(BuildContext context) {
    final ok = event.ok;
    final accent = ok ? const Color(0xFF10B981) : const Color(0xFFEF4444);
    final secondaryAccent = ok
        ? const Color(0xFFF59E0B)
        : const Color(0xFFF97316);

    final bg = dark
        ? const Color(0xFF161A22).withValues(alpha: 0.96)
        : Colors.white.withValues(alpha: 0.97);
    final titleColor = dark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A);
    final subColor = dark ? const Color(0xFF94A3B8) : const Color(0xFF475569);

    final headline = ok
        ? (isZh ? '工作流执行完成！' : 'Workflow Completed!')
        : (isZh ? '工作流执行未通过' : 'Workflow Failed');

    final durStr = _formatDuration(event.duration);
    final subtitle = ok
        ? (isZh
              ? '${event.workflowName} · 已通过 ${event.succeededNodes} 个节点'
              : '${event.workflowName} · ${event.succeededNodes} nodes passed')
        : (event.error?.isNotEmpty == true
              ? '${event.workflowName} · ${event.error}'
              : (isZh
                    ? '${event.workflowName} · 部分节点执行失败'
                    : '${event.workflowName} · One or more nodes failed'));

    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, minWidth: 320),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                accent.withValues(alpha: dark ? 0.72 : 0.55),
                secondaryAccent.withValues(alpha: dark ? 0.65 : 0.45),
                (ok ? const Color(0xFF38BDF8) : const Color(0xFFEF4444))
                    .withValues(alpha: dark ? 0.55 : 0.4),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: dark ? 0.28 : 0.18),
                blurRadius: 28,
                spreadRadius: 1,
                offset: const Offset(0, 10),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.45 : 0.1),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          padding: const EdgeInsets.all(1.5),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14.5),
            child: Container(
              color: bg,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 10, 11),
                    child: Row(
                      children: [
                        // Glowing emblem badge
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                accent.withValues(alpha: dark ? 0.28 : 0.18),
                                secondaryAccent.withValues(
                                  alpha: dark ? 0.22 : 0.14,
                                ),
                              ],
                            ),
                            border: Border.all(
                              color: accent.withValues(alpha: 0.45),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            ok ? Codicons.sparkle : Codicons.error,
                            size: 19,
                            color: ok
                                ? (dark
                                      ? const Color(0xFFFBBF24)
                                      : const Color(0xFFD97706))
                                : accent,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      headline,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -0.1,
                                        color: titleColor,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: accent.withValues(
                                        alpha: dark ? 0.2 : 0.12,
                                      ),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color: accent.withValues(alpha: 0.3),
                                      ),
                                    ),
                                    child: Text(
                                      durStr,
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                        color: dark
                                            ? (ok
                                                  ? const Color(0xFF34D399)
                                                  : const Color(0xFFF87171))
                                            : accent,
                                        fontFeatures: const [
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                subtitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.3,
                                  color: subColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (onReplay != null) ...[
                          const SizedBox(width: 8),
                          Tooltip(
                            message: isZh ? '再放一次烟花' : 'Replay fireworks',
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: onReplay,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: secondaryAccent.withValues(
                                    alpha: dark ? 0.18 : 0.11,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: secondaryAccent.withValues(
                                      alpha: 0.34,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Codicons.sparkle,
                                      size: 13,
                                      color: dark
                                          ? const Color(0xFFFBBF24)
                                          : const Color(0xFFD97706),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      isZh ? '再放一次' : 'Encore',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                        color: dark
                                            ? const Color(0xFFFDE68A)
                                            : const Color(0xFFB45309),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 4),
                        Tooltip(
                          message: isZh ? '关闭提示' : 'Dismiss',
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: onDismiss,
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Icon(
                                Codicons.close,
                                size: 14,
                                color: subColor,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Auto-dismiss progress bar
                  AnimatedBuilder(
                    animation: countdown,
                    builder: (context, _) {
                      final remaining = (1.0 - countdown.value).clamp(0.0, 1.0);
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: remaining,
                          child: Container(
                            height: 2.5,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [accent, secondaryAccent],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FireworkBurst {
  const _FireworkBurst({
    required this.launchX,
    required this.targetX,
    required this.targetY,
    required this.startFrac,
    required this.ascendFrac,
    required this.burstDurationFrac,
    required this.primaryColor,
    required this.accentColor,
    required this.sparks,
  });

  final double launchX;
  final double targetX;
  final double targetY;
  final double startFrac;
  final double ascendFrac;
  final double burstDurationFrac;
  final Color primaryColor;
  final Color accentColor;
  final List<_SparkParticle> sparks;
}

class _SparkParticle {
  const _SparkParticle({
    required this.vx,
    required this.vy,
    required this.color,
    required this.radius,
    required this.drag,
    required this.gravity,
    required this.lifeSpan,
    required this.twinklePhase,
    required this.isInner,
  });

  final double vx;
  final double vy;
  final Color color;
  final double radius;
  final double drag;
  final double gravity;
  final double lifeSpan;
  final double twinklePhase;
  final bool isInner;
}

class _ConfettiPiece {
  const _ConfettiPiece({
    required this.startX,
    required this.startY,
    required this.vx,
    required this.vy,
    required this.startFrac,
    required this.swayAmp,
    required this.swayFreq,
    required this.spinSpeed,
    required this.flipSpeed,
    required this.phase,
    required this.width,
    required this.height,
    required this.color,
  });

  final double startX;
  final double startY;
  final double vx;
  final double vy;
  final double startFrac;
  final double swayAmp;
  final double swayFreq;
  final double spinSpeed;
  final double flipSpeed;
  final double phase;
  final double width;
  final double height;
  final Color color;
}

class _FireworksPainter extends CustomPainter {
  const _FireworksPainter({
    required this.progress,
    required this.bursts,
    required this.confetti,
    required this.dark,
  });

  final double progress;
  final List<_FireworkBurst> bursts;
  final List<_ConfettiPiece> confetti;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final scale = (math.min(size.width, size.height) / 760.0).clamp(0.65, 1.35);

    // 1. Confetti ribbons drifting from upper corners.
    _paintConfetti(canvas, size, scale);

    // 2. Multi-wave firework shells: launch trail -> shockwave -> glowing sparks.
    for (final burst in bursts) {
      _paintBurst(canvas, size, burst, scale);
    }
  }

  void _paintBurst(
    Canvas canvas,
    Size size,
    _FireworkBurst burst,
    double scale,
  ) {
    final local = progress - burst.startFrac;
    if (local < 0) return;

    final launchPos = Offset(size.width * burst.launchX, size.height * 0.88);
    final center = Offset(
      size.width * burst.targetX,
      size.height * burst.targetY,
    );

    // Phase A: Ascending rocket trail
    if (local < burst.ascendFrac) {
      final t = (local / burst.ascendFrac).clamp(0.0, 1.0);
      final eased = Curves.easeOutCubic.transform(t);
      final head = Offset.lerp(launchPos, center, eased)!;
      final tailT = math.max(0.0, eased - 0.22);
      final tail = Offset.lerp(launchPos, center, tailT)!;

      final trailPaint = Paint()
        ..shader = LinearGradient(
          colors: [
            burst.primaryColor.withValues(alpha: 0.0),
            burst.accentColor.withValues(alpha: dark ? 0.85 : 0.72),
            Colors.white.withValues(alpha: dark ? 0.95 : 0.85),
          ],
        ).createShader(Rect.fromPoints(tail, head))
        ..strokeWidth = 2.6 * scale
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      canvas.drawLine(tail, head, trailPaint);

      final headGlow = Paint()
        ..color = burst.primaryColor.withValues(alpha: dark ? 0.55 : 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawCircle(head, 4.5 * scale, headGlow);
      canvas.drawCircle(
        head,
        2.2 * scale,
        Paint()..color = dark ? Colors.white : burst.primaryColor,
      );
      return;
    }

    // Phase B: Explosion & falling spark trails
    final burstElapsed = local - burst.ascendFrac;
    if (burstElapsed > burst.burstDurationFrac) return;
    final norm = (burstElapsed / burst.burstDurationFrac).clamp(0.0, 1.0);
    // Physical seconds since ignition (burstDurationFrac ~ 2.0s)
    final tSec = norm * 2.05;

    // Flash glow + shockwave ring right after ignition
    if (norm < 0.28) {
      final flashT = (norm / 0.28).clamp(0.0, 1.0);
      final flashAlpha = (1.0 - flashT) * (1.0 - flashT);
      final flashRadius = (20 + 78 * Curves.easeOutQuad.transform(flashT)) * scale;
      final glowPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            (dark ? Colors.white : burst.accentColor).withValues(
              alpha: flashAlpha * (dark ? 0.52 : 0.32),
            ),
            burst.primaryColor.withValues(alpha: flashAlpha * 0.18),
            burst.primaryColor.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: flashRadius));
      canvas.drawCircle(center, flashRadius, glowPaint);

      final ringPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (2.6 * (1.0 - flashT) + 0.5) * scale
        ..color = burst.accentColor.withValues(
          alpha: flashAlpha * (dark ? 0.58 : 0.45),
        );
      canvas.drawCircle(center, flashRadius * 0.92, ringPaint);
    }

    // Spark particles with analytical air-drag + gravity & multi-segment trails
    for (final s in burst.sparks) {
      if (norm > s.lifeSpan) continue;
      final lifeT = (norm / s.lifeSpan).clamp(0.0, 1.0);
      final fade = math.pow(1.0 - lifeT, 1.55).toDouble();
      final twinkle = lifeT > 0.42
          ? (0.62 + 0.38 * math.sin(tSec * 22.0 + s.twinklePhase))
          : 1.0;
      final alpha = (fade * twinkle).clamp(0.0, 1.0);
      if (alpha <= 0.02) continue;

      final pos = _sparkPos(center, s, tSec, scale);
      final trailDt = s.isInner ? 0.065 : 0.105;
      final prevT = math.max(0.0, tSec - trailDt);
      final prevPos = _sparkPos(center, s, prevT, scale);

      final sparkColor = _toneForTheme(s.color, dark);

      // Tapered glowing tail
      if ((pos - prevPos).distanceSquared > 1.0) {
        final tailPaint = Paint()
          ..shader = LinearGradient(
            colors: [
              sparkColor.withValues(alpha: 0.0),
              sparkColor.withValues(alpha: alpha * (dark ? 0.78 : 0.68)),
            ],
          ).createShader(Rect.fromPoints(prevPos, pos))
          ..strokeWidth = math.max(1.0, s.radius * (1.15 - lifeT * 0.45) * scale)
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke;
        canvas.drawLine(prevPos, pos, tailPaint);
      }

      // Soft halo around bright spark head
      final headR = math.max(0.9, s.radius * (1.0 - lifeT * 0.35) * scale);
      if (dark) {
        canvas.drawCircle(
          pos,
          headR * 2.3,
          Paint()
            ..color = sparkColor.withValues(alpha: alpha * 0.28)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
      } else {
        // Subtle crisp outline on light backgrounds so bright sparks pop.
        canvas.drawCircle(
          pos,
          headR * 1.45,
          Paint()..color = sparkColor.withValues(alpha: alpha * 0.22),
        );
      }

      // Bright core
      canvas.drawCircle(
        pos,
        headR,
        Paint()
          ..color = Color.lerp(
            sparkColor,
            dark ? Colors.white : sparkColor,
            (1.0 - lifeT) * 0.45,
          )!.withValues(alpha: alpha),
      );
    }
  }

  Offset _sparkPos(
    Offset origin,
    _SparkParticle s,
    double t,
    double scale,
  ) {
    final decay = (1.0 - math.exp(-s.drag * t)) / s.drag;
    final dx = s.vx * decay * scale;
    final dy = (s.vy * decay + 0.5 * s.gravity * t * t) * scale;
    return Offset(origin.dx + dx, origin.dy + dy);
  }

  void _paintConfetti(Canvas canvas, Size size, double scale) {
    for (final c in confetti) {
      final local = progress - c.startFrac;
      if (local <= 0) continue;
      final norm = (local / 0.76).clamp(0.0, 1.0);
      if (norm >= 1.0) continue;
      final tSec = norm * 3.4;

      final dragX = (1.0 - math.exp(-1.1 * tSec)) / 1.1;
      final x =
          size.width * c.startX +
          c.vx * dragX * scale +
          math.sin(tSec * c.swayFreq + c.phase) * c.swayAmp * scale;
      final y =
          size.height * c.startY +
          (c.vy * tSec + 0.5 * 58.0 * tSec * tSec) * scale;
      if (y > size.height + 24) continue;

      final alpha = norm < 0.72
          ? 0.92
          : (1.0 - (norm - 0.72) / 0.28).clamp(0.0, 1.0) * 0.92;
      if (alpha <= 0.02) continue;

      final color = _toneForTheme(c.color, dark).withValues(alpha: alpha);
      final angle = c.phase + tSec * c.spinSpeed;
      final flipScaleY = 0.25 + 0.75 * math.cos(tSec * c.flipSpeed + c.phase).abs();

      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(angle);
      canvas.scale(1.0, flipScaleY);
      final rect = Rect.fromCenter(
        center: Offset.zero,
        width: c.width * scale,
        height: c.height * scale,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1.4)),
        Paint()..color = color,
      );
      canvas.restore();
    }
  }

  Color _toneForTheme(Color raw, bool dark) {
    if (dark) return raw;
    // Deepen very pale pastel highlights slightly on light themes so they
    // remain vibrant and legible against white/light-gray canvases.
    final hsl = HSLColor.fromColor(raw);
    if (hsl.lightness > 0.78) {
      return hsl
          .withLightness(0.56)
          .withSaturation(math.min(1.0, hsl.saturation + 0.15))
          .toColor();
    }
    return raw;
  }

  @override
  bool shouldRepaint(covariant _FireworksPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.dark != dark ||
      oldDelegate.bursts != bursts;
}
