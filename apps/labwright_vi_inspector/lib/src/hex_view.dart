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
  late final List<_SpanInfo> _records;
  late final List<int> _byteToRecord; // byte offset -> record index (or -1)
  int _selected = -1;

  @override
  void initState() {
    super.initState();
    final b = widget.section.bytes;
    final isHeap = widget.section.wasCompressed || _looksLikeHeap(b);
    _records = isHeap ? _parseHeap(b, widget.section.tag) : const [];
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
    super.dispose();
  }

  void _select(int i) {
    setState(() => _selected = i);
    if (i >= 0 && i < _records.length) {
      final row = _records[i].offset ~/ 16;
      final target = (row * _kRowHeight).clamp(0.0, _hexScroll.position.maxScrollExtent);
      _hexScroll.animateTo(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
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
                '${_records.isEmpty ? 'raw bytes (no record framing)' : '${_records.length} records'}',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
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
              const VerticalDivider(width: 1),
              // records panel
              Expanded(
                flex: 2,
                child: _records.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'This section is not a record-framed heap, so only the raw '
                            'hex is shown.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey),
                          ),
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: ListView.builder(
                              itemCount: _records.length,
                              itemBuilder: (context, i) => _recordRow(i),
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

  Widget _hexRow(List<int> b, int row) {
    final base = row * 16;
    final hex = <TextSpan>[];
    final ascii = <TextSpan>[];
    for (var i = 0; i < 16; i++) {
      final o = base + i;
      if (o >= b.length) {
        hex.add(const TextSpan(text: '   '));
        continue;
      }
      final ri = _byteToRecord[o];
      final color = ri < 0 ? const Color(0xFF6E6E6E) : _records[ri].color;
      final sel = ri >= 0 && ri == _selected;
      final style = TextStyle(
        color: sel ? Colors.black : color,
        background: sel ? (Paint()..color = color) : null,
        fontFamily: 'monospace',
        fontSize: 12.5,
        height: 1.3,
      );
      hex.add(TextSpan(text: '${b[o].toRadixString(16).padLeft(2, '0')} ', style: style));
      final c = b[o];
      ascii.add(TextSpan(text: c >= 0x20 && c < 0x7f ? String.fromCharCode(c) : '·', style: style));
    }
    return InkWell(
      onTap: () {
        final ri = _byteToRecord[base.clamp(0, b.length - 1)];
        if (ri >= 0) _select(ri);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Text(base.toRadixString(16).padLeft(6, '0'),
                style: const TextStyle(color: Color(0xFF888888), fontFamily: 'monospace', fontSize: 12.5)),
            const SizedBox(width: 12),
            Expanded(child: Text.rich(TextSpan(children: hex), softWrap: false, overflow: TextOverflow.clip)),
            const SizedBox(width: 8),
            Text.rich(TextSpan(children: ascii), softWrap: false, overflow: TextOverflow.clip),
          ],
        ),
      ),
    );
  }

  Widget _recordRow(int i) {
    final r = _records[i];
    final selected = i == _selected;
    return InkWell(
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
  });
  final int offset;
  final int length;
  final int lead;
  final Color color;
  final String title;
  final String detail;
  final Color? swatch;
  final Widget? display;
}

int _u16(List<int> b, int p) => (b[p] << 8) | b[p + 1];

/// Walks the heap body and classifies each record into a [_SpanInfo] using the
/// videcode catalogs — the same decode the rest of the app trusts.
List<_SpanInfo> _parseHeap(List<int> bytes, String tag) {
  final b = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final out = <_SpanInfo>[];
  final HeapWalk walk;
  try {
    walk = walkHeapBody(b);
  } catch (_) {
    return const [];
  }
  for (final s in walk.spans) {
    out.add(_classify(b, s, tag));
  }
  return out;
}

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
  _SpanInfo make(Color c, String title, String detail, {Color? swatch, Widget? display}) =>
      _SpanInfo(offset: o, length: len, lead: lead, color: c, title: title, detail: detail, swatch: swatch, display: display);

  // Object header: 10/11/12 02 fe <kind> fd <oid>
  if ((lead == 0x10 || lead == 0x11 || lead == 0x12) && o + 9 <= b.length && b[o + 2] == 0x02 && b[o + 3] == 0xfe && b[o + 6] == 0xfd) {
    final kind = _u16(b, o + 4), oid = _u16(b, o + 7);
    final cls = HeapObjectClass.fromCode(kind);
    final conf = cls.confidence == ClassConfidence.confirmed ? '' : ' (${cls.confidence.name})';
    return make(_cObject, 'Object · ${cls.label}',
        'Declares object #$oid of class 0x${kind.toRadixString(16)} — ${cls.label}$conf.');
  }
  // Group open / close (bracket tree)
  if (lead == 0x10 || lead == 0x11 || lead == 0x12 || lead == 0x13) {
    return make(_cGroup, 'Group open', 'Opens a typed-list / object group (bracket-tree node).');
  }
  if (lead == 0x08 || lead == 0x09 || lead == 0x0a || lead == 0x0b) {
    return make(_cGroup, 'Group close', 'Closes the innermost open group (popped positionally).');
  }
  // Child-membership reference: 14 19 01 fd <oid>
  if (lead == 0x14 && o + 6 <= b.length && b[o + 1] == 0x19 && b[o + 2] == 0x01 && b[o + 3] == 0xfd) {
    return make(_cRef, 'Child reference → #${_u16(b, o + 4)}', 'A structure/container child-membership reference (not a wire).');
  }
  // C4 length-prefixed record
  if (lead == kHeapRecordPrefix) {
    final rec = c4FrameAt(b, o, tag);
    if (rec != null) {
      final op = rec.opcode;
      final opc = rec.kind;
      final hexop = 'C4 ${op.toRadixString(16).padLeft(2, '0')}';
      final r = rec.bounds ?? rec.sizeRect;
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
      default:
        return make(_cAttr, '$hexlead · $name',
            '${_kindLabel(attr.kind)} = ${attr.asInt} (${attr.width.name}).');
    }
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
