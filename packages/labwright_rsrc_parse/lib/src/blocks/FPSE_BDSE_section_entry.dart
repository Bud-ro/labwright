/// `FPSE` / `BDSE` — front-panel and block-diagram section entries: one u32, sometimes
/// followed by a second.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     value                      u32      role TODO
/// optional, when the record is 8 bytes:
/// 4       4     extra                      u32      role TODO
/// ```
///
/// [ViSectionEntry] is a view over the payload; [decodeSectionEntry] requires 4 or 8 bytes.
library;

import 'dart:typed_data';

import '../block_layout.dart';

const _value = BlockField(0, 4, 'value', 'u32', 'role TODO');
const _extra = BlockField(4, 4, 'extra', 'u32', 'role TODO', optional: 'the record is 8 bytes');

const BlockLayout sectionEntryLayout = [_value, _extra];

/// A view over an `FPSE` or `BDSE` payload.
class ViSectionEntry {
  ViSectionEntry._(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  int get value => _view.getUint32(_value.offset);

  /// Null in the 4-byte form.
  int? get extra => bytes.length >= _extra.end ? _view.getUint32(_extra.offset) : null;

  Uint8List serialize() => bytes;
}

ViSectionEntry decodeSectionEntry(Uint8List bytes) {
  assert(bytes.length == _value.end || bytes.length == _extra.end, 'a section entry is one or two u32 words');
  return ViSectionEntry._(bytes);
}
