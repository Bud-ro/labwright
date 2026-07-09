import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Pumps [body] inside MaterialApp/Scaffold at a fixed [view] size.
Future<void> pumpBody(
  WidgetTester tester,
  Widget body, {
  Size view = const Size(1000, 1000),
}) async {
  tester.view.physicalSize = view;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: body)));
  await tester.pump();
}

// Heap record builders (mirror the videcode bracket model).
List<int> open(int kind, int oid, {int tag = 0x19}) => [
  0x10,
  tag,
  0x02,
  0xfe,
  kind >> 8,
  kind & 0xff,
  0xfd,
  oid >> 8,
  oid & 0xff,
];
List<int> close([int tag = 0x19]) => [0x08, tag];
List<int> bounds(int t, int l, int b, int r) => [
  0xc4,
  0x2d,
  0x08,
  t >> 8,
  t & 0xff,
  l >> 8,
  l & 0xff,
  b >> 8,
  b & 0xff,
  r >> 8,
  r & 0xff,
];
List<int> caption(String s) => [0xc4, 0x22, s.length, ...s.codeUnits];
List<int> helpRecord(String s) => [0xc4, 0x19, s.length, ...s.codeUnits];
List<int> enum2e(List<String> items) {
  final b = <int>[
    for (final it in items) ...[it.length, ...it.codeUnits],
  ];
  return [0xc4, 0x2e, b.length, ...b];
}

List<int> childRef(int oid) => [0x14, 0x19, 0x01, 0xfd, oid >> 8, oid & 0xff];
List<int> memberRef(int oid) => [0x14, 0x4f, 0x01, 0xfd, oid >> 8, oid & 0xff];

/// Frames [records] with the u32 heap content-length header as a section.
DecodedSection heapSection(
  List<int> records, {
  String tag = 'BDHb',
  bool compressed = false,
}) {
  final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
  return DecodedSection(
    section: ViSection(tag: tag, index: 0, dataOffset: 0, bytes: body),
    bytes: body,
    wasCompressed: compressed,
  );
}

ViModel modelFromRecords(List<int> records) =>
    buildViModelFromDecoded([heapSection(records)]);

/// A ViHeapObject with the commonly-poked fields settable in one call.
ViHeapObject heapObj(
  int kind, {
  int oid = 1,
  ViObjectKind? cat,
  (int, int, int, int)? at,
  String? label,
  List<String>? items,
  List<String>? plotNames,
  List<int>? plotColors,
  double? min,
  double? max,
  String? help,
  ViTypeKind? typeKind,
}) {
  final o = ViHeapObject(oid: oid, kind: kind, offset: 0);
  if (cat != null) o.category = cat;
  if (plotColors != null) o.plotColors = plotColors;
  if (at != null) {
    o.absBounds = HeapRect(
      top: at.$1,
      left: at.$2,
      bottom: at.$3,
      right: at.$4,
    );
  }
  if (label != null) o.label = label;
  if (items != null) o.items = items;
  if (plotNames != null) o.plotNames = plotNames;
  if (min != null) o.controlMin = min;
  if (max != null) o.controlMax = max;
  if (help != null) o.helpText = help;
  if (typeKind != null) o.typeKind = typeKind;
  return o;
}
