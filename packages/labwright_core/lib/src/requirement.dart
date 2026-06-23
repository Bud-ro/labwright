/// A reference from a test (a phase or measurement) to a requirement, pinned to
/// the requirement's content [hash] at the time the test was written.
///
/// `labwright_traceability` compares [hash] against the current requirement file:
/// a mismatch means the requirement changed since the test was authored (drift),
/// and the test should be re-reviewed.
class RequirementRef {
  const RequirementRef(this.id, {required this.hash});
  final String id;
  final String hash;

  Map<String, Object?> toJson() => {'id': id, 'hash': hash};
}

/// Wire format for a list of requirement refs flattened into a single string
/// field (e.g. a TDMS channel/group property): `id@hash; id@hash`.
/// [encodeRequirementRefs] and [decodeRequirementRefs] are inverses and define
/// this format in exactly one place, so embedders and readers can't drift.
String encodeRequirementRefs(Iterable<RequirementRef> refs) => refs.map((r) => '${r.id}@${r.hash}').join('; ');

/// Parses the [encodeRequirementRefs] format back into refs. Tolerant of extra
/// whitespace and a missing `@hash` (hash becomes empty).
List<RequirementRef> decodeRequirementRefs(String value) {
  final out = <RequirementRef>[];
  for (final part in value.split(';')) {
    final ref = part.trim();
    if (ref.isEmpty) continue;
    final at = ref.indexOf('@');
    out.add(at < 0 ? RequirementRef(ref, hash: '') : RequirementRef(ref.substring(0, at), hash: ref.substring(at + 1)));
  }
  return out;
}
