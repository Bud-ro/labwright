import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'faithful_controls.dart';

/// How the diagram is drawn: a debug **wireframe** (colored boxes + labels,
/// click-to-inspect) or a **faithful** render (real-looking interactive controls).
enum DiagramRenderMode { wireframe, faithful }

/// Faithful mode mounts one live (stateful) Flutter control per object, so it is
/// capped: diagrams with more drawable objects than this fall back to the cheap
/// single-CustomPaint wireframe (a few corpus VIs reach several thousand objects,
/// which would otherwise mount thousands of controllers/render objects at once).
const int kFaithfulMaxObjects = 1500;

/// A read-only **layout view** of a decoded VI block diagram, rendered to a
/// faithful, LabVIEW-like canvas: every recovered object drawn at its absolute
/// coordinates, with nesting-aware z-order, type-faithful terminal colors,
/// structure frames, labels, click-to-inspect, pan/zoom and auto-fit.
///
/// Backed entirely by the clean-room `labwright_rsrc_parse` decode
/// (`buildViModel` → `blockDiagrams`/`frontPanelDiagrams`). Honest by construction: only objects
/// with recovered absolute bounds are drawn, and **signal wires are not shown** —
/// LabVIEW does not persist wire geometry (it re-routes wires at draw time), so
/// drawing them would be fabrication. This is a faithful object/position view,
/// not a re-render of LabVIEW's canvas.
class ViDiagramView extends StatefulWidget {
  const ViDiagramView({
    super.key,
    required this.diagrams,
    this.emptyHint = 'No decodable layout in this file.',
    this.subViNames = const [],
    this.isFrontPanel = false,
  });

  /// The diagrams to render (block-diagram or front-panel heap trees); the
  /// richest is shown. Pass `model.blockDiagrams` or `model.frontPanelDiagrams`.
  final List<ViDiagram>? diagrams;

  /// Shown when no diagram has positioned objects.
  final String emptyHint;

  /// The VI's sub-VI dependency names from the LIbd linker block
  /// (`model.subViNames`) — the names LabVIEW records as block-diagram
  /// dependencies (recoverable for ~82% of VIs; the rest call no subVIs or none
  /// with a stored name). This is a dependency list from the linker, NOT a
  /// per-node call mapping, but it does not depend on individual BD node labels.
  /// Pass only for the block diagram (empty for the front panel).
  final List<String> subViNames;

  /// True when rendering the front panel. On the FP, structure containers
  /// (clusters/arrays/panes) show their caption instead of a class-kind badge so
  /// the badge never obscures the control's label; the BD keeps kind badges.
  final bool isFrontPanel;

  @override
  State<ViDiagramView> createState() => _ViDiagramViewState();
}

class _ViDiagramViewState extends State<ViDiagramView> {
  final _transform = TransformationController();
  ViHeapObject? _selected;
  Set<ViHeapObject> _members = const {};
  Size? _lastViewport;
  Rect? _lastContent;
  bool _fitted = false;
  DiagramRenderMode _mode = DiagramRenderMode.wireframe;

  late final ViDiagram? _diagram = _largestDiagram(widget.diagrams);
  late final Map<int, ViHeapObject> _byId = _diagram?.byId ?? const {};
  late final List<ViHeapObject> _drawable = _diagram == null
      ? const []
      : [
          for (final object in _diagram.objects)
            if (object.absBounds != null &&
                object.absBounds!.isValid &&
                object.absBounds!.width > 0 &&
                object.absBounds!.height > 0 &&
                object.absBounds!.width < 8000 &&
                object.absBounds!.height < 8000 &&
                !_isScaffolding(object, _byId))
              object,
        ];
  late final List<ViHeapObject> _ordered = [..._drawable]..sort((a, b) => _depth(a, _byId).compareTo(_depth(b, _byId)));
  late final Rect _content = _drawable.isEmpty ? Rect.zero : _contentRect(_drawable);
  late final Map<ViObjectKind, int> _counts = _computeCounts();

  Map<ViObjectKind, int> _computeCounts() {
    final countsByKind = <ViObjectKind, int>{};
    for (final object in _drawable) {
      countsByKind[object.category] = (countsByKind[object.category] ?? 0) + 1;
    }
    return countsByKind;
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_diagram == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(widget.emptyHint, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
        ),
      );
    }
    if (_drawable.isEmpty) {
      return const Center(child: Text('Diagram has no positioned objects.', style: TextStyle(color: Colors.grey)));
    }

    final content = _content;
    _lastContent = content;
    final ordered = _ordered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(_drawable.length, _counts),
        _BdOutline(outline: computeBdOutline(_drawable), linkedSubVis: widget.subViNames),
        const SizedBox(height: 6),
        Expanded(
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
                      color: const Color(0xFFE9E9E9),
                      child: InteractiveViewer(
                        transformationController: _transform,
                        constrained: false,
                        minScale: 0.02,
                        maxScale: 16,
                        boundaryMargin: const EdgeInsets.all(2000),
                        child: (_mode == DiagramRenderMode.faithful && ordered.length <= kFaithfulMaxObjects)
                            ? FaithfulLayer(objects: ordered, origin: content.topLeft, size: content.size, isFrontPanel: widget.isFrontPanel)
                            : GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapDown: (d) => _selectAt(d.localPosition, ordered, content),
                                child: CustomPaint(
                                  size: Size(content.width, content.height),
                                  painter: _DiagramPainter(objects: ordered, origin: content.topLeft),
                                  foregroundPainter: _OverlayPainter(
                                    origin: content.topLeft,
                                    selected: _selected,
                                    members: _members,
                                  ),
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
                  child: _DetailsCard(object: _selected!, members: _members, onClose: () => setState(() {
                        _selected = null;
                        _members = const {};
                      })),
                ),
              if (_mode == DiagramRenderMode.faithful && _ordered.length > kFaithfulMaxObjects)
                Positioned(
                  left: 8,
                  right: 8,
                  top: 8,
                  child: Material(
                    color: const Color(0xFFFFF3CD),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        'Faithful mode is disabled for large diagrams '
                        '(${_ordered.length} objects > $kFaithfulMaxObjects) — showing wireframe.',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF7A5B00)),
                      ),
                    ),
                  ),
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

  Widget _toolbar(int objectCount, Map<ViObjectKind, int> counts) => Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('$objectCount objects', style: const TextStyle(fontWeight: FontWeight.bold)),
          for (final entry in counts.entries)
            _LegendChip(color: _kindColor(entry.key), label: '${entry.key.name} ${entry.value}'),
          SegmentedButton<DiagramRenderMode>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: DiagramRenderMode.wireframe, icon: Icon(Icons.grid_4x4, size: 16), label: Text('Wireframe')),
              ButtonSegment(value: DiagramRenderMode.faithful, icon: Icon(Icons.widgets_outlined, size: 16), label: Text('Faithful')),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() {
              _mode = s.first;
              if (_mode == DiagramRenderMode.faithful) {
                _selected = null;
                _members = const {};
              }
            }),
          ),
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
    for (final object in objects) {
      final bounds = object.absBounds!;
      if (x >= bounds.left && x <= bounds.right && y >= bounds.top && y <= bounds.bottom) {
        final area = (bounds.width * bounds.height).toDouble();
        if (area <= bestArea) {
          bestArea = area;
          hit = object;
        }
      }
    }
    setState(() {
      _selected = hit;
      _members = _membersOf(hit);
    });
  }

  Set<ViHeapObject> _membersOf(ViHeapObject? o) =>
      o != null && o.category == ViObjectKind.structure ? nodesWithin(o, _drawable) : membersOf(o, _byId);

  void _fit() {
    final viewport = _lastViewport;
    final content = _lastContent;
    if (viewport == null || content == null || content.width <= 0 || content.height <= 0) return;
    final widthScale = (viewport.width / content.width).clamp(0.0, double.infinity);
    final scale = (widthScale < viewport.height / content.height ? widthScale : viewport.height / content.height) * 0.94;
    final tx = (viewport.width - content.width * scale) / 2;
    final ty = (viewport.height - content.height * scale) / 2;
    _transform.value = Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
    _fitted = true;
  }

  static Rect _contentRect(List<ViHeapObject> drawable) {
    var minX = 1 << 30, minY = 1 << 30, maxX = -(1 << 30), maxY = -(1 << 30);
    for (final object in drawable) {
      final bounds = object.absBounds!;
      if (bounds.left < minX) minX = bounds.left;
      if (bounds.top < minY) minY = bounds.top;
      if (bounds.right > maxX) maxX = bounds.right;
      if (bounds.bottom > maxY) maxY = bounds.bottom;
    }
    const margin = 40;
    return Rect.fromLTRB(
      (minX - margin).toDouble(),
      (minY - margin).toDouble(),
      (maxX + margin).toDouble(),
      (maxY + margin).toDouble(),
    );
  }

  static int _depth(ViHeapObject object, Map<int, ViHeapObject> byId) {
    var depth = 0;
    var cur = object;
    while (cur.parentOid != null && depth < 64) {
      final parent = byId[cur.parentOid];
      if (parent == null) break;
      cur = parent;
      depth++;
    }
    return depth;
  }

  static ViDiagram? _largestDiagram(List<ViDiagram>? diagrams) {
    if (diagrams == null || diagrams.isEmpty) return null;
    ViDiagram? best;
    var bestN = -1;
    for (final diagram in diagrams) {
      final placedCount = diagram.objects.where((o) => o.absBounds != null).length;
      if (placedCount > bestN) {
        bestN = placedCount;
        best = diagram;
      }
    }
    return bestN <= 0 ? null : best;
  }
}

/// Faithful-ish LabVIEW palette: terminals colored by data type, else by class.
Color _typeColor(ViTypeKind t) => switch (t) {
      ViTypeKind.numericFloat => const Color(0xFFE8732A),
      ViTypeKind.numericInt => const Color(0xFF1F6FE0),
      ViTypeKind.enumRing => const Color(0xFF1FA0C0),
      ViTypeKind.path => const Color(0xFF3FA64B),
      ViTypeKind.clnNode => const Color(0xFFE8C547),
      ViTypeKind.unknown => const Color(0xFF707070),
    };

Color _kindColor(ViObjectKind k) => switch (k) {
      ViObjectKind.node => const Color(0xFFE8C547),
      ViObjectKind.terminal => const Color(0xFF5C9BD6),
      ViObjectKind.terminalCluster => const Color(0xFF2BB8A8),
      ViObjectKind.structure => const Color(0xFF9A6B2E),
      ViObjectKind.decoration => const Color(0xFFBDBDBD),
      ViObjectKind.unknown => const Color(0xFF9E9E9E),
    };

Color _objectColor(ViHeapObject object) =>
    object.category == ViObjectKind.terminal && object.typeKind != ViTypeKind.unknown ? _typeColor(object.typeKind) : _kindColor(object.category);

/// The label drawn on a wireframe object. Structures (never text-labeled) show
/// their catalog kind via [structureBadge] (so the wireframe reads as logic too,
/// honestly tracking the class catalog — e.g. "For loop", "Case structure",
/// "Loop (BD) / container (FP)"); other objects show their recovered name and
/// (for terminals) data type. Pure + public for unit testing the canvas text.
String? wireframeAnnotation(ViHeapObject o) {
  if (o.category == ViObjectKind.structure) return structureBadge(o);
  final label = o.label;
  final type = o.typeKind == ViTypeKind.unknown ? null : o.typeKind.name;
  if (label != null && type != null) return '$label · $type';
  return label ?? type;
}

/// An honest, wire-free **control-flow outline** of a block diagram: the
/// structures grouped by catalog kind (e.g. `While loop`, `Case structure`), the
/// distinct **labeled-node captions** (a node's `C4 22` caption — for a subVI
/// usually its name, but NOT a proven call; many node kinds carry captions), and
/// the total node count. Conveys the diagram's control-flow shape at a glance
/// without claiming any dataflow edges (LabVIEW stores wires as geometry, with no
/// recoverable node→node endpoints). Pure + public so it is unit-testable.
({Map<String, int> structuresByKind, List<String> labeledNodes, int nodeCount, Map<ClassConfidence, int> confidence}) computeBdOutline(
    Iterable<ViHeapObject> objects) {
  const notControlFlow = {
    HeapObjectClass.diagramRoot,
    HeapObjectClass.diagramProps,
    HeapObjectClass.diagramFrame,
    HeapObjectClass.rootAux,
  };
  final byKind = <String, int>{};
  final labeledNodes = <String>[];
  var nodeCount = 0;
  final confidence = <ClassConfidence, int>{};
  for (final object in objects) {
    if (object.category == ViObjectKind.structure) {
      if (notControlFlow.contains(object.objectClass)) continue;
      final badge = structureBadge(object);
      byKind[badge] = (byKind[badge] ?? 0) + 1;
      confidence[object.objectClass.confidence] = (confidence[object.objectClass.confidence] ?? 0) + 1;
    } else if (object.category == ViObjectKind.node) {
      nodeCount++;
      confidence[object.objectClass.confidence] = (confidence[object.objectClass.confidence] ?? 0) + 1;
      final dl = nodeDisplayLabel(object);
      if (!dl.isHint && !labeledNodes.contains(dl.text)) labeledNodes.add(dl.text);
    }
  }
  return (structuresByKind: byKind, labeledNodes: labeledNodes, nodeCount: nodeCount, confidence: confidence);
}

/// Control-terminal classes — their internal sub-terminals are scaffolding.

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
///   propagated up to the control, so suppressing it loses nothing);
/// - subVI-node internal display sub-parts (`0xe5`) — corpus: 947, all under a
///   `0xc5` node; they overlap the parent node and would otherwise paint a stray
///   unknown rectangle over it.
bool _isScaffolding(ViHeapObject o, Map<int, ViHeapObject> byId) {
  if (o.kind == 0x09 || o.kind == 0x11c) return true;
  if (o.kind == 0xe5) return true;
  if (o.kind == 0x68 && o.bounds == null) return true;
  if (o.kind == 0xe0 || o.kind == 0x0b || o.kind == 0x0c || o.kind == 0x0d) {
    var parentOid = o.parentOid;
    var depth = 0;
    while (parentOid != null && depth < 64) {
      final po = byId[parentOid];
      if (po == null) break;
      if (kControlTerminalCodes.contains(po.kind)) return true;
      parentOid = po.parentOid;
      depth++;
    }
  }
  return false;
}

/// The **drawn** objects [o] declares as members (childRef ∪ memberRef from the
/// 0x14 ref graph), resolved via [byId] and filtered to objects actually on the
/// canvas (has bounds, not scaffolding-suppressed, not [o] itself) so a highlight
/// never floats over empty canvas. In practice members resolve to a drawn object
/// mostly for loops/structures — most other carriers' refs point at non-drawn
/// internal records — so the amber typically appears only for a selected structure.
/// Public for testing.
Set<ViHeapObject> membersOf(ViHeapObject? o, Map<int, ViHeapObject> byId) {
  if (o == null) return const {};
  return {
    for (final oid in o.memberOids)
      if (byId[oid] case final m? when m.absBounds != null && !identical(m, o) && !_isScaffolding(m, byId)) m,
  };
}

/// The **logic nodes/structures spatially inside** [structure] — the honest
/// "what this loop/case contains" signal (LabVIEW does not store an explicit
/// member list for the diagram, so containment is positional). Returns drawable
/// node/structure objects whose absolute bounds fall within [structure]'s bounds
/// (excluding itself and same-size overlaps); terminals/decorations are omitted
/// so the highlight reads as the contained logic. Public for testing.
Set<ViHeapObject> nodesWithin(ViHeapObject structure, Iterable<ViHeapObject> objects) {
  final structureBounds = structure.absBounds;
  if (structureBounds == null) return const {};
  final out = <ViHeapObject>{};
  for (final object in objects) {
    if (identical(object, structure)) continue;
    if (object.category != ViObjectKind.node && object.category != ViObjectKind.structure) continue;
    final bounds = object.absBounds;
    if (bounds == null) continue;
    if (bounds.left < structureBounds.left || bounds.top < structureBounds.top || bounds.right > structureBounds.right || bounds.bottom > structureBounds.bottom) continue;
    if (bounds.left == structureBounds.left && bounds.top == structureBounds.top && bounds.right == structureBounds.right && bounds.bottom == structureBounds.bottom) continue;
    out.add(object);
  }
  return out;
}

/// The **static** diagram layer: grid, objects, and labels. Depends only on the
/// (memoized, stable) object list + origin, so a selection tap never repaints it
/// — the cheap [_OverlayPainter] handles highlights instead.
class _DiagramPainter extends CustomPainter {
  _DiagramPainter({required this.objects, required this.origin});

  final List<ViHeapObject> objects;
  final Offset origin;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFE9E9E9));
    _drawDotGrid(canvas, size);

    Rect rectOf(ViHeapObject o) {
      final bounds = o.absBounds!;
      return Rect.fromLTRB(bounds.left - origin.dx, bounds.top - origin.dy, bounds.right - origin.dx, bounds.bottom - origin.dy);
    }

    final structures = objects.where((o) => o.category == ViObjectKind.structure).toList();
    final decorations = objects.where((o) => o.category == ViObjectKind.decoration).toList();
    final solids = objects
        .where((o) => o.category != ViObjectKind.structure && o.category != ViObjectKind.decoration)
        .toList()
      ..sort((a, b) => (b.absBounds!.width * b.absBounds!.height).compareTo(a.absBounds!.width * a.absBounds!.height));

    for (final object in decorations) {
      canvas.drawRect(rectOf(object), Paint()..color = _kindColor(object.category).withValues(alpha: 0.10));
    }
    for (final object in structures) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rectOf(object), const Radius.circular(5)),
        Paint()
          ..color = _kindColor(ViObjectKind.structure).withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    for (final object in solids) {
      final rr = RRect.fromRectAndRadius(rectOf(object), const Radius.circular(2.5));
      canvas.drawRRect(rr, Paint()..color = _objectColor(object).withValues(alpha: 0.92));
      canvas.drawRRect(rr, Paint()
        ..color = Colors.black.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8);
    }
    for (final object in objects) {
      final text = wireframeAnnotation(object);
      if (text == null) continue;
      final rect = rectOf(object);
      if (rect.width < 26 || rect.height < 11) continue;
      final onFrame = object.category == ViObjectKind.structure;
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
  }

  void _drawDotGrid(Canvas canvas, Size size) {
    const stepPx = 12.0;
    const maxDots = 20000;
    final cells = (size.width / stepPx) * (size.height / stepPx);
    final step = cells > maxDots ? stepPx * (cells / maxDots) : stepPx;
    final dot = Paint()..color = const Color(0x22000000);
    for (var x = 0.0; x < size.width; x += step) {
      for (var y = 0.0; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 0.6, dot);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DiagramPainter old) =>
      !identical(old.objects, objects) || old.origin != origin;
}

/// The **overlay** layer: just the selection + declared-member highlight strokes.
/// A few `drawRect`s, so a selection tap repaints this (not the static object
/// layer). Shares the object→canvas mapping with [_DiagramPainter].
class _OverlayPainter extends CustomPainter {
  _OverlayPainter({required this.origin, required this.selected, required this.members});

  final Offset origin;
  final ViHeapObject? selected;
  final Set<ViHeapObject> members;

  Rect _rectOf(ViHeapObject o) {
    final bounds = o.absBounds!;
    return Rect.fromLTRB(bounds.left - origin.dx, bounds.top - origin.dy, bounds.right - origin.dx, bounds.bottom - origin.dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (members.isNotEmpty) {
      final mp = Paint()
        ..color = const Color(0xFFEF6C00)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      for (final member in members) {
        if (member.absBounds != null) canvas.drawRect(_rectOf(member).inflate(1.5), mp);
      }
    }
    final sel = selected;
    if (sel != null && sel.absBounds != null) {
      canvas.drawRect(_rectOf(sel).inflate(2.5), Paint()
        ..color = const Color(0xFF1565C0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5);
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) =>
      old.origin != origin || !identical(old.selected, selected) ||
      old.members.length != members.length || !old.members.containsAll(members);
}

/// A "label: value" detail row for the selected-object card (decoded semantics).
Widget _detail(String label, String value) => Padding(
      padding: const EdgeInsets.only(top: 3),
      child: RichText(
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          style: const TextStyle(fontSize: 12, color: Color(0xFF333333)),
          children: [
            TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF1565C0))),
            TextSpan(text: value),
          ],
        ),
      ),
    );

class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.object, required this.onClose, this.members = const {}});
  final ViHeapObject object;
  final VoidCallback onClose;

  /// The logic objects this one contains (for a selected structure) — listed so
  /// the user can read "this loop/case contains these subVIs" textually.
  final Set<ViHeapObject> members;

  static String _contentLabel(ViHeapObject o) {
    final label = o.label?.trim();
    return (label != null && label.isNotEmpty) ? label : o.objectClass.label;
  }

  @override
  Widget build(BuildContext context) {
    final bounds = object.absBounds;
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
                  Text(
                    object.label ??
                        (cls != HeapObjectClass.unknown
                            ? cls.label
                            : switch (object.category) {
                                ViObjectKind.node => 'Node',
                                ViObjectKind.structure => 'Structure',
                                ViObjectKind.terminal => 'Terminal',
                                _ => cls.label,
                              }),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${cls.label}$conf · class 0x${object.kind.toRadixString(16)} · oid ${object.oid}'
                    '${object.typeKind != ViTypeKind.unknown ? ' · type ${object.typeKind.name}' : ''}'
                    '${bounds != null ? ' · ${bounds.width}×${bounds.height} @(${bounds.left},${bounds.top})' : ''}'
                    '${object.parentOid != null ? ' · parent ${object.parentOid}' : ''}',
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  if (object.items.isNotEmpty)
                    _detail('values', object.items.take(8).join(', ') + (object.items.length > 8 ? ', …' : '')),
                  if (formatControlRange(object.controlMin, object.controlMax) case final range?)
                    _detail('range', range),
                  if (object.helpText != null && stripHelpMarkup(object.helpText!).isNotEmpty)
                    _detail('help', stripHelpMarkup(object.helpText!)),
                  if (members.isNotEmpty)
                    _detail(
                      'contains',
                      members.map(_contentLabel).take(10).join(', ') + (members.length > 10 ? ', …' : ''),
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

/// A compact, honest control-flow outline strip under the diagram toolbar:
/// structures grouped by catalog kind + the named subVI/function calls. Renders
/// nothing when the diagram has no structures or named calls.
class _BdOutline extends StatelessWidget {
  const _BdOutline({required this.outline, this.linkedSubVis = const []});
  final ({Map<String, int> structuresByKind, List<String> labeledNodes, int nodeCount, Map<ClassConfidence, int> confidence}) outline;

  /// The VI's sub-VI dependency names from the LIbd linker block — recoverable
  /// for ~82% of VIs; a linker dependency list, not a per-node call mapping.
  /// Shown separately from the heap-derived diagram-labeled nodes.
  final List<String> linkedSubVis;

  @override
  Widget build(BuildContext context) {
    final structs = outline.structuresByKind.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final labeledNodes = outline.labeledNodes;
    if (structs.isEmpty && labeledNodes.isEmpty && linkedSubVis.isEmpty && outline.confidence.isEmpty) {
      return const SizedBox.shrink();
    }

    const muted = TextStyle(fontSize: 12, color: Colors.grey);
    Widget capped(String prefix, List<String> items) => Text(
          '$prefix: ' +
              items.take(20).join(', ') +
              (items.length > 20 ? ', … (+${items.length - 20})' : ''),
          style: muted,
        );
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (structs.isNotEmpty)
            Wrap(spacing: 10, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
              const Text('Control flow:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              for (final entry in structs) Text('${entry.key} ×${entry.value}', style: muted),
            ]),
          if (linkedSubVis.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: capped('Linked subVIs (${linkedSubVis.length})', linkedSubVis),
            ),
          if (labeledNodes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: capped('Diagram-labeled nodes (${labeledNodes.length})', labeledNodes),
            ),
          if (outline.confidence.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Wrap(spacing: 10, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                const Text('Class confidence:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                Text('${outline.confidence[ClassConfidence.confirmed] ?? 0} confirmed', style: muted),
                Text('${outline.confidence[ClassConfidence.inferred] ?? 0} inferred', style: muted),
                Text('${outline.confidence[ClassConfidence.kindOnly] ?? 0} guessed', style: muted),
              ]),
            ),
            const Text('(how solid each object’s classification is — not dataflow / execution order)',
                style: TextStyle(fontSize: 11, color: Colors.grey, fontStyle: FontStyle.italic)),
          ],
        ],
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
