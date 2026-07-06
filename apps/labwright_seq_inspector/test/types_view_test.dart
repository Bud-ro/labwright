import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_seq/labwright_seq.dart';
import 'package:labwright_seq_inspector/src/types_view.dart';

void main() {
  Future<void> pump(WidgetTester tester, List<SeqProperty> types) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TypesView(types: types)),
        ),
      );

  testWidgets('lists the file type names and a total count', (tester) async {
    await pump(tester, [
      SeqProperty(name: 'NI_MultipleNumericLimitTest', className: 'Obj'),
      SeqProperty(name: 'FlexGStepAdditions', className: 'Obj'),
    ]);
    expect(
      find.textContaining('NI_MultipleNumericLimitTest', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('FlexGStepAdditions', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('2/2'), findsOneWidget);
  });

  testWidgets('filters types by name', (tester) async {
    await pump(tester, [
      SeqProperty(name: 'Action', className: 'Obj'),
      SeqProperty(name: 'PassFailTest', className: 'Obj'),
    ]);
    await tester.enterText(find.byType(TextField), 'passfail');
    await tester.pump();
    expect(
      find.textContaining('PassFailTest', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('Action', findRichText: true), findsNothing);
    expect(find.text('1/2'), findsOneWidget);
  });

  testWidgets('an empty palette says so honestly', (tester) async {
    await pump(tester, const []);
    expect(find.text('This file defines no types.'), findsOneWidget);
  });
}
