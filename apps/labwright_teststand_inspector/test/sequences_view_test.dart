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
  });
}
