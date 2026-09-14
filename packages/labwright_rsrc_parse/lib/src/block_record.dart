import 'dart:typed_data';

/// A decoded block that re-emits the payload it was decoded from; a view-backed model returns
/// its backing bytes. A tag whose decoder yields one has a writer.
abstract interface class BlockRecord {
  Uint8List serialize();
}
