/// `FPHb` / `FPHc` / `FPHP` - Front-Panel Heap
///
/// The front-panel object heap: a length word and a stream of records, stored in the zlib
/// envelope that [inflateHeapPayload] opens; the layout is the inflated body. `FPHb` is the C4
/// record heap that [walkHeapBody] frames and [decodeFrontPanel] turns into a [ViDiagram]
/// through [buildDiagram]; the `c` and `P` encodings are not decoded.
///
/// ```text
/// offset  size  field    type   meaning
/// 0       4     length   u32    Bytes of records that follow.
/// 4       rest  records  u8[]   C4 records, see HeapOpcode.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../decode.dart' show inflateHeapPayload;
import '../diagram/diagram.dart';
import '../heap/heap.dart';

/// The fields of an `FPHb` payload.
abstract final class Fphb {
  static const length = U32(0); // Bytes of records that follow.
  static const records = Bytes(4); // C4 records, see HeapOpcode.

  static const layout = ByteLayout([length, records]);
}

ViDiagram decodeFrontPanel(Uint8List bytes) => buildDiagram(bytes, sectionTag: 'FPHb');
