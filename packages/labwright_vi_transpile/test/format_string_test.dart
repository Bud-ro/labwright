import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

void main() {
  test('a format string reads into literals and specifiers', () {
    final pieces = lvFormatPieces(r'Temp: %5.1f%% at %2$s\n%-03dx%02X')!;
    expect(pieces, hasLength(8));
    expect((pieces[0] as LvFormatLiteral).text, 'Temp: ');
    final fixed = pieces[1] as LvFormatSpecifier;
    expect((fixed.conversion, fixed.width, fixed.precision), (LvFormatConversion.fixed, 5, 1));
    expect((pieces[2] as LvFormatLiteral).text, '% at ');
    final second = pieces[3] as LvFormatSpecifier;
    expect((second.conversion, second.argument), (LvFormatConversion.text, 1));
    expect((pieces[4] as LvFormatLiteral).text, '\n');
    final decimal = pieces[5] as LvFormatSpecifier;
    expect((decimal.leftJustify, decimal.zeroPad, decimal.width), (true, true, 3));
    expect((pieces[6] as LvFormatLiteral).text, 'x');
    final hex = pieces[7] as LvFormatSpecifier;
    expect((hex.conversion, hex.zeroPad, hex.width), (LvFormatConversion.hexadecimalUpper, true, 2));
    expect((lvFormatPieces(r'a\\b\s\41')!.single as LvFormatLiteral).text, r'a\b A');
    for (final unreadable in ['%g', '%e', '%#d', '%^.3e', '%.2p', '%_2p', r'\q', '%', '%5.', '%{mN}f']) {
      expect(lvFormatPieces(unreadable), isNull, reason: unreadable);
    }
  });

  test('a Dart string literal escapes what Dart would read', () {
    expect(lvDartStringLiteral("it's \$x\\\n"), r"'it\'s \$x\\\n'");
  });
}
