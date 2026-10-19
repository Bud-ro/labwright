import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// The schema version of the corpus index this build reads.
const int kCorpusSchema = 1;

/// The files a corpus index records, by extension.
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

  static CorpusFileType? ofExtension(String extension) {
    for (final type in values) {
      if (type.extension == extension) return type;
    }
    return null;
  }
}

/// The fields a search term can be narrowed to with a `field:` prefix.
enum CorpusField {
  name('name'),
  path('path'),
  prim('prim'),
  objectClass('class'),
  subVi('sub'),
  library('lib'),
  member('member'),
  type('type'),
  version('version');

  const CorpusField(this.prefix);

  final String prefix;

  static CorpusField? ofPrefix(String prefix) {
    for (final field in values) {
      if (field.prefix == prefix) return field;
    }
    return null;
  }
}

/// One term of a query: the text to match and the field it is narrowed to, or null for any.
class CorpusTerm {
  const CorpusTerm(this.text, {this.field});

  final String text;

  final CorpusField? field;

  /// The terms of [query]: whitespace-separated, quotes keep a phrase together, and
  /// `field:text` narrows a term to one of [CorpusField]; every term must match.
  static List<CorpusTerm> parse(String query) {
    final terms = <CorpusTerm>[];
    for (final match in RegExp(
      r'(?:([a-z]+):)?(?:"([^"]*)"|(\S+))',
    ).allMatches(query)) {
      final prefix = match.group(1);
      final text = (match.group(2) ?? match.group(3) ?? '').trim();
      if (text.isEmpty) continue;
      final field = prefix == null ? null : CorpusField.ofPrefix(prefix);
      terms.add(
        field == null && prefix != null
            ? CorpusTerm('$prefix:$text')
            : CorpusTerm(text, field: field),
      );
    }
    return terms;
  }

  /// The id the term names, when it is a decimal or `0x` hexadecimal number.
  int? get asId =>
      int.tryParse(text) ??
      (text.startsWith('0x')
          ? int.tryParse(text.substring(2), radix: 16)
          : null);
}

/// One file a search found: its row in `file` and what the query matched beyond its name.
class CorpusHit {
  const CorpusHit({
    required this.path,
    required this.type,
    required this.bytes,
    this.name,
    this.version,
    this.error,
    this.prims = const [],
    this.objectClasses = const [],
    this.subVis = const [],
    this.libraries = const [],
    this.members = const [],
  });

  /// The file's path relative to its repository root.
  final String path;

  final CorpusFileType type;

  final int bytes;

  final String? name;

  final String? version;

  final String? error;

  /// The primitive, class, sub-VI, library and member names the query matched.
  final List<String> prims;
  final List<String> objectClasses;
  final List<String> subVis;
  final List<String> libraries;
  final List<String> members;

  String get fileName => path.substring(path.lastIndexOf('/') + 1);

  bool get isSnippet => type == CorpusFileType.snippet;
}

/// A corpus index (the `index.sqlite` a corpus repository releases) open for reading.
class CorpusDatabase {
  CorpusDatabase._(this.file, this._db, this.meta);

  /// Opens the index at [file] read-only; throws when it is not an index of the schema this
  /// build reads.
  factory CorpusDatabase.open(File file) {
    final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try {
      final meta = {
        for (final row in db.select('select key, value from meta'))
          row['key'] as String: row['value'] as String,
      };
      if (meta['schema'] != '$kCorpusSchema') {
        throw FormatException(
          '${file.path} has schema ${meta['schema']}, this build reads $kCorpusSchema',
        );
      }
      return CorpusDatabase._(file, db, meta);
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  final File file;

  final Database _db;

  /// `meta`: `schema`, `repository`, `commit`, `labwright`, `built`, `files`.
  final Map<String, String> meta;

  /// The corpus repository's name.
  String get repository => meta['repository'] ?? '';

  /// The repository commit the index was built from.
  String get commit => meta['commit'] ?? '';

  int get files => int.tryParse(meta['files'] ?? '') ?? 0;

  /// How many files each type has.
  Map<CorpusFileType, int> get typeCounts => {
    for (final row in _db.select(
      'select type, count(*) as n from file group by type',
    ))
      if (CorpusFileType.ofExtension(row['type'] as String) case final type?)
        type: row['n'] as int,
  };

  /// Whether a file at [path] (relative to the repository root) is indexed.
  bool contains(String path) =>
      _db.select('select 1 from file where path = ?', [path]).isNotEmpty;

  /// The files every term of [query] matches, restricted to [types] when given, the first
  /// [limit] in path order. A term matches a file's name, path, version or type, or a primitive,
  /// class, sub-VI, library or member name (or a primitive or class id) its heaps hold, unless
  /// its field narrows it. What each returned file matched beyond its name is gathered
  /// afterwards for the returned rows only, one query per table.
  List<CorpusHit> search(
    String query, {
    Set<CorpusFileType>? types,
    int limit = 200,
  }) {
    final terms = CorpusTerm.parse(query);
    final where = <String>[];
    final args = <Object?>[];
    for (final term in terms) {
      final clauses = <String>[];
      final pattern = '%${_escape(term.text)}%';
      void like(String column) {
        clauses.add("$column like ? escape '\\'");
        args.add(pattern);
      }

      void named(String table, String nameTable, String key) {
        clauses.add(
          'f.id in (select file from $table where $key in (${_namedIds(nameTable, key, term, args)}))',
        );
      }

      void listed(String table) {
        clauses.add(
          "f.id in (select file from $table where name like ? escape '\\')",
        );
        args.add(pattern);
      }

      switch (term.field) {
        case CorpusField.name:
          like('f.name');
        case CorpusField.path:
          like('f.path');
        case CorpusField.version:
          like('f.version');
        case CorpusField.type:
          clauses.add('f.type = ?');
          args.add(term.text.toLowerCase());
        case CorpusField.prim:
          named('prim', 'prim_name', 'id');
        case CorpusField.objectClass:
          named('bd_object', 'bd_class', 'code');
          named('fp_object', 'fp_class', 'code');
        case CorpusField.subVi:
          listed('sub_vi');
        case CorpusField.library:
          listed('library');
        case CorpusField.member:
          listed('member');
        case null:
          like('f.name');
          like('f.path');
          like('f.version');
          clauses.add('f.type = ?');
          args.add(term.text.toLowerCase());
          named('prim', 'prim_name', 'id');
          named('bd_object', 'bd_class', 'code');
          named('fp_object', 'fp_class', 'code');
          listed('sub_vi');
          listed('library');
          listed('member');
      }
      where.add('(${clauses.join(' or ')})');
    }
    if (types != null) {
      where.add('f.type in (${List.filled(types.length, '?').join(', ')})');
      args.addAll(types.map((t) => t.extension));
    }
    args.add(limit);
    final rows = _db.select(
      'select f.id, f.path, f.type, f.bytes, f.name, f.version, f.error from file f'
      '${where.isEmpty ? '' : ' where ${where.join(' and ')}'}'
      ' order by f.id limit ?',
      args,
    );
    final ids = [for (final row in rows) row['id'] as int];
    final prims = _matchedNamed('prim', 'prim_name', 'id', terms, ids);
    final classes = _matchedNamed('bd_object', 'bd_class', 'code', terms, ids);
    for (final MapEntry(key: id, value: names) in _matchedNamed(
      'fp_object',
      'fp_class',
      'code',
      terms,
      ids,
    ).entries) {
      (classes[id] ??= []).addAll(names);
    }
    final subVis = _matchedListed('sub_vi', terms, ids);
    final libraries = _matchedListed('library', terms, ids);
    final members = _matchedListed('member', terms, ids);
    return [
      for (final row in rows)
        CorpusHit(
          path: row['path'] as String,
          type:
              CorpusFileType.ofExtension(row['type'] as String) ??
              CorpusFileType.vi,
          bytes: row['bytes'] as int,
          name: row['name'] as String?,
          version: row['version'] as String?,
          error: row['error'] as String?,
          prims: prims[row['id']] ?? const [],
          objectClasses: classes[row['id']] ?? const [],
          subVis: subVis[row['id']] ?? const [],
          libraries: libraries[row['id']] ?? const [],
          members: members[row['id']] ?? const [],
        ),
    ];
  }

  /// A subquery for the ids in [nameTable] whose name [term] matches, or that [term] names
  /// outright, appending its parameters to [args].
  static String _namedIds(
    String nameTable,
    String key,
    CorpusTerm term,
    List<Object?> args,
  ) {
    var sql = "select $key from $nameTable where name like ? escape '\\'";
    args.add('%${_escape(term.text)}%');
    if (term.asId case final id?) {
      sql = '$sql union select ?';
      args.add(id);
    }
    return sql;
  }

  /// For the files [ids], the names in [nameTable] that any of [terms] matched among the ids
  /// [table] records for them.
  Map<int, List<String>> _matchedNamed(
    String table,
    String nameTable,
    String key,
    List<CorpusTerm> terms,
    List<int> ids,
  ) {
    if (terms.isEmpty || ids.isEmpty) return const {};
    final args = <Object?>[];
    final matching = [
      for (final term in terms) _namedIds(nameTable, key, term, args),
    ].join(' union ');
    args.addAll(ids);
    final out = <int, List<String>>{};
    for (final row in _db.select(
      'select h.file, n.name from $table h join $nameTable n on n.$key = h.$key '
      'where h.$key in ($matching) and h.file in (${List.filled(ids.length, '?').join(', ')}) '
      'order by h.file, n.name',
      args,
    )) {
      final names = out.putIfAbsent(row['file'] as int, () => []);
      if (!names.contains(row['name'])) names.add(row['name'] as String);
    }
    return out;
  }

  /// For the files [ids], the names in [table] that any of [terms] matched.
  Map<int, List<String>> _matchedListed(
    String table,
    List<CorpusTerm> terms,
    List<int> ids,
  ) {
    if (terms.isEmpty || ids.isEmpty) return const {};
    final args = <Object?>[
      for (final term in terms) '%${_escape(term.text)}%',
      ...ids,
    ];
    final out = <int, List<String>>{};
    for (final row in _db.select(
      'select file, name from $table where (${List.filled(terms.length, "name like ? escape '\\'").join(' or ')}) '
      'and file in (${List.filled(ids.length, '?').join(', ')}) order by file, name',
      args,
    )) {
      final names = out.putIfAbsent(row['file'] as int, () => []);
      if (!names.contains(row['name'])) names.add(row['name'] as String);
    }
    return out;
  }

  void close() => _db.close();

  static String _escape(String text) => text
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');
}
