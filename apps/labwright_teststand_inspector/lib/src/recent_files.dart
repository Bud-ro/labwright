/// Recent-files list management — a Flutter-free, unit-testable helper.
///
/// In-memory only for now (lost on restart); persisting it (e.g. via
/// shared_preferences) is a future idea.

/// Returns a new list with [path] at the front, most-recent-first: any existing
/// occurrence is removed first (dedup), then the list is capped at [cap]. The
/// input list is not mutated. Pure.
List<String> addRecent(List<String> current, String path, {int cap = 8}) {
  final out = <String>[path, ...current.where((p) => p != path)];
  if (out.length > cap) out.removeRange(cap, out.length);
  return out;
}
