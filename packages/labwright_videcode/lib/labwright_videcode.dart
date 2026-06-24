/// Decodes the contents of LabVIEW VI blocks toward a read-only graph/IR.
///
/// The known heap-record opcodes are catalogued in one place: the [HeapOpcode]
/// enhanced enum (see `src/heap.dart`) — the authoritative, documented list of
/// every reverse-engineered opcode and its decoding status.
///
/// Pipeline: [decodeSections] inflate the compressed heap sections → the record
/// [walkHeapBody] (`recordSkip`) frames the heap's opcode stream → [buildDiagram]
/// recovers the block-diagram as a [ViDiagram] (a nesting tree of [ViHeapObject]s
/// with absolute bounds, classified by [ViObjectKind] and typed by [ViTypeKind])
/// → [buildViModel] aggregates everything into the read-only [ViModel] IR.
/// Honest/total throughout; documented limits (e.g. geometry-only signal wires).
library;

export 'src/dart_scaffold.dart';
export 'src/decode.dart';
export 'src/graph.dart';
export 'src/heap.dart';
export 'src/icon.dart';
export 'src/ir.dart';
export 'src/ir_json.dart';
export 'src/meta.dart';
export 'src/type_pool.dart';
