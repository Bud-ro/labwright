/// `CONP` / `CPC2` — the connector pane's type: a two-byte index into the `VCTP` type pool,
/// or an inline type descriptor of any other length.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       2     typeIndex                  u16      1-based index into the VCTP top-level types
/// optional, when the payload is not two bytes:
/// 0       rest  TODO                       type descriptor retained; not decoded
/// ```
///
/// [decodeConnectorPane] requires a non-empty payload and returns a [ViConnectorPaneTypeIndex]
/// for two bytes, otherwise a [ViConnectorPaneInline]. `CPC2` carries the same two forms;
/// whether its index reading is the pool index is not established.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';
import '../viparse.dart' show ViSection;

const _typeIndex = BlockField(0, 2, 'typeIndex', 'u16', '1-based index into the VCTP top-level types');
const _descriptor = BlockField.undecoded(0, null, type: 'type descriptor', optional: 'the payload is not two bytes');

const BlockLayout connectorPaneLayout = [_typeIndex, _descriptor];

/// A view over a `CONP` or `CPC2` payload.
sealed class ViConnectorPane implements BlockRecord {
  const ViConnectorPane._(this.bytes);

  final Uint8List bytes;

  @override
  Uint8List serialize() => bytes;
}

/// The two-byte form: an index into the type pool.
final class ViConnectorPaneTypeIndex extends ViConnectorPane {
  const ViConnectorPaneTypeIndex._(super.bytes) : super._();

  int get typeIndex => ByteData.sublistView(bytes).getUint16(_typeIndex.offset);
}

/// Any other length: an inline type descriptor, retained undecoded.
final class ViConnectorPaneInline extends ViConnectorPane {
  const ViConnectorPaneInline._(super.bytes) : super._();

  Uint8List get descriptor => bytes;
}

ViConnectorPane decodeConnectorPane(Uint8List bytes) {
  assert(bytes.isNotEmpty, 'a connector pane block is not empty');
  return bytes.length == _typeIndex.end ? ViConnectorPaneTypeIndex._(bytes) : ViConnectorPaneInline._(bytes);
}

ViConnectorPane? connectorPaneFromSections(Iterable<ViSection> sections) {
  ViSection? conp, cpc2;
  for (final section in sections) {
    if (section.tag == 'CONP') conp = section;
    if (section.tag == 'CPC2') cpc2 = section;
  }
  final pick = conp ?? cpc2;
  return pick == null ? null : decodeConnectorPane(pick.bytes);
}
