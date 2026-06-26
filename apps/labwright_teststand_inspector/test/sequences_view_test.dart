import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_teststand/labwright_teststand.dart';
import 'package:labwright_teststand_inspector/src/sequence_outline.dart';
import 'package:labwright_teststand_inspector/src/sequences_view.dart';

void main() {
  group('adapterColor', () {
    // The adapters that name a code module (and so get a distinct chip color).
    // none/unknown are flow-control / not-yet-recognized and use the fallback.
    const fallbackAdapters = {SeqAdapter.none, SeqAdapter.unknown};

    test('every code-bearing SeqAdapter has a color (catches enum drift)', () {
      for (final a in SeqAdapter.values) {
        if (fallbackAdapters.contains(a)) {
          expect(adapterColors.containsKey(a.name), isFalse,
              reason: '${a.name} should fall back, not have a color');
        } else {
          expect(adapterColors.containsKey(a.name), isTrue,
              reason: '${a.name} is missing a chip color');
        }
      }
    });

    test('color keys are exactly SeqAdapter names (no stale/typo keys)', () {
      final names = {for (final a in SeqAdapter.values) a.name};
      expect(names.containsAll(adapterColors.keys), isTrue);
    });

    test('resolves known adapters, falls back for the rest', () {
      expect(adapterColor(SeqAdapter.labView.name),
          adapterColors[SeqAdapter.labView.name]);
      expect(adapterColor(SeqAdapter.none.name), adapterFallbackColor);
      expect(adapterColor('not-an-adapter'), adapterFallbackColor);
    });
  });

  group('SequencesView step rendering', () {
    SeqOutline outlineWith(StepOutline step) => SeqOutline([
          SequenceOutline(
            name: 'MainSequence',
            parameters: const [],
            locals: const [],
            groups: [StepGroupOutline('Main', [step])],
          ),
        ]);

    Future<void> pump(WidgetTester tester, SeqOutline outline) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(body: SequencesView(outline: outline)),
        ));

    testWidgets('renders a forced run-mode badge for a Skip step',
        (tester) async {
      await pump(
        tester,
        outlineWith(StepOutline(
          name: 'Skipped',
          type: 'Statement',
          runMode: 'Skip',
          notes: const [],
        )),
      );
      // The first sequence is expanded by default, so the Main group + step
      // render (the step name itself is a RichText, hence the group anchor).
      expect(find.text('Main'), findsOneWidget);
      expect(find.text('mode: Skip'), findsOneWidget);
    });

    testWidgets('a Normal step shows no run-mode badge', (tester) async {
      await pump(
        tester,
        outlineWith(StepOutline(
          name: 'Plain',
          type: 'Statement',
          notes: const [],
        )),
      );
      expect(find.text('Main'), findsOneWidget);
      expect(find.textContaining('mode:'), findsNothing);
    });

    testWidgets('renders a step status expression row', (tester) async {
      await pump(
        tester,
        outlineWith(StepOutline(
          name: 'Decide',
          type: 'Statement',
          expressions: const [('Status', 'Locals.x == 1')],
          notes: const [],
        )),
      );
      expect(
        find.textContaining('Locals.x == 1', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('renders a module call arguments mini-table', (tester) async {
      await pump(
        tester,
        outlineWith(StepOutline(
          name: 'Get User',
          type: 'Action',
          adapter: SeqAdapter.cModule.name,
          target: 'Engine.GetUser',
          callArgs: [
            CallArgOutline(
              name: 'LoginName',
              direction: 'in',
              boundExpression: 'FileGlobals.UserToAutoLogin',
              displayType: 'String',
            ),
            CallArgOutline(
              name: 'Return Value',
              direction: 'out',
              boundExpression: 'Locals.userToLogin',
              displayType: 'User (Object Reference)',
            ),
          ],
          notes: const [],
        )),
      );
      expect(find.text('Arguments'), findsOneWidget);
      // Direction-tagged labels and the bound expressions both render.
      expect(find.text('LoginName (in)'), findsOneWidget);
      expect(find.text('Return Value (out)'), findsOneWidget);
      expect(find.text('FileGlobals.UserToAutoLogin'), findsOneWidget);
      expect(find.text('Locals.userToLogin'), findsOneWidget);
    });

    testWidgets('shows recorded units as a row in the limits table',
        (tester) async {
      await pump(
        tester,
        outlineWith(StepOutline(
          name: 'Check V',
          type: 'NumericLimitTest',
          limits: 'GELE [9, 11]',
          limitsDetail: LimitsOutline(comparison: 'GELE', low: '9', high: '11'),
          units: 'mA',
          notes: const [],
        )),
      );
      expect(find.text('Limits'), findsOneWidget);
      expect(find.text('Units'), findsOneWidget); // the row label
      expect(find.text('mA'), findsOneWidget); // the value
    });

    testWidgets('shows recorded units as a chip when the step has no limits',
        (tester) async {
      await pump(
        tester,
        outlineWith(StepOutline(
          name: 'Measure',
          type: 'Action',
          units: 'V',
          notes: const [],
        )),
      );
      expect(find.text('units V'), findsOneWidget);
    });

    testWidgets('shows a PassFailTest data-source criterion as a chip',
        (tester) async {
      await pump(
        tester,
        outlineWith(StepOutline(
          name: 'Motor running',
          type: 'PassFailTest',
          dataSource: 'Step.Result.PassFail',
          notes: const [],
        )),
      );
      expect(find.text('data-source Step.Result.PassFail'), findsOneWidget);
    });

    testWidgets('renders a step free-text comment', (tester) async {
      await pump(
        tester,
        outlineWith(StepOutline(
          name: 'Lock',
          type: 'Action',
          comment: 'Lock sequence',
          notes: const [],
        )),
      );
      expect(find.text('Lock sequence'), findsOneWidget);
    });

    testWidgets('renders a sequence free-text comment', (tester) async {
      await pump(
        tester,
        SeqOutline([
          SequenceOutline(
            name: 'Startup',
            parameters: const [],
            locals: const [],
            groups: [
              StepGroupOutline('Main', [
                StepOutline(name: 's', type: 'Action', notes: const []),
              ]),
            ],
            comment: 'Runs once at startup',
          ),
        ]),
      );
      expect(find.text('Runs once at startup'), findsOneWidget);
    });

    testWidgets('shows a collapsed sequence comment as a subtitle preview',
        (tester) async {
      SequenceOutline seq(String name, String? comment) => SequenceOutline(
            name: name,
            parameters: const [],
            locals: const [],
            groups: [
              StepGroupOutline('Main', [
                StepOutline(name: '$name-s', type: 'Action', notes: const []),
              ]),
            ],
            comment: comment,
          );
      // Two sequences: only the first is expanded by default, so the second's
      // comment is visible solely via its collapsed subtitle preview.
      await pump(
        tester,
        SeqOutline([seq('First', null), seq('Second', 'Cleans up the DUT')]),
      );
      expect(find.text('Cleans up the DUT'), findsOneWidget);
    });

    testWidgets('very long recovered text wraps without overflow',
        (tester) async {
      final long = 'X${' word' * 200}'; // ~1000 chars, no hard breaks
      await pump(
        tester,
        SeqOutline([
          SequenceOutline(
            name: 'Seq',
            parameters: const [],
            locals: const [],
            groups: [
              StepGroupOutline('Main', [
                StepOutline(
                  name: 'Step',
                  type: 'Action',
                  comment: long,
                  expressions: [('Status', long)],
                  notes: const [],
                ),
              ]),
            ],
            comment: long,
          ),
        ]),
      );
      // A RenderFlex/text overflow surfaces as a thrown exception during layout;
      // assert none occurred (the comment/expression rows must wrap, not clip).
      expect(tester.takeException(), isNull);
    });
  });

  group('flow-control nesting in the outline', () {
    SeqFile parse(String xml) => parseSeqFile(Uint8List.fromList([
          0xef, 0xbb, 0xbf, // BOM
          ...xml.codeUnits,
        ]));

    // if { action } end ; for each { action } end — balanced blocks.
    final file = parse('''<?xml version="1.0" encoding="UTF-8"?>
<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>
  <typelist/>
  <Data classname='Obj'><subprops>
    <Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>
      <Sequence name='MainSequence' classname='Obj'><subprops>
        <Main classname='Objs'><value lbound='[0]' ubound='[6]'>
          <value><Step typename='NI_Flow_If' name='If'><subprops>
            <ConditionExpr classname='ExprValue'><value>Locals.X &gt; 0</value></ConditionExpr>
          </subprops></Step></value>
          <value><Step typename='Action' name='Do Work'/></value>
          <value><Step typename='NI_Flow_End' name='End'/></value>
          <value><Step typename='NI_Flow_ForEach' name='For Each'><subprops>
            <ArrayExpr classname='ExprValue'><value>Locals.Items</value></ArrayExpr>
            <ArrayElementExpr classname='ExprValue'><value>Locals.Item</value></ArrayElementExpr>
          </subprops></Step></value>
          <value><Step typename='Action' name='Process'/></value>
          <value><Step typename='NI_Flow_End' name='End'/></value>
        </value></Main>
      </subprops></Sequence>
    </value></value></Seq>
  </subprops></Data>
</teststandfileheader>''');

    test('flowHeader + flowDepth are computed for NI_Flow_* steps', () {
      final steps = SeqOutline.of(file).sequences.single.groups.single.steps;
      expect(steps.map((s) => s.flowHeader), [
        'if (Locals.X > 0)',
        null, // inner action
        'end',
        'for each (Locals.Item in Locals.Items)',
        null, // inner action
        'end',
      ]);
      // The body of each block indents one level; the opener/end sit at level 0.
      expect(steps.map((s) => s.flowDepth), [0, 1, 0, 0, 1, 0]);
    });

    test('the flow header is searchable', () {
      final steps = SeqOutline.of(file).sequences.single.groups.single.steps;
      expect(stepMatches(steps.first, 'for each'), isFalse);
      expect(stepMatches(steps.first, 'if (locals'), isTrue);
    });

    testWidgets('renders the flow-control header chip', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SequencesView(outline: SeqOutline.of(file))),
      ));
      expect(find.text('if (Locals.X > 0)'), findsOneWidget);
      expect(find.text('for each (Locals.Item in Locals.Items)'), findsOneWidget);
    });
  });
}
