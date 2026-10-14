import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'heap_spec.dart';
import 'vi_spec.dart';

/// The text form of the VI [bytes]: its own sections in file order, heaps as their records,
/// the type pool as its descriptors, everything else as bytes.
ViSpec viSpecOf(Uint8List bytes, {String? name}) {
  final sections = decodeSections(bytes);
  final summary = parseVi(bytes);
  return ViSpec(name ?? summary.name ?? 'untitled.vi', [
    for (final section in sections) sectionSpecOf(section),
  ], fileType: summary.fileType);
}

SectionSpec sectionSpecOf(DecodedSection section) {
  final tag = section.tag;
  if ((tag == BlockTag.bdhb.tag || tag == BlockTag.fphb.tag) &&
      section.bytes.length >= 4) {
    return HeapSection(
      tag,
      heapSpecsOf(section.bytes),
      index: section.index,
      compressed: section.wasCompressed,
    );
  }
  if (tag == BlockTag.vctp.tag && typePoolFrames(section.bytes)) {
    final pool = ViTypePool(section.bytes);
    return TypePoolSection(
      [for (final type in pool.types) Uint8List.fromList(type.descriptorBytes)],
      topLevel: pool.topLevelIndices,
      index: section.index,
      compressed: section.wasCompressed,
    );
  }
  return RawSection(
    tag,
    section.bytes,
    index: section.index,
    compressed: section.wasCompressed,
  );
}
