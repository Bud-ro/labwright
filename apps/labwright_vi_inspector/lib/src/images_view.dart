import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'span_annotations.dart';

/// The eight-byte PNG signature `\x89PNG\r\n\x1a\n`. A block payload is scanned
/// for this magic to locate embedded images; `decodePngEnvelope` then validates
/// the IHDR and reports dimensions at each hit.
const List<int> _pngSignature = [
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
];

/// One PNG located inside a block payload: the source block tag/index, the IHDR
/// dimensions, and the exact PNG byte slice ready for `Image.memory`.
class EmbeddedPng {
  const EmbeddedPng({
    required this.tag,
    required this.index,
    required this.width,
    required this.height,
    required this.bytes,
  });

  /// The resource-block tag the PNG was found in (e.g. `MNGI`, `DSIM`).
  final String tag;

  /// The section index within that tag.
  final int index;

  final int width;
  final int height;

  /// The exact PNG bytes, from the magic to the end of the payload.
  final Uint8List bytes;
}

/// One legacy 32×32 icon bitmap (`icl8`/`icl4`/`ICON`) with its source tag.
class EmbeddedLegacyIcon {
  const EmbeddedLegacyIcon({required this.tag, required this.icon});
  final String tag;
  final ViLegacyIcon icon;
}

/// The renderable images recovered from a VI: embedded PNGs plus legacy icon
/// bitmaps. Both lists are empty when the VI carries no images.
class ViImages {
  const ViImages({this.pngs = const [], this.icons = const []});
  final List<EmbeddedPng> pngs;
  final List<EmbeddedLegacyIcon> icons;

  bool get isEmpty => pngs.isEmpty && icons.isEmpty;
  int get count => pngs.length + icons.length;
}

/// Whether the PNG signature begins at [start] in [bytes].
bool _pngSignatureAt(Uint8List bytes, int start) {
  if (start + _pngSignature.length > bytes.length) return false;
  for (var i = 0; i < _pngSignature.length; i++) {
    if (bytes[start + i] != _pngSignature[i]) return false;
  }
  return true;
}

/// Extracts every renderable image from the decoded [sections]. Each payload is
/// scanned for PNG signatures (`MNGI` is a raw PNG; `DSIM` embeds one after a
/// geometry header; scanning all payloads catches any other carrier), and
/// `decodePngEnvelope` validates the IHDR + reports dimensions at each hit.
/// `icl8`/`icl4`/`ICON` payloads are decoded to 32×32 index grids.
ViImages extractViImages(List<DecodedSection> sections) {
  final pngs = <EmbeddedPng>[];
  final icons = <EmbeddedLegacyIcon>[];
  for (final section in sections) {
    final payload = section.bytes;
    final bpp = legacyIconBpp(section.tag);
    if (bpp != null) {
      final icon = decodeLegacyIcon(payload, bpp);
      if (icon != null) {
        icons.add(EmbeddedLegacyIcon(tag: section.tag, icon: icon));
      }
    }
    for (var off = 0; off + _pngSignature.length <= payload.length; off++) {
      if (!_pngSignatureAt(payload, off)) continue;
      final png = decodePngEnvelope(payload, off);
      if (png == null) continue;
      final end = off + png.byteLength;
      if (end > payload.length) continue;
      pngs.add(
        EmbeddedPng(
          tag: section.tag,
          index: section.index,
          width: png.width,
          height: png.height,
          bytes: payload.sublist(off, end),
        ),
      );
    }
  }
  return ViImages(pngs: pngs, icons: icons);
}

/// A gallery of the VI's embedded images: PNGs (`MNGI`/`DSIM` and any other
/// carrier) rendered via `Image.memory`, and legacy 32×32 icon bitmaps
/// (`icl8`/`icl4`/`ICON`) drawn from their pixel grids. Each tile is captioned
/// with its source block tag, dimensions, and byte size; a per-image failure
/// renders a placeholder rather than crashing the tab.
class ViImagesView extends StatelessWidget {
  const ViImagesView({super.key, required this.images});
  final ViImages images;

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No embedded images',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(
          'Embedded images (${images.count})',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        const Text(
          'PNGs carried in the resource blocks, plus the VI\'s legacy 32×32 '
          'icon bitmap when present.',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final png in images.pngs) _PngTile(png),
            for (final icon in images.icons) _LegacyIconTile(icon),
          ],
        ),
      ],
    );
  }
}

/// A framed image tile with a two-line caption (tag · dimensions · size).
class _ImageTile extends StatelessWidget {
  const _ImageTile({required this.caption, required this.child});
  final String caption;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 176,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 176,
          height: 176,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.25),
            border: Border.all(color: const Color(0x33FFFFFF)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: child,
        ),
        const SizedBox(height: 6),
        Text(caption, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    ),
  );
}

class _PngTile extends StatelessWidget {
  const _PngTile(this.png);
  final EmbeddedPng png;

  @override
  Widget build(BuildContext context) => _ImageTile(
    caption:
        '${png.tag} · ${png.width}×${png.height} · ${_fmtSize(png.bytes.length)}',
    child: Image.memory(
      png.bytes,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.none,
      gaplessPlayback: true,
      errorBuilder: (context, error, stack) => _Failed(tag: png.tag),
    ),
  );
}

class _LegacyIconTile extends StatelessWidget {
  const _LegacyIconTile(this.entry);
  final EmbeddedLegacyIcon entry;

  @override
  Widget build(BuildContext context) => _ImageTile(
    caption: '${entry.tag} · 32×32 · ${entry.icon.bpp}bpp icon',
    child: CustomPaint(
      size: const Size(128, 128),
      painter: LegacyIconPainter(entry.icon),
    ),
  );
}

/// The per-image failure placeholder — names the source tag rather than letting
/// a decode/render error take down the tab.
class _Failed extends StatelessWidget {
  const _Failed({required this.tag});
  final String tag;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.broken_image_outlined, color: Colors.grey),
        const SizedBox(height: 6),
        Text(
          '$tag image failed to render',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ],
    ),
  );
}

String _fmtSize(int byteCount) => byteCount >= 1024
    ? '${(byteCount / 1024).toStringAsFixed(1)} KB'
    : '$byteCount B';
