import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/span_annotations.dart';
import 'package:labwright_vi_inspector/src/vctp_view.dart';

final Uint8List _body = Uint8List.fromList(const [
  0x00, 0x00, 0x00, 0x03, // count = 3
  0x00, 0x05, 0x00, 0x03, 0x00, // #0 i32, len 5
  0x00, 0x08, 0x40, 0x21, 0x03, 0x61, 0x62, 0x63, // #1 boolean 'abc', len 8
  0x00, 0x05, 0x00, 0x05, 0x00, // #2 u8, len 5
  0x00, 0x00, // top-level list, 0 entries
]);

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

int _highlightedCells(WidgetTester tester) => tester
    .widgetList<Container>(find.byType(Container))
    .where((c) => c.color == spanColorObject.withValues(alpha: 0.35))
    .length;

void main() {
  testWidgets('selecting a type highlights its byte span and names the field', (
    tester,
  ) async {
    await _pump(tester, VctpCorrelationView(body: _body));
    expect(_highlightedCells(tester), 0);

    await tester.tap(find.byKey(const ValueKey('vctp-type-1')));
    await tester.pump();

    expect(_highlightedCells(tester), greaterThanOrEqualTo(12));
    expect(find.textContaining('Descriptor #1'), findsOneWidget);
    expect(find.textContaining('boolean'), findsWidgets);
    expect(find.textContaining('descriptor length (u16)'), findsOneWidget);
  });

  testWidgets('a body that does not frame shows an honest empty state', (
    tester,
  ) async {
    await _pump(
      tester,
      VctpCorrelationView(body: Uint8List.fromList(const [0, 0, 0, 0])),
    );
    expect(find.textContaining('did not frame'), findsOneWidget);
  });
}
