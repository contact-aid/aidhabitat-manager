import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Déplace deux pages côte à côte avec le doigt, puis termine ou annule
/// le mouvement selon la distance parcourue.
class DocumentPageSlide extends StatefulWidget {
  const DocumentPageSlide({
    super.key,
    required this.page,
    required this.current,
    required this.onPageChange,
    this.previous,
    this.next,
    this.canSwipe,
  });

  final int page;
  final Widget current;
  final Widget? previous;
  final Widget? next;
  final Future<void> Function(int direction) onPageChange;
  final bool Function()? canSwipe;

  @override
  State<DocumentPageSlide> createState() => DocumentPageSlideState();
}

class DocumentPageSlideState extends State<DocumentPageSlide>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Animation<double>? _animation;
  final Set<int> _touches = {};
  int? _dragPointer;
  Offset? _dragStart;
  double _offset = 0;
  bool _settling = false;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 280),
        )..addListener(() {
          final animation = _animation;
          if (animation != null) setState(() => _offset = animation.value);
        });
  }

  @override
  void didUpdateWidget(covariant DocumentPageSlide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page) {
      _controller.stop();
      _animation = null;
      _offset = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _animateTo(double target, double width) async {
    _controller.stop();
    final distance = (target - _offset).abs();
    _controller.duration = Duration(
      milliseconds: (280 * distance / width).round().clamp(120, 300),
    );
    _animation = Tween<double>(
      begin: _offset,
      end: target,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    await _controller.forward(from: 0);
  }

  Future<void> turnPage(int direction) async {
    if (_settling || !mounted) return;
    if (direction == -1 && widget.previous == null) return;
    if (direction == 1 && widget.next == null) return;
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    _settling = true;
    try {
      await _animateTo(direction == 1 ? -width : width, width);
      if (!mounted) return;
      await widget.onPageChange(direction);
    } finally {
      if (mounted) {
        setState(() {
          _offset = 0;
          _settling = false;
        });
      }
    }
  }

  void _onDown(PointerDownEvent event) {
    if (event.kind != ui.PointerDeviceKind.touch || _settling) return;
    _touches.add(event.pointer);
    if (_touches.length == 1 && (widget.canSwipe?.call() ?? true)) {
      _dragPointer = event.pointer;
      _dragStart = event.localPosition;
    } else {
      _dragPointer = null;
      _dragStart = null;
      if (_offset != 0) {
        final width = context.size?.width ?? 1;
        _settling = true;
        _animateTo(0, width).whenComplete(() {
          if (mounted) setState(() => _settling = false);
        });
      }
    }
  }

  void _onMove(PointerMoveEvent event) {
    if (event.pointer != _dragPointer || _settling) return;
    final start = _dragStart;
    if (start == null || !(widget.canSwipe?.call() ?? true)) return;
    final delta = event.localPosition - start;
    if (delta.dx.abs() < delta.dy.abs() * 1.3) return;
    if (delta.dx > 0 && widget.previous == null) return;
    if (delta.dx < 0 && widget.next == null) return;
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    setState(() => _offset = delta.dx.clamp(-width, width));
  }

  void _onEnd(PointerEvent event) {
    _touches.remove(event.pointer);
    if (event.pointer != _dragPointer) return;
    _dragPointer = null;
    _dragStart = null;
    final width = context.size?.width ?? 0;
    if (width <= 0 || _offset == 0 || _settling) return;
    final direction = _offset < 0 ? 1 : -1;
    if (_offset.abs() > width * 0.28) {
      turnPage(direction);
    } else {
      _settling = true;
      _animateTo(0, width).whenComplete(() {
        if (mounted) setState(() => _settling = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final neighbor = _offset > 0 ? widget.previous : widget.next;
        return ClipRect(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onDown,
            onPointerMove: _onMove,
            onPointerUp: _onEnd,
            onPointerCancel: _onEnd,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (neighbor != null && _offset != 0)
                  Transform.translate(
                    offset: Offset(_offset + (_offset > 0 ? -width : width), 0),
                    child: IgnorePointer(child: neighbor),
                  ),
                Transform.translate(
                  offset: Offset(_offset, 0),
                  child: widget.current,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
