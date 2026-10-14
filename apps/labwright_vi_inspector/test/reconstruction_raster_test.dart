@Tags(['corpus'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';

import '../../../packages/labwright_rsrc_parse/test/reconstruction/array_to_spreadsheet_string_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/crc8_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/current_time_stamp_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/boolean_output_values_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/display_current_time_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/execute_vi_remotely_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/for_loop_range_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/for_loop_start_increment_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/hex_string_display_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/mean_of_2d_array_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/multiply_rows_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/reinitialize_shift_register_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/snippet_example_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/unit_test_add_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/string_to_number_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/toggle_text_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/while_loop_infinite_reconstruction.dart';
import '../../../packages/labwright_rsrc_parse/test/reconstruction/while_loop_reconstruction.dart';
import 'util.dart';

/// The reconstructions that draw as their snippet draws, by snippet file name.
final Map<String, ViModel Function()> layoutReconstructions = {
  'While_Loop_-_Infinite_Loop.png': buildWhileLoopInfinite,
  'snippet_example.png': buildSnippetExample,
  '30934016_6biOD.png': buildForLoopRange,
  'Execute_VI_Remotely_by_Using_VI_Server_2.png': buildExecuteViRemotely,
  'Display_Current_Time_in_LabVIEW_VI_2.png': buildDisplayCurrentTime,
  'How_Can_I_Calculate_the_Mean_of_a_2D_Array_in_LabVIEW.png':
      buildMeanOf2dArray,
  'Display_Current_Time_in_LabVIEW_VI.png': buildCurrentTimeStamp,
  '53146805_3DSU7.png': buildArrayToSpreadsheetString,
  'Using_Test_Vector_Indexes_With_the_LabVIEW_Unit_Test_Framework_Toolkit.png':
      buildUnitTestAdd,
  'crc8.png': buildCrc8,
  'Convert_from_a_String_to_a_Numeric_Data_Type_in_LabVIEW.png':
      buildStringToNumber,
  'Converting_Hexadeicmal_String_from_Normal_Display_to_Hex_Display.png':
      buildHexStringDisplay,
  'Modifying_LabVIEW_Boolean_Control_Output_Values.png':
      buildBooleanOutputValues,
  'LabVIEW_While.png': buildWhileLoop,
  'Reinitializing_a_Shift_Register_Without_Stopping_the_VI.png':
      buildReinitializeShiftRegister,
  '32768403_29Tuz.png': buildToggleText,
  'Creating_a_For_Loop_with_Alternative_Starting_Index_and_Increment_Valu.png':
      buildForLoopStartIncrement,
  '16605742_hOPNk.png': buildMultiplyRows,
};

Future<ui.Image> _render(ViModel model) async => (await rasteriseBlockDiagram(
  bestBlockDiagram(model)!,
  scale: 1.0,
  margin: 2,
))!.image;

Future<Uint8List> _rgba(ui.Image image) async =>
    (await image.toByteData())!.buffer.asUint8List();

void main() {
  for (final MapEntry(key: png, value: build)
      in layoutReconstructions.entries) {
    testWidgets('$png rebuilt from the API draws the same pixels', (
      tester,
    ) async {
      await loadRealTextFont();
      await tester.runAsync(() async {
        final original = await _render(
          buildViModel(extractSnippetVi(snippetPng(png).readAsBytesSync())!),
        );
        final built = await _render(build());
        final out = Directory(
          '${Platform.environment['TMPDIR'] ?? '/tmp'}/reconstruction-raster',
        )..createSync(recursive: true);
        final stem = png.replaceAll('.png', '');
        File(
          '${out.path}/$stem-original.png',
        ).writeAsBytesSync(await imageToPng(original));
        File(
          '${out.path}/$stem-built.png',
        ).writeAsBytesSync(await imageToPng(built));
        expect(
          (built.width, built.height),
          (original.width, original.height),
          reason: 'raster size',
        );
        final a = await _rgba(original), b = await _rgba(built);
        final comparison = compareRgba(
          a,
          b,
          original.width,
          original.height,
          threshold: 0,
        );
        final diff = await decodeImageFromPixels(
          comparison.diff,
          original.width,
          original.height,
        );
        File(
          '${out.path}/$stem-diff.png',
        ).writeAsBytesSync(await imageToPng(diff));
        expect(
          comparison.diffFraction,
          0,
          reason: 'pixels differing out of ${a.length ~/ 4}',
        );
      });
    });
  }
}

Future<ui.Image> decodeImageFromPixels(
  Uint8List rgba,
  int width,
  int height,
) async {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}
