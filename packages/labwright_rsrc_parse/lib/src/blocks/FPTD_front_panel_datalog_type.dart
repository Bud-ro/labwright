/// `FPTD` - Front-Panel Datalog Type: [ViFrontPanelType]
///
/// The type a datalog of this VI's panel would use: a datalog refnum whose record is a
/// two-member cluster, the second member being the cluster of the front panel's data items in
/// the order `CPMp` indexes them ([ViFrontPanelType.panelItemsIn]); the first member's role is
/// TODO. LabVIEW 8.6 and later store the 1-based index of that refnum type among the `VCTP`
/// top-level types, and every one of the 4128 indexed files resolves that way. LabVIEW 8.0 to 8.5 files, which have no `VCTP`, embed a
/// type pool in the legacy inline grammar whose one top-level type is the datalog refnum, as
/// `CONP` does. The one LabVIEW 7.1 file carries a third form, led by its own length, in a
/// descriptor grammar that is not decoded.
///
/// ```text
/// FPTD:
/// offset  size  field     type   meaning
/// 0       2     typeIndex u16    1-based index among the VCTP top-level types of the panel's datalog refnum
///                                type.
/// ViFrontPanelTypeInline:
/// offset  size            field           type                  meaning
/// 0       …               pool            ViTypePool            A type pool in the VCTP grammar.
///   +0    4               count           u32                   Number of descriptors.
///   +4    …               descriptors     VctpDescriptor[count]
///   +…    2               topLevelCount   u16                   Number of top-level types, after the
///                                                               descriptors.
///   +…    2·topLevelCount topLevelIndices u16[topLevelCount]    Descriptor index of each top-level type.
/// ViFrontPanelTypeLabview7:
/// offset  size  field    type   meaning
/// 0       2     length   u16    Equals the payload length.
/// 2       rest  unknown2        Type descriptors in the LabVIEW 7 grammar; not decoded.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';
import 'VCTP_type_pool.dart';

sealed class ViFrontPanelType extends ByteRecord {
  ViFrontPanelType._(super.bytes, super.layout);

  factory ViFrontPanelType(Uint8List bytes) {
    assert(bytes.length >= 2, 'a front-panel type block holds a word');
    if (bytes.length == ViFrontPanelTypeIndex.layout.size) return ViFrontPanelTypeIndex(bytes);
    if (ViFrontPanelTypeLabview7._length.read(ByteData.sublistView(bytes)) == bytes.length) {
      return ViFrontPanelTypeLabview7(bytes);
    }
    return ViFrontPanelTypeInline(bytes);
  }

  /// The datalog refnum type: [ViFrontPanelTypeIndex.resolve]d in [pool], the embedded one, or
  /// null for the LabVIEW 7 form.
  ViType? typeIn(ViTypePool? pool);

  /// The cluster of the panel's data items, in the order `CPMp` indexes them: the second member
  /// of the datalog refnum's record cluster. Null when the chain breaks, which it does in no
  /// corpus file that has the block.
  ViClusterType? panelItemsIn(ViTypePool? pool) {
    final types = this is ViFrontPanelTypeInline ? (this as ViFrontPanelTypeInline).pool.types : pool?.types;
    final refnum = typeIn(pool);
    if (types == null ||
        refnum is! ViRefnumType ||
        refnum.refnumKind != ViRefnumKind.dataLog ||
        refnum.clientCount != 1) {
      return null;
    }
    final record = types[refnum.clientIndexAt(0)];
    if (record is! ViClusterType || record.memberCount != 2) return null;
    return switch (types[record.memberIndexAt(1)]) {
      final ViClusterType items => items,
      _ => null,
    };
  }
}

/// The LabVIEW 8.6 and later form: an index into the VI's type pool.
final class ViFrontPanelTypeIndex extends ViFrontPanelType {
  ViFrontPanelTypeIndex(Uint8List bytes) : super._(bytes, layout);

  /// 1-based index among the VCTP top-level types of the panel's datalog refnum type.
  int get typeIndex => _typeIndex.read(view);

  /// The datalog refnum type in [pool], or null when the index is outside its top-level list.
  ViType? resolve(ViTypePool pool) {
    final top = typeIndex - 1;
    return top >= 0 && top < pool.topLevelCount ? pool.types[pool.topLevelIndexAt(top)] : null;
  }

  @override
  ViType? typeIn(ViTypePool? pool) => pool == null ? null : resolve(pool);

  static const _typeIndex = U16(0);

  static const layout = ByteLayout([_typeIndex]);
}

/// The LabVIEW 8.0 to 8.5 form: a type pool whose one top-level type is the datalog refnum.
final class ViFrontPanelTypeInline extends ViFrontPanelType {
  ViFrontPanelTypeInline(Uint8List bytes) : super._(bytes, layout) {
    pool = ViTypePool(bytes, legacy: true);
    assert(pool.topLevelCount == 1, 'the embedded pool has one top-level type, the datalog refnum');
  }

  late final ViTypePool pool;

  ViType get type => pool.types[pool.topLevelIndexAt(0)];

  @override
  ViType typeIn(ViTypePool? _) => type;

  static const _pool = Struct(0, ViTypePool.layout); // A type pool in the VCTP grammar.

  static const layout = ByteLayout([_pool]);
}

/// The LabVIEW 7 form: its own length, then descriptors in a grammar that is not decoded.
final class ViFrontPanelTypeLabview7 extends ViFrontPanelType {
  ViFrontPanelTypeLabview7(Uint8List bytes) : super._(bytes, layout) {
    assert(_length.read(view) == view.lengthInBytes, 'the length word spans the payload');
  }

  @override
  ViType? typeIn(ViTypePool? _) => null;

  static const _length = U16(0); // Equals the payload length.
  static const _unknown2 = Unknown(2); // Type descriptors in the LabVIEW 7 grammar; not decoded.

  static const layout = ByteLayout([_length, _unknown2]);
}
