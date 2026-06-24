import 'package:flutter/material.dart';
import 'package:labwright_videcode/labwright_videcode.dart';

/// A read-only **layout view** of a decoded VI block diagram: every recovered
/// object drawn at its absolute coordinates, colored by [ViObjectKind], labeled,
/// and annotated with its [ViTypeKind]. Backed entirely by the clean-room
/// `labwright_videcode` decode (`buildViModel` → `ViModel.diagrams`).
///
/// Honest by construction: only objects with recovered absolute bounds are drawn;
/// signal wires are not shown (they are stored as geometry without recoverable
/// endpoints — see the format notes). This is a structural/positional view of the
/// diagram's objects, not a re-render of LabVIEW's canvas.
class ViDiagramView extends StatelessWidget {
  const ViDiagramView({super.key, required this.model});

  final ViModel? model;

  static const _palette = <ViObjectKind, Color>{
    ViObjectKind.node: Color(0xFF4F8AF7),
    ViObjectKind.terminal: Color(0xFF49C26B),
    ViObjectKind.terminalCluster: Color(0xFF2BB8B8),
    ViObjectKind.structure: Color(0xFFE8923A),
    ViObjectKind.decoration: Color(0xFF8A8A8A),
    ViObjectKind.unknown: Color(0xFF5A5A5A),
  };

  @override
  Widget build(BuildContext context) {
    final diagram = _largestDiagram(model);
    if (diagram == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No decodable block diagram in this file.\n'
            'Load a real .vi with a BDEx block to see its object layout.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    final drawable = [
      for (final o in diagram.objects)
        if (o.absBounds != null && o.absBounds!.isValid && o.absBounds!.width < 6000 && o.absBounds!.height < 6000) o,
    ];
    if (drawable.isEmpty) {
      return const Center(child: Text('Diagram has no positioned objects.', style: TextStyle(color: Colors.grey)));
    }

    // Bounding box of all drawable objects, in diagram pixels.
    var minX = 1 << 30, minY = 1 << 30, maxX = -(1 << 30), maxY = -(1 << 30);
    for (final o in drawable) {
      final r = o.absBounds!;
      if (r.left < minX) minX = r.left;
      if (r.top < minY) minY = r.top;
      if (r.right > maxX) maxX = r.right;
      if (r.bottom > maxY) maxY = r.bottom;
    }
    const margin = 24;
    final w = (maxX - minX) + margin * 2;
    final h = (maxY - minY) + margin * 2;

    final counts = <ViObjectKind, int>{};
    for (final o in drawable) {
      counts[o.category] = (counts[o.category] ?? 0) + 1;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Wrap(spacing: 12, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('${drawable.length} objects', style: const TextStyle(fontWeight: FontWeight.bold)),
            for (final e in counts.entries)
              _LegendChip(color: _palette[e.key] ?? Colors.grey, label: '${e.key.name} ${e.value}'),
          ]),
        ),
        Expanded(
          child: ClipRect(
            child: InteractiveViewer(
              constrained: false,
              minScale: 0.05,
              maxScale: 12,
              boundaryMargin: const EdgeInsets.all(400),
              child: CustomPaint(
                size: Size(w.toDouble(), h.toDouble()),
                painter: _DiagramPainter(
                  objects: drawable,
                  originX: minX - margin,
                  originY: minY - margin,
                  palette: _palette,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static ViDiagram? _largestDiagram(ViModel? model) {
    if (model == null || model.diagrams.isEmpty) return null;
    ViDiagram? best;
    var bestN = -1;
    for (final d in model.diagrams) {
      final n = d.objects.where((o) => o.absBounds != null).length;
      if (n > bestN) {
        bestN = n;
        best = d;
      }
    }
    return bestN <= 0 ? null : best;
  }
}

class _DiagramPainter extends CustomPainter {
  _DiagramPainter({required this.objects, required this.originX, required this.originY, required this.palette});

  final List<ViHeapObject> objects;
  final int originX;
  final int originY;
  final Map<ViObjectKind, Color> palette;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF1A1A1A));

    // Structures first (containers, drawn as outlines behind everything).
    final ordered = [
      ...objects.where((o) => o.category == ViObjectKind.structure),
      ...objects.where((o) => o.category != ViObjectKind.structure),
    ];

    for (final o in ordered) {
      final r = o.absBounds!;
      final rect = Rect.fromLTRB(
        (r.left - originX).toDouble(),
        (r.top - originY).toDouble(),
        (r.right - originX).toDouble(),
        (r.bottom - originY).toDouble(),
      );
      final color = palette[o.category] ?? Colors.grey;
      if (o.category == ViObjectKind.structure) {
        canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.06));
        canvas.drawRect(rect, Paint()
          ..color = color.withValues(alpha: 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
      } else {
        canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.22));
        canvas.drawRect(rect, Paint()
          ..color = color.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
      }

      // Label / type annotation when the box is big enough to hold text.
      final text = _annotation(o);
      if (text != null && rect.width >= 28 && rect.height >= 12) {
        final tp = TextPainter(
          text: TextSpan(text: text, style: const TextStyle(color: Colors.white, fontSize: 10)),
          maxLines: 1,
          ellipsis: '…',
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: rect.width - 4);
        tp.paint(canvas, rect.topLeft + const Offset(2, 1));
      }
    }
  }

  String? _annotation(ViHeapObject o) {
    final label = o.label;
    final type = o.typeKind == ViTypeKind.unknown ? null : o.typeKind.name;
    if (label != null && type != null) return '$label · $type';
    return label ?? type;
  }

  @override
  bool shouldRepaint(covariant _DiagramPainter old) =>
      old.objects != objects || old.originX != originX || old.originY != originY;
}

class _LegendChip extends StatelessWidget {
  const _LegendChip({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      );
}
