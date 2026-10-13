/// Format Into String's `%s`: [text] cut to [maxLength] characters when given, then padded with
/// spaces to [width], on the left unless [leftJustify].
String lvFormatText(String text, {int width = 0, bool leftJustify = false, int? maxLength}) {
  final cut = maxLength != null && text.length > maxLength ? text.substring(0, maxLength) : text;
  return _padded(cut, width: width, leftJustify: leftJustify, zeroPad: false, signed: false);
}

/// Format Into String's `%d`: [value] in decimal with its sign, padded to [width] with spaces, or
/// with zeros after the sign when [zeroPad] and not [leftJustify]; [plusSign] writes `+` on a
/// non-negative value.
String lvFormatInt(int value, {int width = 0, bool zeroPad = false, bool leftJustify = false, bool plusSign = false}) {
  final digits = value.abs().toString();
  final sign = value < 0
      ? '-'
      : plusSign
      ? '+'
      : '';
  return _padded('$sign$digits', width: width, leftJustify: leftJustify, zeroPad: zeroPad, signed: sign.isNotEmpty);
}

/// Format Into String's `%x`, `%o` and `%b`: [value] in [radix] as the unsigned [bits]-wide
/// pattern of its two's complement, padded to [width] with spaces or zeros, in upper case when
/// [upper].
String lvFormatRadix(
  int value,
  int radix,
  int bits, {
  int width = 0,
  bool zeroPad = false,
  bool leftJustify = false,
  bool upper = false,
}) {
  final digits = (bits < 64 ? value.toUnsigned(bits) : value).toRadixString(radix);
  final text = upper ? digits.toUpperCase() : digits;
  return _padded(text, width: width, leftJustify: leftJustify, zeroPad: zeroPad, signed: false);
}

/// Format Into String's `%f`: [value] with [precision] digits after the point, padded to [width]
/// with spaces, or with zeros after the sign when [zeroPad] and not [leftJustify]; [plusSign]
/// writes `+` on a non-negative value.
String lvFormatFixed(
  double value,
  int precision, {
  int width = 0,
  bool zeroPad = false,
  bool leftJustify = false,
  bool plusSign = false,
}) {
  final magnitude = value.abs().toStringAsFixed(precision);
  final sign = value.isNegative && !value.isNaN
      ? '-'
      : plusSign
      ? '+'
      : '';
  return _padded('$sign$magnitude', width: width, leftJustify: leftJustify, zeroPad: zeroPad, signed: sign.isNotEmpty);
}

String _padded(
  String text, {
  required int width,
  required bool leftJustify,
  required bool zeroPad,
  required bool signed,
}) {
  if (text.length >= width) return text;
  if (leftJustify) return text.padRight(width);
  if (!zeroPad) return text.padLeft(width);
  final sign = signed ? text.substring(0, 1) : '';
  return sign + text.substring(sign.length).padLeft(width - sign.length, '0');
}
