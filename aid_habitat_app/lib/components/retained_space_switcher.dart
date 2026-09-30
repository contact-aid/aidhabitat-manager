import 'dart:async';

import 'package:flutter/material.dart';

/// Lazily opens each space, then retains its form, notes and scroll state.
class RetainedSpaceSwitcher extends StatefulWidget {
  final bool showSecond;
  final WidgetBuilder firstBuilder;
  final WidgetBuilder secondBuilder;

  const RetainedSpaceSwitcher({
    super.key,
    required this.showSecond,
    required this.firstBuilder,
    required this.secondBuilder,
  });

  @override
  State<RetainedSpaceSwitcher> createState() => _RetainedSpaceSwitcherState();
}

class _RetainedSpaceSwitcherState extends State<RetainedSpaceSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 160),
    reverseDuration: const Duration(milliseconds: 110),
  );
  late bool _visibleSecond = widget.showSecond;

  @override
  void didUpdateWidget(covariant RetainedSpaceSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showSecond != oldWidget.showSecond) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _fade.stop();
        _fade.value = 1;
        _visibleSecond = widget.showSecond;
      } else {
        unawaited(_switchWithFade());
      }
    }
  }

  Future<void> _switchWithFade() async {
    try {
      await _fade.reverse().orCancel;
      if (!mounted) return;
      setState(() => _visibleSecond = widget.showSecond);
      await _fade.forward().orCancel;
    } on TickerCanceled {
      // A newer switch or disposal supersedes this transition.
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  bool _firstOpened = false;
  bool _secondOpened = false;

  @override
  Widget build(BuildContext context) {
    _firstOpened |= !_visibleSecond;
    _secondOpened |= _visibleSecond;
    return AnimatedBuilder(
      animation: _fade,
      builder: (context, child) => IgnorePointer(
        ignoring: _fade.isAnimating,
        child: FadeTransition(opacity: _fade, child: child),
      ),
      child: IndexedStack(
        index: _visibleSecond ? 1 : 0,
        children: [
          ExcludeFocus(
            excluding: _visibleSecond,
            child: TickerMode(
              enabled: !_visibleSecond,
              child: _firstOpened
                  ? widget.firstBuilder(context)
                  : const SizedBox.shrink(),
            ),
          ),
          ExcludeFocus(
            excluding: !_visibleSecond,
            child: TickerMode(
              enabled: _visibleSecond,
              child: _secondOpened
                  ? widget.secondBuilder(context)
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}
