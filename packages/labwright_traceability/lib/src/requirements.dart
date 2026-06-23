/// One requirement loaded from the org's requirements file.
class RequirementSpec {
  const RequirementSpec({required this.id, required this.hash, this.text});
  final String id;
  final String hash;
  final String? text;
}

/// Parses requirements from already-decoded JSON, tolerant of common shapes:
///
/// - a top-level `List` of entry objects,
/// - a `Map` with a list under [listKey] (defaults to trying `requirements` then `entries`),
/// - a `Map` of `id -> entry` object.
///
/// Each entry supplies an id ([idKey]), content hash ([hashKey]), and optional
/// text ([textKey]). Returns a map keyed by requirement id.
Map<String, RequirementSpec> parseRequirements(
  Object? json, {
  String idKey = 'id',
  String hashKey = 'hash',
  String textKey = 'text',
  String? listKey,
}) {
  final entries = _entryList(json, idKey: idKey, listKey: listKey);

  final out = <String, RequirementSpec>{};
  for (final e in entries) {
    if (e is! Map) continue;
    final id = '${e[idKey]}';
    out[id] = RequirementSpec(
      id: id,
      hash: '${e[hashKey] ?? ''}',
      text: e[textKey]?.toString(),
    );
  }
  return out;
}

/// Pulls the raw requirement entries out of the supported JSON shapes (list,
/// map-with-list under [listKey], or map of `id -> entry`). Shared by
/// [parseRequirements] and [lintRequirements] so both see the same entries.
List<Object?> _entryList(Object? json, {String idKey = 'id', String? listKey}) {
  final entries = <Object?>[];
  if (json is List) {
    entries.addAll(json);
  } else if (json is Map) {
    final list = listKey != null ? json[listKey] : (json['requirements'] ?? json['entries']);
    if (list is List) {
      entries.addAll(list);
    } else {
      // Treat as a map of id -> entry.
      json.forEach((k, v) {
        if (v is Map) {
          entries.add({...v, idKey: v[idKey] ?? k});
        }
      });
    }
  }
  return entries;
}

/// Validates a decoded requirements file and returns human-readable issues
/// (empty = clean). Flags problems `parseRequirements` silently tolerates:
/// non-object entries, entries with no id, **duplicate ids** (later entries
/// overwrite earlier ones, so coverage can be silently lost), and missing/empty
/// hashes (which make hash-drift detection meaningless). Run it before gating CI
/// on the file.
List<String> lintRequirements(Object? json, {String idKey = 'id', String hashKey = 'hash', String? listKey}) {
  final issues = <String>[];
  if (json is! List && json is! Map) {
    issues.add('requirements must be a JSON list or object (got ${json.runtimeType})');
    return issues;
  }
  final entries = _entryList(json, idKey: idKey, listKey: listKey);
  if (entries.isEmpty) {
    issues.add('no requirement entries found');
    return issues;
  }
  final seen = <String>{};
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    if (e is! Map) {
      issues.add('entry $i is not an object (got ${e.runtimeType})');
      continue;
    }
    final rawId = e[idKey];
    if (rawId == null || '$rawId'.trim().isEmpty) {
      issues.add('entry $i has no "$idKey"');
      continue;
    }
    final id = '$rawId';
    if (!seen.add(id)) {
      issues.add('duplicate id "$id" (later entries overwrite earlier ones)');
    }
    final hash = e[hashKey];
    if (hash == null || '$hash'.trim().isEmpty) {
      issues.add('requirement "$id" has a missing/empty "$hashKey"');
    }
  }
  return issues;
}
