/// `BDTS` — block-diagram tag store: the tags of each tagged diagram object, each a
/// length-prefixed name and a flattened LabVIEW variant framed as in `VITS`.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     count                      u32      number of tagged objects
/// 4       rest  objects                    entry[count] count tagged objects
///   +0    4     oid                        u32      object id
///   +4    4     tagCount                   u32      tags that follow
///   +8    rest  tags                       entry[tagCount] the object's tags, as VITS entries
/// ```
///
/// [ViDiagramTagStore] is a view over the payload; each [ViDiagramTagObject] names one
/// object and its [ViTagEntry]s; [decodeDiagramTagStore] requires the objects to tile the
/// payload exactly.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';
import 'VITS_tag_store.dart';

const _count = BlockField(0, 4, 'count', 'u32', 'number of tagged objects');
const _oid = BlockField(0, 4, 'oid', 'u32', 'object id');
const _tagCount = BlockField(4, 4, 'tagCount', 'u32', 'tags that follow');
const _tags = BlockField(8, null, 'tags', 'entry[tagCount]', "the object's tags, as VITS entries");
const _objects = BlockField(
  4,
  null,
  'objects',
  'entry[count]',
  'count tagged objects',
  entry: [_oid, _tagCount, _tags],
);

const BlockLayout bdtsLayout = [_count, _objects];

/// One tagged object of a [ViDiagramTagStore].
class ViDiagramTagObject {
  const ViDiagramTagObject._(this.oid, this.tags);

  final int oid;

  final List<ViTagEntry> tags;
}

/// A view over a `BDTS` payload.
class ViDiagramTagStore implements BlockRecord {
  ViDiagramTagStore._(this.bytes, this.objects) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  final List<ViDiagramTagObject> objects;

  int get declaredCount => _view.getUint32(_count.offset);

  @override
  Uint8List serialize() => bytes;
}

ViDiagramTagStore decodeDiagramTagStore(Uint8List bytes) {
  assert(bytes.length >= _objects.offset, 'a diagram tag store starts with its count');
  final view = ByteData.sublistView(bytes);
  final count = view.getUint32(_count.offset);
  assert(count <= (bytes.length - _objects.offset) ~/ 8, 'the count fits the payload');
  final objects = <ViDiagramTagObject>[];
  var at = _objects.offset;
  for (var i = 0; i < count; i++) {
    assert(at + _tags.offset <= bytes.length, 'object $i has an id and a tag count');
    final oid = view.getUint32(at + _oid.offset);
    final tagCount = view.getUint32(at + _tagCount.offset);
    at += _tags.offset;
    assert(tagCount <= (bytes.length - at) ~/ 8, 'the tag count of object $i fits the payload');
    final tags = <ViTagEntry>[];
    for (var t = 0; t < tagCount; t++) {
      final tag = tagEntryAt(bytes, at, t);
      tags.add(tag);
      at = tag.end;
    }
    objects.add(ViDiagramTagObject._(oid, tags));
  }
  assert(at == bytes.length, 'the objects tile the payload');
  return ViDiagramTagStore._(bytes, objects);
}
