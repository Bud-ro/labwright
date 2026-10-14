@Tags(['corpus'])
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../corpus_dirs.dart';
import 'array_to_spreadsheet_string_reconstruction.dart';
import 'boolean_output_values_reconstruction.dart';
import 'crc8_reconstruction.dart';
import 'current_time_stamp_reconstruction.dart';
import 'dataflow.dart';
import 'display_current_time_reconstruction.dart';
import 'execute_vi_remotely_reconstruction.dart';
import 'for_loop_range_reconstruction.dart';
import 'for_loop_start_increment_reconstruction.dart';
import 'loop_invariant_code_motion_reconstruction.dart';
import 'hex_string_display_reconstruction.dart';
import 'mean_of_2d_array_reconstruction.dart';
import 'multiply_rows_reconstruction.dart';
import 'reinitialize_shift_register_reconstruction.dart';
import 'snippet_example_reconstruction.dart';
import 'toggle_text_reconstruction.dart';
import 'string_to_number_reconstruction.dart';
import 'unit_test_add_reconstruction.dart';
import 'while_loop_infinite_reconstruction.dart';
import 'while_loop_reconstruction.dart';

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
  'Creating_a_For_Loop_with_Alternative_Starting_Index_and_Increment_Valu.png': buildForLoopStartIncrement,
  '16605742_hOPNk.png': buildMultiplyRows,
  'Reinitializing_a_Shift_Register_Without_Stopping_the_VI.png': buildReinitializeShiftRegister,
  '32768403_29Tuz.png': buildToggleText,
  'Display_Current_Time_in_LabVIEW_VI.png': buildCurrentTimeStamp,
  '53146805_3DSU7.png': buildArrayToSpreadsheetString,
  'Using_Test_Vector_Indexes_With_the_LabVIEW_Unit_Test_Framework_Toolkit.png': buildUnitTestAdd,
  'Convert_from_a_String_to_a_Numeric_Data_Type_in_LabVIEW.png': buildStringToNumber,
  'Converting_Hexadeicmal_String_from_Normal_Display_to_Hex_Display.png': buildHexStringDisplay,
  'Modifying_LabVIEW_Boolean_Control_Output_Values.png': buildBooleanOutputValues,
  'LabVIEW_While.png': buildWhileLoop,
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
