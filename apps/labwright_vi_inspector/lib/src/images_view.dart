import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'image_clipboard.dart';
import 'span_annotations.dart';

class EmbeddedPng {
  const EmbeddedPng({
    required this.tag,
    required this.index,
    required this.width,
    required this.height,
    required this.bytes,
  });

  final String tag;

  final int index;

  final int width;
  final int height;

  final Uint8List bytes;
}

class EmbeddedLegacyIcon {
  const EmbeddedLegacyIcon({required this.tag, required this.icon});
  final String tag;
  final ViLegacyIcon icon;
}

class DecodedMetafileImage {
  const DecodedMetafileImage({
    required this.tag,
    required this.width,
    required this.height,
    required this.depth,
    required this.png,
  });

  final String tag;
  final int width;
  final int height;

  final int depth;

  final Uint8List png;
}

class ViImages {
  const ViImages({
    this.pngs = const [],
    this.icons = const [],
    this.metafiles = const [],
  });
  final List<EmbeddedPng> pngs;
  final List<EmbeddedLegacyIcon> icons;
  final List<DecodedMetafileImage> metafiles;

  bool get isEmpty => pngs.isEmpty && icons.isEmpty && metafiles.isEmpty;
  int get count => pngs.length + icons.length + metafiles.length;
}

ViImages extractViImages(List<DecodedSection> sections) {
  final pngs = <EmbeddedPng>[];
  final icons = <EmbeddedLegacyIcon>[];
  final metafiles = <DecodedMetafileImage>[];
  void png(DecodedSection section, ViPngStream stream) => pngs.add(
    EmbeddedPng(
      tag: section.tag,
      index: section.index,
      width: stream.width,
      height: stream.height,
      bytes: stream.bytes,
    ),
  );
  for (final section in sections) {
    final payload = section.bytes;
    switch (BlockTag.of(section.tag)) {
      case BlockTag.icl8 || BlockTag.icl4 || BlockTag.icon:
        final depth = LegacyIconDepth.forTag(section.tag)!;
        if (payload.length == depth.byteLength) {
          icons.add(
            EmbeddedLegacyIcon(
              tag: section.tag,
              icon: decodeLegacyIcon(payload, depth),
            ),
          );
        }
      case BlockTag.pict:
        final raster = decodePict(payload).quickTimeRaster;
        if (raster != null) {
          metafiles.add(
            DecodedMetafileImage(
              tag: section.tag,
              width: raster.width,
              height: raster.height,
              depth: raster.depth,
              png: encodeQuickTimeRasterPng(
                raster.width,
                raster.height,
                raster.depth,
                raster.pixels,
              ),
            ),
          );
        }
      case BlockTag.mngi:
        final stream = decodePngStream(payload);
        if (stream.kind == ChunkStreamKind.png) png(section, stream);
      case BlockTag.dsim:
        if (decodeDataSpaceImage(payload) case ViDataSpacePng(
          png: final stream,
        )) {
          png(section, stream);
        }
      default:
        break;
    }
  }
  return ViImages(pngs: pngs, icons: icons, metafiles: metafiles);
}

Uint8List encodeQuickTimeRasterPng(
  int width,
  int height,
  int depth,
  Uint8List pixels,
) {
  if (depth != 24 && depth != 32) {
    return img.encodePng(img.Image(width: 1, height: 1));
  }
  final bytesPerPixel = depth ~/ 8;
  final image = img.Image(width: width, height: height);
  final rowBytes = width * bytesPerPixel;
  for (var y = 0; y < height; y++) {
    final row = y * rowBytes;
    for (var x = 0; x < width; x++) {
      final base = row + x * bytesPerPixel + (bytesPerPixel - 3);
      image.setPixelRgb(x, y, pixels[base], pixels[base + 1], pixels[base + 2]);
    }
  }
  return img.encodePng(image);
}

List<EmbeddedLegacyIcon> orderedLegacyIcons(List<EmbeddedLegacyIcon> icons) {
  const order = {'icl8': 0, 'icl4': 1, 'ICON': 2};
  return [...icons]
    ..sort((a, b) => (order[a.tag] ?? 9).compareTo(order[b.tag] ?? 9));
}

ViLegacyIcon? bestLegacyIcon(ViImages images) =>
    images.icons.isEmpty ? null : orderedLegacyIcons(images.icons).first.icon;

Uint8List encodeLegacyIconPng(ViLegacyIcon icon) {
  const dim = ViLegacyIcon.width;
  final image = img.Image(width: dim, height: dim);
  for (var y = 0; y < dim; y++) {
    for (var x = 0; x < dim; x++) {
      final argb = icon.argbAt(x, y);
      image.setPixelRgb(
        x,
        y,
        (argb >> 16) & 0xff,
        (argb >> 8) & 0xff,
        argb & 0xff,
      );
    }
  }
  return img.encodePng(image);
}

class ViImagesView extends StatelessWidget {
  const ViImagesView({
    super.key,
    required this.images,
    this.clipboard = const SystemImageClipboard(),
  });
  final ViImages images;

  final ImageClipboard clipboard;

  Future<void> _copy(
    BuildContext context,
    Uint8List pngBytes,
    String what,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await clipboard.copyPng(pngBytes);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'Copied $what to clipboard' : 'Could not copy $what',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  List<EmbeddedLegacyIcon> get _orderedIcons =>
      orderedLegacyIcons(images.icons);

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
    final icons = _orderedIcons;
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
        if (images.pngs.isNotEmpty)
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final png in images.pngs)
                _PngTile(
                  png,
                  onCopy: () => _copy(context, png.bytes, '${png.tag} image'),
                ),
            ],
          ),
        if (images.metafiles.isNotEmpty) ...[
          if (images.pngs.isNotEmpty) const SizedBox(height: 20),
          const Text(
            'Metafile images',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Pixel rasters decoded out of metafile blocks — a PICT\'s '
            'uncompressed QuickTime image — re-encoded as PNG for display.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final metafile in images.metafiles)
                _ImageTile(
                  caption:
                      '${metafile.tag} · ${metafile.width}×${metafile.height} '
                      '· ${metafile.depth}-bit QuickTime raw',
                  onCopy: () =>
                      _copy(context, metafile.png, '${metafile.tag} image'),
                  child: Image.memory(
                    metafile.png,
                    width: 320,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const SizedBox(
                      width: 120,
                      height: 80,
                      child: Center(child: Icon(Icons.broken_image_outlined)),
                    ),
                  ),
                ),
            ],
          ),
        ],
        if (icons.isNotEmpty) ...[
          if (images.pngs.isNotEmpty) const SizedBox(height: 20),
          const Text('VI icon', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text(
            'The VI\'s 32×32 icon at different colour depths — icl8 (8-bit), '
            'icl4 (4-bit) and ICON (1-bit) are stored independently, not '
            'guaranteed identical. Each pixel index is mapped through the '
            'standard Macintosh icon palette for its depth.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final icon in icons)
                _LegacyIconTile(
                  icon,
                  sameAs: _matchNote(icon, icons),
                  onCopy: () => _copy(
                    context,
                    encodeLegacyIconPng(icon.icon),
                    '${icon.tag} icon',
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  String? _matchNote(EmbeddedLegacyIcon icon, List<EmbeddedLegacyIcon> icons) {
    for (final other in icons) {
      if (identical(other, icon)) break;
      if (other.icon.sameGrid(icon.icon)) return other.tag;
    }
    return null;
  }
}

class _ImageTile extends StatelessWidget {
  const _ImageTile({
    required this.caption,
    required this.child,
    required this.onCopy,
  });
  final String caption;
  final Widget child;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 176,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
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
            Positioned(
              top: 2,
              right: 2,
              child: Material(
                type: MaterialType.transparency,
                child: IconButton(
                  tooltip: 'Copy image to clipboard',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: 0.45),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: onCopy,
                  icon: const Icon(Icons.content_copy),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(caption, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    ),
  );
}

class _PngTile extends StatelessWidget {
  const _PngTile(this.png, {required this.onCopy});
  final EmbeddedPng png;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) => _ImageTile(
    onCopy: onCopy,
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
  const _LegacyIconTile(this.entry, {required this.onCopy, this.sameAs});
  final EmbeddedLegacyIcon entry;
  final VoidCallback onCopy;

  final String? sameAs;

  @override
  Widget build(BuildContext context) => _ImageTile(
    onCopy: onCopy,
    caption:
        'VI icon · ${entry.icon.depth.bits}-bit (${entry.tag})'
        '${sameAs != null ? ' · identical grid to $sameAs' : ''}',
    child: CustomPaint(
      size: const Size(128, 128),
      painter: LegacyIconPainter(entry.icon),
    ),
  );
}

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
