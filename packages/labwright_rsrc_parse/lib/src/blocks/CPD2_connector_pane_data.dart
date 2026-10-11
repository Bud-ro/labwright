/// `CPD2` - Connector Pane Data: [ViConnectorPaneData]
///
/// One u16 that repeats `CPC2`'s type index in every corpus file that carries it (53, most saved
/// by LabVIEW 2012); why it exists is not decoded.
///
/// ```text
/// offset  size  field     type   meaning
/// 0       2     typeIndex u16    1-based index among the VCTP top-level types, the same as CPC2's.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViConnectorPaneData extends ByteRecord {
  ViConnectorPaneData(Uint8List bytes) : super(bytes, layout);

  /// 1-based index among the VCTP top-level types, the same as CPC2's.
  int get typeIndex => _typeIndex.read(view);

  static const _typeIndex = U16(0);

  static const layout = ByteLayout([_typeIndex]);
}
