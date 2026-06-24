import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/generated_dart_view.dart';
import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:labwright_viparse/labwright_viparse.dart';

// Heap record helpers (mirror the videcode bracket model).
List<int> open(int kind, int oid, {int tag = 0x19}) =>
    [0x10, tag, 0x02, 0xfe, kind >> 8, kind & 0xff, 0xfd, oid >> 8, oid & 0xff];
List<int> close([int tag = 0x19]) => [0x08, tag];
List<int> bounds(int t, int l, int b, int r) =>
    [0xc4, 0x2d, 0x08, t >> 8, t & 0xff, l >> 8, l & 0xff, b >> 8, b & 0xff, r >> 8, r & 0xff];

// A block diagram: a root containing a While-loop structure (0x53) with a
// subVI-call node (0x12) inside it.
ViModel _bdModel() {
  final records = <int>[
    ...open(0x7e, 1), ...bounds(0, 0, 400, 400),
    ...open(0x53, 2, tag: 0x1a), ...bounds(20, 20, 380, 380), // while loop
    ...open(0x12, 3, tag: 0x1b), ...bounds(40, 40, 90, 160), // subVI node
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
  return buildViModelFromDecoded([sec], subViNames: const ['Helper.vi']);
}

Future<void> _pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

void main() {
  testWidgets('shows the honest scaffold marker and the structures/subVIs', (tester) async {
    await _pump(tester, GeneratedDartView(model: _bdModel(), viName: 'MyVi.vi'));

    // the no-dataflow disclaimer is always present
    expect(find.textContaining(scaffoldMarker, findRichText: true), findsWidgets);
    // the function name comes from the VI name (.vi stripped)
    expect(find.textContaining('void MyVi(', findRichText: true), findsWidgets);
    // the recovered subVI is listed
    expect(find.textContaining('Helper.vi', findRichText: true), findsWidgets);
  });

  testWidgets('JSON IR view shows valid, decodable JSON with the schema version and oids', (tester) async {
    await _pump(tester, GeneratedDartView(model: _bdModel(), viName: 'MyVi.vi'));
    await tester.tap(find.text('JSON IR'));
    await tester.pumpAndSettle();
    // pull the actual displayed text and assert it is genuinely valid JSON
    final shown = tester.widget<SelectableText>(find.byType(SelectableText)).data!;
    final decoded = jsonDecode(shown) as Map<String, Object?>;
    expect(decoded['irVersion'], viIrVersion);
    final objs = ((decoded['blockDiagrams'] as List).first as Map)['objects'] as List;
    final oids = objs.map((o) => (o as Map)['oid']).toSet();
    expect(oids, containsAll(<int>[2, 3])); // the while-loop + subVI node from _bdModel
  });

  testWidgets('function name falls back to "vi" when the VI name is null or only ".vi"', (tester) async {
    await _pump(tester, GeneratedDartView(model: _bdModel())); // viName null -> 'vi'
    expect(find.textContaining('void vi(', findRichText: true), findsWidgets);

    await _pump(tester, GeneratedDartView(model: _bdModel(), viName: '.vi'));
    expect(find.textContaining('void vi(', findRichText: true), findsWidgets);
  });

  testWidgets('font size can be increased and decreased', (tester) async {
    await _pump(tester, GeneratedDartView(model: _bdModel(), viName: 'MyVi.vi'));

    double fontOf() => tester.widget<SelectableText>(find.byType(SelectableText)).style!.fontSize!;
    final initial = fontOf();
    await tester.tap(find.byTooltip('Larger text'));
    await tester.pump();
    expect(fontOf(), greaterThan(initial));
    await tester.tap(find.byTooltip('Smaller text'));
    await tester.pump();
    expect(fontOf(), initial);
  });

  testWidgets('handles a null model gracefully', (tester) async {
    await _pump(tester, const GeneratedDartView(model: null));
    expect(find.textContaining('No model recovered'), findsOneWidget);
  });
}
