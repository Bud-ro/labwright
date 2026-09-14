/// `VINS` — an embedded VI: a complete RSRC file stored as one section in the embedded
/// section namespace, one section per VI.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       rest  file                       rsrc     a whole RSRC file, parsed like the VI that
///                                                   embeds it
/// ```
///
/// [decodeEmbeddedVi] parses the payload as a VI; [readEmbeddedVis] lists every embedded
/// VI of a file as a [ViEmbeddedVi].
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../viparse.dart';

const _file = BlockField(0, null, 'file', 'rsrc', 'a whole RSRC file, parsed like the VI that embeds it');

const BlockLayout vinsLayout = [_file];

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
