import 'package:flutter/material.dart';

class AppDurations {
  AppDurations._();
  static const Duration fast = Duration(milliseconds: 200);
  static const Duration normal = Duration(milliseconds: 350);
  static const Duration slow = Duration(milliseconds: 500);
  static const Duration pageTransition = Duration(milliseconds: 400);
}

class AppCurves {
  AppCurves._();
  static const Curve easeOut = Curves.easeOutCubic;
  static const Curve elasticOut = Curves.elasticOut;
  static const Curve slideIn = Curves.easeOutQuart;
  static const Curve fadeIn = Curves.easeInOut;
}

class FadeSlideIn extends StatelessWidget {
  final Widget child;
  final Duration duration;
  final Offset beginOffset;
  final Curve curve;

  const FadeSlideIn({
    super.key,
    required this.child,
    this.duration = AppDurations.normal,
    this.beginOffset = const Offset(0, 0.05),
    this.curve = AppCurves.slideIn,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: duration,
      curve: curve,
      builder: (context, value, _) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(
              beginOffset.dx * (1 - value),
              beginOffset.dy * (1 - value),
            ),
            child: child,
          ),
        );
      },
    );
  }
}

class ScaleIn extends StatelessWidget {
  final Widget child;
  final Duration duration;
  final double beginScale;
  final Curve curve;

  const ScaleIn({
    super.key,
    required this.child,
    this.duration = AppDurations.normal,
    this.beginScale = 0.92,
    this.curve = AppCurves.easeOut,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: beginScale, end: 1.0),
      duration: duration,
      curve: curve,
      builder: (context, value, _) {
        return Transform.scale(
          scale: value,
          child: Opacity(
            opacity: (value - beginScale) / (1 - beginScale),
            child: child,
          ),
        );
      },
    );
  }
}

class AnimatedHeart extends StatefulWidget {
  final bool isActive;
  final double size;
  final Color? activeColor;
  final Color? inactiveColor;
  final VoidCallback? onTap;

  const AnimatedHeart({
    super.key,
    required this.isActive,
    this.size = 24,
    this.activeColor,
    this.inactiveColor,
    this.onTap,
  });

  @override
  State<AnimatedHeart> createState() => _AnimatedHeartState();
}

class _AnimatedHeartState extends State<AnimatedHeart>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _scaleAnim = TweenSequence([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.3), weight: 40),
      TweenSequenceItem(tween: Tween(begin: 1.3, end: 1.0), weight: 60),
    ]).animate(CurvedAnimation(parent: _controller, curve: AppCurves.elasticOut));
  }

  @override
  void didUpdateWidget(AnimatedHeart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: ScaleTransition(
        scale: _scaleAnim,
        child: Icon(
          widget.isActive ? Icons.favorite : Icons.favorite_border,
          size: widget.size,
          color: widget.isActive
              ? (widget.activeColor ?? Colors.redAccent)
              : (widget.inactiveColor ?? Colors.grey),
        ),
      ),
    );
  }
}

class ShimmerLoading extends StatefulWidget {
  final double width;
  final double height;
  final double borderRadius;

  const ShimmerLoading({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius = 12,
  });

  @override
  State<ShimmerLoading> createState() => _ShimmerLoadingState();
}

class _ShimmerLoadingState extends State<ShimmerLoading>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = isDark ? const Color(0xFF1A1A2E) : const Color(0xFFE0E0E8);
    final highlightColor = isDark ? const Color(0xFF2A2A4A) : const Color(0xFFF0F0F8);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final dx = _controller.value * 2 - 1;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            gradient: LinearGradient(
              begin: Alignment(-1.0 + dx, 0),
              end: Alignment(1.0 + dx, 0),
              colors: [baseColor, highlightColor, baseColor],
            ),
          ),
        );
      },
    );
  }
}

class PageSlideTransition extends PageRouteBuilder {
  final Widget page;

  PageSlideTransition({required this.page})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) => page,
          transitionDuration: AppDurations.pageTransition,
          reverseTransitionDuration: AppDurations.pageTransition,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: AppCurves.slideIn,
              reverseCurve: AppCurves.easeOut,
            );
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.1, 0),
                end: Offset.zero,
              ).animate(curved),
              child: FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: const Interval(0.3, 1.0),
                ),
                child: child,
              ),
            );
          },
        );
}
