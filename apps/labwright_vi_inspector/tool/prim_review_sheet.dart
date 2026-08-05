import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';

import '../test/util.dart';

/// Exports the primitive review contact sheet: one row per block-diagram
/// operation the transpiler has no lowering rule for, showing LabVIEW's own
/// icon art beside the identity, how much of the corpus it blocks, and a corpus
/// VI that carries it.
///
/// The list is data ([kReviewSheetRows]), measured by the transpiler's
/// corpus census (`kCorpusPrimReviewList`), ranked by the VIs each identity
/// blocks. An entry whose icon is not bundled draws its identity on an empty
/// plate and names the VI to open instead — the class-coded nodes have no
/// extracted art (see `assets/prim_icons/MANIFEST.md`).
///
/// It rasterises icon art, so it runs under the flutter_test harness rather
/// than as a plain script, from the app package root:
///
///     flutter test tool/prim_review_sheet.dart --dart-define=SHEET_DIR=<dir>
///
/// Both forms are written from the same rows: `prim_review_sheet.png` draws
/// each identity's icon, and `prim_review_sheet.txt` carries the same table as
/// text for reading where an image cannot be opened.
///
/// The rows' consistency with the icon catalogue is checked in the default
/// suite by test/prim_review_sheet_test.dart.
void main() {
  const sheetDir = String.fromEnvironment('SHEET_DIR');
  testWidgets('SHEET_DIR=<dir> exports prim_review_sheet.png', (tester) async {
    if (sheetDir.isEmpty) {
      markTestSkipped('pass --dart-define=SHEET_DIR=<dir> to export');
      return;
    }
    await loadRealTextFont();
    await tester.runAsync(() async {
      final icons = await loadPrimIcons();
      final png = await _paintSheet(icons);
      final out = Directory(sheetDir)..createSync(recursive: true);
      final file = File('${out.path}/prim_review_sheet.png')
        ..writeAsBytesSync(png);
      final text = File('${out.path}/prim_review_sheet.txt')
        ..writeAsStringSync(reviewSheetText());
      // ignore: avoid_print
      print('exported ${file.path} and ${text.path}');
    });
  });
}

/// One contact-sheet row: what the identity is, what it costs, and where to
/// look at it.
typedef ReviewSheetRow = ({
  String identity,
  int? primResId,
  int? classCode,
  bool hasIcon,
  int vis,
  int nodes,
  int sole,
  String note,
  String example,
});

/// The rows, ranked by the VIs each identity blocks.
///
/// `vis` / `nodes` / `sole` are the transpiler's corpus census over 7 508 VIs:
/// the VIs holding at least one such node, the node instances, and the VIs
/// whose ONLY unmapped identity it is. `note` states what specifically is not
/// decoded — the question each row asks.
///
/// `sole` counts only PRIMITIVE blockers, so it is an upper bound on what a
/// rule for the row would buy and never the count of VIs it would make lower.
/// `kCorpusPrimReviewList` measures how far apart those are.
const List<ReviewSheetRow> kReviewSheetRows = [
  (
    identity: 'class 0x34 — Bundle',
    primResId: null,
    classCode: 0x34,
    hasIcon: false,
    vis: 805,
    nodes: 1659,
    sole: 84,
    note:
        'named by 26 corpus captions; which terminal is the cluster being '
        'modified and which are the members is not decoded',
    example: 'smithed_vicompare/…/Trunk/performaction.vi',
  ),
  (
    identity: 'Close Reference (primResID 8011)',
    primResId: 8011,
    classCode: null,
    hasIcon: false,
    vis: 759,
    nodes: 3068,
    sole: 41,
    note:
        'what closing a reference does to the referent is not decoded, and '
        'the reference classes are not separated (LvRefnum is one handle type)',
    example: 'vipm-io_caraya/…/src/subVIs/VI Name.vi',
  ),
  (
    identity: 'class 0x93 — Format Into String',
    primResId: null,
    classCode: 0x93,
    hasIcon: false,
    vis: 690,
    nodes: 1566,
    sole: 107,
    note:
        'named by 37 corpus captions; LabVIEW\'s format-specifier grammar is '
        'not decoded, so the format string cannot be read',
    example: 'G-CLI_G-CLI/…/build/setVipBuildNumber.vi',
  ),
  (
    identity: 'Match Pattern (primResID 1535)',
    primResId: 1535,
    classCode: null,
    hasIcon: true,
    vis: 680,
    nodes: 1800,
    sole: 71,
    note:
        'the pattern dialect is not decoded: LabVIEW\'s Match Pattern is not '
        'a regular expression, and its metacharacter set is not established',
    example: 'G-CLI_G-CLI/…/build/setVipBuildNumber.vi',
  ),
  (
    identity: 'class 0xa9 — 38 distinct captions',
    primResId: null,
    classCode: 0xa9,
    hasIcon: false,
    vis: 678,
    nodes: 2619,
    sole: 62,
    note:
        'captions read Invoke Node ×84 then Classes ×10, Attribute ×10, '
        'Save ×8 — is the class one node whose caption is the invoked member?',
    example: 'vipm-io_caraya/…/src/tests/All Tests.vi',
  ),
  (
    identity: 'class 0x6c — Compound Arithmetic',
    primResId: null,
    classCode: 0x6c,
    hasIcon: false,
    vis: 621,
    nodes: 1104,
    sole: 67,
    note:
        'operand order reads; the node\'s mode (add/multiply/AND/OR/XOR) and '
        'its per-operand inversion bit are not tied to any decoded field',
    example: 'vipm-io_caraya/…/src/subVIs/FindLibPath.vi',
  ),
  (
    identity: 'Search 1D Array (primResID 1901)',
    primResId: 1901,
    classCode: null,
    hasIcon: true,
    vis: 591,
    nodes: 1338,
    sole: 29,
    note:
        'arity and operand order read; the value returned when the element is '
        'absent, and the start-index default when unwired, are not decoded',
    example: 'vipm-io_caraya/…/src/Caraya CLI.vi',
  ),
  (
    identity: 'class 0x153 — In Place Element (DVR access)',
    primResId: null,
    classCode: 0x153,
    hasIcon: false,
    vis: 556,
    nodes: 1466,
    sole: 337,
    note:
        'all 1466 sit inside an In Place Element Structure and name a data '
        'value reference; no VI holding one lowers on a rule for it alone',
    example: 'rfporter_Modbus-Master/…/MB_Master_TCP/RX.vi',
  ),
  (
    identity: 'Build Path (primResID 1419)',
    primResId: 1419,
    classCode: null,
    hasIcon: true,
    vis: 439,
    nodes: 1215,
    sole: 25,
    note:
        'LvPath carries components and a root flag; how LabVIEW joins a '
        'relative name onto a path, and what it does with an empty one, is not decoded',
    example: 'G-CLI_G-CLI/…/build/vipbBuild-nocli.vi',
  ),
  (
    identity: 'class 0xd6 — Event Data / Event Filter Node',
    primResId: null,
    classCode: 0xd6,
    hasIcon: false,
    vis: 378,
    nodes: 2437,
    sole: 25,
    note:
        'captioned two ways (Event Data Node ×17, Event Filter Node ×1); no '
        'decoded field separates the two the way 0x63\'s flag bit does',
    example: 'G-CLI_G-CLI/…/LabVIEW Source/CLI Demo.vi',
  ),
  (
    identity: 'Strip Path (primResID 1420)',
    primResId: 1420,
    classCode: null,
    hasIcon: true,
    vis: 370,
    nodes: 865,
    sole: 1,
    note:
        'which of the two outputs is the stripped path and which the removed '
        'name is not decoded, and the behaviour on a rootless path is not stated',
    example: 'vipm-io_caraya/…/src/Caraya CLI.vi',
  ),
  (
    identity: 'To More Specific Class (primResID 8016)',
    primResId: 8016,
    classCode: null,
    hasIcon: false,
    vis: 344,
    nodes: 825,
    sole: 39,
    note:
        'LabVIEW class hierarchies are not decoded, so what makes one class '
        'more specific than another has no reading',
    example: 'nasa_NDAS/…/Menu Manager/Activate Menu.vi',
  ),
  (
    identity: 'class 0xbd — Delete From Array',
    primResId: null,
    classCode: 0xbd,
    hasIcon: false,
    vis: 332,
    nodes: 645,
    sole: 10,
    note:
        'named by 7 corpus captions, unanimous; which terminal is the index '
        'and which the length, and which output is the remainder, are not decoded',
    example: 'DAQIO_LVMQTT/…/Sub/Sub_Read_MQTT_String.vi',
  ),
  (
    identity: 'String Subset (primResID 1503)',
    primResId: 1503,
    classCode: null,
    hasIcon: true,
    vis: 298,
    nodes: 669,
    sole: 34,
    note:
        'operand order reads as [string, offset, length] and the offset is '
        '0-based; the rule for an offset or length outside the string is not decoded',
    example: 'smithed_vicompare/…/Trunk/is absolute path.vi',
  ),
  (
    identity: 'class 0xb6 — 147 distinct captions',
    primResId: null,
    classCode: 0xb6,
    hasIcon: false,
    vis: 264,
    nodes: 533,
    sole: 20,
    note:
        'every node is 0 inputs 1 output; captions read Current VI Reference '
        '×141, This VI ×34, This Application ×8 — a reference source?',
    example: 'vipm-io_caraya/…/src/tests/All Tests.vi',
  ),
  (
    identity: 'Variant To Data (primResID 8003)',
    primResId: 8003,
    classCode: null,
    hasIcon: true,
    vis: 263,
    nodes: 506,
    sole: 10,
    note:
        'variant payload layout is not decoded (LvVariant carries the bytes '
        'and the descriptor verbatim), so nothing reads a value back out',
    example: 'ni_grpc-labview/…/tests/gRPC_ATS/SubVIs/RunVI.vi',
  ),
  (
    identity: 'To Lower Case (primResID 1189)',
    primResId: 1189,
    classCode: null,
    hasIcon: true,
    vis: 255,
    nodes: 673,
    sole: 4,
    note:
        'LabVIEW\'s case-mapping table over a byte string is not decoded, and '
        'Dart\'s toLowerCase is Unicode\'s, which differs above U+007F',
    example: 'smithed_vicompare/…/Trunk/fix all paths.vi',
  ),
  (
    identity: 'Open VI Reference (primResID 8010)',
    primResId: 8010,
    classCode: null,
    hasIcon: true,
    vis: 251,
    nodes: 447,
    sole: 7,
    note:
        'the options word\'s bits are not decoded, and a VI reference has no '
        'runtime to open against',
    example: 'vipm-io_caraya/…/src/subVIs/VI Name.vi',
  ),
  (
    identity: 'class 0x114 — no caption agreement',
    primResId: null,
    classCode: 0x114,
    hasIcon: false,
    vis: 243,
    nodes: 414,
    sole: 13,
    note:
        'captions read Overflow array ×4 against Initialize Array ×3, both of '
        'which read as author text — what is this node?',
    example: 'vipm-io_caraya/…/src/subVIs/Call Chain To Hash.vi',
  ),
  (
    identity: 'class 0x14a — Feedback Node',
    primResId: null,
    classCode: 0x14a,
    hasIcon: false,
    vis: 221,
    nodes: 380,
    sole: 0,
    note:
        'captions read Feedback Node ×12 and Target Angle ×2; a feedback node '
        'carries state across iterations, which this dataflow IR has no unit for',
    example: 'nasa_NDAS/…/File Manager/Write Results.vi',
  ),
  (
    identity: 'class 0x170 — no caption at all',
    primResId: null,
    classCode: 0x170,
    hasIcon: false,
    vis: 221,
    nodes: 380,
    sole: 0,
    note:
        'not one corpus node carries a caption; every node is sink-only '
        '(1i0o ×372, 2i0o ×8), so it consumes values and yields none',
    example: 'nasa_NDAS/…/File Manager/Write Results.vi',
  ),
  (
    identity: 'class 0xeb — Register For Events',
    primResId: null,
    classCode: 0xeb,
    hasIcon: false,
    vis: 199,
    nodes: 226,
    sole: 6,
    note:
        'only 2 corpus captions, below the naming bar; the terminal grammar '
        'of a growable registration node is not decoded',
    example: 'opengds_OpenGDS/…/Open_GDS_Tools/Temp/SelectClassIcon.vi',
  ),
  (
    identity: 'Unregister For Events (primResID 2076)',
    primResId: 2076,
    classCode: null,
    hasIcon: true,
    vis: 181,
    nodes: 203,
    sole: 0,
    note:
        'the event system has no runtime model, so unregistering has no '
        'observable effect to lower to',
    example: 'nasa_NDAS/…/Peer Review Tool/Peer Review Tool.vi',
  ),
  (
    identity: 'Call Chain (primResID 1999)',
    primResId: 1999,
    classCode: null,
    hasIcon: false,
    vis: 174,
    nodes: 175,
    sole: 37,
    note:
        'yields the caller chain as an array of paths; the runtime keeps no '
        'call stack of VI paths, so the value has no source',
    example: 'vipm-io_caraya/…/src/subVIs/VI Name.vi',
  ),
  (
    identity: 'Search and Replace String (primResID 3914)',
    primResId: 3914,
    classCode: null,
    hasIcon: true,
    vis: 157,
    nodes: 243,
    sole: 10,
    note:
        'the node carries a regular-expression mode and a replace-all flag; '
        'neither is tied to a decoded field, and the dialect is Match Pattern\'s',
    example: 'smithed_vicompare/…/Trunk/swap slashes.vi',
  ),
  (
    identity: 'class 0x150 — In Place Element border node',
    primResId: null,
    classCode: 0x150,
    hasIcon: false,
    vis: 157,
    nodes: 406,
    sole: 28,
    note:
        'all 406 sit inside an In Place Element Structure and pair off '
        'left/right; which element access each performs is not recovered',
    example: 'nasa_NDAS/…/Peer Review Tool/Functions/Reset Files.vi',
  ),
  (
    identity: 'Get Variant Attribute (primResID 8205)',
    primResId: 8205,
    classCode: null,
    hasIcon: true,
    vis: 153,
    nodes: 307,
    sole: 27,
    note:
        'variant attribute storage is not decoded — neither where a variant '
        'keeps its attribute table nor how a name selects one',
    example: 'rfporter_Modbus-Master/…/MB_Master_TCP/TX.vi',
  ),
  (
    identity: 'Enqueue Element (primResID 9111)',
    primResId: 9111,
    classCode: null,
    hasIcon: false,
    vis: 152,
    nodes: 369,
    sole: 3,
    note:
        'queues have no runtime model; the timeout terminal\'s unwired default '
        'and the timed-out output\'s polarity are not decoded either',
    example: 'rfporter_Modbus-Master/…/MB_Master_TCP/Core.vi',
  ),
  (
    identity: 'primResID 9113 — name not decoded',
    primResId: 9113,
    classCode: null,
    hasIcon: false,
    vis: 152,
    nodes: 187,
    sole: 2,
    note:
        'no corpus VI labels this id and no bundled icon exists for it; it '
        'sits in the queue run (9108 Obtain, 9109 Release, 9111 Enqueue)',
    example: 'rfporter_Modbus-Master/…/Tools/Modbus Comm Tester.vi',
  ),
  (
    identity: 'primResID 1181 — name not decoded',
    primResId: 1181,
    classCode: null,
    hasIcon: true,
    vis: 3,
    nodes: 6,
    sole: 0,
    note:
        'MAINTAINER-BLOCKED: two inputs, one output; no corpus VI labels it '
        'and its icon has not been read — what operation is this?',
    example: 'vipm-io_caraya/…/src/subVIs/guid_generator.vi',
  ),
  (
    identity: 'primResID 1082 — name not decoded',
    primResId: 1082,
    classCode: null,
    hasIcon: true,
    vis: 2,
    nodes: 3,
    sole: 0,
    note:
        'MAINTAINER-BLOCKED: two inputs, one output, drawn beside the '
        'arithmetic run; no corpus label and no reading of its icon',
    example: 'rcpacini_LabVIEW-VI-Hacker/…/src/MD5.vi',
  ),
];

/// The sheet as PNG bytes: a header, then one row per [kReviewSheetRows] entry.
Future<List<int>> _paintSheet(Map<int, PrimIconArt> icons) async {
  const width = 1180.0;
  const rowHeight = 52.0;
  const headerHeight = 64.0;
  final height = headerHeight + rowHeight * kReviewSheetRows.length + 16;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = const Color(0xFFFFFFFF),
  );

  void text(
    String value,
    double x,
    double y, {
    double size = 12,
    bool bold = false,
    Color? colour,
    double? max,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontFamily: 'Selawik',
          fontSize: size,
          color: colour ?? const Color(0xFF202020),
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: max ?? width - x - 8);
    painter.paint(canvas, Offset(x, y));
  }

  text(
    'Unmapped block-diagram operations, ranked by the VIs each one blocks',
    16,
    14,
    size: 17,
    bold: true,
  );
  text(
    'vis / nodes / sole over the 7 508-VI corpus; "sole" is the VIs whose only unmapped identity it is. '
    'A row with no icon has no extracted art — open the example VI to see it drawn.',
    16,
    38,
    size: 11,
    colour: const Color(0xFF606060),
  );

  var y = headerHeight;
  for (final row in kReviewSheetRows) {
    canvas.drawRect(
      Rect.fromLTWH(0, y, width, rowHeight),
      Paint()
        ..color = y ~/ rowHeight % 2 == 0
            ? const Color(0xFFFFFFFF)
            : const Color(0xFFF6F6F6),
    );
    canvas.drawRect(
      Rect.fromLTWH(12, y + 8, 36, 36),
      Paint()
        ..color = const Color(0xFFD0D0D0)
        ..style = PaintingStyle.stroke,
    );
    final art = row.primResId == null ? null : icons[row.primResId!];
    if (art != null) {
      final image = art.base;
      final scale = (34 / image.width).clamp(0.0, 34 / image.height);
      final w = image.width * scale, h = image.height * scale;
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(12 + (36 - w) / 2, y + 8 + (36 - h) / 2, w, h),
        Paint()..filterQuality = FilterQuality.none,
      );
    } else {
      text('?', 26, y + 16, size: 16, colour: const Color(0xFFA0A0A0));
    }
    text(row.identity, 58, y + 8, size: 12.5, bold: true, max: 300);
    text(
      '${row.vis} VIs · ${row.nodes} nodes · ${row.sole} sole',
      58,
      y + 28,
      size: 11,
      colour: const Color(0xFF505050),
      max: 300,
    );
    text(row.note, 370, y + 7, size: 11, max: 500);
    text(
      row.example,
      880,
      y + 18,
      size: 10,
      colour: const Color(0xFF707070),
      max: 292,
    );
    y += rowHeight;
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(width.round(), height.round());
  return imageToPng(image);
}

/// [kReviewSheetRows] as plain text — the same table the sheet draws, in the
/// form that needs no image viewer. Each entry names the identity, its VI /
/// node / sole counts, what specifically is not decoded, and a corpus VI that
/// holds one.
String reviewSheetText() {
  final out = StringBuffer()
    ..writeln(
      'Unmapped block-diagram operations, ranked by the VIs each one blocks',
    )
    ..writeln('=' * 78)
    ..writeln()
    ..writeln(
      'vis / nodes / sole over the 7508-VI corpus. "sole" is the VIs whose only',
    )
    ..writeln(
      'unmapped identity this is — but it ranks primitive blockers only, so a node',
    )
    ..writeln(
      'whose enclosing structure refuses first is not unblocked by naming it.',
    )
    ..writeln();
  for (final row in kReviewSheetRows) {
    out
      ..writeln(row.identity)
      ..writeln('  ${row.vis} VIs · ${row.nodes} nodes · ${row.sole} sole')
      ..writeln('  unknown: ${row.note}')
      ..writeln('  example: ${row.example}')
      ..writeln();
  }
  return out.toString();
}
