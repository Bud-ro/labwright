/// Decodes the contents of LabVIEW VI blocks toward a read-only graph/IR.
///
/// The known heap-record opcodes are catalogued in one place: the [HeapOpcode]
/// enhanced enum (see `src/heap.dart`) — the authoritative, documented list of
/// every reverse-engineered opcode and its decoding status.
///
/// Stage 1: [decodeSections] / [inflateSection] take the raw block sections from
/// `labwright_viparse` and inflate the compressed heap sections (`BDEx`, `DTHP`,
/// `vers`, …) into their decompressed bytes — the input to the heap/graph/IR
/// layers that build on top. Heap-tree parsing and graph recovery land next.
library;

export 'src/decode.dart';
export 'src/heap.dart';
export 'src/ir.dart';
export 'src/meta.dart';
