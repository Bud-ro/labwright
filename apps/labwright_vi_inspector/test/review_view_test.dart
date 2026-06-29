import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';
import 'package:labwright_vi_inspector/src/generated_dart_view.dart';
import 'package:labwright_vi_inspector/src/review_view.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

List<int> open(int kind, int oid, {int tag = 0x19}) =>
    [0x10, tag, 0x02, 0xfe, kind >> 8, kind & 0xff, 0xfd, oid >> 8, oid & 0xff];
List<int> close([int tag = 0x19]) => [0x08, tag];
List<int> bounds(int t, int l, int b, int r) =>
    [0xc4, 0x2d, 0x08, t >> 8, t & 0xff, l >> 8, l & 0xff, b >> 8, b & 0xff, r >> 8, r & 0xff];

ViModel _bdModel() {
  final records = <int>[
    ...open(0x7e, 1), ...bounds(0, 0, 400, 400),
    ...open(0x53, 2, tag: 0x1a), ...bounds(20, 20, 380, 380),
    ...open(0x12, 3, tag: 0x1b), ...bounds(40, 40, 90, 160),
    ...close(0x1b),
    ...close(0x1a),
    ...close(),
  ];
  final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
  final sec = DecodedSection(
    section: ViSection(tag: 'BDHb', index: 0, dataOffset: 0, bytes: body),
    bytes: body,
    wasCompressed: false,
  );
  return buildViModelFromDecoded([sec]);
}

void main() {
  testWidgets('review view shows both the diagram and the generated Dart side by side', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ViReviewView(model: _bdModel(), viName: 'MyVi.vi'))));

    expect(find.byType(ViDiagramView), findsOneWidget);
    expect(find.byType(GeneratedDartView), findsOneWidget);
    expect(find.byType(VerticalDivider), findsOneWidget);
    expect(find.textContaining(scaffoldMarker, findRichText: true), findsWidgets);
  });

  testWidgets('review view shows an honest recovery summary from real counts', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ViReviewView(model: _bdModel(), viName: 'MyVi.vi'))));

    expect(find.textContaining('Recovered:'), findsOneWidget);
    expect(find.textContaining('BD objects'), findsOneWidget);
    expect(find.textContaining('dataflow / wires are not recovered'), findsOneWidget);
  });

  testWidgets('review view stacks vertically on a narrow viewport', (tester) async {
    tester.view.physicalSize = const Size(500, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ViReviewView(model: _bdModel(), viName: 'MyVi.vi'))));

    expect(find.byType(ViDiagramView), findsOneWidget);
    expect(find.byType(GeneratedDartView), findsOneWidget);
    expect(find.byType(VerticalDivider), findsNothing);
  });
}
