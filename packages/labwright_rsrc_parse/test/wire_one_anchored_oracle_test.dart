@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'wire_style_oracle.dart';

Map<String, int> _census(Uint8List png, String path) {
  final c = <String, int>{};
  void bump(String k, [int n = 1]) => c[k] = (c[k] ?? 0) + n;
  final Raster raster;
  try {
    raster = decodePngRaster(png);
  } catch (_) {
    return c;
  }
  final vi = extractSnippetVi(png);
  if (vi == null) return c;
  final interior = snippetDiagramInterior(raster.width, raster.height);
  final model = buildViModelFromDecoded(decodeSections(vi));
  if (model.blockDiagrams.isEmpty) return c;
  var bi = 0;
  for (var i = 1; i < model.blockDiagrams.length; i++) {
    if (model.blockDiagrams[i].objects.length > model.blockDiagrams[bi].objects.length) bi = i;
  }
  final bd = model.blockDiagrams[bi];
  final reg = registerDiagram(bd, raster, interior);
  if (reg.max < 150 || reg.score / reg.max < (reg.leafMode ? 0.60 : 0.75)) {
    bump('oa_reg_failed');
    return c;
  }

  bool onInk(ViPoint p) {
    final px = p.x - reg.dx + interior.left, py = p.y - reg.dy + interior.top;
    for (var oy = -1; oy <= 1; oy++) {
      for (var ox = -1; ox <= 1; ox++) {
        final x = px + ox, y = py + oy;
        if (x < interior.left || x >= interior.right || y < interior.top || y >= interior.bottom) continue;
        final o = (y * raster.width + x) * 4;
        if (raster.rgba[o] <= 210 || raster.rgba[o + 1] <= 210 || raster.rgba[o + 2] <= 210) return true;
      }
    }
    return false;
  }

  (int, int) measure(List<List<ViPoint>> polys) {
    var px = 0, ink = 0;
    for (final poly in polys) {
      for (var s = 0; s + 1 < poly.length; s++) {
        final a = poly[s], b = poly[s + 1];
        final steps = (a.x - b.x).abs() + (a.y - b.y).abs();
        for (var t = 0; t <= steps; t++) {
          final den = steps == 0 ? 1 : steps;
          final p = (x: a.x + (b.x - a.x) * t ~/ den, y: a.y + (b.y - a.y) * t ~/ den);
          px++;
          if (onInk(p)) ink++;
        }
      }
    }
    return (px, ink);
  }

  var ctrlPx = 0, ctrlInk = 0;
  for (final w in bd.wires) {
    if (w.endpointOids.length != 2 || w.routePointsFidelity != WireRouteFidelity.closed) continue;
    if (bd.wireAttachPoint(w.endpointOids[0]) == null || bd.wireAttachPoint(w.endpointOids[1]) == null) continue;
    if (!objectVisibleInRender(bd, w.signalOid)) continue;
    final (px, ink) = measure([w.routePoints!]);
    ctrlPx += px;
    ctrlInk += ink;
  }
  const kMinControlPx = 40;
  if (ctrlPx >= kMinControlPx && ctrlInk * 100 < 90 * ctrlPx) {
    bump('oa_reg_control_skip');
    return c;
  }
  bump('oa_reg_ok');
  bump('oa2_closed_runpx', ctrlPx);
  bump('oa2_closed_runink', ctrlInk);

  void record(String tier, List<List<ViPoint>> polys) {
    final (px, ink) = measure(polys);
    bump('${tier}_runpx', px);
    bump('${tier}_runink', ink);
    bump('${tier}_wires');
    final q = px == 0 ? 1.0 : ink / px;
    bump(
      '${tier}_q${q >= 0.95
          ? '95'
          : q >= 0.8
          ? '80'
          : q >= 0.5
          ? '50'
          : 'lo'}',
    );
  }

  for (final w in bd.wires) {
    if (!objectVisibleInRender(bd, w.signalOid)) continue;

    if (w.endpointOids.length == 2 && w.route != null) {
      final a0 = bd.wireAttachPoint(w.endpointOids[0]);
      final a1 = bd.wireAttachPoint(w.endpointOids[1]);
      final oneAnchored = (a0 == null) ^ (a1 == null);
      if (w.routePointsFidelity == WireRouteFidelity.closed && (a0 == null || a1 == null)) {
        record('oa2_dcoclosed', [w.routePoints!]);
        continue;
      }
      if (w.routePointsFidelity == WireRouteFidelity.walked) {
        if (a0 == null && a1 == null) {
          record('oa2_dcorow', [w.routePoints!]);
          continue;
        }
        if (w.routeHeadSlack != null) {
          record('oa2_slack', [w.routePoints!]);
          bump('oa2_slack_anchor');
          if (onInk(w.routePoints!.last)) bump('oa2_slack_anchor_ink');
          final head = bd.byId[w.endpointOids[0]];
          if (head != null && head.kind == 0x15 && head.parentOid != null) {
            bump('oa2_slack_head_dco');
          }
          continue;
        }
        record('oa2_ship', [w.routePoints!]);
        if (w.routeClosingStep != null) record('oa2_into', [w.routePoints!]);
        final terminus = a0 != null ? w.routePoints!.last : w.routePoints!.first;
        bump('oa2_ship_term');
        if (onInk(terminus)) bump('oa2_ship_term_ink');
      } else if (w.routePoints == null && oneAnchored) {
        final ai = a0 != null ? 0 : 1;
        final farBox = w.endpointAnchors[1 - ai];
        if (farBox == null) continue;
        final poly = walkOneAnchoredRoute(w.route!, anchor: (a0 ?? a1)!, anchoredIndex: ai, farBox: farBox);
        if (poly != null) record('oa2_held', [poly.points]);
      }
    } else if (w.endpointOids.length >= 3 && w.branchRoute != null) {
      if (w.routeTreeFidelity == WireRouteFidelity.walked) {
        final tree = w.routeTree!;
        record('oab_ship', tree.polylines);
        for (final leaf in tree.leaves) {
          bump('oab_ship_leaf');
          if (onInk(leaf)) bump('oab_ship_leaf_ink');
        }
      } else if (w.routeTree == null) {
        final origin = bd.wireAttachPoint(w.endpointOids[0]);
        if (origin != null) record('oab_held', walkWireBranchRoute(w.branchRoute!, origin).polylines);
      }
    }
  }
  return c;
}

int _pct(Map<String, int> c, String tier) {
  final px = c['${tier}_runpx'] ?? 0;
  if (px == 0) return -1;
  return (100 * (c['${tier}_runink'] ?? 0) / px).round();
}

const kShipGrossMisses = <String, int>{
  '18726000_BBgBQ.png': 1,
  '23824206_lZCON.png': 1,
  '44061689_Pkwe4.png': 1,
  '48456600_4eyDr.png': 2,
  '48623072_LYYv9.png': 2,
  '53800813_GEVVE.png': 2,
  '55137255_O8ltm.png': 3,
  '57642244_cm7Ca.png': 5,
  'Accessing_Shared_Variables_From_a_LabVIEW_Web_Service_2.png': 1,
  'Index_Array_-_Get_First_Element.png': 1,
  'Index_Array_-_Get_First_Few_Elements.png': 1,
  'Index_Array_-_Get_Specific_Elements.png': 1,
  'Initialize_Array_-_Create_Array_From_Element.png': 1,
  'Performing_Analog_Output_Software_timed_Waveform_Generation_in_LabVIEW.png': 1,
  'Threshold_1D_Array_-_Threshold_Out_Of_Range.png': 1,
  'for-loop_autoindex.png': 6,
};

const kSlackAnchorsOffInk = <String, int>{
  '69539137_5Mi4k.png': 4,
  'Get_Multiple_Inspection_Images_with_The_Vision_Builder_for_Automated_I.png': 1,
  'On_Demand_Pulse_Generation_Without_Recreating_DAQmx_Task.png': 1,
  'Replace_Subset_of_2D_Array_with_Smaller_2D_Array_in_LabVIEW.png': 1,
  'Run_VBAI_Inspection_in_LabVIEW.png': 1,
  'for-loop_autoindex.png': 1,
};

const kSlackHeadsNotDco = <String, int>{};

const kShipInkPct = <String, int>{
  '18726000_BBgBQ.png': 88,
  '23824206_lZCON.png': 0,
  '34140795_eK3nc.png': 87,
  '37811753_DVcve.png': 77,
  '38607813_VljVk.png': 90,
  '44061689_Pkwe4.png': 78,
  '48375096_LaIbB.png': 83,
  '48456600_4eyDr.png': 26,
  '48623072_LYYv9.png': 0,
  '53800813_GEVVE.png': 0,
  '55137255_O8ltm.png': 69,
  '56468164_sOjUK.png': 90,
  '57642244_cm7Ca.png': 40,
  'Accessing_Shared_Variables_From_a_LabVIEW_Web_Service_2.png': 7,
  'Index_Array_-_Get_First_Element.png': 42,
  'Index_Array_-_Get_First_Few_Elements.png': 42,
  'Index_Array_-_Get_Specific_Elements.png': 42,
  'Initialize_Array_-_Create_Array_From_Element.png': 33,
  'Threshold_1D_Array_-_Threshold_Out_Of_Range.png': 48,
  'for-loop_autoindex.png': 22,
  'hse_loop_timer_-_stop.png': 91,
};

const kShipBelowClosedPct = <String, int>{
  '18726000_BBgBQ.png': 12,
  '23824206_lZCON.png': 67,
  '33003667_WQUOg.png': 4,
  '34140795_eK3nc.png': 12,
  '44061689_Pkwe4.png': 21,
  '48624280_wTQyY.png': 4,
  '56468164_sOjUK.png': 7,
  '57642244_cm7Ca.png': 56,
};

const kHeldNotWorseThanShip = <String>{
  '16347228_ATJUN.png',
  '18726000_BBgBQ.png',
  '26103724_Lk2H5.png',
  '2_packet_convert_cluster.png',
  '31949337_Nurez.png',
  '36790337_6otPV.png',
  '42658007_WxW2z.png',
  '43292939_cDHQF.png',
  '43309546_cGFGy.png',
  '48624280_wTQyY.png',
  '50799360_sx9Q3.png',
  '52175083_RKkve.png',
  '53538259_DJf0i.png',
  '53538259_j1cS2.png',
  '53541044_9rOae.png',
  '55101960_vZSSg.png',
  '56386018_EToD7.png',
  '62643358_CqHhu.png',
  '63563672_qPrsL.png',
  '69539137_5Mi4k.png',
  '71321004_rDU7K.png',
  '72352838_UT2JQ.png',
  '72363146_RmwtK.png',
  '72499494_WQO8a.png',
  '72501225_0EfiP.png',
  '74521931_DWPW0.png',
  '9864653_o6HLd.png',
  'ClassChildren.png',
  'Convert_Date_Format_in_Excel_with_LabVIEW_Report_Generation_Toolkit_2.png',
  'Creating_an_Intensity_Graph_from_a_Single_Waveform.png',
  'Different_Methods_for_Representing_Data_on_an_XY_Graph_3.png',
  'Different_Methods_for_Representing_Data_on_an_XY_Graph_4.png',
  'Dragging_Individual_Curves_Up_and_Down_in_LabVIEW_Waveform_Graph.png',
  'Error_2000000006_With_Joystick_in_LabVIEW.png',
  'Error_417_Expectation_Failed_When_Using_HTTP_Methods_in_LabVIEW_2.png',
  'GenerateTree.png',
  'How_Can_I_Read_a_Very_Large_CSV_File_in_LabVIEW.png',
  'LabVIEW_7.png',
  'LabVIEW_8.png',
  'LabVIEW_Call_Library_Function_Node_Not_Unloading_a_DLL_After_VI_Execut.png',
  'MD5.png',
  'Programmatically_Centering_a_Word_Document_Table_in_LabVIEW_2.png',
  'Replace_NI_DAQmx_Physical_Channel_Drop_Down_Menu_With_Check_Boxes_for.png',
  'Writing_Values_to_VeriStand_Channels_Without_Data_Loss_Using_VeriStand.png',
};

const kIntoGrossMisses = <String, int>{
  '55137255_O8ltm.png': 1,
};

const kIntoInkPct = <String, int>{
  '33003667_WQUOg.png': 57,
  '55137255_O8ltm.png': 34,
  '70680356_I1bC9.png': 86,
  'Editing_the_Header_of_Multicolumn_Listbox_Control_While_VI_is_Running.png': 77,
  'Hardware_Time_Based_Control_of_CAN_Frame_Transmit_Time_with_NI_XNET.png': 66,
};

const kBranchInkPct = <String, int>{
  '1_simple_tcp_client.png': 49,
  '24373370_ux1oO.png': 52,
  '36857051_9pIwb.png': 44,
  '45220097_n46Kf.png': 38,
  '47748166_UCZjH.png': 60,
  '48623072_LYYv9.png': 22,
  '57642244_cm7Ca.png': 30,
  '69380394_fBJCD.png': 78,
  '8850929_jswjp.png': 1,
  'Adding_Custom_Glyphs_to_List_Controls_in_LabVIEW_3.png': 74,
  'Display_Current_Time_in_LabVIEW_VI_2.png': 40,
  'Error_1_An_Input_Parameter_Is_Invalid_in_LabVIEW.png': 19,
  'GetCurrentDirectory.png': 81,
  'Obtaining_Enum_Elements_in_String_Format.png': 50,
  'Prevent_LabVIEW_Executable_to_Run_by_Different_Windows_Users_2.png': 79,
  'Write_to_a_Password_Protected_Excel_File_so_That_the_Password_Prompt_I.png': 69,
  'for-loop_autoindex.png': 22,
};

const kBranchGrossMisses = <String, int>{
  '1_simple_tcp_client.png': 1,
  '36857051_9pIwb.png': 2,
  '45220097_n46Kf.png': 1,
  '48623072_LYYv9.png': 2,
  '57642244_cm7Ca.png': 2,
  '8850929_jswjp.png': 1,
  'Display_Current_Time_in_LabVIEW_VI_2.png': 1,
  'Error_1_An_Input_Parameter_Is_Invalid_in_LabVIEW.png': 2,
  'Obtaining_Enum_Elements_in_String_Format.png': 1,
  'Write_to_a_Password_Protected_Excel_File_so_That_the_Password_Prompt_I.png': 1,
  'for-loop_autoindex.png': 1,
};

void main() {
  final pngs = listSnippetPngs(corpusViDir);
  late final Map<String, Map<String, int>> byFile;
  late final Map<String, int> C;
  setUpAll(() async {
    final res = await Future.wait([for (final f in pngs) Future(() => _census(f.readAsBytesSync(), f.path))]);
    byFile = {for (var i = 0; i < pngs.length; i++) pngs[i].uri.pathSegments.last: res[i]};
    C = {};
    for (final m in res) {
      m.forEach((k, v) => C[k] = (C[k] ?? 0) + v);
    }
  });

  Map<String, int> perFile(int Function(Map<String, int> c) value) => {
    for (final e in byFile.entries)
      if (value(e.value) != 0) e.key: value(e.value),
  };

  Map<String, int> belowPct(String tier, Map<String, int> pins, int floor) => {
    for (final e in byFile.entries)
      if ((e.value['${tier}_runpx'] ?? 0) > 0 && _pct(e.value, tier) < (pins[e.key] ?? floor))
        e.key: _pct(e.value, tier),
  };

  test('one-anchored oracle law: NO shipped two-endpoint walk grossly misses the ink', () {
    final gross = perFile((c) => c['oa2_ship_qlo'] ?? 0);
    final slackOff = perFile((c) => (c['oa2_slack_anchor'] ?? 0) - (c['oa2_slack_anchor_ink'] ?? 0));
    final notDco = perFile((c) => (c['oa2_slack_anchor'] ?? 0) - (c['oa2_slack_head_dco'] ?? 0));
    final shipBelow = belowPct('oa2_ship', kShipInkPct, 93);
    final belowClosed = <String, int>{};
    final heldNotWorse = <String>{};
    byFile.forEach((name, c) {
      if ((c['oa2_ship_runpx'] ?? 0) == 0) return;
      if ((c['oa2_closed_runpx'] ?? 0) > 0) {
        final gap = _pct(c, 'oa2_closed') - _pct(c, 'oa2_ship');
        if (gap > (kShipBelowClosedPct[name] ?? 3)) belowClosed[name] = gap;
      }
      if ((c['oa2_held_runpx'] ?? 0) > 0 && _pct(c, 'oa2_held') >= _pct(c, 'oa2_ship')) heldNotWorse.add(name);
    });
    expect(C['oa2_ship_wires'] ?? 0, greaterThan(0), reason: 'the snippets carry shipped walked polylines');
    expect(C['oa2_slack_anchor'] ?? 0, greaterThan(0), reason: 'the snippets carry head-slack ships');
    expect(gross, kShipGrossMisses);
    expect(slackOff, kSlackAnchorsOffInk);
    expect(notDco, kSlackHeadsNotDco);
    expect(shipBelow, isEmpty);
    expect(belowClosed, isEmpty);
    expect(heldNotWorse, kHeldNotWorseThanShip);
  });

  test('one-anchored oracle law: into-node ships overlay ink on their own', () {
    final gross = perFile((c) => c['oa2_into_qlo'] ?? 0);
    final below = belowPct('oa2_into', kIntoInkPct, 93);
    expect(C['oa2_into_wires'] ?? 0, greaterThan(0), reason: 'the snippets carry into-node ships');
    expect(gross, kIntoGrossMisses);
    expect(below, isEmpty);
  });

  test('one-anchored oracle law: shipped branch trees overlay reference ink', () {
    final below = belowPct('oab_ship', kBranchInkPct, 85);
    final gross = perFile((c) => c['oab_ship_qlo'] ?? 0);
    expect(below, isEmpty);
    expect(gross, kBranchGrossMisses);
  });
}
