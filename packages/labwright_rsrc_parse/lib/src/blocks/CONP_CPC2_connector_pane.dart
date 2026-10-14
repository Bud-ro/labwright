/// `CONP` / `CPC2` - Connector Pane: [ViConnectorPane]
///
/// This block describes the connection points (in/out) a VI has when used as a sub-VI.
///
/// It holds a 1-based index into the `VCTP` top-level types, resolved by
/// [ViConnectorPaneIndex.resolve] to `pool.types[pool.topLevelIndexAt(typeIndex - 1)]`, or in
/// LabVIEW 8.0 to 8.5 a small type pool of its own whose one top-level type is the pane's.
/// What that type is follows the VI's kind, the `LVSR` word [ViSaveRecord.kind]:
///   - [ViKind.standard]: a [ViFunctionType] with one parameter per pane terminal, in pane
///     order; terminal `i` is `pool.types[fn.parameterIndexAt(i)]`. A wired terminal's parameter
///     is the descriptor of the control or indicator behind it, and its [ViType.label] is that
///     control's name; an unwired terminal's is a [ViVoidType] with no label.
///   - [ViKind.global]: a [ViClusterType], presumably of the globals.
///   - [ViKind.polymorphic]: a [ViPolyViType], a 32-bit id distinct per VI whose derivation is
///     not decoded; the instances are named by `CPST`.
///   - [ViKind.control] (one corpus file): a [ViTypedefType] over a cluster.
///
/// TODO: Which terminals are inputs and which outputs, and their required/recommended/optional
/// settings, are not decoded; the function descriptor carries bytes after its parameter list
/// that are the place to look.
///
/// `CPC2` is a second copy in the same forms. In every file that has both, its type has the same
/// parameters and parameter types as `CONP`'s (the labels differ in a few files); the two
/// descriptors differ only in the undecoded bytes after the parameter list, where `CONP`'s
/// first byte is 2 or 3 and `CPC2`'s is 0, and in a polymorphic VI `CPC2` is the function type
/// where `CONP` is the [ViPolyViType]. TODO: figure out what it is for; it is entangled with the other TODO above.
///
/// ```text
/// CONP / CPC2:
/// offset  size  field     type   meaning
/// 0       2     typeIndex u16    1-based index among the VCTP top-level types.
/// ViConnectorPaneInline:
/// offset  size            field           type                  meaning
/// 0       …               pool            ViTypePool            A type pool in the VCTP grammar.
///   +0    4               count           u32                   Number of descriptors.
///   +4    …               descriptors     VctpDescriptor[count]
///   +…    2               topLevelCount   u16                   Number of top-level types, after the
///                                                               descriptors.
///   +…    2·topLevelCount topLevelIndices u16[topLevelCount]    Descriptor index of each top-level type.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';
import 'LVSR_save_record.dart';
import 'VCTP_type_pool.dart';

sealed class ViConnectorPane extends ByteRecord {
  ViConnectorPane._(super.bytes, super.layout);

  factory ViConnectorPane(Uint8List bytes) {
    assert(bytes.isNotEmpty, 'a connector pane block is not empty');
    return bytes.length == ViConnectorPaneIndex.layout.size
        ? ViConnectorPaneIndex(bytes)
        : ViConnectorPaneInline(bytes);
  }

  /// The pane's type: [ViConnectorPaneIndex.resolve]d in [pool], or the embedded one.
  ViType? typeIn(ViTypePool? pool);
}

/// The LabVIEW 8.6 and later form: an index into the VI's type pool.
final class ViConnectorPaneIndex extends ViConnectorPane {
  ViConnectorPaneIndex(Uint8List bytes) : super._(bytes, layout);

  /// 1-based index among the VCTP top-level types.
  int get typeIndex => _typeIndex.read(view);

  /// The pane's type in [pool], or null when the index is outside its top-level list.
  ViType? resolve(ViTypePool pool) {
    final top = typeIndex - 1;
    return top >= 0 && top < pool.topLevelCount ? pool.types[pool.topLevelIndexAt(top)] : null;
  }

  @override
  ViType? typeIn(ViTypePool? pool) => pool == null ? null : resolve(pool);

  static Uint8List encode(int typeIndex) {
    final out = Uint8List(layout.size!);
    _typeIndex.write(ByteData.sublistView(out), typeIndex);
    return out;
  }

  static const _typeIndex = U16(0);

  static const layout = ByteLayout([_typeIndex]);
}

/// The LabVIEW 8.0 to 8.5 form: a type pool whose one top-level type is the pane's.
final class ViConnectorPaneInline extends ViConnectorPane {
  ViConnectorPaneInline(Uint8List bytes) : super._(bytes, layout) {
    pool = ViTypePool(bytes, legacy: true);
    assert(pool.topLevelCount == 1, 'the embedded pool has one top-level type, the pane');
  }

  late final ViTypePool pool;

  ViType get type => pool.types[pool.topLevelIndexAt(0)];

  @override
  ViType typeIn(ViTypePool? _) => type;

  static const _pool = Struct(0, ViTypePool.layout); // A type pool in the VCTP grammar.

  static const layout = ByteLayout([_pool]);
}
