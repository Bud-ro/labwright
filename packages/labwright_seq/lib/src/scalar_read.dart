/// Small readers for TestStand scalar property values, shared by the typed
/// lens modules (`seq_file` / `seq_step` / `seq_module` / `seq_typedefs`).
library;

import 'seq_property.dart';

String? nonEmpty(String? value) => (value == null || value.isEmpty) ? null : value;

/// Collects the non-empty scalar values of an array-property container (a
/// `Links`/`EditPanels` list, …), skipping null/empty elements. Empty when the
/// container is null or holds no array.
List<String> scalarValues(SeqProperty? container) => [
      for (final element in container?.array ?? const <SeqProperty>[])
        if (nonEmpty(element.scalar) case final s?) s,
    ];

/// Parses a TestStand boolean stored either as `true`/`false` (XML, any case) or
/// `1`/`0` (some numeric flags). null when absent or unrecognized.
bool? parseFlag(String? text) => parseFlagStrict(text?.toLowerCase());

/// A strict (case-sensitive) TestStand boolean: `true`/`1` → true, `false`/`0` →
/// false, everything else (including uppercase) → null. The non-lowercasing
/// counterpart to [parseFlag].
bool? parseFlagStrict(String? text) => switch (text) {
      'true' || '1' => true,
      'false' || '0' => false,
      _ => null,
    };

/// Unwraps a TestStand string-literal expression for display: strips one layer of
/// surrounding quotes, whether backslash-escaped (`\"…\"`, as the INI form stores
/// a quoted target after its own outer quotes are removed) or plain (`"…"`).
/// Returns the input unchanged when it is not a wrapped string literal, and null
/// for null. Used for flow-action targets like `\"<Cleanup>\"` → `<Cleanup>`.
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
