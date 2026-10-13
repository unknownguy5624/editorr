import 'dart:io';

import 'package:flutter/material.dart';

/// CapCut-style trim bar: video frames with two draggable handles.
class TrimBar extends StatelessWidget {
  final List<String> thumbs;
  final double duration;
  final double start;
  final double end;
  final double position;
  final void Function(double start, double end) onChanged;
  final VoidCallback onChangeEnd;

  const TrimBar({
    super.key,
    required this.thumbs,
    required this.duration,
    required this.start,
    required this.end,
    required this.position,
    required this.onChanged,
    required this.onChangeEnd,
  });

  static const double _inset = 16;
  static const double _minLen = 0.5;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: LayoutBuilder(
        builder: (context, box) {
          final trackW = box.maxWidth - _inset * 2;
          if (duration <= 0 || trackW <= 0) return const SizedBox.shrink();

          double toX(double t) => _inset + (t / duration) * trackW;
          final sx = toX(start);
          final ex = toX(end);
          final px = toX(position.clamp(0.0, duration));
          final secPerPx = duration / trackW;

          return Stack(
            children: [
              Positioned(
                left: _inset,
                right: _inset,
                top: 0,
                bottom: 0,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: thumbs.isEmpty
                      ? Container(color: const Color(0xFF1E1E28))
                      : Row(
                          children: [
                            for (final t in thumbs)
                              Expanded(
                                child: Image.file(
                                  File(t),
                                  fit: BoxFit.cover,
                                  height: double.infinity,
                                ),
                              ),
                          ],
                        ),
                ),
              ),
              // dimmed areas outside the selection
              Positioned(
                left: _inset,
                width: sx - _inset,
                top: 0,
                bottom: 0,
                child: const ColoredBox(color: Color(0xAA000000)),
              ),
              Positioned(
                left: ex,
                right: _inset,
                top: 0,
                bottom: 0,
                child: const ColoredBox(color: Color(0xAA000000)),
              ),
              // selection frame
              Positioned(
                left: sx,
                width: ex - sx,
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(
                    decoration: const BoxDecoration(
                      border: Border.symmetric(
                        horizontal: BorderSide(color: Colors.amber, width: 3),
                      ),
                    ),
                  ),
                ),
              ),
              // playhead
              Positioned(
                left: px - 1,
                width: 2,
                top: 0,
                bottom: 0,
                child: const IgnorePointer(
                  child: ColoredBox(color: Colors.white),
                ),
              ),
              // left handle
              Positioned(
                left: sx - _inset,
                width: _inset * 2,
                top: 0,
                bottom: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: (d) {
                    final maxStart = (end - _minLen).clamp(0.0, duration);
                    final v = (start + d.delta.dx * secPerPx)
                        .clamp(0.0, maxStart);
                    onChanged(v, end);
                  },
                  onHorizontalDragEnd: (_) => onChangeEnd(),
                  child: const Center(child: _Handle()),
                ),
              ),
              // right handle
              Positioned(
                left: ex - _inset,
                width: _inset * 2,
                top: 0,
                bottom: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: (d) {
                    final minEnd = (start + _minLen).clamp(0.0, duration);
                    final v =
                        (end + d.delta.dx * secPerPx).clamp(minEnd, duration);
                    onChanged(start, v);
                  },
                  onHorizontalDragEnd: (_) => onChangeEnd(),
                  child: const Center(child: _Handle()),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 64,
      decoration: BoxDecoration(
        color: Colors.amber,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Center(
        child: SizedBox(
          width: 2,
          height: 22,
          child: ColoredBox(color: Colors.black54),
        ),
      ),
    );
  }
}
