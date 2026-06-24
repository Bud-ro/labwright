import 'package:flutter/material.dart';
import 'package:labwright_videcode/labwright_videcode.dart';

/// The **Faithful** render layer: draws each recovered block-diagram object as a
/// real, type-appropriate Flutter control positioned at its absolute coordinates
/// — numeric spinners, enum/ring dropdowns, boolean toggles, string/path fields,
/// graph placeholders, titled structure frames and subVI node boxes. The widgets
/// are interactive (they respond to clicks/drags/typing) but **not wired to any
/// backend** — this is a faithful *appearance* of the VI's panel-on-diagram, not
/// a running VI. Layout uses each object's real pixel bounds; the surrounding
/// `InteractiveViewer` provides pan/zoom.
class FaithfulLayer extends StatelessWidget {
  const FaithfulLayer({super.key, required this.objects, required this.origin, required this.size});

  /// Drawable objects in paint order (containers first, so controls land on top).
  final List<ViHeapObject> objects;

  /// Top-left of the content rect, subtracted so the canvas starts at (0,0).
  final Offset origin;

  /// The content size.
  final Size size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(
        children: [
          for (final o in objects)
            if (o.absBounds != null)
              Positioned(
                left: o.absBounds!.left - origin.dx,
                top: o.absBounds!.top - origin.dy,
                width: o.absBounds!.width.toDouble().clamp(1, 8000),
                height: o.absBounds!.height.toDouble().clamp(1, 8000),
                child: ClipRect(child: _withHelp(o, _faithfulFor(o))),
              ),
        ],
      ),
    );
  }
}

/// Wraps a faithful control in a hover [Tooltip] surfacing its decoded help text
/// and/or numeric range — honest (only shown when actually decoded), and on the
/// tooltip so it never overflows a tiny control box.
Widget _withHelp(ViHeapObject o, Widget child) {
  final msg = controlTooltip(o);
  return msg == null ? child : Tooltip(message: msg, waitDuration: const Duration(milliseconds: 400), child: child);
}

/// The faithful-control hover tooltip for [o] — its decoded help text and/or
/// numeric range (`help\nrange: lo … hi`), or null when neither is present.
/// Pure + public for unit testing (the tap-to-select path is widget-test-hostile).
String? controlTooltip(ViHeapObject o) {
  final parts = <String>[];
  final h = o.helpText?.trim();
  if (h != null && h.isNotEmpty) parts.add(h);
  final range = formatControlRange(o.controlMin, o.controlMax);
  if (range != null) parts.add('range: $range');
  return parts.isEmpty ? null : parts.join('\n');
}

Widget _faithfulFor(ViHeapObject o) {
  switch (o.objectClass) {
    case HeapObjectClass.loop:
    case HeapObjectClass.caseOrSequence:
    case HeapObjectClass.clusterShell:
      return _StructureFrame(isCase: o.objectClass == HeapObjectClass.caseOrSequence);
    case HeapObjectClass.controlLabel:
      return _LabelText(o.label);
    case HeapObjectClass.numericControl:
    case HeapObjectClass.numericControlVariant:
      return const _ControlWidget(form: _Form.numeric);
    case HeapObjectClass.enumRingControl:
      return _ControlWidget(form: _Form.enumRing, items: o.items);
    case HeapObjectClass.booleanOrClusterControl:
      // Gate on the items that actually reach the control (ring items propagate
      // up from the 0x0d child); typeKind never propagates to a 0x4f, so the old
      // typeKind check could never fire a dropdown.
      return _ControlWidget(form: o.items.isNotEmpty ? _Form.enumRing : _Form.boolean, items: o.items);
    case HeapObjectClass.stringOrArrayControl:
      return const _ControlWidget(form: _Form.string);
    case HeapObjectClass.pathControl:
      return const _ControlWidget(form: _Form.path);
    case HeapObjectClass.graphIndicator:
      return const _GraphPlaceholder();
    default:
      // Fall back by coarse category.
      if (o.category == ViObjectKind.node) return _NodeBox(o.label);
      if (o.category == ViObjectKind.structure) return const _StructureFrame(isCase: false);
      if (o.category == ViObjectKind.terminal) return const _ControlWidget(form: _Form.generic);
      return const SizedBox.shrink();
  }
}

const _kBorder = Color(0xFF7A7A7A);
const _kField = Color(0xFFFAFAFA);
const _kInk = Color(0xFF1A1A1A);

class _StructureFrame extends StatelessWidget {
  const _StructureFrame({required this.isCase});
  final bool isCase;
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: const Color(0x14000000),
          border: Border.all(color: const Color(0xFF8C6B3F), width: 3),
          borderRadius: BorderRadius.circular(4),
        ),
        // a thin inner highlight for the LabVIEW structure look
        child: Container(
          margin: const EdgeInsets.all(1),
          decoration: BoxDecoration(border: Border.all(color: const Color(0x33FFFFFF))),
        ),
      );
}

class _NodeBox extends StatelessWidget {
  const _NodeBox(this.label);
  final String? label;
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: const Color(0xFFEFD98A),
          border: Border.all(color: const Color(0xFF8A7320)),
          borderRadius: BorderRadius.circular(2),
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(2),
        child: label == null ? null : Text(label!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9, color: _kInk)),
      );
}

class _LabelText extends StatelessWidget {
  const _LabelText(this.label);
  final String? label;
  @override
  Widget build(BuildContext context) => Container(
        // Transparent like a real LabVIEW label (no clashing filled box); a soft
        // white halo keeps the dark text legible over any control beneath it.
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(
          label ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 10,
            color: _kInk,
            shadows: [
              Shadow(color: Color(0xCCFFFFFF), blurRadius: 1.5),
              Shadow(color: Color(0x88FFFFFF), blurRadius: 2.5),
            ],
          ),
        ),
      );
}

class _GraphPlaceholder extends StatelessWidget {
  const _GraphPlaceholder();
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: const Color(0xFF0F1A0F), border: Border.all(color: _kBorder)),
        child: CustomPaint(painter: _GraphPainter()),
      );
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
      final y = size.height / 2 - (size.height / 2.6) * _sin(i / 48 * 6.283 * 2);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, trace);
  }

  // small sine without importing dart:math twice over (keeps the file self-contained)
  double _sin(double t) {
    // Bhaskara approximation is plenty for a decorative trace.
    final x = t % 6.283185;
    final xx = x > 3.14159 ? x - 6.283185 : x;
    return 16 * xx * (3.14159 - xx.abs()) / (5 * 3.14159 * 3.14159 - 4 * xx.abs() * (3.14159 - xx.abs()));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

enum _Form { numeric, enumRing, boolean, string, path, generic }

/// A single interactive (but unwired) control rendered to fit its object bounds.
class _ControlWidget extends StatefulWidget {
  const _ControlWidget({required this.form, this.items = const []});
  final _Form form;
  final List<String> items;
  @override
  State<_ControlWidget> createState() => _ControlWidgetState();
}

class _ControlWidgetState extends State<_ControlWidget> {
  double _num = 0;
  bool _bool = false;
  int _enum = 0;
  late final TextEditingController _text = TextEditingController();
  // Real decoded items when available; a neutral placeholder otherwise.
  List<String> get _enumItems => widget.items.isNotEmpty ? widget.items : const ['—'];

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  BoxDecoration get _box => BoxDecoration(color: _kField, border: Border.all(color: _kBorder), borderRadius: BorderRadius.circular(2));

  @override
  Widget build(BuildContext context) {
    switch (widget.form) {
      case _Form.numeric:
        return Container(
          decoration: _box,
          padding: const EdgeInsets.only(left: 4),
          child: Row(children: [
            Expanded(child: Text(_num.toStringAsFixed(0), style: const TextStyle(fontSize: 11, color: _kInk), overflow: TextOverflow.clip)),
            // SizedBox bounds the width; OverflowBox lets the spinner keep its
            // natural height in very short terminals (clipped by FaithfulLayer's
            // ClipRect) without a RenderFlex overflow assertion.
            SizedBox(
              width: 14,
              child: OverflowBox(
                maxHeight: double.infinity,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  _spin(Icons.arrow_drop_up, () => setState(() => _num += 1)),
                  _spin(Icons.arrow_drop_down, () => setState(() => _num -= 1)),
                ]),
              ),
            ),
          ]),
        );
      case _Form.enumRing:
        return InkWell(
          onTap: () async {
            final box = context.findRenderObject()! as RenderBox;
            final pos = box.localToGlobal(Offset.zero);
            final sel = await showMenu<int>(
              context: context,
              position: RelativeRect.fromLTRB(pos.dx, pos.dy + box.size.height, pos.dx + 1, pos.dy),
              items: [for (var i = 0; i < _enumItems.length; i++) PopupMenuItem(value: i, child: Text(_enumItems[i]))],
            );
            if (sel != null && mounted) setState(() => _enum = sel);
          },
          child: Container(
            decoration: _box.copyWith(color: const Color(0xFFEFEFEF)),
            padding: const EdgeInsets.only(left: 4),
            child: Row(children: [
              Expanded(child: Text(_enumItems[_enum], style: const TextStyle(fontSize: 11, color: _kInk), overflow: TextOverflow.ellipsis)),
              const Icon(Icons.arrow_drop_down, size: 16, color: _kInk),
            ]),
          ),
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
            child: Text(_bool ? 'ON' : 'OFF', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white)),
          ),
        );
      case _Form.string:
        return _field(hint: 'abc');
      case _Form.path:
        return Container(
          decoration: _box,
          child: Row(children: [
            const Padding(padding: EdgeInsets.symmetric(horizontal: 3), child: Icon(Icons.folder_open, size: 13, color: Color(0xFF7A6A20))),
            Expanded(child: _field(hint: 'path', bare: true)),
          ]),
        );
      case _Form.generic:
        return Container(decoration: _box.copyWith(color: const Color(0xFFE3ECF5)));
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
          decoration: InputDecoration.collapsed(hintText: hint, hintStyle: const TextStyle(fontSize: 11, color: Color(0xFFAAAAAA))),
        ),
      );
}
