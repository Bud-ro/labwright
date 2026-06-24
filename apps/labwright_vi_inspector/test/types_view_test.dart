import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/types_view.dart';
import 'package:labwright_videcode/labwright_videcode.dart';

ViModel _modelWithTypes() {
  final types = <ViType>[
    const ViType(index: 0, code: 0x21, kind: ViDataType.boolean, name: 'status'),
    const ViType(index: 1, code: 0x03, kind: ViDataType.i32, name: 'code'),
    const ViType(index: 2, code: 0x50, kind: ViDataType.cluster, name: 'error out', members: [0, 1]),
    const ViType(index: 3, code: 0x16, kind: ViDataType.enumU16, name: 'Direction', enumItems: ['Rising', 'Falling']),
  ];
  return ViModel(
    version: null,
    title: null,
    components: const [],
    stringTables: const [],
    heapRecords: const [],
    types: types,
  );
}

Future<void> _pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

void main() {
  testWidgets('renders enums with items and clusters with typed fields', (tester) async {
    await _pump(tester, ViTypesView(model: _modelWithTypes()));
    final text = tester.widget<SelectableText>(find.byType(SelectableText)).data!;
    expect(text, contains('enum Direction { Rising, Falling }'));
    expect(text, contains('error out {'));
    expect(text, contains('boolean status;'));
    expect(text, contains('i32 code;'));
  });

  testWidgets('font size can be increased and decreased', (tester) async {
    await _pump(tester, ViTypesView(model: _modelWithTypes()));
    double fontOf() => tester.widget<SelectableText>(find.byType(SelectableText)).style!.fontSize!;
    final initial = fontOf();
    await tester.tap(find.byTooltip('Larger text'));
    await tester.pump();
    expect(fontOf(), greaterThan(initial));
    await tester.tap(find.byTooltip('Smaller text'));
    await tester.pump();
    expect(fontOf(), initial);
  });

  testWidgets('shows an honest empty state when there are no types', (tester) async {
    await _pump(tester, const ViTypesView(model: null));
    expect(find.textContaining('No data types recovered'), findsOneWidget);
  });
}
