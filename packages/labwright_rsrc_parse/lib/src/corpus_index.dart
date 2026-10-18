/// The corpus index: one record per LabVIEW file in a corpus repository, naming what the file
/// holds by the raw ids the file stores, and a search over those records that resolves the ids
/// through the parser's catalogues.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../labwright_rsrc_parse.dart';

/// The files an index records, by extension.
enum CorpusFileType {
  vi('vi', 'VI'),
  control('ctl', 'Control'),
  malleableVi('vim', 'Malleable VI'),
  templateVi('vit', 'VI template'),
  templateControl('ctt', 'Control template'),
  libraryArchive('llb', 'VI library archive'),
  library('lvlib', 'Library'),
  lvClass('lvclass', 'Class'),
  xControl('xctl', 'XControl'),
  project('lvproj', 'Project'),
  snippet('png', 'VI snippet');

  const CorpusFileType(this.extension, this.label);

  /// The extension without its dot, which is also the type's name in the index.
  final String extension;

  final String label;

  /// Whether the file is an RSRC container read by [parseVi].
  bool get isRsrc => switch (this) {
    vi || control || malleableVi || templateVi || templateControl || libraryArchive || snippet => true,
    library || lvClass || xControl || project => false,
  };

  /// Whether the file is one of the XML library files [LvLibraryFile] reads.
  bool get isXml => !isRsrc;

  static CorpusFileType? ofPath(String path) {
    final slash = path.lastIndexOf('/');
    final dot = path.lastIndexOf('.');
    if (dot <= slash) return null;
    return ofExtension(path.substring(dot + 1).toLowerCase());
  }

  static CorpusFileType? ofExtension(String extension) {
    for (final type in values) {
      if (type.extension == extension) return type;
    }
    return null;
  }
}

/// One indexed file: where it is, what it is, and the ids it stores, with [prims], [bdClasses]
/// and [fpClasses] counting how many objects carry each `primResID` or class code. The names
/// behind those ids come from [PrimOp], [BdObjectClass] and [FpObjectClass] when searched, so
/// the index stays the same while the catalogues grow.
class CorpusIndexEntry {
  const CorpusIndexEntry({
    required this.path,
    required this.bytes,
    required this.type,
    this.name,
    this.version,
    this.prims = const {},
    this.bdClasses = const {},
    this.fpClasses = const {},
    this.subVis = const [],
    this.libraries = const [],
    this.members = const [],
    this.error,
  });

  factory CorpusIndexEntry.fromJson(Map<String, dynamic> json) {
    Map<int, int> counts(String key) => {
      for (final MapEntry(:key, :value) in ((json[key] as Map?) ?? const {}).entries)
        int.parse(key as String): value as int,
    };
    List<String> names(String key) => ((json[key] as List?) ?? const []).cast<String>();
    return CorpusIndexEntry(
      path: json['path'] as String,
      bytes: json['bytes'] as int,
      type: CorpusFileType.ofExtension(json['type'] as String) ?? CorpusFileType.vi,
      name: json['name'] as String?,
      version: json['version'] as String?,
      prims: counts('prims'),
      bdClasses: counts('bd'),
      fpClasses: counts('fp'),
      subVis: names('subVis'),
      libraries: names('libraries'),
      members: names('members'),
      error: json['error'] as String?,
    );
  }

  /// The file's path relative to the index file's directory, with `/` separators.
  final String path;

  final int bytes;

  final CorpusFileType type;

  /// The VI name the file records, or a library file's name.
  final String? name;

  /// The LabVIEW version that saved the file.
  final String? version;

  /// Objects per `primResID`.
  final Map<int, int> prims;

  /// Block-diagram objects per class code.
  final Map<int, int> bdClasses;

  /// Front-panel objects per class code.
  final Map<int, int> fpClasses;

  /// Sub-VI names from the link info.
  final List<String> subVis;

  /// The owning library names from `LIBN`.
  final List<String> libraries;

  /// A library file's member item names: the items that point at a file.
  final List<String> members;

  /// Why the file did not parse, when it did not.
  final String? error;

  /// The file's own name: the last path segment.
  String get fileName => path.substring(path.lastIndexOf('/') + 1);

  /// This record at [path].
  CorpusIndexEntry withPath(String path) => CorpusIndexEntry(
    path: path,
    bytes: bytes,
    type: type,
    name: name,
    version: version,
    prims: prims,
    bdClasses: bdClasses,
    fpClasses: fpClasses,
    subVis: subVis,
    libraries: libraries,
    members: members,
    error: error,
  );

  bool get isSnippet => type == CorpusFileType.snippet;

  Map<String, Object?> toJson() {
    Map<String, int> counts(Map<int, int> map) => {
      for (final code in map.keys.toList()..sort()) '$code': map[code]!,
    };
    return {
      'path': path,
      'bytes': bytes,
      'type': type.extension,
      if (name != null) 'name': name,
      if (version != null) 'version': version,
      if (prims.isNotEmpty) 'prims': counts(prims),
      if (bdClasses.isNotEmpty) 'bd': counts(bdClasses),
      if (fpClasses.isNotEmpty) 'fp': counts(fpClasses),
      if (subVis.isNotEmpty) 'subVis': subVis,
      if (libraries.isNotEmpty) 'libraries': libraries,
      if (members.isNotEmpty) 'members': members,
      if (error != null) 'error': error,
    };
  }
}

/// The record for the file at [path] holding [bytes], or null for a PNG that carries no VI.
CorpusIndexEntry? indexCorpusFile(String path, Uint8List bytes) {
  final type = CorpusFileType.ofPath(path);
  if (type == null) return null;
  if (type.isXml) return _indexXml(path, bytes, type);
  var vi = bytes;
  if (type == CorpusFileType.snippet) {
    final embedded = extractSnippetVi(bytes);
    if (embedded == null) return null;
    vi = embedded;
  }
  try {
    final summary = parseVi(vi);
    final sections = readViSections(vi);
    final version = versionFromSections(sections);
    final decoded = [for (final section in sections) inflateSection(section)];
    final model = buildViModelFromDecoded(decoded, subViNames: subViNamesOf(sections, vi));
    final prims = <int, int>{};
    final bd = <int, int>{};
    for (final diagram in model.blockDiagrams) {
      for (final object in diagram.objects) {
        bd.update(object.kind, (n) => n + 1, ifAbsent: () => 1);
        final id = object.primitive?.primResId;
        if (id != null) prims.update(id, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    final fp = <int, int>{};
    for (final panel in model.frontPanels) {
      for (final object in panel.objects) {
        fp.update(object.kind, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    return CorpusIndexEntry(
      path: path,
      bytes: bytes.length,
      type: type,
      name: summary.name ?? version.title,
      version: version.version,
      prims: prims,
      bdClasses: bd,
      fpClasses: fp,
      subVis: _distinct(model.subViNames),
      libraries: _distinct(readOwningLibraryNames(vi)),
    );
  } catch (e) {
    return CorpusIndexEntry(path: path, bytes: bytes.length, type: type, error: _oneLine(e));
  }
}

CorpusIndexEntry _indexXml(String path, Uint8List bytes, CorpusFileType type) {
  final fileName = path.substring(path.lastIndexOf('/') + 1);
  try {
    final library = LvLibraryFile.parse(utf8.decode(bytes, allowMalformed: true), fileName: fileName);
    return CorpusIndexEntry(
      path: path,
      bytes: bytes.length,
      type: type,
      name: fileName,
      members: _distinct([
        for (final item in library.items)
          if (item.url != null) item.name,
      ]),
    );
  } catch (e) {
    return CorpusIndexEntry(path: path, bytes: bytes.length, type: type, name: fileName, error: _oneLine(e));
  }
}

List<String> _distinct(Iterable<String> names) {
  final seen = <String>{};
  return [
    for (final name in names)
      if (seen.add(name)) name,
  ];
}

String _oneLine(Object error) {
  final text = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.length > 200 ? '${text.substring(0, 200)}…' : text;
}

/// An `index.json`: the records of every indexed file under its directory, sorted by path.
class CorpusIndex {
  CorpusIndex(List<CorpusIndexEntry> entries) : entries = [...entries]..sort((a, b) => a.path.compareTo(b.path));

  factory CorpusIndex.decode(String json) {
    final map = jsonDecode(json) as Map<String, dynamic>;
    final format = map['format'];
    if (format != currentFormat) throw FormatException('index format $format, expected $currentFormat');
    return CorpusIndex([
      for (final file in (map['files'] as List).cast<Map<String, dynamic>>()) CorpusIndexEntry.fromJson(file),
    ]);
  }

  static const fileName = 'index.json';

  static const currentFormat = 1;

  final List<CorpusIndexEntry> entries;

  /// The file text: one record per line so that diffs name the files that changed.
  String encode() {
    final out = StringBuffer('{"format": $currentFormat, "files": [');
    for (var i = 0; i < entries.length; i++) {
      out
        ..write(i == 0 ? '\n' : ',\n')
        ..write(jsonEncode(entries[i].toJson()));
    }
    out.write(entries.isEmpty ? ']}\n' : '\n]}\n');
    return out.toString();
  }
}

/// Where a search term matched a record.
enum CorpusMatchField {
  name('name'),
  path('path'),
  primitive('prim'),
  blockDiagramClass('class'),
  frontPanelClass('class'),
  subVi('sub'),
  library('lib'),
  member('member'),
  version('version'),
  type('type');

  const CorpusMatchField(this.prefix);

  /// The `prefix:` a term uses to search this field alone; the two class fields share one.
  final String prefix;

  static Set<CorpusMatchField> ofPrefix(String prefix) => {
    for (final field in values)
      if (field.prefix == prefix) field,
  };
}

/// One field value a term matched, as the record shows it.
class CorpusMatch {
  const CorpusMatch(this.field, this.text);

  final CorpusMatchField field;

  final String text;

  @override
  bool operator ==(Object other) => other is CorpusMatch && other.field == field && other.text == text;

  @override
  int get hashCode => Object.hash(field, text);

  @override
  String toString() => '${field.name}: $text';
}

/// A record that satisfied every term of a query, with what each term matched.
class CorpusSearchHit {
  const CorpusSearchHit(this.entry, this.matches, this.score);

  final CorpusIndexEntry entry;

  final List<CorpusMatch> matches;

  /// Higher for matches on the file's own name and for exact field values.
  final int score;
}

/// A term of a query: text to find, in one set of fields or in all.
class CorpusQueryTerm {
  const CorpusQueryTerm(this.text, {this.fields});

  final String text;

  final Set<CorpusMatchField>? fields;

  /// The terms of [query]: whitespace-separated, double quotes grouping, `prefix:` naming a
  /// [CorpusMatchField.prefix].
  static List<CorpusQueryTerm> parse(String query) {
    final terms = <CorpusQueryTerm>[];
    for (final raw in _tokens(query)) {
      final colon = raw.indexOf(':');
      final fields = colon > 0
          ? CorpusMatchField.ofPrefix(raw.substring(0, colon).toLowerCase())
          : const <CorpusMatchField>{};
      final text = (fields.isEmpty ? raw : raw.substring(colon + 1)).toLowerCase();
      if (text.isEmpty) continue;
      terms.add(CorpusQueryTerm(text, fields: fields.isEmpty ? null : fields));
    }
    return terms;
  }

  static Iterable<String> _tokens(String query) sync* {
    final buffer = StringBuffer();
    var quoted = false;
    for (final rune in query.runes) {
      final char = String.fromCharCode(rune);
      if (char == '"') {
        quoted = !quoted;
      } else if (!quoted && char.trim().isEmpty) {
        if (buffer.isNotEmpty) yield buffer.toString();
        buffer.clear();
      } else {
        buffer.write(char);
      }
    }
    if (buffer.isNotEmpty) yield buffer.toString();
  }
}

class _Field {
  const _Field(this.field, this.text, this.display, this.weight);

  final CorpusMatchField field;

  final String text;

  final String display;

  final int weight;
}

class _Document {
  _Document(this.entry, this.fields);

  final CorpusIndexEntry entry;

  final List<_Field> fields;
}

/// A search over index records. Every term must match; a term matches a field whose text
/// contains it, case-insensitively, with primitive ids and class codes matched by their
/// catalogue names as well as their numbers.
class CorpusSearch {
  CorpusSearch(Iterable<CorpusIndexEntry> entries) : _documents = [for (final entry in entries) _document(entry)];

  final List<_Document> _documents;

  int get length => _documents.length;

  Iterable<CorpusIndexEntry> get entries => _documents.map((d) => d.entry);

  /// The records matching [query], best first; [types] keeps only those file types and
  /// [snippets] only snippets (true) or only files that are not snippets (false).
  List<CorpusSearchHit> search(String query, {Set<CorpusFileType>? types, bool? snippets}) {
    final terms = CorpusQueryTerm.parse(query);
    final hits = <CorpusSearchHit>[];
    for (final document in _documents) {
      final entry = document.entry;
      if (types != null && !types.contains(entry.type)) continue;
      if (snippets != null && entry.isSnippet != snippets) continue;
      final matches = <CorpusMatch>[];
      var score = 0;
      var all = true;
      for (final term in terms) {
        var best = 0;
        for (final field in document.fields) {
          if (term.fields != null && !term.fields!.contains(field.field)) continue;
          if (!field.text.contains(term.text)) continue;
          final exact = field.text == term.text;
          final weight = field.weight * (exact ? 3 : 1);
          if (weight > best) best = weight;
          final match = CorpusMatch(field.field, field.display);
          if (!matches.contains(match)) matches.add(match);
        }
        if (best == 0) {
          all = false;
          break;
        }
        score += best;
      }
      if (all) hits.add(CorpusSearchHit(entry, matches, score));
    }
    hits.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.entry.path.compareTo(b.entry.path);
    });
    return hits;
  }

  static _Document _document(CorpusIndexEntry entry) {
    final fields = <_Field>[
      _Field(CorpusMatchField.path, entry.path.toLowerCase(), entry.path, 2),
      _Field(CorpusMatchField.name, entry.fileName.toLowerCase(), entry.fileName, 4),
      _Field(CorpusMatchField.type, entry.type.extension, entry.type.label, 1),
      _Field(CorpusMatchField.type, entry.type.label.toLowerCase(), entry.type.label, 1),
      if (entry.isSnippet) _Field(CorpusMatchField.type, 'snippet', entry.type.label, 1),
    ];
    final name = entry.name;
    if (name != null && name.toLowerCase() != entry.fileName.toLowerCase()) {
      fields.add(_Field(CorpusMatchField.name, name.toLowerCase(), name, 4));
    }
    final version = entry.version;
    if (version != null) fields.add(_Field(CorpusMatchField.version, version.toLowerCase(), version, 1));
    for (final id in entry.prims.keys) {
      final op = PrimOp.fromId(id);
      final display = op == null ? 'primResID $id' : '${op.opName} ($id)';
      fields.add(_Field(CorpusMatchField.primitive, '$id', display, 3));
      if (op != null) {
        fields.add(_Field(CorpusMatchField.primitive, op.opName.toLowerCase(), display, 3));
        fields.add(_Field(CorpusMatchField.primitive, op.name.toLowerCase(), display, 3));
      }
    }
    for (final code in entry.bdClasses.keys) {
      final objectClass = BdObjectClass.fromCode(code);
      _classFields(
        fields,
        CorpusMatchField.blockDiagramClass,
        code,
        objectClass.label,
        objectClass.name,
        'block diagram',
      );
    }
    for (final code in entry.fpClasses.keys) {
      final objectClass = FpObjectClass.fromCode(code);
      _classFields(fields, CorpusMatchField.frontPanelClass, code, objectClass.label, objectClass.name, 'front panel');
    }
    for (final subVi in entry.subVis) {
      fields.add(_Field(CorpusMatchField.subVi, subVi.toLowerCase(), subVi, 2));
    }
    for (final library in entry.libraries) {
      fields.add(_Field(CorpusMatchField.library, library.toLowerCase(), library, 2));
    }
    for (final member in entry.members) {
      fields.add(_Field(CorpusMatchField.member, member.toLowerCase(), member, 2));
    }
    return _Document(entry, fields);
  }

  static void _classFields(
    List<_Field> fields,
    CorpusMatchField field,
    int code,
    String label,
    String enumName,
    String heap,
  ) {
    final hex = '0x${code.toRadixString(16).padLeft(2, '0')}';
    final display = enumName == 'unknown' ? 'unknown $heap class $hex' : '$label ($heap $hex)';
    fields.add(_Field(field, hex, display, 3));
    fields.add(_Field(field, enumName.toLowerCase(), display, 3));
    if (enumName != 'unknown') fields.add(_Field(field, label.toLowerCase(), display, 3));
  }
}
