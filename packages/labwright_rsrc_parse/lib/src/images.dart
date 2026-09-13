/// The pictures a VI carries, collected from its decoded sections by [viImagesOf]: PNG streams
/// from `MNGI` and `DSIM`, the legacy 32×32 icon from `icl8`/`icl4`/`ICON`, and the QuickTime
/// rasters of `PICT` pictures.
library;

import 'dart:typed_data';

import 'block_tag.dart';
import 'blocks/DSIM_data_space_image.dart';
import 'blocks/MNGI_png_image.dart';
import 'blocks/PICT_picture.dart';
import 'blocks/icl8_icl4_ICON_icon.dart';
import 'decode.dart';

/// A PNG stream and the section it came from.
final class EmbeddedPng {
  const EmbeddedPng({required this.tag, required this.index, required this.stream});

  final String tag;

  final int index;

  final ViPngStream stream;

  int get width => stream.width;

  int get height => stream.height;

  Uint8List get bytes => stream.bytes;
}

/// A QuickTime raster and the section it came from.
final class EmbeddedRaster {
  const EmbeddedRaster({required this.tag, required this.raster});

  final String tag;

  final ViQuickTimeRaster raster;
}

/// Every picture of a VI; [icons] is ordered deepest first, so [bestIcon] is the 8-bit icon
/// when the VI has one.
final class ViImages {
  const ViImages({this.pngs = const [], this.icons = const [], this.rasters = const []});

  final List<EmbeddedPng> pngs;

  final List<ViLegacyIcon> icons;

  final List<EmbeddedRaster> rasters;

  bool get isEmpty => pngs.isEmpty && icons.isEmpty && rasters.isEmpty;

  int get count => pngs.length + icons.length + rasters.length;

  ViLegacyIcon? get bestIcon => icons.isEmpty ? null : icons.first;
}

/// Collects the pictures of [sections]: a legacy icon section whose payload has the depth's
/// exact length, a `PICT` whose picture holds an uncompressed QuickTime raster, an `MNGI`
/// PNG stream, and a `DSIM` that carries a PNG after its raster header.
ViImages viImagesOf(Iterable<DecodedSection> sections) {
  final pngs = <EmbeddedPng>[];
  final icons = <ViLegacyIcon>[];
  final rasters = <EmbeddedRaster>[];
  for (final section in sections) {
    final payload = section.bytes;
    switch (BlockTag.of(section.tag)) {
      case BlockTag.icl8 || BlockTag.icl4 || BlockTag.icon:
        final depth = LegacyIconDepth.forTag(section.tag)!;
        if (payload.length == depth.byteLength) icons.add(decodeLegacyIcon(payload, depth));
      case BlockTag.pict:
        if (decodePict(payload).quickTimeRaster case final raster?) {
          rasters.add(EmbeddedRaster(tag: section.tag, raster: raster));
        }
      case BlockTag.mngi:
        final stream = decodePngStream(payload);
        if (stream.kind == ChunkStreamKind.png) {
          pngs.add(EmbeddedPng(tag: section.tag, index: section.index, stream: stream));
        }
      case BlockTag.dsim:
        if (decodeDataSpaceImage(payload) case ViDataSpacePng(png: final stream)) {
          pngs.add(EmbeddedPng(tag: section.tag, index: section.index, stream: stream));
        }
      default:
        break;
    }
  }
  icons.sort((a, b) => b.depth.bits.compareTo(a.depth.bits));
  return ViImages(pngs: pngs, icons: icons, rasters: rasters);
}
