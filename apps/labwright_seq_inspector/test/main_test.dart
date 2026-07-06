import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_seq_inspector/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A minimal XML `.seq` with one flow-control block, so the Logic tab has real
/// nested pseudocode to render.
const _flowSeq = '''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>
  <typelist/>
  <Data classname='Obj'><subprops>
    <Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>
      <Sequence name='MainSequence' classname='Obj'><subprops>
        <Main classname='Objs'><value lbound='[0]' ubound='[3]'>
          <value><Step typename='NI_Flow_If' name='If'><subprops>
            <ConditionExpr classname='ExprValue'><value>Locals.X &gt; 0</value></ConditionExpr>
          </subprops></Step></value>
          <value><Step typename='Action' name='Do Work'/></value>
          <value><Step typename='NI_Flow_End' name='End'/></value>
        </value></Main>
      </subprops></Sequence>
    </value></value></Seq>
  </subprops></Data>
</teststandfileheader>''';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a parsed file exposes a Logic tab with the pseudocode export', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('lw_logic_tab');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/flow.seq')
      ..writeAsBytesSync([0xef, 0xbb, 0xbf, ..._flowSeq.codeUnits]);

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
