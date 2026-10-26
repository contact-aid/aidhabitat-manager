import 'package:flutter/material.dart';

/// Web-only viewport for historical image plans; resetting does not edit them.
class WebPlanImageViewport extends StatefulWidget {
  final Widget child;
  const WebPlanImageViewport({super.key, required this.child});
  @override
  State<WebPlanImageViewport> createState() => _WebPlanImageViewportState();
}

class _WebPlanImageViewportState extends State<WebPlanImageViewport> {
  final _controller = TransformationController();
  Size? _size;
  void _reset() => _controller.value = Matrix4.identity();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (size != _size) {
        _size = size;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && size == _size) _reset();
        });
      }
      return Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 64),
              child: InteractiveViewer(
                transformationController: _controller,
                child: Center(child: widget.child),
              ),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 8,
            child: IconButton.filledTonal(
              tooltip: 'Recentrer le plan',
              onPressed: _reset,
              icon: const Icon(Icons.fit_screen),
            ),
          ),
        ],
      );
    },
  );
}
