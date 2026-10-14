@Tags(['corpus'])
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../corpus_dirs.dart';
import 'crc8_reconstruction.dart';
import 'dataflow.dart';
import 'display_current_time_reconstruction.dart';
import 'execute_vi_remotely_reconstruction.dart';
import 'for_loop_range_reconstruction.dart';
import 'loop_invariant_code_motion_reconstruction.dart';
import 'mean_of_2d_array_reconstruction.dart';
import 'snippet_example_reconstruction.dart';
import 'while_loop_infinite_reconstruction.dart';

/// Each corpus snippet rebuilt from the editing API.
const reconstructions = <String, ViModel Function()>{
  'crc8.png': buildCrc8,
  'While_Loop_-_Infinite_Loop.png': buildWhileLoopInfinite,
  'snippet_example.png': buildSnippetExample,
  'How_Can_I_Calculate_the_Mean_of_a_2D_Array_in_LabVIEW.png': buildMeanOf2dArray,
  '30934016_6biOD.png': buildForLoopRange,
  'Execute_VI_Remotely_by_Using_VI_Server_2.png': buildExecuteViRemotely,
  'Display_Current_Time_in_LabVIEW_VI_2.png': buildDisplayCurrentTime,
  'Loop-Invariant_Code_Motion_-_Before.png': buildLoopInvariantBefore,
  'Loop-Invariant_Code_Motion_-_After.png': buildLoopInvariantAfter,
};

void main() {
  for (final MapEntry(key: png, value: build) in reconstructions.entries) {
    test('$png rebuilt from the API wires the same things together, before and after a file round trip', () {
      final expected = bdDataflow(buildViModel(extractSnippetVi(snippetPng(png).readAsBytesSync())!));
      final built = build();
      expect(bdDataflow(built), expected);
      expect(bdDataflow(buildViModel(built.serialize())), expected);
    });
  }
}
