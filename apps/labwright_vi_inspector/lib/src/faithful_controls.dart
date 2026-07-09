import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// The **Faithful** render layer: draws each recovered block-diagram object as a
/// real, type-appropriate Flutter control positioned at its absolute coordinates
/// — numeric spinners, enum/ring dropdowns, boolean toggles, string/path fields,
/// graph placeholders, titled structure frames and subVI node boxes. The widgets
/// are interactive (they respond to clicks/drags/typing) but **not wired to any
/// backend** — this is a faithful *appearance* of the VI's panel-on-diagram, not
/// a running VI. Layout uses each object's real pixel bounds; the surrounding
/// `InteractiveViewer` provides pan/zoom.
class FaithfulLayer extends StatelessWidget {
  const FaithfulLayer({
    super.key,
    required this.objects,
    required this.origin,
    required this.size,
    this.isFrontPanel = false,
  });

  /// Drawable objects in paint order (containers first, so controls land on top).
  final List<ViHeapObject> objects;

  /// Top-left of the content rect, subtracted so the canvas starts at (0,0).
  final Offset origin;

  /// The content size.
  final Size size;

  /// Whether this is the front panel. On the FP, structures are visual containers
  /// (clusters/arrays/panes) — their class-kind badge is noise and collides with
  /// the control's caption, so we show the caption instead. On the block diagram,
  /// structures are control flow (loops/cases) so the kind badge is kept.
  final bool isFrontPanel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(
        children: [
          for (final object in objects)
            if (object.absBounds != null)
              Positioned(
                left: object.absBounds!.left - origin.dx,
                top: object.absBounds!.top - origin.dy,
                width: object.absBounds!.width.toDouble().clamp(1, 8000),
                height: object.absBounds!.height.toDouble().clamp(1, 8000),
                child: _emphasize(
                  object,
                  ClipRect(
                    child: _withHelp(
                      object,
                      _faithfulFor(object, isFrontPanel: isFrontPanel),
                    ),
                  ),
                  isFrontPanel: isFrontPanel,
                ),
              ),
        ],
      ),
    );
  }
}

/// The title shown on a structure frame. On the block diagram this is the catalog
/// kind ("While loop", "Case structure") so control flow reads; on the front panel
/// — where the structure is just a container — it is the structure's own caption
/// if it has one, else nothing (so it never obscures a separate caption object).
// Rendering decisions that are not obvious from the code:
// - Structure frames draw outline-only (no fill): structures nest inside other
//   structures ~79% of the time, and stacked fills accumulate a muddy tint.
// - Node boxes are translucent placeholders: ~37% of sibling nodes overlap, so
//   an opaque plate would hide neighbours.
// - A recovered subVI name is NOT drawn inside the node box — it already
//   renders as the node's own floating label, and re-printing it would
//   double-print across ~42k corpus nodes. It stays reachable via the tooltip.
String? structureFrameTitle(ViHeapObject object, {required bool isFrontPanel}) {
  if (!isFrontPanel) return structureBadge(object);
  final own = object.label?.trim();
  return (own != null && own.isNotEmpty) ? own : null;
}

/// Visual-hierarchy weight for [o] in the diagram: on the **block diagram** the
/// logic-bearing objects (structures, nodes, labeled controls) stay full strength
/// while unlabeled "noise" (decorations, unclassified boxes, bare terminals) is
/// dimmed so the logic stands out. On the **front panel** this de-emphasis is
/// wrong — a panel is a solid UI, not a logic graph — so everything renders at
/// full strength. Honest either way: nothing is hidden, all objects stay drawn +
/// tappable, and the wireframe view remains the full-strength honest render.
double _emphasis(ViHeapObject object, {bool isFrontPanel = false}) {
  if (isFrontPanel) return 1;
  final labeled = object.label?.trim().isNotEmpty ?? false;
  switch (object.category) {
    case ViObjectKind.structure:
    case ViObjectKind.node:
      return 1;
    case ViObjectKind.decoration:
      return 0.3;
    case ViObjectKind.wire:
      return 1;
    case ViObjectKind.unknown:
      return 0.4;
    case ViObjectKind.terminal:
    case ViObjectKind.terminalCluster:
      return (labeled || object.items.isNotEmpty) ? 1 : 0.6;
  }
}

/// Applies [_emphasis] as opacity. Opacity 1.0 short-circuits (no save layer), so
/// only the dimmed noise objects pay any cost (none on the front panel).
Widget _emphasize(
  ViHeapObject object,
  Widget child, {
  bool isFrontPanel = false,
}) {
  final emphasis = _emphasis(object, isFrontPanel: isFrontPanel);
  return emphasis >= 1 ? child : Opacity(opacity: emphasis, child: child);
}

/// Wraps a faithful control in a hover [Tooltip] surfacing its decoded help text
/// and/or numeric range — honest (only shown when actually decoded), and on the
/// tooltip so it never overflows a tiny control box.
Widget _withHelp(ViHeapObject object, Widget child) {
  final msg = controlTooltip(object);
  return msg == null
      ? child
      : Tooltip(
          message: msg,
          waitDuration: const Duration(milliseconds: 400),
          child: child,
        );
}

/// The faithful-control hover tooltip for [o] — its decoded help text and/or
/// numeric range (`help\nrange: lo … hi`). When neither is present, falls back to
/// the object's identity so a hovered node/structure isn't a silent mystery box:
/// its name (the propagated node caption, e.g. `Build Array`) or, failing that,
/// its class label (`Node (primitive)`, `Case structure`). Returns null only for
/// an anonymous non-node/structure with nothing to say.
/// Pure + public for unit testing (the tap-to-select path is widget-test-hostile).
String? controlTooltip(ViHeapObject object) {
  final parts = <String>[];
  final helpText = object.helpText == null
      ? null
      : stripHelpMarkup(object.helpText!);
  if (helpText != null && helpText.isNotEmpty) parts.add(helpText);
  final range = formatControlRange(object.controlMin, object.controlMax);
  if (range != null) parts.add('range: $range');
  if (parts.isNotEmpty) return parts.join('\n');
  final name = object.label?.trim();
  if (name != null && name.isNotEmpty) return name;
  final cls = object.objectClass;
  if (cls != HeapObjectClass.unknown &&
      (object.category == ViObjectKind.node ||
          object.category == ViObjectKind.structure)) {
    return cls.label;
  }
  return null;
}

Widget _faithfulFor(ViHeapObject object, {bool isFrontPanel = false}) {
  switch (object.objectClass) {
    case HeapObjectClass.loop:
    case HeapObjectClass.caseOrSequence:
    case HeapObjectClass.clusterShell:
    case HeapObjectClass.bdStructureFrame:
      return _StructureFrame(
        kind: structureFrameTitle(object, isFrontPanel: isFrontPanel),
      );
    case HeapObjectClass.controlLabel:
    case HeapObjectClass.bdSelectorLabel:
      return _LabelText(object.label, ink: decodedInk(object));
    case HeapObjectClass.bdGlyph:
      return const _Glyph();
    case HeapObjectClass.numericControl:
    case HeapObjectClass.numericControlVariant:
      return _ControlWidget(
        form: _Form.numeric,
        fill: decodedControlFill(object),
      );
    case HeapObjectClass.enumRingControl:
      return _ControlWidget(form: _Form.enumRing, items: object.items);
    case HeapObjectClass.booleanOrClusterControl:
      return object.items.length >= 2
          ? _ControlWidget(form: _Form.enumRing, items: object.items)
          : _ControlWidget(
              form: _Form.boolean,
              label: object.items.isNotEmpty
                  ? object.items.first
                  : object.label,
            );
    case HeapObjectClass.stringOrArrayControl:
      return _ControlWidget(
        form: _Form.string,
        fill: decodedControlFill(object),
      );
    case HeapObjectClass.pathControl:
      return _ControlWidget(form: _Form.path, fill: decodedControlFill(object));
    case HeapObjectClass.bdLeaf:
      return const _LeafBox();
    case HeapObjectClass.graphIndicator:
      return _GraphPlaceholder(plotNames: object.plotNames);
    case HeapObjectClass.controlSubPart:
      return const _UnknownBox();
    default:
      if (object.category == ViObjectKind.node) {
        final label = nodeDisplayLabel(object);
        return _NodeBox(label: label.text, isHint: label.isHint);
      }
      if (object.category == ViObjectKind.structure) {
        return _StructureFrame(
          kind: structureFrameTitle(object, isFrontPanel: isFrontPanel),
        );
      }
      if (object.category == ViObjectKind.terminal)
        return _ControlWidget(
          form: _Form.generic,
          fill: decodedControlFill(object),
        );
      return const _UnknownBox();
  }
}

const _kBorder = Color(0xFF7A7A7A);
const _kField = Color(0xFFFAFAFA);
const _kInk = Color(0xFF1A1A1A);

/// The decoded interior fill colour for a control — its
/// [ViHeapObject.contentRgb] (the field colour LabVIEW stored) if present, else
/// its [ViHeapObject.bgRgb] — as an opaque colour, or null when neither was
/// decoded (the control then keeps its neutral field colour). See the corpus
/// placement probe: these colours sit on the drawable control itself.
Color? decodedControlFill(ViHeapObject object) {
  final rgb = object.contentRgb ?? object.bgRgb;
  return rgb == null ? null : Color(0xFF000000 | (rgb & 0xFFFFFF));
}

/// The decoded foreground/ink colour for a label ([ViHeapObject.fgRgb], the
/// LabVIEW text colour) as an opaque colour, or null when it was not decoded
/// (the label then keeps its neutral ink). Confirmed and, per the corpus probe,
/// carried on the drawable object itself.
Color? decodedInk(ViHeapObject object) {
  final rgb = object.fgRgb;
  return rgb == null ? null : Color(0xFF000000 | (rgb & 0xFFFFFF));
}

/// The text to show on a node box: its recovered name when present (e.g. a subVI
/// filename), otherwise an honest class HINT derived from its classification
/// (`primitive`, `growable`, `Call Library node`) so the box isn't blank.
/// `isHint` is true for the class-derived fallback so it can be styled apart from
/// a real name. Pure + public for testing.
({String text, bool isHint}) nodeDisplayLabel(ViHeapObject object) {
  final label = object.label?.trim();
  if (label != null && label.isNotEmpty) return (text: label, isHint: false);
  final cls = object.objectClass.label;
  final match = RegExp(r'^Node \((.+)\)$').firstMatch(cls);
  return (text: match != null ? match.group(1)! : cls, isHint: true);
}

/// The badge text for a structure object — taken from the videcode CLASS CATALOG
/// ([HeapObjectClass.label]) rather than a hand-maintained table, so the inspector
/// can't drift from / contradict the catalog's honest, hedged names (e.g. 0x53 =
/// "Loop (BD) / container (FP)", 0x2c = "Case structure", 0x20 = "For loop").
/// Falls back to "Structure" only when the class is uncatalogued. Public for
/// testing + shared with the wireframe annotation.
String structureBadge(ViHeapObject object) =>
    object.objectClass == HeapObjectClass.unknown
    ? 'Structure'
    : object.objectClass.label;

class _StructureFrame extends StatelessWidget {
  const _StructureFrame({this.kind});
  final String? kind;
  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      Positioned.fill(
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFF8C6B3F), width: 3),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Container(
            margin: const EdgeInsets.all(1),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0x33FFFFFF)),
            ),
          ),
        ),
      ),
      if (kind != null)
        Positioned(
          left: 0,
          top: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            color: const Color(0xCC8C6B3F),
            child: Text(
              kind!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 9,
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
    ],
  );
}

class _NodeBox extends StatelessWidget {
  const _NodeBox({this.label, this.isHint = false});
  final String? label;

  /// True when [label] is a class hint (e.g. `primitive`) rather than a recovered
  /// name — rendered italic + dimmer so it reads as "kind" not a real name.
  final bool isHint;

  @override
  Widget build(BuildContext context) => Container(
    alignment: Alignment.center,
    padding: const EdgeInsets.symmetric(horizontal: 1),
    clipBehavior: Clip.hardEdge,
    decoration: BoxDecoration(
      color: const Color(0xCCEFD98A),
      border: Border.all(color: const Color(0xFF8A7320)),
      borderRadius: BorderRadius.circular(2),
    ),
    child: (isHint && label != null && label!.isNotEmpty)
        ? Text(
            label!,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 8,
              color: Color(0x99000000),
              height: 1.05,
              fontStyle: FontStyle.italic,
            ),
          )
        : null,
  );
}

class _LabelText extends StatelessWidget {
  const _LabelText(this.label, {this.ink});
  final String? label;

  /// The decoded foreground/ink colour for this label, or null for the neutral
  /// default (see [decodedInk]).
  final Color? ink;
  @override
  Widget build(BuildContext context) => Container(
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: Text(
      label ?? '',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 10,
        color: ink ?? _kInk,
        shadows: const [
          Shadow(color: Color(0xCCFFFFFF), blurRadius: 1.5),
          Shadow(color: Color(0x88FFFFFF), blurRadius: 2.5),
        ],
      ),
    ),
  );
}

/// A free-standing block-diagram leaf (0x16) — a small terminal/constant box at
/// its real 32×16 bounds (corpus: it sits a median 216px from any node, so it is
/// NOT an on-node pin). Light fill + thin border so it reads as a small diagram
/// element without dominating; the terminal-vs-constant role is not yet recovered.
class _LeafBox extends StatelessWidget {
  const _LeafBox();
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: const Color(0x225B6B7A),
      border: Border.all(color: const Color(0xFF5B6B7A), width: 0.5),
      borderRadius: BorderRadius.circular(1),
    ),
  );
}

/// A bounded but unclassified object — a faint dashed-look outline so it stays
/// visible (matching the wireframe's honest gray box) rather than being silently
/// dropped from the faithful render. ~0.19% of drawable BD objects are this tail.
class _UnknownBox extends StatelessWidget {
  const _UnknownBox();
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: const Color(0x11000000),
      border: Border.all(color: const Color(0x55808080)),
    ),
  );
}

/// A small fixed node glyph (0x177, 12×12) — drawn as a faint centred dot rather
/// than a filled box, so ~6k of them mark their spot without adding visual weight.
class _Glyph extends StatelessWidget {
  const _Glyph();
  @override
  Widget build(BuildContext context) => const Center(
    child: SizedBox(
      width: 4,
      height: 4,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color(0x99000000),
          shape: BoxShape.circle,
        ),
      ),
    ),
  );
}

class _GraphPlaceholder extends StatelessWidget {
  const _GraphPlaceholder({this.plotNames = const []});

  /// Recovered plot/curve names (`C4 27`, e.g. "Plot 0"). NOT painted as an
  /// on-graph legend: the file already carries the real plot legend as its own
  /// positioned decoration object (a `0xE7`/`0xD2` child of the graph), so
  /// drawing a second legend at an invented spot would be fabricated UI. These
  /// are exposed only as a tooltip — an inspector affordance, not VI chrome.
  final List<String> plotNames;

  @override
  Widget build(BuildContext context) {
    final graph = Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F1A0F),
        border: Border.all(color: _kBorder),
      ),
      child: CustomPaint(painter: _GraphPainter()),
    );
    if (plotNames.isEmpty) return graph;
    return Tooltip(
      message: 'Recovered plots: ${plotNames.join(', ')}',
      child: graph,
    );
  }
}

class _GraphPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0x3340C040)
      ..strokeWidth = 0.5;
    for (var x = 0.0; x < size.width; x += size.width / 6) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += size.height / 4) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final trace = Paint()
      ..color = const Color(0xFF63D663)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final path = Path();
    for (var i = 0; i <= 48; i++) {
      final x = size.width * i / 48;
      final y =
          size.height / 2 - (size.height / 2.6) * _sin(i / 48 * 6.283 * 2);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, trace);
  }

  /// Bhaskara I sine approximation — plenty for a decorative trace, and keeps the
  /// file self-contained (no second `dart:math` import).
  double _sin(double t) {
    final radians = t % 6.283185;
    final xx = radians > 3.14159 ? radians - 6.283185 : radians;
    return 16 *
        xx *
        (3.14159 - xx.abs()) /
        (5 * 3.14159 * 3.14159 - 4 * xx.abs() * (3.14159 - xx.abs()));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

enum _Form { numeric, enumRing, boolean, string, path, generic }

/// A single interactive (but unwired) control rendered to fit its object bounds.
class _ControlWidget extends StatefulWidget {
  const _ControlWidget({
    required this.form,
    this.items = const [],
    this.label,
    this.fill,
  });
  final _Form form;
  final List<String> items;

  /// For a boolean: the control's caption (its single 0x0d string), shown on the
  /// button so a labeled boolean ("STOP", "Channel A") reads as itself. Null → ON/OFF.
  final String? label;

  /// The decoded interior fill colour (see [decodedControlFill]), or null to use
  /// the neutral default field colour.
  final Color? fill;
  @override
  State<_ControlWidget> createState() => _ControlWidgetState();
}

class _ControlWidgetState extends State<_ControlWidget> {
  double _num = 0;
  bool _bool = false;
  int _enum = 0;
  late final TextEditingController _text = TextEditingController();
  List<String> get _enumItems =>
      widget.items.isNotEmpty ? widget.items : const ['—'];

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  BoxDecoration get _box => BoxDecoration(
    color: widget.fill ?? _kField,
    border: Border.all(color: _kBorder),
    borderRadius: BorderRadius.circular(2),
  );

  @override
  Widget build(BuildContext context) {
    switch (widget.form) {
      case _Form.numeric:
        return LayoutBuilder(
          builder: (context, c) {
            final showSpin = c.maxWidth >= 22;
            return Container(
              decoration: _box,
              padding: const EdgeInsets.only(left: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _num.toStringAsFixed(0),
                      style: const TextStyle(fontSize: 11, color: _kInk),
                      overflow: TextOverflow.clip,
                    ),
                  ),
                  if (showSpin)
                    SizedBox(
                      width: 14,
                      child: OverflowBox(
                        maxHeight: double.infinity,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _spin(
                              Icons.arrow_drop_up,
                              () => setState(() => _num += 1),
                            ),
                            _spin(
                              Icons.arrow_drop_down,
                              () => setState(() => _num -= 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      case _Form.enumRing:
        return LayoutBuilder(
          builder: (context, c) {
            final showCaret = c.maxWidth >= 24;
            return InkWell(
              onTap: () async {
                final box = context.findRenderObject()! as RenderBox;
                final pos = box.localToGlobal(Offset.zero);
                final sel = await showMenu<int>(
                  context: context,
                  position: RelativeRect.fromLTRB(
                    pos.dx,
                    pos.dy + box.size.height,
                    pos.dx + 1,
                    pos.dy,
                  ),
                  items: [
                    for (var i = 0; i < _enumItems.length; i++)
                      PopupMenuItem(value: i, child: Text(_enumItems[i])),
                  ],
                );
                if (sel != null && mounted) setState(() => _enum = sel);
              },
              child: Container(
                decoration: _box.copyWith(color: const Color(0xFFEFEFEF)),
                padding: const EdgeInsets.only(left: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _enumItems[_enum],
                        style: const TextStyle(fontSize: 11, color: _kInk),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (showCaret)
                      const Icon(Icons.arrow_drop_down, size: 16, color: _kInk),
                  ],
                ),
              ),
            );
          },
        );
      case _Form.boolean:
        return InkWell(
          onTap: () => setState(() => _bool = !_bool),
          child: Container(
            decoration: BoxDecoration(
              color: _bool ? const Color(0xFF4CAF50) : const Color(0xFFB0BEC5),
              border: Border.all(color: _kBorder),
              borderRadius: BorderRadius.circular(3),
            ),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              (widget.label != null && widget.label!.trim().isNotEmpty)
                  ? widget.label!.trim()
                  : (_bool ? 'ON' : 'OFF'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
        );
      case _Form.string:
        return _field(hint: 'abc');
      case _Form.path:
        return LayoutBuilder(
          builder: (context, c) {
            final showIcon = c.maxWidth >= 26;
            return Container(
              decoration: _box,
              child: Row(
                children: [
                  if (showIcon)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 3),
                      child: Icon(
                        Icons.folder_open,
                        size: 13,
                        color: Color(0xFF7A6A20),
                      ),
                    ),
                  Expanded(child: _field(hint: 'path', bare: true)),
                ],
              ),
            );
          },
        );
      case _Form.generic:
        return Container(
          decoration: _box.copyWith(color: const Color(0xFFE3ECF5)),
        );
    }
  }

  Widget _spin(IconData icon, VoidCallback onTap) => InkWell(
    onTap: onTap,
    child: Icon(icon, size: 11, color: _kInk),
  );

  Widget _field({required String hint, bool bare = false}) => Container(
    decoration: bare ? null : _box,
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: TextField(
      controller: _text,
      style: const TextStyle(fontSize: 11, color: _kInk),
      decoration: InputDecoration.collapsed(
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 11, color: Color(0xFFAAAAAA)),
      ),
    ),
  );
}
