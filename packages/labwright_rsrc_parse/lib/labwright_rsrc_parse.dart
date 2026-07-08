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

export 'src/blocks/aux_records.dart';
export 'src/blocks/block_catalog.dart';
export 'src/blocks/block_writer.dart';
export 'src/blocks/connector_pane.dart';
export 'src/blocks/data_type_heap.dart';
export 'src/blocks/font_table.dart';
export 'src/blocks/help_path.dart';
export 'src/blocks/history.dart';
export 'src/blocks/icon.dart';
export 'src/blocks/id_table.dart';
export 'src/blocks/legacy_icon.dart';
export 'src/blocks/link_info.dart';
export 'src/blocks/save_record.dart';
export 'src/blocks/small_records.dart';
export 'src/blocks/string_block.dart';
export 'src/blocks/tag_store.dart';
export 'src/blocks/type_map.dart';
export 'src/blocks/type_pool.dart';
export 'src/blocks/version_word.dart';
export 'src/container.dart';
export 'src/decode.dart';
export 'src/graph.dart';
export 'src/heap.dart';
export 'src/ir.dart';
export 'src/ir_json.dart';
export 'src/meta.dart';
export 'src/viparse.dart';
export 'src/writer_scoreboard.dart';
