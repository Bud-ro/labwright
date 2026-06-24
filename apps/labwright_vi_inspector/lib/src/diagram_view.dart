import 'package:flutter/material.dart';
import 'package:labwright_videcode/labwright_videcode.dart';

import 'faithful_controls.dart';

/// How the diagram is drawn: a debug **wireframe** (colored boxes + labels,
/// click-to-inspect) or a **faithful** render (real-looking interactive controls).
enum DiagramRenderMode { wireframe, faithful }

/// A read-only **layout view** of a decoded VI block diagram, rendered to a
/// faithful, LabVIEW-like canvas: every recovered object drawn at its absolute
/// coordinates, with nesting-aware z-order, type-faithful terminal colors,
/// structure frames, labels, click-to-inspect, pan/zoom and auto-fit.
///
/// Backed entirely by the clean-room `labwright_videcode` decode
/// (`buildViModel` → `ViModel.diagrams`). Honest by construction: only objects
/// with recovered absolute bounds are drawn, and **signal wires are not shown** —
/// LabVIEW does not persist wire geometry (it re-routes wires at draw time), so
/// drawing them would be fabrication. This is a faithful object/position view,
/// not a re-render of LabVIEW's canvas.
class ViDiagramView extends StatefulWidget {
  const ViDiagramView({super.key, required this.model});

  final ViModel? model;

  @override
  State<ViDiagramView> createState() => _ViDiagramViewState();
}

class _ViDiagramViewState extends State<ViDiagramView> {
  final _tc = TransformationController();
  ViHeapObject? _selected;
  Size? _lastViewport;
  Rect? _lastContent;
  bool _fitted = false;
  DiagramRenderMode _mode = DiagramRenderMode.wireframe;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final diagram = _largestDiagram(widget.model);
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

    final byId = diagram.byId;
    final drawable = [
      for (final o in diagram.objects)
        if (o.absBounds != null &&
            o.absBounds!.isValid &&
            o.absBounds!.width < 8000 &&
            o.absBounds!.height < 8000 &&
            !_isScaffolding(o, byId))
          o,
    ];
    if (drawable.isEmpty) {
      return const Center(child: Text('Diagram has no positioned objects.', style: TextStyle(color: Colors.grey)));
    }

    final content = _contentRect(drawable);
    _lastContent = content;

    final counts = <ViObjectKind, int>{};
    for (final o in drawable) {
      counts[o.category] = (counts[o.category] ?? 0) + 1;
    }
    // depth (for z-order: containers first) and a stable paint order.
    final ordered = [...drawable]..sort((a, b) => _depth(a, byId).compareTo(_depth(b, byId)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(drawable.length, counts),
        const SizedBox(height: 6),
        Expanded(
          // Stack so the details card is an OVERLAY — it never changes the
          // viewport size, so selecting an object can't trigger a re-fit/reset.
          child: Stack(
            children: [
              Positioned.fill(
                child: LayoutBuilder(builder: (context, constraints) {
                  final viewport = Size(constraints.maxWidth, constraints.maxHeight);
                  if (viewport != _lastViewport) {
                    _lastViewport = viewport;
                    _fitted = false;
                  }
                  if (!_fitted) {
                    WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
                  }
                  return ClipRect(
                    child: ColoredBox(
                      color: const Color(0xFFE9E9E9), // LabVIEW-like BD canvas
                      child: InteractiveViewer(
                        transformationController: _tc,
                        constrained: false,
                        minScale: 0.02,
                        maxScale: 16,
                        boundaryMargin: const EdgeInsets.all(2000),
                        child: _mode == DiagramRenderMode.faithful
                            ? FaithfulLayer(objects: ordered, origin: content.topLeft, size: content.size)
                            : GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapDown: (d) => _selectAt(d.localPosition, ordered, content),
                                child: CustomPaint(
                                  size: Size(content.width, content.height),
                                  painter: _DiagramPainter(objects: ordered, origin: content.topLeft, selected: _selected),
                                ),
                              ),
                      ),
                    ),
                  );
                }),
              ),
              if (_mode == DiagramRenderMode.wireframe && _selected != null)
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  child: _DetailsCard(object: _selected!, onClose: () => setState(() => _selected = null)),
                ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'Object layout decoded clean-room. Signal wires are not drawn — LabVIEW '
            'does not store wire paths (it re-routes them at draw time).',
            style: TextStyle(color: Colors.grey, fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _toolbar(int n, Map<ViObjectKind, int> counts) => Row(
        children: [
          Text('$n objects', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (final e in counts.entries)
                _LegendChip(color: _kindColor(e.key), label: '${e.key.name} ${e.value}'),
            ]),
          ),
          SegmentedButton<DiagramRenderMode>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: DiagramRenderMode.wireframe, icon: Icon(Icons.grid_4x4, size: 16), label: Text('Wireframe')),
              ButtonSegment(value: DiagramRenderMode.faithful, icon: Icon(Icons.widgets_outlined, size: 16), label: Text('Faithful')),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() {
              _mode = s.first;
              if (_mode == DiagramRenderMode.faithful) _selected = null;
            }),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Fit to view',
            onPressed: _fit,
            icon: const Icon(Icons.fit_screen),
          ),
        ],
      );

  void _selectAt(Offset local, List<ViHeapObject> objects, Rect content) {
    final x = local.dx + content.left;
    final y = local.dy + content.top;
    ViHeapObject? hit;
    var bestArea = double.infinity;
    for (final o in objects) {
      final r = o.absBounds!;
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) {
        final area = (r.width * r.height).toDouble();
        if (area <= bestArea) {
          bestArea = area;
          hit = o; // smallest object under the cursor wins
        }
      }
    }
    setState(() => _selected = hit);
  }

  void _fit() {
    final vp = _lastViewport;
    final c = _lastContent;
    if (vp == null || c == null || c.width <= 0 || c.height <= 0) return;
    final s = (vp.width / c.width).clamp(0.0, double.infinity);
    final scale = (s < vp.height / c.height ? s : vp.height / c.height) * 0.94;
    final tx = (vp.width - c.width * scale) / 2;
    final ty = (vp.height - c.height * scale) / 2;
    _tc.value = Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
    _fitted = true;
  }

  static Rect _contentRect(List<ViHeapObject> drawable) {
    var minX = 1 << 30, minY = 1 << 30, maxX = -(1 << 30), maxY = -(1 << 30);
    for (final o in drawable) {
      final r = o.absBounds!;
      if (r.left < minX) minX = r.left;
      if (r.top < minY) minY = r.top;
      if (r.right > maxX) maxX = r.right;
      if (r.bottom > maxY) maxY = r.bottom;
    }
    const margin = 40;
    return Rect.fromLTRB(
      (minX - margin).toDouble(),
      (minY - margin).toDouble(),
      (maxX + margin).toDouble(),
      (maxY + margin).toDouble(),
    );
  }

  static int _depth(ViHeapObject o, Map<int, ViHeapObject> byId) {
    var d = 0;
    var cur = o;
    while (cur.parentOid != null && d < 64) {
      final p = byId[cur.parentOid];
      if (p == null) break;
      cur = p;
      d++;
    }
    return d;
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

/// Faithful-ish LabVIEW palette: terminals colored by data type, else by class.
Color _typeColor(ViTypeKind t) => switch (t) {
      ViTypeKind.numericFloat => const Color(0xFFE8732A), // orange (DBL/SGL)
      ViTypeKind.numericInt => const Color(0xFF1F6FE0), // blue (integers)
      ViTypeKind.enumRing => const Color(0xFF1FA0C0), // cyan (ring/enum)
      ViTypeKind.path => const Color(0xFF3FA64B), // green (path)
      ViTypeKind.clnNode => const Color(0xFFE8C547), // yellow (CLN/subVI)
      ViTypeKind.unknown => const Color(0xFF707070),
    };

Color _kindColor(ViObjectKind k) => switch (k) {
      ViObjectKind.node => const Color(0xFFE8C547), // subVI/function yellow
      ViObjectKind.terminal => const Color(0xFF5C9BD6),
      ViObjectKind.terminalCluster => const Color(0xFF2BB8A8),
      ViObjectKind.structure => const Color(0xFF9A6B2E),
      ViObjectKind.decoration => const Color(0xFFBDBDBD),
      ViObjectKind.unknown => const Color(0xFF9E9E9E),
    };

Color _objectColor(ViHeapObject o) =>
    o.category == ViObjectKind.terminal && o.typeKind != ViTypeKind.unknown ? _typeColor(o.typeKind) : _kindColor(o.category);

/// Control-terminal classes — their internal sub-terminals are scaffolding.
const _controlKinds = {0x50, 0x4f, 0x57, 0x5b, 0x51};

/// Whether [o] is pure LabVIEW chrome that a faithful layout view should not
/// draw (corpus-validated; suppresses ~76% of raw heap objects, leaving real
/// structures, nodes, controls, decorations and caption bars):
/// - resize/scroll handles (`0x09`);
/// - content viewports (`0x11c`) — used only as the re-anchor frame, the
///   enclosing cluster/structure is drawn instead;
/// - hidden no-bounds terminals (`0x68`);
/// - the display/increment/terminal/item-list parts internal to a control
///   (`0xe0`/`0x0b`/`0x0c`/`0x0d` with a control-kind ancestor) — the control is
///   drawn as a single unit, not its internals (`0x0d`'s enum items are already
///   propagated up to the control, so suppressing it loses nothing).
bool _isScaffolding(ViHeapObject o, Map<int, ViHeapObject> byId) {
  if (o.kind == 0x09 || o.kind == 0x11c) return true;
  if (o.kind == 0x68 && o.bounds == null) return true;
  if (o.kind == 0xe0 || o.kind == 0x0b || o.kind == 0x0c || o.kind == 0x0d) {
    var p = o.parentOid;
    var d = 0;
    while (p != null && d < 64) {
      final po = byId[p];
      if (po == null) break;
      if (_controlKinds.contains(po.kind)) return true;
      p = po.parentOid;
      d++;
    }
  }
  return false;
}

class _DiagramPainter extends CustomPainter {
  _DiagramPainter({required this.objects, required this.origin, required this.selected});

  final List<ViHeapObject> objects;
  final Offset origin;
  final ViHeapObject? selected;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFE9E9E9));
    _drawDotGrid(canvas, size);

    Rect rectOf(ViHeapObject o) {
      final r = o.absBounds!;
      return Rect.fromLTRB(r.left - origin.dx, r.top - origin.dy, r.right - origin.dx, r.bottom - origin.dy);
    }

    final structures = objects.where((o) => o.category == ViObjectKind.structure).toList();
    final decorations = objects.where((o) => o.category == ViObjectKind.decoration).toList();
    // nodes/terminals/clusters, largest-first so small ones end up on top.
    final solids = objects
        .where((o) => o.category != ViObjectKind.structure && o.category != ViObjectKind.decoration)
        .toList()
      ..sort((a, b) => (b.absBounds!.width * b.absBounds!.height).compareTo(a.absBounds!.width * a.absBounds!.height));

    // 1. decorations — faint, behind.
    for (final o in decorations) {
      canvas.drawRect(rectOf(o), Paint()..color = _kindColor(o.category).withValues(alpha: 0.10));
    }
    // 2. structure frames — OUTLINE only (no muddy fill); nesting reads via overlap.
    for (final o in structures) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rectOf(o), const Radius.circular(5)),
        Paint()
          ..color = _kindColor(ViObjectKind.structure).withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    // 3. solids — small on top.
    for (final o in solids) {
      final rr = RRect.fromRectAndRadius(rectOf(o), const Radius.circular(2.5));
      canvas.drawRRect(rr, Paint()..color = _objectColor(o).withValues(alpha: 0.92));
      canvas.drawRRect(rr, Paint()
        ..color = Colors.black.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8);
    }
    // 4. labels on top of everything, so text is never buried.
    for (final o in objects) {
      final text = _annotation(o);
      if (text == null) continue;
      final rect = rectOf(o);
      if (rect.width < 26 || rect.height < 11) continue;
      final onFrame = o.category == ViObjectKind.structure;
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: onFrame ? const Color(0xCC4A2E00) : Colors.black.withValues(alpha: 0.85),
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: rect.width - 5);
      tp.paint(canvas, rect.topLeft + const Offset(3, 1));
    }
    // 5. selection highlight.
    final sel = selected;
    if (sel != null && sel.absBounds != null) {
      canvas.drawRect(rectOf(sel).inflate(2.5), Paint()
        ..color = const Color(0xFF1565C0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5);
    }
  }

  void _drawDotGrid(Canvas canvas, Size size) {
    const step = 12.0;
    final dot = Paint()..color = const Color(0x22000000);
    for (var x = 0.0; x < size.width; x += step) {
      for (var y = 0.0; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 0.6, dot);
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
      old.objects != objects || old.origin != origin || !identical(old.selected, selected);
}

class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.object, required this.onClose});
  final ViHeapObject object;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final r = object.absBounds;
    final cls = object.objectClass;
    final conf = cls.confidence == ClassConfidence.confirmed ? '' : ' (${cls.confidence.name})';
    return Card(
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
              decoration: BoxDecoration(color: _objectColor(object), borderRadius: BorderRadius.circular(3)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(object.label ?? cls.label, style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(
                    '${cls.label}$conf · class 0x${object.kind.toRadixString(16)} · oid ${object.oid}'
                    '${object.typeKind != ViTypeKind.unknown ? ' · type ${object.typeKind.name}' : ''}'
                    '${r != null ? ' · ${r.width}×${r.height} @(${r.left},${r.top})' : ''}'
                    '${object.parentOid != null ? ' · parent ${object.parentOid}' : ''}',
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
            ),
            IconButton(visualDensity: VisualDensity.compact, onPressed: onClose, icon: const Icon(Icons.close, size: 18)),
          ],
        ),
      ),
    );
  }
}

class _LegendChip extends StatelessWidget {
  const _LegendChip({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 11, height: 11, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      );
}
