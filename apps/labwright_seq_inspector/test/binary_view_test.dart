import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_seq/labwright_seq.dart';
import 'package:labwright_seq_inspector/src/binary_view.dart';

void main() {
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

  testWidgets('BinaryView renders categorized recovered sections', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BinaryView(doc: doc))),
    );

    // The recovered-datum category sections render with their counts.
    expect(find.text('Module call-targets (1)'), findsOneWidget);
    expect(find.text('Expressions (test logic) (1)'), findsOneWidget);
    expect(find.text('Quoted literals (values) (1)'), findsOneWidget);
    expect(find.text('Object names (2)'), findsOneWidget);
    expect(find.text('All recovered strings (0)'), findsOneWidget);

    // Expanding a section reveals its recovered item.
    await tester.tap(find.text('Expressions (test logic) (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Locals.x == 1'), findsOneWidget);
  });
}
