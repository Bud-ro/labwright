/// Decodes the contents of LabVIEW VI blocks toward a read-only graph/IR.
///
/// Stage 1: [decodeSections] / [inflateSection] take the raw block sections from
/// `labwright_viparse` and inflate the compressed heap sections (`BDEx`, `DTHP`,
/// `vers`, …) into their decompressed bytes — the input to the heap/graph/IR
/// layers that build on top. Heap-tree parsing and graph recovery land next.
library;

export 'src/decode.dart';
export 'src/heap.dart';
export 'src/meta.dart';
