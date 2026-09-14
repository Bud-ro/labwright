import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/types_view.dart';
import 'package:labwright_vi_inspector/src/vctp_view.dart';

final Uint8List _vctpBody = Uint8List.fromList(const [
  0x00, 0x00, 0x00, 0x01, //
  0x00, 0x05, 0x00, 0x03, 0x00,
  0x00, 0x00,
]);

ViModel _modelWithTypes() => ViModel(
  version: null,
  title: null,
  components: const [],
  heapRecords: const [],
  types: decodeTypePool(
    Uint8List.fromList([
      0, 0, 0, 4, //
      0, 12, 0x40, 0x21, 6, ...'status'.codeUnits, 0,
      0, 11, 0x40, 0x03, 0, 4, ...'code'.codeUnits, 0,
      0, 20, 0x40, 0x50, 0, 2, 0, 0, 0, 1, 9, ...'error out'.codeUnits,
      0, 33, 0x40, 0x16,
      0,
      2,
      6,
      ...'Rising'.codeUnits,
      7,
      ...'Falling'.codeUnits,
      0,
      0,
      9,
      ...'Direction'.codeUnits,
      0, 0,
    ]),
  ).types,
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
