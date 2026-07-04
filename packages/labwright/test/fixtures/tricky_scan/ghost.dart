// Genuinely unplugged. Other files mention this one ONLY inside comments
// and string literals — a text-match walk would think it is imported; the
// AST walk must still flag it.
import 'package:labwright/labwright.dart';

void register() {
  test('the forgotten ghost', () {
    expect(true, isTrue);
  });
}
