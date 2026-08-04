import 'package:flutter_test/flutter_test.dart';

import '../tool/prim_icon_extraction.dart';

/// The reproducibility contract on the primitive-icon assets: a key marked
/// verified in the review catalog is pipeline ground truth, so a sweep of the
/// snippet corpus must reproduce its committed pixels exactly or produce
/// nothing at all. A different extraction for a verified key fails here, so an
/// algorithm change can never silently alter a verified asset.
///
/// The generator that writes the assets is tool/extract_prim_icons.dart.
void main() {
  testWidgets('verified icons reproduce pixel-for-pixel', (tester) async {
    final extraction = await extractPrimIcons(tester);
    if (extraction == null) {
      markTestSkipped('snippet corpus not fetched');
      return;
    }
    final errors = primIconReproErrors(extraction);
    expect(
      errors,
      isEmpty,
      reason:
          'the extraction algorithm no longer reproduces verified icons:\n'
          '${errors.join('\n')}',
    );
  });
}
