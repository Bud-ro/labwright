library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

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

Color spanColorFor(HeapSpanKind kind) => switch (kind) {
  HeapSpanKind.header => spanColorHeader,
  HeapSpanKind.unframed => spanColorUnframed,
  HeapSpanKind.objectOpen => spanColorObject,
  HeapSpanKind.groupOpen || HeapSpanKind.groupClose => spanColorGroup,
  HeapSpanKind.rectangle => spanColorRect,
  HeapSpanKind.text => spanColorString,
  HeapSpanKind.container => spanColorContainer,
  HeapSpanKind.property ||
  HeapSpanKind.color ||
  HeapSpanKind.attribute => spanColorAttr,
  HeapSpanKind.reference => spanColorRef,
  HeapSpanKind.record ||
  HeapSpanKind.typeToken ||
  HeapSpanKind.other => spanColorOther,
};

SpanInfo spanInfoOf(HeapSpanInfo info) {
  final confidence = info.confidence == null ? '' : ' (${info.confidence})';
  final (detail, swatch, display, inlinePreview) = switch (info.value) {
    HeapRectValue(:final rect) => (
      '${info.detail} top ${rect.top}, left ${rect.left}, bottom ${rect.bottom}, right ${rect.right}  '
          '(${rect.width}×${rect.height}).',
      null,
      RectPreview(rect),
      null,
    ),
    HeapTextValue(:final text) => (
      info.detail,
      null,
      StringPreview(text),
      null,
    ),
    HeapColorValue(:final rgb) => (
      rgb == null
          ? 'Colour: transparent.'
          : 'Colour #${rgb.toRadixString(16).padLeft(6, '0')}.',
      rgb == null ? null : Color(0xFF000000 | rgb),
      rgb == null ? null : ColorPreview(Color(0xFF000000 | rgb), rgb),
      null,
    ),
    HeapDoubleValue(:final value) => (
      '${info.detail} = $value',
      null,
      null,
      null,
    ),
    HeapByteCountValue(:final bytes) => (
      '${info.detail} = $bytes bytes.',
      null,
      null,
      '$bytes B',
    ),
    HeapNumberValue(:final value, :final ascii) => switch (info.kind) {
      HeapSpanKind.objectOpen ||
      HeapSpanKind.reference => ('${info.detail}$confidence', null, null, null),
      _ => (
        '${info.detail} = $value${ascii != null ? ' — ASCII "$ascii"' : ''}$confidence',
        null,
        null,
        null,
      ),
    },
    null => ('${info.detail}$confidence', null, null, null),
  };
  return SpanInfo(
    offset: info.offset,
    length: info.length,
    lead: info.lead,
    color: spanColorFor(info.kind),
    title: info.title,
    detail: detail,
    swatch: swatch,
    display: display,
    inlinePreview: inlinePreview,
  );
}

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

Widget? iconPreview(String tag, Uint8List bytes) {
  if (tag != BlockTag.dsim.tag || bytes.length < 46) return null;
  if (decodeDataSpaceImage(bytes)
      case ViDataSpaceRaster(depth: 24) && final icon) {
    return IconView(
      caption: '${icon.width}×${icon.height} · embedded 24-bit RGB picture',
      child: ViIconImage(icon: icon),
    );
  }
  return null;
}

class ViIconImage extends StatelessWidget {
  const ViIconImage({super.key, required this.icon, this.size = 160});
  final ViDataSpaceRaster icon;
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
  final ViDataSpaceRaster icon;
  @override
  void paint(Canvas canvas, Size size) {
    final pw = size.width / icon.width, ph = size.height / icon.height;
    final paint = Paint();
    final rgb = icon.pixels;
    var k = 0;
    for (var y = 0; y < icon.height; y++) {
      for (var x = 0; x < icon.width; x++) {
        paint.color = Color.fromARGB(255, rgb[k], rgb[k + 1], rgb[k + 2]);
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

class LegacyIconPainter extends CustomPainter {
  LegacyIconPainter(this.icon);
  final ViLegacyIcon icon;

  @override
  void paint(Canvas canvas, Size size) {
    paintLegacyIcon(canvas, icon, Offset.zero & size);
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

void paintLegacyIcon(Canvas canvas, ViLegacyIcon icon, Rect rect) {
  const dim = 32;
  final cw = rect.width / dim;
  final ch = rect.height / dim;
  final paint = Paint();
  for (var y = 0; y < dim; y++) {
    for (var x = 0; x < dim; x++) {
      paint.color = Color(icon.argbAt(x, y));
      canvas.drawRect(
        Rect.fromLTWH(
          rect.left + x * cw,
          rect.top + y * ch,
          cw + 0.5,
          ch + 0.5,
        ),
        paint,
      );
    }
  }
}
