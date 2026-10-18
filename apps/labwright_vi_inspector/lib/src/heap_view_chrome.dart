import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// A grey centred message in place of a view with nothing to draw.
Widget heapPlaceholder(String text) => Center(
  child: Padding(
    padding: const EdgeInsets.all(24),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(color: Colors.grey),
    ),
  ),
);

/// The object count, the fit button and the shelf toggle above a heap canvas.
Widget heapViewToolbar({
  required int objectCount,
  required VoidCallback onFit,
  required bool shelfOpen,
  required VoidCallback onToggleShelf,
}) => Wrap(
  spacing: 12,
  runSpacing: 4,
  crossAxisAlignment: WrapCrossAlignment.center,
  children: [
    Text(
      '$objectCount objects',
      style: const TextStyle(fontWeight: FontWeight.bold),
    ),
    IconButton(
      tooltip: 'Fit to view',
      onPressed: onFit,
      icon: const Icon(Icons.fit_screen),
    ),
    IconButton(
      tooltip: shelfOpen ? 'Hide details panel' : 'Show details panel',
      onPressed: onToggleShelf,
      icon: Icon(shelfOpen ? Icons.view_sidebar : Icons.view_sidebar_outlined),
    ),
  ],
);

/// The clipped grey surface a heap canvas pans and zooms in.
Widget heapCanvas({
  required TransformationController controller,
  void Function(ScaleEndDetails)? onInteractionEnd,
  required Widget child,
}) => ClipRect(
  child: ColoredBox(
    color: const Color(0xFFE9E9E9),
    child: InteractiveViewer(
      transformationController: controller,
      constrained: false,
      minScale: 0.02,
      maxScale: 16,
      boundaryMargin: const EdgeInsets.all(2000),
      onInteractionEnd: onInteractionEnd,
      child: child,
    ),
  ),
);

/// The transform that centres [content] in [viewport] with a small margin, and its scale; null
/// when either is empty.
({Matrix4 transform, double scale})? fitTransform(Size viewport, Rect content) {
  if (content.width <= 0 || content.height <= 0) return null;
  final scale =
      math.min(
        viewport.width / content.width,
        viewport.height / content.height,
      ) *
      0.94;
  final tx = (viewport.width - content.width * scale) / 2;
  final ty = (viewport.height - content.height * scale) / 2;
  return (
    transform: Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1),
    scale: scale,
  );
}

Map<K, int> countBy<T, K>(Iterable<T> items, K Function(T) key) {
  final counts = <K, int>{};
  for (final item in items) {
    counts.update(key(item), (n) => n + 1, ifAbsent: () => 1);
  }
  return counts;
}

/// The rectangle that holds every bounded object, with a margin; empty for none.
Rect heapContentRect(Iterable<HeapPlaced> objects, {int margin = 40}) {
  var minX = 1 << 30, minY = 1 << 30, maxX = -(1 << 30), maxY = -(1 << 30);
  var any = false;
  for (final object in objects) {
    final bounds = object.absBounds;
    any = true;
    if (bounds.left < minX) minX = bounds.left;
    if (bounds.top < minY) minY = bounds.top;
    if (bounds.right > maxX) maxX = bounds.right;
    if (bounds.bottom > maxY) maxY = bounds.bottom;
  }
  if (!any) return Rect.zero;
  return Rect.fromLTRB(
    (minX - margin).toDouble(),
    (minY - margin).toDouble(),
    (maxX + margin).toDouble(),
    (maxY + margin).toDouble(),
  );
}

/// One `label: value` line of a details card.
Widget detailLine(String label, String value) => Padding(
  padding: const EdgeInsets.only(top: 3),
  child: Text.rich(
    maxLines: 3,
    overflow: TextOverflow.ellipsis,
    TextSpan(
      style: const TextStyle(fontSize: 12),
      children: [
        TextSpan(
          text: '$label: ',
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            color: Color(0xFF5B9BD5),
          ),
        ),
        TextSpan(text: value),
      ],
    ),
  ),
);

/// A colour swatch with a count, one per object role in a view's legend.
class LegendChip extends StatelessWidget {
  const LegendChip({super.key, required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
    ],
  );
}

/// The card for a selected object: a role swatch, a title, a grey subtitle and detail lines.
class HeapDetailsCard extends StatelessWidget {
  const HeapDetailsCard({
    super.key,
    required this.swatch,
    required this.title,
    required this.subtitle,
    required this.details,
    required this.onClose,
  });

  final Color swatch;
  final String title;
  final String subtitle;
  final List<Widget> details;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: 6),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 14,
            height: 14,
            margin: const EdgeInsets.only(top: 2, right: 8),
            decoration: BoxDecoration(
              color: swatch,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                ...details,
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: onClose,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    ),
  );
}
