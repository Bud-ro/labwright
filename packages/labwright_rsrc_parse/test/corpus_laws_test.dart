@Tags(['corpus'])
library;

import 'package:test/test.dart';

import 'corpus/aux_blocks.dart';
import 'corpus/const_value_census.dart';
import 'corpus/corpus_coverage.dart';
import 'corpus/corpus_invariants.dart';
import 'corpus/corpus_snapshot.dart';
import 'corpus/heap_edit.dart';
import 'corpus/invariants.dart';
import 'corpus/ir_json.dart';
import 'corpus/model_serialize.dart';
import 'corpus/object_color.dart';
import 'corpus/pane_terminal_census.dart';
import 'corpus/selector_range_census.dart';
import 'corpus/signal_type_census.dart';
import 'corpus/type_reencode.dart';
import 'corpus/wire_branch_oracle.dart';
import 'corpus/wire_one_anchored_oracle.dart';
import 'corpus/wire_render_style_census.dart';
import 'corpus/wire_route_census.dart';
import 'corpus/writer_scoreboard.dart';
import 'corpus_dirs.dart';

void main() {
  tearDownAll(() async {
    final seconds = await corpusVis.lawSeconds;
    // ignore: avoid_print
    print(
      'corpus law seconds across workers: ${seconds.entries.map((e) => '${e.key} ${e.value.toStringAsFixed(1)}').join(', ')}',
    );
  });
  group('invariants', invariantsTests);
  group('heap_edit', heapEditTests);
  group('corpus_snapshot', corpusSnapshotTests);
  group('ir_json', irJsonTests);
  group('model_serialize', modelSerializeTests);
  group('writer_scoreboard', writerScoreboardTests);
  group('wire_route_census', wireRouteCensusTests);
  group('object_color', objectColorTests);
  group('pane_terminal_census', paneTerminalCensusTests);
  group('signal_type_census', signalTypeCensusTests);
  group('type_reencode', typeReencodeTests);
  group('const_value_census', constValueCensusTests);
  group('corpus_coverage', corpusCoverageTests);
  group('selector_range_census', selectorRangeCensusTests);
  group('aux_blocks', auxBlocksTests);
  group('corpus_invariants', corpusInvariantsTests);
  group('wire_render_style_census', wireRenderStyleCensusTests);
  group('wire_one_anchored_oracle', wireOneAnchoredOracleTests);
  group('wire_branch_oracle', wireBranchOracleTests);
}
