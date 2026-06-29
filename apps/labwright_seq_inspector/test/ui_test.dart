import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_seq_inspector/src/ui.dart';

void main() {
  test('monoStyle is the documented monospace base (family + 12pt)', () {
    expect(monoStyle.fontFamily, monoFamily);
    expect(monoStyle.fontSize, 12);
    // copyWith variants keep the family — the single source of truth holds.
    expect(monoStyle.copyWith(fontSize: 11).fontFamily, monoFamily);
    expect(monoStyle.copyWith(fontSize: 11).fontSize, 11);
  });
}
