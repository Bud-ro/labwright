import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'image_clipboard.dart';
import 'span_annotations.dart';

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
    final icons = images.icons;
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
        if (images.rasters.isNotEmpty) ...[
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
              for (final EmbeddedRaster(:tag, :raster) in images.rasters)
                _ImageTile(
                  caption:
                      '$tag · ${raster.width}×${raster.height} '
                      '· ${raster.depth}-bit QuickTime raw',
                  onCopy: () => _copy(
                    context,
                    encodeQuickTimeRasterPng(
                      raster.width,
                      raster.height,
                      raster.depth,
                      raster.pixels,
                    ),
                    '$tag image',
                  ),
                  child: Image.memory(
                    encodeQuickTimeRasterPng(
                      raster.width,
                      raster.height,
                      raster.depth,
                      raster.pixels,
                    ),
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
                    encodeLegacyIconPng(icon),
                    '${icon.depth.tag} icon',
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  String? _matchNote(ViLegacyIcon icon, List<ViLegacyIcon> icons) {
    for (final other in icons) {
      if (identical(other, icon)) break;
      if (other.sameGrid(icon)) return other.depth.tag;
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
  const _LegacyIconTile(this.icon, {required this.onCopy, this.sameAs});
  final ViLegacyIcon icon;
  final VoidCallback onCopy;

  final String? sameAs;

  @override
  Widget build(BuildContext context) => _ImageTile(
    onCopy: onCopy,
    caption:
        'VI icon · ${icon.depth.bits}-bit (${icon.depth.tag})'
        '${sameAs != null ? ' · identical grid to $sameAs' : ''}',
    child: CustomPaint(
      size: const Size(128, 128),
      painter: LegacyIconPainter(icon),
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
