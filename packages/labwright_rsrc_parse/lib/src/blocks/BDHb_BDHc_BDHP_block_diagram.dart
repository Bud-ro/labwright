/// `BDHb` / `BDHc` / `BDHP` - Block-Diagram Heap
///
/// The block-diagram object heap: a length word and a stream of records, stored in the zlib
/// envelope that [inflateHeapPayload] opens; the layout is the inflated body. `BDHb` is the C4
/// record heap that [walkHeapBody] frames and [decodeBlockDiagram] turns into a [BdDiagram]
/// through [buildBlockDiagram]; the `c` and `P` encodings are not decoded.
///
/// ```text
/// offset  size  field    type   meaning
/// 0       4     length   u32    Bytes of records that follow.
/// 4       rest  records  u8[]   C4 records, see HeapOpcode.
/// ```
library;

import 'dart:typed_data';

import '../block_diagram/bd_build.dart';
import '../block_diagram/bd_diagram.dart';
import '../byte_layout.dart';
import '../decode.dart' show inflateHeapPayload;
import '../heap/heap.dart';

/// The fields of a `BDHb` payload.
abstract final class Bdhb {
  static const length = U32(0); // Bytes of records that follow.
  static const records = Bytes(4); // C4 records, see HeapOpcode.

  static const layout = ByteLayout([length, records]);
}

BdDiagram decodeBlockDiagram(Uint8List bytes) => buildBlockDiagram(bytes);
