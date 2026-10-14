import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'heap_spec.dart';
import 'section_specs.dart';
import 'vi_spec.dart';

/// The text form of the VI [bytes]: its own sections in file order, heaps as their records,
/// the type pool as its descriptors, the sections a block view decodes as their fields,
/// everything else as bytes.
ViSpec viSpecOf(Uint8List bytes, {String? name}) {
  final sections = decodeSections(bytes);
  final summary = parseVi(bytes);
  final vers = sections.where((s) => s.tag == BlockTag.vers.tag).firstOrNull;
  final version = vers == null ? null : ViVersBlock(vers.bytes).versionWord;
  return ViSpec(name ?? summary.name ?? 'untitled.vi', [
    for (final section in sections) sectionSpecOf(section, version: version),
  ], fileType: summary.fileType);
}

/// [section] as the text form holds it; a typed section only when its constructor builds the
/// section's own bytes. [version] is the saving version `vers` gives.
SectionSpec sectionSpecOf(DecodedSection section, {ViVersionWord? version}) {
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
  final typed = typedSectionOf(section, version: version);
  if (typed != null && _same(typed.payload, section.bytes)) return typed;
  return RawSection(
    tag,
    section.bytes,
    index: section.index,
    compressed: section.wasCompressed,
  );
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
