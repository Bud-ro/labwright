/// `BDHb` / `BDHc` / `BDHP` — the block-diagram object heap: a length word and a stream of
/// records. `BDHb` is the C4 record heap that [walkHeapBody] frames and [buildDiagram] turns
/// into a [ViDiagram]; the `c` and `P` encodings are not decoded.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     length                     u32      bytes of records that follow
/// 4       rest  records                    record[] C4 records, see HeapOpcode
/// ```
///
/// [decodeBlockDiagram] builds the [ViDiagram] of a `BDHb` payload.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../diagram/diagram.dart';
import '../heap/heap.dart';

const _length = BlockField(0, 4, 'length', 'u32', 'bytes of records that follow');
const _records = BlockField(4, null, 'records', 'record[]', 'C4 records, see HeapOpcode');

const BlockLayout blockDiagramHeapLayout = [_length, _records];

ViDiagram decodeBlockDiagram(Uint8List bytes) => buildDiagram(bytes);
