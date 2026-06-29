/// Clean-room, LabVIEW-less reader for LabVIEW `.vi`/`.ctl`/`.llb` files.
///
/// Two layers, one package:
///
/// 1. **Container + blocks** — [parseVi] turns bytes into a [ViSummary]: file
///    type, version, the RSRC resource-block inventory, and capability flags
///    (front panel, block diagram, connector pane, sub-VI links) that summarize
///    *what a VI is and does*.
/// 2. **Heap decode → IR** — [decodeSections] inflate the compressed heap
///    sections, [walkHeapBody] frames the opcode stream, [buildDiagram] recovers
///    the block diagram as a [ViDiagram] (a nesting tree of [ViHeapObject]s
///    classified by [ViObjectKind] / typed by [ViTypeKind]), and [buildViModel]
///    aggregates everything into the read-only [ViModel] IR. The known
///    heap-record opcodes live in one place: the [HeapOpcode] enhanced enum.
///
/// Honest/total throughout; documented limits (e.g. geometry-only signal wires).
/// Recovering full block-diagram *logic* is ongoing work.
library;

// Container + resource blocks (parse layer) and heap decode → graph/IR
// (decode layer), one flat surface.
export 'src/block_catalog.dart';
export 'src/connector_pane.dart';
export 'src/container.dart';
export 'src/dart_scaffold.dart';
export 'src/data_type_heap.dart';
export 'src/decode.dart';
export 'src/font_table.dart';
export 'src/graph.dart';
export 'src/heap.dart';
export 'src/help_path.dart';
export 'src/history.dart';
export 'src/icon.dart';
export 'src/id_table.dart';
export 'src/ir.dart';
export 'src/ir_json.dart';
export 'src/legacy_icon.dart';
export 'src/meta.dart';
export 'src/save_record.dart';
export 'src/string_block.dart';
export 'src/type_map.dart';
export 'src/type_pool.dart';
export 'src/version_word.dart';
export 'src/viparse.dart';
