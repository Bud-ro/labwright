import '../corpus_dirs.dart';

import 'aux_blocks.dart';
import 'bd_edit.dart';
import 'const_value_census.dart';
import 'corpus_coverage.dart';
import 'corpus_invariants.dart';
import 'corpus_snapshot.dart';
import 'heap_edit.dart';
import 'heap_tree.dart';
import 'invariants.dart';
import 'ir_json.dart';
import 'model_serialize.dart';
import 'object_color.dart';
import 'pane_terminal_census.dart';
import 'selector_range_census.dart';
import 'signal_type_census.dart';
import 'type_reencode.dart';
import 'wire_branch_oracle.dart';
import 'wire_one_anchored_oracle.dart';
import 'wire_render_style_census.dart';
import 'wire_route_census.dart';
import 'wire_table.dart';
import 'writer_scoreboard.dart';

/// Every corpus law, as the worker applies them to each VI.
const List<CorpusLaw<Object?>> corpusLaws = [
  auxBlocksLaw,
  bdEditLaw,
  constValueCensusLaw,
  corpusCoverageLaw,
  corpusInvariantsLaw,
  corpusSnapshotLaw,
  heapEditLaw,
  heapTreeLaw,
  invariantsLaw,
  irJsonLaw,
  modelSerializeLaw,
  objectColorLaw,
  paneTerminalCensusLaw,
  selectorRangeCensusLaw,
  signalTypeCensusLaw,
  typeReencodeLaw,
  wireBranchOracleLaw,
  wireOneAnchoredOracleLaw,
  wireRenderStyleCensusLaw,
  wireRouteCensusLaw,
  wireTableLaw,
  writerScoreboardLaw,
];
