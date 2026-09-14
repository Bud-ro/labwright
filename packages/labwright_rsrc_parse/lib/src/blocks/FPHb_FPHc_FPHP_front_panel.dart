/// `FPHb` / `FPHc` / `FPHP` — the front-panel object heap: a length word and a stream of
/// records. `FPHb` is the C4 record heap that [walkHeapBody] frames and [buildDiagram] turns
/// into a [ViDiagram]; the `c` and `P` encodings are not decoded.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     length                     u32      bytes of records that follow
/// 4       rest  records                    record[] C4 records, see HeapOpcode
/// ```
///
/// The section stores the payload in the zlib envelope that [inflateHeapPayload] opens; the
/// layout is the inflated body.
///
/// [decodeFrontPanel] builds the [ViDiagram] of an `FPHb` payload.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../decode.dart' show inflateHeapPayload;
import '../diagram/diagram.dart';
import '../heap/heap.dart';

const _length = BlockField(0, 4, 'length', 'u32', 'bytes of records that follow');
const _records = BlockField(4, null, 'records', 'record[]', 'C4 records, see HeapOpcode');

const BlockLayout frontPanelHeapLayout = [_length, _records];

ViDiagram decodeFrontPanel(Uint8List bytes) => buildDiagram(bytes, sectionTag: 'FPHb');
