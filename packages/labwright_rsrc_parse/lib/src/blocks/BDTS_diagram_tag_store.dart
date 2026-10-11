/// `BDTS` - Block-Diagram Tag Store: [ViDiagramTagStore]
///
/// The persistent tags of block-diagram objects.
///
/// A tag is a (name, variant) pair that VI Server's `Set Tag` method attaches to any object
/// and `Get Tag` reads back. A tag set with `Is Persistent?` true is saved with the VI,
/// in `VITS` when it belongs to the VI and here when it belongs to a diagram object.
///
/// Names are free strings chosen by whoever sets them, so no closed set exists. The corpus has an example:
/// `SIM Discrete Run` on three simulation nodes.
///
/// 36 files carry the block, naming 75 objects of which 72 have no tags left; 58 ids name a
/// sub-VI call or XNode of `BDHb` and 17 name no object of a fully walked diagram. Entries
/// are framed as in `VITS`.
///
/// ```text
/// offset  size  field    type                meaning
/// 0       4     count    u32                 Number of tagged objects.
/// 4       …     objects  BdtsObject[count]
///   +0    4     oid      u32                 Object id.
///   +4    4     tagCount u32                 Tags that follow.
///   +8    …     tags     VitsEntry[tagCount] The object's tags, as `VITS` entries.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';
import 'VITS_tag_store.dart';

/// One tagged object of a [ViDiagramTagStore].
final class ViDiagramTagObject {
  const ViDiagramTagObject(this.oid, this.tags);

  final int oid;

  final List<ViTagEntry> tags;
}

final class ViDiagramTagStore extends ByteRecord {
  ViDiagramTagStore(Uint8List bytes) : super(bytes, layout) {
    final count = _count.read(view);
    assert(count <= (view.lengthInBytes - _objects.offset) ~/ 8, 'the count fits the payload');
    final objects = <ViDiagramTagObject>[];
    var at = _objects.offset;
    for (var i = 0; i < count; i++) {
      assert(at + BdtsObject.tags.offset <= view.lengthInBytes, 'object $i has an id and a tag count');
      final oid = view.getUint32(at + BdtsObject.oid.offset);
      final tagCount = view.getUint32(at + BdtsObject.tagCount.offset);
      at += BdtsObject.tags.offset;
      assert(tagCount <= (view.lengthInBytes - at) ~/ 8, 'the tag count of object $i fits the payload');
      final tags = <ViTagEntry>[];
      for (var t = 0; t < tagCount; t++) {
        final tag = ViTagEntry.at(view, at, t);
        tags.add(tag);
        at = tag.end;
      }
      objects.add(ViDiagramTagObject(oid, tags));
    }
    assert(at == view.lengthInBytes, 'the objects tile the payload');
    this.objects = objects;
  }

  late final List<ViDiagramTagObject> objects;

  /// Number of tagged objects.
  int get declaredCount => _count.read(view);

  static const _count = U32(0);
  static const _objects = Entries(4, BdtsObject.layout, count: _count);

  static const layout = ByteLayout([_count, _objects]);
}

/// One tagged object.
abstract final class BdtsObject {
  static const oid = U32(0); // Object id.
  static const tagCount = U32(4); // Tags that follow.
  static const tags = Entries(8, VitsEntry.layout, count: tagCount); // The object's tags, as `VITS` entries.

  static const layout = ByteLayout([oid, tagCount, tags]);
}
