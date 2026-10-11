import 'dart:typed_data';

import 'byte_layout.dart';

/// A decoded block: a view over its payload, laid out as the class's `static const layout`
/// says, that re-emits the payload byte-exactly. A tag whose decoder yields one has a writer.
abstract base class ByteRecord {
  ByteRecord(Uint8List bytes, ByteLayout layout) : view = ByteData.sublistView(bytes) {
    layout.check(view);
  }

  final ByteData view;

  Uint8List serialize() => Uint8List.sublistView(view);
}
