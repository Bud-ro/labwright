/// Byte-span annotation model for the hex viewer: classifies each walked
/// [HeapSpan] of a section into a colored, titled [SpanInfo] (record frames,
/// attributes, refs, strings, rects), with inline preview widgets for the
/// decoded payloads.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'mac_icon_palette.dart';

/// One parsed record for display.
class SpanInfo {
  SpanInfo({
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

int readU16be(List<int> bytes, int at) => (bytes[at] << 8) | bytes[at + 1];
int readU32be(List<int> bytes, int at) =>
    (bytes[at] << 24) |
    (bytes[at + 1] << 16) |
    (bytes[at + 2] << 8) |
    bytes[at + 3];

const spanColorHeader = Color(0xFFD08BB0);
const spanColorUnframed = Color(0xFFE57373);
const spanColorObject = Color(0xFF9E7BE0);
const spanColorGroup = Color(0xFF8A8A8A);
const spanColorRect = Color(0xFF5C9BD6);
const spanColorString = Color(0xFF6FCF6F);
const spanColorContainer = Color(0xFF2BB8A8);
const spanColorAttr = Color(0xFFE8A33A);
const spanColorRef = Color(0xFF49C4D8);
const spanColorOther = Color(0xFFB0B0B0);

SpanInfo classifySpan(Uint8List bytes, HeapSpan span, String tag) {
  final offset = span.offset, lead = span.lead, len = span.length;
  SpanInfo make(
    Color color,
    String title,
    String detail, {
    Color? swatch,
    Widget? display,
    String? inlinePreview,
  }) => SpanInfo(
    offset: offset,
    length: len,
    lead: lead,
    color: color,
    title: title,
    detail: detail,
    swatch: swatch,
    display: display,
    inlinePreview: inlinePreview,
  );

  if ((lead == 0x10 || lead == 0x11 || lead == 0x12) &&
      offset + 9 <= bytes.length &&
      bytes[offset + 2] == 0x02 &&
      bytes[offset + 3] == 0xfe &&
      bytes[offset + 6] == 0xfd) {
    final kind = readU16be(bytes, offset + 4),
        oid = readU16be(bytes, offset + 7);
    final cls = HeapObjectClass.fromCode(kind);
    final conf = cls.confidence == ClassConfidence.confirmed
        ? ''
        : ' (${cls.confidence.name})';
    return make(
      spanColorObject,
      'Object · ${cls.label}',
      'Declares object #$oid of class 0x${kind.toRadixString(16)} — ${cls.label}$conf.',
    );
  }
  final prop = decodeHeapPropertyToken(bytes, offset);
  if (prop != null) {
    final token = prop.token;
    final conf = token.confidence == AttrConfidence.confirmed
        ? ''
        : ' (${token.confidence.name})';
    final hexpair =
        '${lead.toRadixString(16).padLeft(2, '0')} ${bytes[offset + 1].toRadixString(16).padLeft(2, '0')}';
    final val = prop.value == null ? '' : ' = ${prop.value}';
    return make(
      spanColorAttr,
      '$hexpair · ${token.tokenName}',
      'Object property$val$conf.',
    );
  }
  String _hx(int value) => '0x${value.toRadixString(16).padLeft(2, '0')}';
  if (lead == 0x10 || lead == 0x11 || lead == 0x12 || lead == 0x13) {
    final hasTypeTag =
        offset + 3 < bytes.length &&
        (bytes[offset + 3] == 0xfb ||
            bytes[offset + 3] == 0xfe ||
            bytes[offset + 3] == 0xfd);
    if (hasTypeTag) {
      final tag = offset + 1 < bytes.length ? bytes[offset + 1] : -1;
      return make(
        spanColorGroup,
        'Group open · tag ${_hx(tag)}',
        'Opens a bracket-tree group: ${_hx(lead)} subop count ${_hx(bytes[offset + 3])}(type tag). The '
            'type tag at +3 (fb/fe/fd) is what makes this a GROUP rather than a property token. Its '
            'matching close is lead ${_hx(lead - 0x08)} (open − 0x08) carrying the same tag ${_hx(tag)} '
            '— structural (corpus: 99.99% lead, 99.8% tag).',
      );
    }
  }
  if (lead == 0x08 || lead == 0x09 || lead == 0x0a || lead == 0x0b) {
    final tag = offset + 1 < bytes.length ? bytes[offset + 1] : -1;
    return make(
      spanColorGroup,
      'Group close · tag ${_hx(tag)}',
      'Closes the group whose open lead is ${_hx(lead + 0x08)} (open − 0x08) and which carries '
          'the same tag ${_hx(tag)}. The pairing is structural (corpus: 99.99% lead, 99.8% tag); '
          'otherwise the innermost open is popped positionally (~0.07% of closes have no tracked open).',
    );
  }
  final ref = decodeHeapRef(bytes, offset);
  if (ref != null) {
    final conf = ref.kind.confidence == AttrConfidence.confirmed
        ? ''
        : ' (${ref.kind.confidence.name})';
    return make(
      spanColorRef,
      '${ref.kind.refName} → #${ref.targetOid}',
      'A typed object reference (${ref.kind.refName}$conf) — a link in the object graph, not a wire.',
    );
  }
  if (lead == kHeapRecordPrefix) {
    final rec = c4FrameAt(bytes, offset, tag);
    if (rec != null) {
      final op = rec.opcode;
      final opcode = rec.kind;
      final hexop = 'C4 ${op.toRadixString(16).padLeft(2, '0')}';
      final rect = rec.rect;
      if (rect != null) {
        return make(
          spanColorRect,
          '$hexop · ${opcode.name}',
          'Rectangle (4× s16): top ${rect.top}, left ${rect.left}, bottom ${rect.bottom}, right ${rect.right}  (${rect.width}×${rect.height}).',
          display: RectPreview(rect),
        );
      }
      final text = rec.text ?? rec.descriptionText ?? rec.path;
      if (text != null && text.isNotEmpty) {
        return make(
          spanColorString,
          '$hexop · ${opcode.name}',
          'String payload:',
          display: StringPreview(text),
        );
      }
      final isContainer =
          opcode == HeapOpcode.container24 ||
          opcode == HeapOpcode.container44 ||
          opcode == HeapOpcode.container64;
      return make(
        isContainer ? spanColorContainer : spanColorOther,
        '$hexop · ${opcode == HeapOpcode.unknown ? 'record' : opcode.name}',
        opcode.isDecoded
            ? 'A decoded ${opcode.name} record.'
            : 'A framed ${opcode.name} record (${rec.payload.length}-byte payload).',
      );
    }
  }
  final attr = decodeHeapAttr(bytes, offset);
  if (attr != null) {
    final attribute = attr.attribute;
    final name = attribute == HeapAttribute.unknown
        ? 'attribute 0x${attr.id.toRadixString(16)}'
        : attribute.attrName;
    final hexlead = lead.toRadixString(16).padLeft(2, '0');
    switch (attr.kind) {
      case HeapAttrKind.color:
        final rgb = attr.rgb ?? 0;
        final swatch = attr.isTransparent ? null : Color(0xFF000000 | rgb);
        return make(
          spanColorAttr,
          '$hexlead · $name',
          attr.isTransparent
              ? 'Colour: transparent.'
              : 'Colour #${rgb.toRadixString(16).padLeft(6, '0')}.',
          swatch: swatch,
          display: swatch == null ? null : ColorPreview(swatch, rgb),
        );
      case HeapAttrKind.controlParam:
        return make(
          spanColorAttr,
          '$hexlead · $name',
          'Numeric-control parameter (f64) = ${attr.asDouble}.',
        );
      case HeapAttrKind.stringBlob:
        return make(
          spanColorString,
          '$hexlead · $name',
          'String/blob:',
          display: StringPreview(attr.asString ?? ''),
        );
      case HeapAttrKind.rectangle:
        final rect = attr.asRect;
        return rect == null
            ? make(spanColorAttr, '$hexlead · $name', 'Rectangle (4× s16).')
            : make(
                spanColorRect,
                '$hexlead · $name',
                'Rectangle (4× s16): top ${rect.top}, left ${rect.left}, bottom ${rect.bottom}, right ${rect.right}  (${rect.width}×${rect.height}).',
                display: RectPreview(rect),
              );
      case HeapAttrKind.container:
        return make(
          spanColorContainer,
          '$hexlead · $name',
          'An opaque length-prefixed container (count-like lead byte ${attr.asInt}; e.g. attribute front-panel attribute blob).',
        );
      default:
        final ascii = attr.asciiText;
        return make(
          spanColorAttr,
          '$hexlead · $name',
          '${heapAttrKindLabel(attr.kind)} = ${attr.asInt} (${attr.width.name})'
              '${ascii != null ? ' — ASCII "$ascii"' : ''}.',
        );
    }
  }
  if (isTypeDescriptorToken(lead)) {
    return make(
      spanColorOther,
      '04 ${bytes[offset + 1].toRadixString(16).padLeft(2, '0')} · 04-token',
      'A bare 04 <subop> token (framed; role undecoded).',
    );
  }
  return make(
    spanColorOther,
    'lead 0x${lead.toRadixString(16)}',
    'Framed record ($len bytes); role not individually decoded.',
  );
}

String heapAttrKindLabel(HeapAttrKind k) => switch (k) {
  HeapAttrKind.coordinate => 'Coordinate',
  HeapAttrKind.size => 'Size',
  HeapAttrKind.enumValue => 'Enum value',
  HeapAttrKind.flag => 'Flag',
  HeapAttrKind.ordinal => 'Index',
  HeapAttrKind.numeric => 'Numeric',
  HeapAttrKind.text => 'Text attribute',
  _ => 'Value',
};

class RectPreview extends StatelessWidget {
  const RectPreview(this.r);
  final HeapRect r;
  @override
  Widget build(BuildContext context) {
    final width = r.width.abs().clamp(1, 200).toDouble();
    final height = r.height.abs().clamp(1, 80).toDouble();
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        border: Border.all(color: spanColorRect),
        color: spanColorRect.withValues(alpha: 0.15),
      ),
      alignment: Alignment.center,
      child: Text(
        '${r.width}×${r.height}',
        style: const TextStyle(fontSize: 10, color: Colors.white70),
      ),
    );
  }
}

class ColorPreview extends StatelessWidget {
  const ColorPreview(this.color, this.rgb);
  final Color color;
  final int rgb;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 40,
        height: 24,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: Colors.black26),
        ),
      ),
      const SizedBox(width: 8),
      Text(
        '#${rgb.toRadixString(16).padLeft(6, '0')}',
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    ],
  );
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
  return IconView(
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
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: RgbIconPainter(icon)),
  );
}

class IconView extends StatelessWidget {
  const IconView({required this.caption, required this.child});
  final String caption;
  final Widget child;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0x33FFFFFF)),
        ),
        child: child,
      ),
      const SizedBox(height: 8),
      Text(caption, style: const TextStyle(color: Colors.grey, fontSize: 12)),
    ],
  );
}

class RgbIconPainter extends CustomPainter {
  RgbIconPainter(this.icon);
  final ViIcon icon;
  @override
  void paint(Canvas canvas, Size size) {
    final pw = size.width / icon.width, ph = size.height / icon.height;
    final paint = Paint();
    var k = 0;
    for (var y = 0; y < icon.height; y++) {
      for (var x = 0; x < icon.width; x++) {
        paint.color = Color.fromARGB(
          255,
          icon.rgb[k],
          icon.rgb[k + 1],
          icon.rgb[k + 2],
        );
        k += 3;
        canvas.drawRect(
          Rect.fromLTWH(x * pw, y * ph, pw + 0.5, ph + 0.5),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant RgbIconPainter oldDelegate) => false;
}

class StringPreview extends StatelessWidget {
  const StringPreview(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(4),
    ),
    child: SelectableText(
      text,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
    ),
  );
}

/// Paints a 32×32 [ViLegacyIcon] scaled to fill the given size, mapping each
/// stored pixel index through the standard Macintosh icon palette for the icon's
/// bit depth (see [macIconArgb]): `ICON` (1-bit) → black/white, `icl4` (4-bit) →
/// the 16-color system palette, `icl8` (8-bit) → the 256-color system palette.
/// `ICON`/`icl4`/`icl8` store palette indices, not a mask, so a color icon draws
/// its actual colours. These formats carry no alpha here, so every pixel is drawn
/// opaque (index 0 is white, the classic icon background).
class LegacyIconPainter extends CustomPainter {
  LegacyIconPainter(this.icon);
  final ViLegacyIcon icon;

  @override
  void paint(Canvas canvas, Size size) {
    const dim = 32;
    final cw = size.width / dim;
    final ch = size.height / dim;
    final paint = Paint();
    for (var y = 0; y < dim; y++) {
      for (var x = 0; x < dim; x++) {
        paint.color = Color(macIconArgb(icon.bpp, icon.pixels[y * dim + x]));
        canvas.drawRect(
          Rect.fromLTWH(x * cw, y * ch, cw + 0.5, ch + 0.5),
          paint,
        );
      }
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = const Color(0xFF888888),
    );
  }

  @override
  bool shouldRepaint(LegacyIconPainter old) => !identical(old.icon, icon);
}
