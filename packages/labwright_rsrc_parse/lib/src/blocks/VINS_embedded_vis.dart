/// `VINS` - VI Instances
///
/// A complete VI file stored in the embedded section namespace, one section per instance,
/// parsed like the VI that embeds it: the instance VIs of the caller's Express VIs, named by a
/// number and owned by a library called `Instance`, with their own diagram, panel and compiled
/// code but never an embedded VI of their own. [readEmbeddedVis] lists them as [ViEmbeddedVi].
///
/// ```text
/// offset  size  field    type   meaning
/// 0       rest  file     u8[]   A whole VI file, parsed like the VI that embeds it.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../viparse.dart';

/// The fields of a `VINS` payload.
abstract final class Vins {
  static const file = Bytes(0); // A whole VI file, parsed like the VI that embeds it.

  static const layout = ByteLayout([file]);
}

ViSummary decodeEmbeddedVi(Uint8List bytes) => parseVi(bytes);

/// One embedded VI: its name when the payload parses, its size, and its bytes.
class ViEmbeddedVi {
  ViEmbeddedVi({required this.name, required this.sizeBytes, this.bytes});

  final String? name;

  final int sizeBytes;

  final Uint8List? bytes;
}

List<ViEmbeddedVi> readEmbeddedVis(Uint8List viBytes) {
  final out = <ViEmbeddedVi>[];
  for (final section in embeddedSectionsOrEmpty(viBytes)) {
    if (section.tag != 'VINS') continue;
    String? name;
    try {
      name = decodeEmbeddedVi(section.bytes).name;
    } on ViFormatException {
      name = null;
    }
    out.add(ViEmbeddedVi(name: name, sizeBytes: section.bytes.length, bytes: section.bytes));
  }
  return out;
}
