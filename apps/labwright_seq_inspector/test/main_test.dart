import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_seq_inspector/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'util.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a parsed file exposes a Logic tab with the pseudocode export', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('lw_logic_tab');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/flow.seq')
      ..writeAsBytesSync(
        seqXml(
          ubound: '[3]',
          steps:
              step(
                'NI_Flow_If',
                'If',
                prop('ConditionExpr', 'Locals.X &gt; 0', 'ExprValue'),
              ) +
              step('Action', 'Do Work') +
              step('NI_Flow_End', 'End'),
        ),
      );

    await tester.pumpWidget(InspectorApp(initialPath: f.path));
    await tester.pumpAndSettle();
    expect(find.text('Logic'), findsOneWidget);
    expect(find.text('Dump'), findsOneWidget);

    await tester.tap(find.text('Logic'));
    await tester.pumpAndSettle();
    expect(find.textContaining('if (Locals.X > 0) {'), findsOneWidget);
  });

  testWidgets('with no file loaded there is only the Dump tab (no Logic)', (
    tester,
  ) async {
    await tester.pumpWidget(const InspectorApp());
    await tester.pumpAndSettle();
    expect(find.text('Dump'), findsOneWidget);
    expect(find.text('Logic'), findsNothing);
  });
}
