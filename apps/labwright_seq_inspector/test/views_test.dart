// BinaryView, PropertiesView, TypesView, and ui style constants.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_seq/labwright_seq.dart';
import 'package:labwright_seq_inspector/src/binary_view.dart';
import 'package:labwright_seq_inspector/src/properties_view.dart';
import 'package:labwright_seq_inspector/src/property_outline.dart';
import 'package:labwright_seq_inspector/src/types_view.dart';
import 'package:labwright_seq_inspector/src/ui.dart';

Future<void> pump(WidgetTester tester, Widget body) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: body)));

void main() {
  testWidgets('BinaryView renders categorized recovered sections', (
    tester,
  ) async {
    const doc = BinarySeqDocument(
      header: SeqFileHeader(
        format: SeqFormat.binary,
        fileType: 'SequenceFile',
        productName: 'TestStand',
      ),
      inflatedSize: 1234,
      strings: [],
      stringTable: [],
      objectNames: ['MainSequence', 'Step1'],
      modulePaths: [r'My Computer\Lib\Read.vi'],
      stepReferences: ['ID#:abc'],
      expressions: ['Locals.x == 1'],
      quotedLiterals: ['"6105A"'],
    );
    await pump(tester, const BinaryView(doc: doc));
    for (final t in [
      'Module call-targets (1)',
      'Expressions (test logic) (1)',
      'Quoted literals (values) (1)',
      'Object names (2)',
      'All recovered strings (0)',
    ]) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    await tester.tap(find.text('Expressions (test logic) (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Locals.x == 1'), findsOneWidget);
  });

  testWidgets('BinaryView surfaces the decode-coverage tiers when given them', (
    tester,
  ) async {
    const doc = BinarySeqDocument(
      header: SeqFileHeader(format: SeqFormat.binary),
      inflatedSize: 1000,
      strings: [],
      stringTable: [],
    );
    // body 1000 = pool 400 + record region 600 (semantic 300, structural 100,
    // so undecoded 200). Record region: 50% decoded, 66.7% accounted.
    const cov = BinaryByteCoverage(
      bodyBytes: 1000,
      poolBytes: 400,
      recordSemanticBytes: 300,
      recordStructuralBytes: 100,
    );
    await pump(tester, const BinaryView(doc: doc, coverage: cov));
    expect(find.text('Binary body coverage'), findsOneWidget);
    expect(
      find.textContaining('record · semantic  300 B · 30.0%'),
      findsOneWidget,
    );
    expect(
      find.textContaining('record · undecoded  200 B · 20.0%'),
      findsOneWidget,
    );
    expect(find.textContaining('50.0% decoded'), findsOneWidget);
  });

  testWidgets('BinaryView omits the coverage panel when coverage is null', (
    tester,
  ) async {
    const doc = BinarySeqDocument(
      header: SeqFileHeader(format: SeqFormat.binary),
      inflatedSize: 0,
      strings: [],
      stringTable: [],
    );
    await pump(tester, const BinaryView(doc: doc));
    expect(find.text('Binary body coverage'), findsNothing);
  });

  testWidgets('PropertiesView marks %INSTOVRD nodes; plain nodes unmarked', (
    tester,
  ) async {
    await pump(
      tester,
      PropertiesView(
        root: PropertyNode(
          name: 'Data',
          children: [
            PropertyNode(
              name: 'TS',
              attributes: const {'%INSTOVRD': '5046297'},
              children: const [],
            ),
          ],
        ),
      ),
    );
    expect(
      find.textContaining('overridden', findRichText: true),
      findsOneWidget,
    );
    await pump(
      tester,
      PropertiesView(
        root: PropertyNode(
          name: 'Data',
          children: [
            PropertyNode(name: 'Mode', value: 'Normal', children: const []),
          ],
        ),
      ),
    );
    expect(find.textContaining('overridden', findRichText: true), findsNothing);
  });

  testWidgets('TypesView lists type names with a total count', (tester) async {
    await pump(
      tester,
      TypesView(
        types: [
          SeqProperty(name: 'NI_MultipleNumericLimitTest', className: 'Obj'),
          SeqProperty(name: 'FlexGStepAdditions', className: 'Obj'),
        ],
      ),
    );
    for (final t in ['NI_MultipleNumericLimitTest', 'FlexGStepAdditions']) {
      expect(
        find.textContaining(t, findRichText: true),
        findsOneWidget,
        reason: t,
      );
    }
    expect(find.text('2/2'), findsOneWidget);
  });

  testWidgets('TypesView filters types by name', (tester) async {
    await pump(
      tester,
      TypesView(
        types: [
          SeqProperty(name: 'Action', className: 'Obj'),
          SeqProperty(name: 'PassFailTest', className: 'Obj'),
        ],
      ),
    );
    await tester.enterText(find.byType(TextField), 'passfail');
    await tester.pump();
    expect(
      find.textContaining('PassFailTest', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('Action', findRichText: true), findsNothing);
    expect(find.text('1/2'), findsOneWidget);
  });

  testWidgets('an empty type palette says so honestly', (tester) async {
    await pump(tester, const TypesView(types: []));
    expect(find.text('This file defines no types.'), findsOneWidget);
  });

  test('monoStyle is the monospace base (family survives copyWith)', () {
    expect(monoStyle.fontFamily, monoFamily);
    expect(monoStyle.fontSize, 12);
    expect(monoStyle.copyWith(fontSize: 11).fontFamily, monoFamily);
    expect(monoStyle.copyWith(fontSize: 11).fontSize, 11);
  });
}
