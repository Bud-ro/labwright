/// Small readers for TestStand scalar property values, shared by the typed
/// lens modules (`seq_file` / `seq_step` / `seq_module` / `seq_typedefs`).
library;

import 'seq_property.dart';

String? nonEmpty(String? s) => (s == null || s.isEmpty) ? null : s;

/// Collects the non-empty scalar values of an array-property container (a
/// `Links`/`EditPanels` list, …), skipping null/empty elements. Empty when the
/// container is null or holds no array.
List<String> scalarValues(SeqProperty? container) => [
      for (final e in container?.array ?? const <SeqProperty>[])
        if (nonEmpty(e.scalar) case final s?) s,
    ];

/// Parses a TestStand boolean stored either as `true`/`false` (XML, any case) or
/// `1`/`0` (some numeric flags). null when absent or unrecognized.
bool? parseFlag(String? s) => parseFlagStrict(s?.toLowerCase());

/// A strict (case-sensitive) TestStand boolean: `true`/`1` → true, `false`/`0` →
/// false, everything else (including uppercase) → null. The non-lowercasing
/// counterpart to [parseFlag].
bool? parseFlagStrict(String? s) => switch (s) {
      'true' || '1' => true,
      'false' || '0' => false,
      _ => null,
    };

/// Unwraps a TestStand string-literal expression for display: strips one layer of
/// surrounding quotes, whether backslash-escaped (`\"…\"`, as the INI form stores
/// a quoted target after its own outer quotes are removed) or plain (`"…"`).
/// Returns the input unchanged when it is not a wrapped string literal, and null
/// for null. Used for flow-action targets like `\"<Cleanup>\"` → `<Cleanup>`.
String? unwrapExprString(String? s) {
  if (s == null) return null;
  final t = s.trim();
  if (t.length >= 4 && t.startsWith(r'\"') && t.endsWith(r'\"')) {
    return t.substring(2, t.length - 2);
  }
  if (t.length >= 2 && t.startsWith('"') && t.endsWith('"')) {
    return t.substring(1, t.length - 1);
  }
  return t;
}
