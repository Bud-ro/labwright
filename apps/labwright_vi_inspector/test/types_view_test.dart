import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/types_view.dart';
import 'package:labwright_vi_inspector/src/vctp_view.dart';

/// A minimal well-framed VCTP body (count=1, one i32 descriptor, empty top-level
/// list) — enough to enable the bytes↔types toggle.
final Uint8List _vctpBody = Uint8List.fromList(const [
  0x00, 0x00, 0x00, 0x01, //
  0x00, 0x04, 0x00, 0x03,
  0x00, 0x00,
]);

ViModel _modelWithTypes() => const ViModel(
  version: null,
  title: null,
  components: const [],
  stringTables: const [],
  heapRecords: const [],
  types: const [
    ViType(index: 0, code: 0x21, kind: ViDataType.boolean, name: 'status'),
    ViType(index: 1, code: 0x03, kind: ViDataType.i32, name: 'code'),
    ViType(
      index: 2,
      code: 0x50,
      kind: ViDataType.cluster,
      name: 'error out',
      members: [0, 1],
    ),
    ViType(
      index: 3,
      code: 0x16,
      kind: ViDataType.enumU16,
      name: 'Direction',
      enumItems: ['Rising', 'Falling'],
    ),
  ],
);

Future<void> _pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

void main() {
  testWidgets('renders enums with items and clusters with typed fields', (
    tester,
  ) async {
    await _pump(tester, ViTypesView(model: _modelWithTypes()));
    final text = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data!;
    expect(text, contains('enum Direction { Rising, Falling }'));
    expect(text, contains('error out {'));
    expect(text, contains('boolean status;'));
    expect(text, contains('i32 code;'));
  });

  testWidgets('font size can be increased and decreased', (tester) async {
    await _pump(tester, ViTypesView(model: _modelWithTypes()));
    double fontOf() => tester
        .widget<SelectableText>(find.byType(SelectableText))
        .style!
        .fontSize!;
    final initial = fontOf();
    await tester.tap(find.byTooltip('Larger text'));
    await tester.pump();
    expect(fontOf(), greaterThan(initial));
    await tester.tap(find.byTooltip('Smaller text'));
    await tester.pump();
    expect(fontOf(), initial);
  });

  testWidgets('shows an honest empty state when there are no types', (
    tester,
  ) async {
    await _pump(tester, const ViTypesView(model: null));
    expect(find.textContaining('No data types recovered'), findsOneWidget);
  });

  testWidgets('with a VCTP body, the toggle switches to the correlation view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pump(
      tester,
      ViTypesView(model: _modelWithTypes(), vctpBytes: _vctpBody),
    );
    // Listing shown first; no correlation view yet.
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.byType(VctpCorrelationView), findsNothing);

    await tester.tap(find.text('Bytes ↔ types'));
    await tester.pumpAndSettle();
    expect(find.byType(VctpCorrelationView), findsOneWidget);
  });

  testWidgets('no toggle appears without a VCTP body', (tester) async {
    await _pump(tester, ViTypesView(model: _modelWithTypes()));
    expect(find.text('Bytes ↔ types'), findsNothing);
  });
}
