import 'package:flutter_test/flutter_test.dart';

import '../tool/prim_icon_extraction.dart';

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
