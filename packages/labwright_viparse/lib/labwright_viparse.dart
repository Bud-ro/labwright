/// Clean-room, LabVIEW-less reader for the LabVIEW RSRC (`.vi`) container.
///
/// [parseVi] turns bytes into a [ViSummary] — file type, version, the resource
/// block inventory, and capability flags (front panel, block diagram, connector
/// pane, sub-VI links) that summarize *what a VI is and does*. Recovering the
/// block-diagram logic itself is future work.
library;

export 'src/block_catalog.dart';
export 'src/connector_pane.dart';
export 'src/container.dart';
export 'src/data_type_heap.dart';
export 'src/history.dart';
export 'src/save_record.dart';
export 'src/string_block.dart';
export 'src/type_map.dart';
export 'src/viparse.dart';
