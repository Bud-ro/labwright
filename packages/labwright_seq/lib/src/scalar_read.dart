library;

import 'seq_property.dart';

String? nonEmpty(String? value) => (value == null || value.isEmpty) ? null : value;

List<String> scalarValues(SeqProperty? container) => [
  for (final element in container?.array ?? const <SeqProperty>[])
    if (nonEmpty(element.scalar) case final s?) s,
];

bool? parseFlag(String? text) => parseFlagStrict(text?.toLowerCase());

bool? parseFlagStrict(String? text) => switch (text) {
  'true' || '1' => true,
  'false' || '0' => false,
  _ => null,
};

String? unwrapExprString(String? expr) {
  if (expr == null) return null;
  final trimmed = expr.trim();
  if (trimmed.length >= 4 && trimmed.startsWith(r'\"') && trimmed.endsWith(r'\"')) {
    return trimmed.substring(2, trimmed.length - 2);
  }
  if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}
