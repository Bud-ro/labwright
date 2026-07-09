import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/coverage_view.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

/// A hand-built attribution: 100-byte file, half model / half copied at the byte
/// level; one compressed section inflates 20→80, so the content total is 160.
WriterAttribution _attr({bool byteExact = true, int bugs = 0}) =>
    WriterAttribution(
      fileLength: 100,
      byteExact: byteExact,
      headerBytes: 32,
      infoStructBytes: 10,
      sectionPrefixBytes: 4,
      typedPayloadBytes: 4,
      alignPadBytes: 0,
      infoRawBytes: 6,
      gapBytes: 4,
      compressedPayloadBytes: 20,
      untypedPayloadBytes: 20,
      inflatedContentBytes: 80,
      heapModelBytes: 60,
      heapCopiedBytes: 20,
      imageCompressedBytes: 0,
      imageInflatedBytes: 0,
      imageInflatedModelBytes: 0,
      imageInflatedCopiedBytes: 0,
      heapModelBugs: bugs,
    );

void main() {
  testWidgets('null attribution shows an honest empty state', (tester) async {
    await _pump(tester, const ViCoverageView(attribution: null));
    expect(find.textContaining('unavailable'), findsOneWidget);
  });

  testWidgets('surfaces headline coverage and byte-exact round-trip', (
    tester,
  ) async {
    await _pump(tester, ViCoverageView(attribution: _attr()));
    expect(find.text('Content model'), findsOneWidget);
    expect(find.text('Byte model'), findsOneWidget);
    // Byte model = 50/100; content model = (50+60)/160 = 68.8%.
    expect(find.text('50.0%'), findsOneWidget);
    expect(find.text('68.8%'), findsOneWidget);
    expect(find.text('byte-exact'), findsOneWidget);
    expect(find.text('Heap content (model)'), findsOneWidget);
  });

  testWidgets('a non-round-tripping VI reads "differs"', (tester) async {
    await _pump(tester, ViCoverageView(attribution: _attr(byteExact: false)));
    expect(find.text('differs'), findsOneWidget);
    expect(find.text('byte-exact'), findsNothing);
  });

  testWidgets('heap model bugs surface as a loud warning', (tester) async {
    await _pump(tester, ViCoverageView(attribution: _attr(bugs: 3)));
    expect(find.textContaining('3 heap record'), findsOneWidget);
  });
}
