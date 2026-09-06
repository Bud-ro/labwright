import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_seq/labwright_seq.dart';
import 'package:labwright_seq_inspector/src/sequence_outline.dart';
import 'package:labwright_seq_inspector/src/sequences_view.dart';

import 'util.dart';

SeqOutline outlineWith(StepOutline s, {String seqComment = ''}) => SeqOutline([
  SequenceOutline(
    name: 'MainSequence',
    parameters: const [],
    locals: const [],
    groups: [
      StepGroupOutline('Main', [s]),
    ],
    comment: seqComment.isEmpty ? null : seqComment,
  ),
]);

Future<void> pump(WidgetTester tester, SeqOutline outline) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: SequencesView(outline: outline)),
  ),
);

void main() {
  group('adapterColor', () {
    const fallback = {SeqAdapter.none, SeqAdapter.unknown};

    test('keys are exactly the code-bearing adapters (enum drift)', () {
      for (final a in SeqAdapter.values) {
        expect(
          adapterColors.containsKey(a),
          !fallback.contains(a),
          reason: a.name,
        );
      }
    });

    test('resolves known adapters, falls back for the rest', () {
      expect(
        adapterColor(SeqAdapter.labView),
        adapterColors[SeqAdapter.labView],
      );
      expect(adapterColor(SeqAdapter.none), adapterFallbackColor);
      expect(adapterColor(SeqAdapter.unknown), adapterFallbackColor);
    });
  });

  group('step rendering', () {
    final rows = <(String, StepOutline, List<String>)>[
      (
        'forced run-mode badge for a Skip step',
        StepOutline(
          name: 'Skipped',
          type: 'Statement',
          runMode: 'Skip',
          notes: const [],
        ),
        ['Main', 'mode: Skip'],
      ),
      (
        'module call arguments mini-table',
        StepOutline(
          name: 'Get User',
          type: 'Action',
          adapter: SeqAdapter.cModule,
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
        ),
        [
          'Arguments',
          'LoginName (in)',
          'Return Value (out)',
          'FileGlobals.UserToAutoLogin',
          'Locals.userToLogin',
        ],
      ),
      (
        'units row inside the limits table',
        StepOutline(
          name: 'Check V',
          type: 'NumericLimitTest',
          limits: 'GELE [9, 11]',
          limitsDetail: LimitsOutline(comparison: 'GELE', low: '9', high: '11'),
          units: 'mA',
          notes: const [],
        ),
        ['Limits', 'Units', 'mA'],
      ),
      (
        'units chip when the step has no limits',
        StepOutline(
          name: 'Measure',
          type: 'Action',
          units: 'V',
          notes: const [],
        ),
        ['units V'],
      ),
      (
        'PassFailTest data-source chip',
        StepOutline(
          name: 'Motor running',
          type: 'PassFailTest',
          dataSource: 'Step.Result.PassFail',
          notes: const [],
        ),
        ['data-source Step.Result.PassFail'],
      ),
      (
        'step free-text comment',
        StepOutline(
          name: 'Lock',
          type: 'Action',
          comment: 'Lock sequence',
          notes: const [],
        ),
        ['Lock sequence'],
      ),
    ];
    for (final (name, s, texts) in rows) {
      testWidgets('renders $name', (tester) async {
        await pump(tester, outlineWith(s));
        for (final t in texts) {
          expect(find.text(t), findsOneWidget, reason: t);
        }
      });
    }

    testWidgets('a Normal step shows no run-mode badge', (tester) async {
      await pump(
        tester,
        outlineWith(
          StepOutline(name: 'Plain', type: 'Statement', notes: const []),
        ),
      );
      expect(find.text('Main'), findsOneWidget);
      expect(find.textContaining('mode:'), findsNothing);
    });

    testWidgets('renders a step status expression row', (tester) async {
      await pump(
        tester,
        outlineWith(
          StepOutline(
            name: 'Decide',
            type: 'Statement',
            expressions: const [('Status', 'Locals.x == 1')],
            notes: const [],
          ),
        ),
      );
      expect(
        find.textContaining('Locals.x == 1', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('renders a sequence free-text comment', (tester) async {
      await pump(
        tester,
        outlineWith(
          StepOutline(name: 's', type: 'Action', notes: const []),
          seqComment: 'Runs once at startup',
        ),
      );
      expect(find.text('Runs once at startup'), findsOneWidget);
    });

    testWidgets('a collapsed sequence comment shows as a subtitle preview', (
      tester,
    ) async {
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
      await pump(
        tester,
        SeqOutline([seq('First', null), seq('Second', 'Cleans up the DUT')]),
      );
      expect(find.text('Cleans up the DUT'), findsOneWidget);
    });

    testWidgets('very long recovered text wraps without overflow', (
      tester,
    ) async {
      final long = 'X${' word' * 200}';
      await pump(
        tester,
        outlineWith(
          StepOutline(
            name: 'Step',
            type: 'Action',
            comment: long,
            expressions: [('Status', long)],
            notes: const [],
          ),
          seqComment: long,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('flow-control nesting', () {
    final file = parseSeqFile(
      seqXml(
        ubound: '[6]',
        steps:
            step(
              'NI_Flow_If',
              'If',
              prop('ConditionExpr', 'Locals.X &gt; 0', 'ExprValue'),
            ) +
            step('Action', 'Do Work') +
            step('NI_Flow_End', 'End') +
            step(
              'NI_Flow_ForEach',
              'For Each',
              prop('ArrayExpr', 'Locals.Items', 'ExprValue') +
                  prop('ArrayElementExpr', 'Locals.Item', 'ExprValue'),
            ) +
            step('Action', 'Process') +
            step('NI_Flow_End', 'End'),
      ),
    );

    test('flowHeader + flowDepth are computed for NI_Flow_* steps', () {
      final steps = SeqOutline.of(file).sequences.single.groups.single.steps;
      expect(steps.map((s) => s.flowHeader), [
        'if (Locals.X > 0)',
        null,
        'end',
        'for each (Locals.Item in Locals.Items)',
        null,
        'end',
      ]);
      expect(steps.map((s) => s.flowDepth), [0, 1, 0, 0, 1, 0]);
    });

    test('the flow header is searchable', () {
      final steps = SeqOutline.of(file).sequences.single.groups.single.steps;
      expect(stepMatches(steps.first, 'for each'), isFalse);
      expect(stepMatches(steps.first, 'if (locals'), isTrue);
    });

    testWidgets('renders the flow-control header chips', (tester) async {
      await pump(tester, SeqOutline.of(file));
      expect(find.text('if (Locals.X > 0)'), findsOneWidget);
      expect(
        find.text('for each (Locals.Item in Locals.Items)'),
        findsOneWidget,
      );
    });
  });
}
