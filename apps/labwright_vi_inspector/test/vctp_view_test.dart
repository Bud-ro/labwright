import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/span_annotations.dart';
import 'package:labwright_vi_inspector/src/vctp_view.dart';

final Uint8List _body = Uint8List.fromList(const [
  0x00, 0x00, 0x00, 0x03, // count = 3
  0x00, 0x04, 0x00, 0x03, // #0 i32, len 4
  0x00, 0x06, 0x00, 0x21, 0xaa, 0xbb, // #1 boolean, len 6
  0x00, 0x04, 0x00, 0x05, // #2 u8, len 4
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
  test(
    'vctpTypeSpans tiles the descriptor region and pairs types by index',
    () {
      final spans = vctpTypeSpans(_body);
      final types = decodeTypePool(_body);
      expect(spans, hasLength(types.length));
      expect(spans, hasLength(3));

      expect(spans.map((s) => s.offset).toList(), [4, 8, 14]);
      expect(spans.map((s) => s.length).toList(), [4, 6, 4]);

      for (var i = 1; i < spans.length; i++) {
        expect(spans[i].offset, spans[i - 1].offset + spans[i - 1].length);
      }

      for (var i = 0; i < spans.length; i++) {
        expect(spans[i].type.index, i);
        expect(spans[i].type.code, types[i].code);
        expect(spans[i].type.kind, types[i].kind);
      }
      expect(spans.map((s) => s.type.kind).toList(), [
        ViDataType.i32,
        ViDataType.boolean,
        ViDataType.u8,
      ]);
    },
  );

  test('vctpTypeSpans is total on malformed/short bodies', () {
    expect(vctpTypeSpans(Uint8List(0)), isEmpty);
    expect(vctpTypeSpans(Uint8List.fromList(const [0, 0, 0, 1])), isEmpty);
  });

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
