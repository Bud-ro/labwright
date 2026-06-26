import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_teststand/labwright_teststand.dart';
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
}
