import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:labwright_videcode/labwright_videcode.dart';

/// A read-only **hex + parser** view of one decoded resource-block section —
/// HxD/Wireshark style. The section's bytes are shown as a hex dump on the left,
/// record-colored; the right panel lists the parsed records (driven by the
/// clean-room `HeapOpcode` / `HeapObjectClass` / `HeapAttribute` catalogs and the
/// heap walker). Selecting a record highlights its bytes and shows its decoded
/// meaning, including typed displays (colour swatches, rectangles, strings,
/// numbers). Honest by construction: bytes the walker can't frame are shown as
/// an uncovered gap, never hidden.
class BlockHexView extends StatefulWidget {
  const BlockHexView({super.key, required this.section});

  final DecodedSection section;

  @override
  State<BlockHexView> createState() => _BlockHexViewState();
}

class _BlockHexViewState extends State<BlockHexView> {
  final _hexScroll = ScrollController();
  final _recScroll = ScrollController();
  late final List<_SpanInfo> _records;
  late final List<int> _byteToRecord; // byte offset -> record index (or -1)
  Widget? _preview; // typed whole-section display (e.g. an icon image)
  HeapWalk? _walk; // the record walk (for coverage / stop-point reporting)
  int _selected = -1;

  @override
  void initState() {
    super.initState();
    final b = widget.section.bytes;
    _preview = iconPreview(b);
    final isHeap = widget.section.wasCompressed || _looksLikeHeap(b);
    if (isHeap) {
      try {
        final w = walkHeapBody(b);
        _walk = w;
        _records = [
          // The heap stream opens with a u32 big-endian content-length header
          // (= record-stream bytes that follow = decompressed size − 4). The walk
          // proper begins at offset 4; annotate the header so no byte is unlabeled.
          if (b.length >= 4)
            _SpanInfo(
              offset: 0,
              length: 4,
              lead: b[0],
              color: _cHeader,
              title: 'Heap content length (u32)',
              detail: 'Big-endian u32 = ${_u32(b, 0)} bytes: the size of the record stream that '
                  'follows (= decompressed heap size − 4). The bracket-tree walk begins at offset 4.',
              inlinePreview: '${_u32(b, 0)} B',
            ),
          for (final s in w.spans) _classify(b, s, widget.section.tag),
        ];
      } catch (_) {
        _records = const [];
      }
    } else {
      _records = const [];
    }
    _byteToRecord = List<int>.filled(b.length, -1);
    for (var i = 0; i < _records.length; i++) {
      final r = _records[i];
      for (var o = r.offset; o < r.offset + r.length && o < b.length; o++) {
        _byteToRecord[o] = i;
      }
    }
  }

  @override
  void dispose() {
    _hexScroll.dispose();
    _recScroll.dispose();
    super.dispose();
  }

  /// Selects record [i]. Always scrolls the hex dump to the record's bytes; when
  /// the selection originated from a hex-byte tap ([fromHex]) it also scrolls the
  /// records list to bring that record into view (and vice-versa is implicit:
  /// tapping a record row scrolls the hex to its bytes).
  void _select(int i, {bool fromHex = false}) {
    setState(() => _selected = i);
    if (i < 0 || i >= _records.length) return;
    if (_hexScroll.hasClients) {
      final row = _records[i].offset ~/ 16;
      _hexScroll.animateTo((row * _kRowHeight).clamp(0.0, _hexScroll.position.maxScrollExtent),
          duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    }
    if (fromHex && _recScroll.hasClients) {
      _recScroll.animateTo((i * _kRecHeight - 80).clamp(0.0, _recScroll.position.maxScrollExtent),
          duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.section.bytes;
    final rows = (b.length + 15) ~/ 16;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(
            children: [
              Text('${widget.section.tag}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontFamily: 'monospace')),
              const SizedBox(width: 10),
              Text(
                '${_fmt(b.length)} ${widget.section.wasCompressed ? '(inflated)' : ''} · '
                '${_records.isEmpty ? 'raw bytes (no record framing)' : '${_records.length} records'}'
                '${_walk != null && !_walk!.complete ? ' · walk stopped at 0x${_walk!.stoppedAtOffset!.toRadixString(16)} (lead 0x${_walk!.stoppedLead!.toRadixString(16)}), ${(_walk!.coverage * 100).toStringAsFixed(0)}% framed' : ''}',
                style: TextStyle(color: _walk != null && !_walk!.complete ? Colors.orange : Colors.grey, fontSize: 12),
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // hex dump
              Expanded(
                flex: 3,
                child: Container(
                  color: const Color(0xFF1E1E1E),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: _rowWidth,
                      child: Scrollbar(
                        controller: _hexScroll,
                        thumbVisibility: true,
                        child: ListView.builder(
                          controller: _hexScroll,
                          itemCount: rows,
                          itemExtent: _kRowHeight,
                          itemBuilder: (context, row) => _hexRow(b, row),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              // records panel
              Expanded(
                flex: 2,
                child: _records.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: _preview ??
                              const Text(
                                'This section is not a record-framed heap, so only the '
                                'raw hex is shown.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey),
                              ),
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: Scrollbar(
                              controller: _recScroll,
                              thumbVisibility: true,
                              child: ListView.builder(
                                controller: _recScroll,
                                itemCount: _records.length,
                                itemExtent: _kRecHeight,
                                itemBuilder: (context, i) => _recordRow(i),
                              ),
                            ),
                          ),
                          if (_selected >= 0) _detail(_records[_selected]),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Fixed-width columns so the hex/ASCII grids align regardless of the platform
  // font (a "monospace" family alone does not guarantee equal glyph advance),
  // and so a tap maps to an exact byte.
  static const _offW = 66.0; // offset column
  static const _cellW = 21.0; // per-hex-byte cell
  static const _asciiW = 9.0; // per-ascii-char cell
  static const _gap = 14.0; // hex→ascii gap
  static const _rowWidth = _offW + 16 * _cellW + _gap + 16 * _asciiW;

  Widget _hexRow(List<int> b, int row) {
    final base = row * 16;
    const hexStart = _offW;
    const asciiStart = _offW + 16 * _cellW + _gap;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) {
        final dx = d.localPosition.dx;
        int? off;
        if (dx >= hexStart && dx < hexStart + 16 * _cellW) {
          off = base + ((dx - hexStart) ~/ _cellW);
        } else if (dx >= asciiStart && dx < asciiStart + 16 * _asciiW) {
          off = base + ((dx - asciiStart) ~/ _asciiW);
        }
        if (off != null && off >= 0 && off < b.length) {
          final ri = _byteToRecord[off];
          if (ri >= 0) _select(ri, fromHex: true);
        }
      },
      child: Row(
        children: [
          SizedBox(
            width: _offW,
            child: Text('  ${base.toRadixString(16).padLeft(6, '0')}',
                style: const TextStyle(color: Color(0xFF888888), fontFamily: 'monospace', fontSize: 12.5)),
          ),
          for (var i = 0; i < 16; i++) _cell(b, base + i, hex: true),
          const SizedBox(width: _gap),
          for (var i = 0; i < 16; i++) _cell(b, base + i, hex: false),
        ],
      ),
    );
  }

  Widget _cell(List<int> b, int o, {required bool hex}) {
    if (o >= b.length) return SizedBox(width: hex ? _cellW : _asciiW);
    final ri = _byteToRecord[o];
    final color = ri < 0 ? const Color(0xFF6E6E6E) : _records[ri].color;
    final sel = ri >= 0 && ri == _selected;
    final c = b[o];
    final text = hex ? b[o].toRadixString(16).padLeft(2, '0') : (c >= 0x20 && c < 0x7f ? String.fromCharCode(c) : '·');
    return Container(
      width: hex ? _cellW : _asciiW,
      alignment: Alignment.center,
      color: sel ? color.withValues(alpha: 0.30) : null,
      child: Text(text,
          maxLines: 1,
          style: TextStyle(color: sel ? Colors.white : color, fontFamily: 'monospace', fontSize: 12.5, height: 1.35)),
    );
  }

  Widget _recordRow(int i) {
    final r = _records[i];
    final selected = i == _selected;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _select(i),
      child: Container(
        color: selected ? r.color.withValues(alpha: 0.18) : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          children: [
            Container(width: 8, height: 8, margin: const EdgeInsets.only(right: 8), decoration: BoxDecoration(color: r.color, shape: BoxShape.circle)),
            SizedBox(
              width: 54,
              child: Text('@${r.offset.toRadixString(16)}',
                  style: const TextStyle(color: Colors.grey, fontFamily: 'monospace', fontSize: 11)),
            ),
            Expanded(child: Text(r.title, style: const TextStyle(fontSize: 12.5), overflow: TextOverflow.ellipsis)),
            if (r.inlinePreview != null)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(r.inlinePreview!,
                    style: const TextStyle(fontSize: 11.5, color: Colors.grey, fontFamily: 'monospace')),
              ),
            if (r.swatch != null)
              Container(width: 14, height: 14, decoration: BoxDecoration(color: r.swatch, borderRadius: BorderRadius.circular(2), border: Border.all(color: Colors.black26))),
          ],
        ),
      ),
    );
  }

  Widget _detail(_SpanInfo r) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0x33FFFFFF)))),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r.title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('offset 0x${r.offset.toRadixString(16)} · ${r.length} bytes · lead 0x${r.lead.toRadixString(16)}',
              style: const TextStyle(color: Colors.grey, fontSize: 11)),
          const SizedBox(height: 8),
          Text(r.detail, style: const TextStyle(fontSize: 12.5)),
          if (r.display != null) ...[const SizedBox(height: 10), r.display!],
        ],
      ),
    );
  }

  static String _fmt(int n) => n >= 1024 ? '${(n / 1024).toStringAsFixed(1)} KB' : '$n B';
  static bool _looksLikeHeap(List<int> b) => b.length > 8 && (b[4] == 0xc4 || b[4] == 0x10 || b[4] == 0x11 || b[4] == 0x12);
}

const double _kRowHeight = 20;
const double _kRecHeight = 30; // records-list row height (fixed → smooth scroll + scroll-to-index)

/// One parsed record for display.
class _SpanInfo {
  _SpanInfo({
    required this.offset,
    required this.length,
    required this.lead,
    required this.color,
    required this.title,
    required this.detail,
    this.swatch,
    this.display,
    this.inlinePreview,
  });
  final int offset;
  final int length;
  final int lead;
  final Color color;
  final String title;
  final String detail;
  final Color? swatch;
  final Widget? display;

  /// A short value shown inline in the record row (right-aligned) — a "preview"
  /// of the decoded value (e.g. a size/count) so it is legible without selecting
  /// the row, mirroring the colour swatch for colour records.
  final String? inlinePreview;
}

int _u16(List<int> b, int p) => (b[p] << 8) | b[p + 1];
int _u32(List<int> b, int p) => (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];

const _cHeader = Color(0xFFD08BB0);
const _cObject = Color(0xFF9E7BE0);
const _cGroup = Color(0xFF8A8A8A);
const _cRect = Color(0xFF5C9BD6);
const _cString = Color(0xFF6FCF6F);
const _cContainer = Color(0xFF2BB8A8);
const _cAttr = Color(0xFFE8A33A);
const _cRef = Color(0xFF49C4D8);
const _cOther = Color(0xFFB0B0B0);

_SpanInfo _classify(Uint8List b, HeapSpan s, String tag) {
  final o = s.offset, lead = s.lead, len = s.length;
  _SpanInfo make(Color c, String title, String detail, {Color? swatch, Widget? display, String? inlinePreview}) =>
      _SpanInfo(
          offset: o,
          length: len,
          lead: lead,
          color: c,
          title: title,
          detail: detail,
          swatch: swatch,
          display: display,
          inlinePreview: inlinePreview);

  // Object header: 10/11/12 02 fe <kind> fd <oid>
  if ((lead == 0x10 || lead == 0x11 || lead == 0x12) && o + 9 <= b.length && b[o + 2] == 0x02 && b[o + 3] == 0xfe && b[o + 6] == 0xfd) {
    final kind = _u16(b, o + 4), oid = _u16(b, o + 7);
    final cls = HeapObjectClass.fromCode(kind);
    final conf = cls.confidence == ClassConfidence.confirmed ? '' : ' (${cls.confidence.name})';
    return make(_cObject, 'Object · ${cls.label}',
        'Declares object #$oid of class 0x${kind.toRadixString(16)} — ${cls.label}$conf.');
  }
  // Named property token (the decoded hi-nibble 0/1 family) — show its meaning.
  final prop = decodeHeapPropertyToken(b, o);
  if (prop != null) {
    final t = prop.token;
    final conf = t.confidence == AttrConfidence.confirmed ? '' : ' (${t.confidence.name})';
    final hexpair = '${lead.toRadixString(16).padLeft(2, '0')} ${b[o + 1].toRadixString(16).padLeft(2, '0')}';
    final val = prop.value == null ? '' : ' = ${prop.value}';
    return make(_cAttr, '$hexpair · ${t.tokenName}', 'Object property$val$conf.');
  }
  // Group open / close (bracket tree). What MAKES a group: a record
  // <10|11|12|13> <subop> <count> <type-tag> where the byte at +3 is a type tag
  // (fb/fe/fd) — that type tag is the discriminator (a 0x10/0x11 WITHOUT it is a
  // property token, not a group). The matching close is the open's lead − 0x08
  // (0x08←0x10, 0x09←0x11, 0x0a←0x12) carrying the same subop tag — STRUCTURAL,
  // not coincidence: corpus-measured 99.99% on the lead and 99.8% on the tag, with
  // the tree ~99.93% balanced (the rest pop the innermost open positionally).
  String _hx(int v) => '0x${v.toRadixString(16).padLeft(2, '0')}';
  if (lead == 0x10 || lead == 0x11 || lead == 0x12 || lead == 0x13) {
    final hasTypeTag = o + 3 < b.length && (b[o + 3] == 0xfb || b[o + 3] == 0xfe || b[o + 3] == 0xfd);
    if (hasTypeTag) {
      final tag = o + 1 < b.length ? b[o + 1] : -1;
      return make(_cGroup, 'Group open · tag ${_hx(tag)}',
          'Opens a bracket-tree group: ${_hx(lead)} subop count ${_hx(b[o + 3])}(type tag). The '
          'type tag at +3 (fb/fe/fd) is what makes this a GROUP rather than a property token. Its '
          'matching close is lead ${_hx(lead - 0x08)} (open − 0x08) carrying the same tag ${_hx(tag)} '
          '— structural (corpus: 99.99% lead, 99.8% tag).');
    }
    // No type tag at +3 → this is not a group open; fall through to generic classification.
  }
  if (lead == 0x08 || lead == 0x09 || lead == 0x0a || lead == 0x0b) {
    final tag = o + 1 < b.length ? b[o + 1] : -1;
    return make(_cGroup, 'Group close · tag ${_hx(tag)}',
        'Closes the group whose open lead is ${_hx(lead + 0x08)} (open − 0x08) and which carries '
        'the same tag ${_hx(tag)}. The pairing is structural (corpus: 99.99% lead, 99.8% tag); '
        'otherwise the innermost open is popped positionally (~0.07% of closes have no tracked open).');
  }
  // Typed object reference: 14 <subop> 01 fd <oid> (the heap's object graph).
  final ref = decodeHeapRef(b, o);
  if (ref != null) {
    final conf = ref.kind.confidence == AttrConfidence.confirmed ? '' : ' (${ref.kind.confidence.name})';
    return make(_cRef, '${ref.kind.refName} → #${ref.targetOid}',
        'A typed object reference (${ref.kind.refName}$conf) — a link in the object graph, not a wire.');
  }
  // C4 length-prefixed record
  if (lead == kHeapRecordPrefix) {
    final rec = c4FrameAt(b, o, tag);
    if (rec != null) {
      final op = rec.opcode;
      final opc = rec.kind;
      final hexop = 'C4 ${op.toRadixString(16).padLeft(2, '0')}';
      final r = rec.rect; // any rectangle-shape opcode (0x2d/0x1f/0x4a/0x5f/…), not just bounds/size
      if (r != null) {
        return make(_cRect, '$hexop · ${opc.name}',
            'Rectangle (4× s16): top ${r.top}, left ${r.left}, bottom ${r.bottom}, right ${r.right}  (${r.width}×${r.height}).',
            display: _RectPreview(r));
      }
      final text = rec.text ?? rec.descriptionText ?? rec.path;
      if (text != null && text.isNotEmpty) {
        return make(_cString, '$hexop · ${opc.name}', 'String payload:', display: _StringPreview(text));
      }
      final c = opc == HeapOpcode.container24 || opc == HeapOpcode.container44 || opc == HeapOpcode.container64;
      return make(c ? _cContainer : _cOther, '$hexop · ${opc == HeapOpcode.unknown ? 'record' : opc.name}',
          opc.isDecoded ? 'A decoded ${opc.name} record.' : 'A framed ${opc.name} record (${rec.payload.length}-byte payload).');
    }
  }
  // Attribute records (nibble family / 84 colour / C5 f64 / C6 blob)
  final attr = decodeHeapAttr(b, o);
  if (attr != null) {
    final a = attr.attribute;
    final name = a == HeapAttribute.unknown ? 'attribute 0x${attr.id.toRadixString(16)}' : a.attrName;
    final hexlead = lead.toRadixString(16).padLeft(2, '0');
    switch (attr.kind) {
      case HeapAttrKind.color:
        final rgb = attr.rgb ?? 0;
        final swatch = attr.isTransparent ? null : Color(0xFF000000 | rgb);
        return make(_cAttr, '$hexlead · $name',
            attr.isTransparent ? 'Colour: transparent.' : 'Colour #${rgb.toRadixString(16).padLeft(6, '0')}.',
            swatch: swatch, display: swatch == null ? null : _ColorPreview(swatch, rgb));
      case HeapAttrKind.controlParam:
        return make(_cAttr, '$hexlead · $name', 'Numeric-control parameter (f64) = ${attr.asDouble}.');
      case HeapAttrKind.stringBlob:
        return make(_cString, '$hexlead · $name', 'String/blob:', display: _StringPreview(attr.asString ?? ''));
      case HeapAttrKind.rectangle:
        final r = attr.asRect;
        return r == null
            ? make(_cAttr, '$hexlead · $name', 'Rectangle (4× s16).')
            : make(_cRect, '$hexlead · $name',
                'Rectangle (4× s16): top ${r.top}, left ${r.left}, bottom ${r.bottom}, right ${r.right}  (${r.width}×${r.height}).',
                display: _RectPreview(r));
      case HeapAttrKind.container:
        return make(_cContainer, '$hexlead · $name',
            'An opaque length-prefixed container (count-like lead byte ${attr.asInt}; e.g. a front-panel attribute blob).');
      default:
        return make(_cAttr, '$hexlead · $name',
            '${_kindLabel(attr.kind)} = ${attr.asInt} (${attr.width.name}).');
    }
  }
  if (isTypeDescriptorToken(lead)) {
    return make(_cOther, '04 ${b[o + 1].toRadixString(16).padLeft(2, '0')} · 04-token',
        'A bare 04 <subop> token (framed; role undecoded).');
  }
  return make(_cOther, 'lead 0x${lead.toRadixString(16)}', 'Framed record ($len bytes); role not individually decoded.');
}

String _kindLabel(HeapAttrKind k) => switch (k) {
      HeapAttrKind.coordinate => 'Coordinate',
      HeapAttrKind.size => 'Size',
      HeapAttrKind.enumValue => 'Enum value',
      HeapAttrKind.flag => 'Flag',
      HeapAttrKind.ordinal => 'Index',
      HeapAttrKind.numeric => 'Numeric',
      HeapAttrKind.text => 'Text attribute',
      _ => 'Value',
    };

class _RectPreview extends StatelessWidget {
  const _RectPreview(this.r);
  final HeapRect r;
  @override
  Widget build(BuildContext context) {
    final w = r.width.abs().clamp(1, 200).toDouble();
    final h = r.height.abs().clamp(1, 80).toDouble();
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(border: Border.all(color: _cRect), color: _cRect.withValues(alpha: 0.15)),
      alignment: Alignment.center,
      child: Text('${r.width}×${r.height}', style: const TextStyle(fontSize: 10, color: Colors.white70)),
    );
  }
}

class _ColorPreview extends StatelessWidget {
  const _ColorPreview(this.color, this.rgb);
  final Color color;
  final int rgb;
  @override
  Widget build(BuildContext context) => Row(children: [
        Container(width: 40, height: 24, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3), border: Border.all(color: Colors.black26))),
        const SizedBox(width: 8),
        Text('#${rgb.toRadixString(16).padLeft(6, '0')}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
      ]);
}

/// A typed whole-section display for the VI icon. The recognizable icon is a
/// plain 24-bit RGB bitmap embedded (uncompressed) in a LabVIEW "picture" stream
/// — it can appear under several tags (`PICC`/`DSIM`/`FPHb`/…), *not* the
/// `ICON`/`icl4`/`icl8` resource blocks (those hold unrelated metadata). So this
/// keys on the bitmap signature in the bytes, not the tag. Returns null when the
/// section carries no embedded RGB bitmap.
Widget? iconPreview(Uint8List bytes) {
  final icon = extractRgbIcon(bytes);
  if (icon == null) return null;
  return _IconView(
    caption: '${icon.width}×${icon.height} · embedded 24-bit RGB picture',
    child: ViIconImage(icon: icon),
  );
}

/// Renders a decoded [ViIcon] (24-bit RGB bitmap) at [size]×[size], nearest-
/// neighbour scaled so the small icon stays crisp.
class ViIconImage extends StatelessWidget {
  const ViIconImage({super.key, required this.icon, this.size = 160});
  final ViIcon icon;
  final double size;
  @override
  Widget build(BuildContext context) =>
      SizedBox(width: size, height: size, child: CustomPaint(painter: _RgbIconPainter(icon)));
}

class _IconView extends StatelessWidget {
  const _IconView({required this.caption, required this.child});
  final String caption;
  final Widget child;
  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(border: Border.all(color: const Color(0x33FFFFFF))),
            child: child,
          ),
          const SizedBox(height: 8),
          Text(caption, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      );
}

class _RgbIconPainter extends CustomPainter {
  _RgbIconPainter(this.icon);
  final ViIcon icon;
  @override
  void paint(Canvas canvas, Size size) {
    final pw = size.width / icon.width, ph = size.height / icon.height;
    final p = Paint();
    var k = 0;
    for (var y = 0; y < icon.height; y++) {
      for (var x = 0; x < icon.width; x++) {
        p.color = Color.fromARGB(255, icon.rgb[k], icon.rgb[k + 1], icon.rgb[k + 2]);
        k += 3;
        canvas.drawRect(Rect.fromLTWH(x * pw, y * ph, pw + 0.5, ph + 0.5), p);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RgbIconPainter oldDelegate) => false;
}

class _StringPreview extends StatelessWidget {
  const _StringPreview(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(4)),
        child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
      );
}
