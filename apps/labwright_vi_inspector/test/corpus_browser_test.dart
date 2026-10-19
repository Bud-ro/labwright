import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/testing.dart';
import 'package:labwright_vi_inspector/src/corpus_browser.dart';
import 'package:labwright_vi_inspector/src/corpus_database.dart';
import 'package:labwright_vi_inspector/src/representative_vis.dart';
import 'package:labwright_vi_inspector/src/vi_screen.dart';
import 'package:sqlite3/sqlite3.dart';

/// One file of a test index.
typedef _Row = ({
  String path,
  String type,
  String? name,
  String? version,
  Map<int, int> prims,
  Map<int, int> bd,
  List<String> subVis,
  List<String> libraries,
  List<String> members,
});

_Row _row(
  String path,
  String type, {
  String? name,
  String? version,
  Map<int, int> prims = const {},
  Map<int, int> bd = const {},
  List<String> subVis = const [],
  List<String> libraries = const [],
  List<String> members = const [],
}) => (
  path: path,
  type: type,
  name: name,
  version: version,
  prims: prims,
  bd: bd,
  subVis: subVis,
  libraries: libraries,
  members: members,
);

/// Writes an index of schema 1 as the corpus repositories' `tool/index` does, naming the
/// primitives and classes in [primNames] and [classNames].
void _writeIndex(
  File out,
  List<_Row> rows, {
  required String repository,
  required String commit,
  Map<int, String> primNames = const {1050: 'Add', 1051: 'Subtract'},
  Map<int, String> classNames = const {0x20: 'For Loop'},
}) {
  if (out.existsSync()) out.deleteSync();
  final db = sqlite3.open(out.path);
  db.execute('''
    create table meta(key text primary key, value text not null);
    create table file(id integer primary key, path text not null unique, source text, bytes integer not null,
      type text not null, name text, version text, error text);
    create table prim(file integer, id integer, n integer);
    create table bd_object(file integer, code integer, n integer);
    create table fp_object(file integer, code integer, n integer);
    create table prim_name(id integer primary key, name text not null);
    create table bd_class(code integer primary key, name text not null);
    create table fp_class(code integer primary key, name text not null);
    create view prims as select p.file, p.id, n.name, p.n from prim p left join prim_name n on n.id = p.id;
    create view bd_objects as select o.file, o.code, c.name, o.n from bd_object o left join bd_class c on c.code = o.code;
    create view fp_objects as select o.file, o.code, c.name, o.n from fp_object o left join fp_class c on c.code = o.code;
    create table sub_vi(file integer, name text);
    create table library(file integer, name text);
    create table member(file integer, name text);
  ''');
  for (final MapEntry(:key, :value) in {
    'schema': '1',
    'repository': repository,
    'commit': commit,
    'labwright': 'test',
    'built': '2026-01-01T00:00:00Z',
    'files': '${rows.length}',
  }.entries) {
    db.execute('insert into meta values (?, ?)', [key, value]);
  }
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    db.execute('insert into file values (?, ?, ?, ?, ?, ?, ?, null)', [
      i + 1,
      row.path,
      null,
      10,
      row.type,
      row.name,
      row.version,
    ]);
    for (final MapEntry(key: id, value: n) in row.prims.entries) {
      db.execute('insert into prim values (?, ?, ?)', [i + 1, id, n]);
    }
    for (final MapEntry(key: code, value: n) in row.bd.entries) {
      db.execute('insert into bd_object values (?, ?, ?)', [i + 1, code, n]);
    }
    for (final name in row.subVis) {
      db.execute('insert into sub_vi values (?, ?)', [i + 1, name]);
    }
    for (final name in row.libraries) {
      db.execute('insert into library values (?, ?)', [i + 1, name]);
    }
    for (final name in row.members) {
      db.execute('insert into member values (?, ?)', [i + 1, name]);
    }
  }
  for (final MapEntry(key: id, value: name) in primNames.entries) {
    db.execute('insert into prim_name values (?, ?)', [id, name]);
  }
  for (final MapEntry(key: code, value: name) in classNames.entries) {
    db.execute('insert into bd_class values (?, ?)', [code, name]);
  }
  db.close();
}

final _corpusRows = [
  _row(
    'sources/acme__maths/Adder.vi',
    'vi',
    name: 'Adder.vi',
    version: '13.0',
    prims: {1050: 2},
    bd: {0x20: 1, 0x7ff: 1},
    subVis: ['Helper.vi'],
    libraries: ['Maths.lvlib'],
  ),
  _row(
    'sources/acme__maths/lib/Maths.lvlib',
    'lvlib',
    name: 'Maths.lvlib',
    members: ['Adder.vi'],
  ),
];

final _snippetRows = [
  _row(
    'ni-kb/Adding_Numbers.png',
    'png',
    name: 'Untitled 1',
    version: '20.0',
    prims: {1050: 1, 1051: 1},
  ),
];

const _corpusRef = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _snippetsRef = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// A labwright checkout whose `corpus/repos.json` pins two repositories, with `Adder.vi`
/// checked out as a real minimal VI, and a cache directory beside it.
({Directory root, Directory cache}) _checkout() {
  final root = Directory.systemTemp.createTempSync('corpus_browser_test');
  File('${root.path}/corpus/repos.json')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
{"vi": [
  {"repo": "https://github.com/Bud-ro/vi-corpus.git", "ref": "$_corpusRef", "paths": ["sources/acme__maths"]},
  {"repo": "https://github.com/Bud-ro/vi-snippets.git", "ref": "$_snippetsRef"}
]}
''');
  final source = Directory(
    '${root.path}/corpus/vi/vi-corpus/sources/acme__maths',
  )..createSync(recursive: true);
  File(
    '${source.path}/Adder.vi',
  ).writeAsBytesSync(minimalViBytes(name: 'Adder.vi'));
  return (root: root, cache: Directory('${root.path}/cache')..createSync());
}

void _fillCache(Directory cache) {
  _writeIndex(
    File('${cache.path}/vi-corpus.sqlite'),
    _corpusRows,
    repository: 'vi-corpus',
    commit: _corpusRef,
  );
  _writeIndex(
    File('${cache.path}/vi-snippets.sqlite'),
    _snippetRows,
    repository: 'vi-snippets',
    commit: _snippetsRef,
  );
}

/// Serves the two repositories' released indexes (as xz) and a minimal VI for anything else.
Future<Uint8List> Function(Uri) _github(
  Directory scratch,
  List<Uri> requested,
) => (url) async {
  requested.add(url);
  if (!url.path.endsWith('index.sqlite.xz')) return minimalViBytes();
  final name = url.pathSegments[1];
  final file = File('${scratch.path}/$name.sqlite');
  if (name == 'vi-corpus') {
    _writeIndex(file, _corpusRows, repository: 'vi-corpus', commit: _corpusRef);
  } else {
    _writeIndex(
      file,
      _snippetRows,
      repository: 'vi-snippets',
      commit: _snippetsRef,
    );
  }
  return XZEncoder().encodeBytes(file.readAsBytesSync());
};

void main() {
  late Directory root;
  late Directory cache;

  setUp(() => (root: root, cache: cache) = _checkout());
  tearDown(() => root.deleteSync(recursive: true));

  Map<String, String> env([Map<String, String> more = const {}]) => {
    'LABWRIGHT_CORPUS_INDEX': cache.path,
    ...more,
  };

  test(
    'locate walks up to the checkout that holds corpus/repos.json, or follows LABWRIGHT_CORPUS',
    () {
      final nested = Directory('${root.path}/apps/x/y')
        ..createSync(recursive: true);
      expect(
        CorpusLibrary.locate(from: nested, environment: const {})?.path,
        '${root.path}/corpus/vi',
      );
      expect(
        CorpusLibrary.locate(from: Directory.systemTemp, environment: const {}),
        isNull,
      );
      expect(
        CorpusLibrary.locate(
          from: Directory.systemTemp,
          environment: {'LABWRIGHT_CORPUS': '${root.path}/corpus'},
        )?.path,
        '${root.path}/corpus/vi',
      );
      expect(
        CorpusLibrary.locate(
          from: nested,
          environment: {'LABWRIGHT_CORPUS': '${root.path}/nowhere'},
        ),
        isNull,
      );
    },
  );

  test(
    'the cache directory comes from LABWRIGHT_CORPUS_INDEX, else the user cache',
    () {
      expect(
        CorpusLibrary.cacheDirectory({'LABWRIGHT_CORPUS_INDEX': '/x'}).path,
        '/x',
      );
      expect(
        CorpusLibrary.cacheDirectory({
          'XDG_CACHE_HOME': '/c',
          'HOME': '/h',
        }).path,
        '/c/labwright/corpus-index',
      );
      expect(
        CorpusLibrary.cacheDirectory({'HOME': '/h'}).path,
        '/h/.cache/labwright/corpus-index',
      );
      expect(
        CorpusLibrary.cacheDirectory({
          'LOCALAPPDATA': r'C:\u\AppData\Local',
        }).path,
        r'C:\u\AppData\Local/labwright/corpus-index',
      );
    },
  );

  test(
    'open takes its pins from the checkout, or the default repositories without one',
    () {
      final nested = Directory('${root.path}/apps/x')
        ..createSync(recursive: true);
      final pinned = CorpusLibrary.open(
        from: nested,
        environment: env(),
        inIsolate: false,
      );
      addTearDown(pinned.close);
      expect(pinned.checkout?.path, '${root.path}/corpus/vi');
      expect(pinned.pins.map((p) => (p.name, p.ref)), [
        ('vi-corpus', _corpusRef),
        ('vi-snippets', _snippetsRef),
      ]);
      expect(pinned.pins.first.repo, 'Bud-ro/vi-corpus');
      expect(
        pinned.pins.first.asset.toString(),
        'https://github.com/Bud-ro/vi-corpus/releases/download/index-aaaaaaaaaaaa/index.sqlite.xz',
      );
      expect(pinned.databases, isEmpty);

      final unpinned = CorpusLibrary.open(
        from: Directory.systemTemp,
        environment: env(),
        inIsolate: false,
      );
      addTearDown(unpinned.close);
      expect(unpinned.checkout, isNull);
      expect(unpinned.pins.map((p) => p.url), kCorpusRepositories);
      expect(
        unpinned.pins.first.asset.toString(),
        'https://github.com/Bud-ro/vi-corpus/releases/latest/download/index.sqlite.xz',
      );
    },
  );

  test('a library reads every cached index and searches them as one', () async {
    _fillCache(cache);
    final library = CorpusLibrary.open(
      from: root,
      environment: env(),
      inIsolate: false,
    );
    addTearDown(library.close);
    expect(library.databases.map((db) => db.repository), [
      'vi-corpus',
      'vi-snippets',
    ]);
    expect(library.files, 3);
    expect(library.typeCounts, {
      CorpusFileType.vi: 1,
      CorpusFileType.library: 1,
      CorpusFileType.snippet: 1,
    });
    expect(
      (await library.search('add')).map((h) => '${h.repository}/${h.hit.path}'),
      [
        'vi-corpus/sources/acme__maths/Adder.vi',
        'vi-corpus/sources/acme__maths/lib/Maths.lvlib',
        'vi-snippets/ni-kb/Adding_Numbers.png',
      ],
    );
    expect((await library.search('add')).first.hit.prims, ['Add']);
    expect((await library.search('for loop')).single.hit.objectClasses, [
      'For Loop',
    ]);
    expect(
      (await library.search('prim:1051')).single.repository,
      'vi-snippets',
    );
    expect(
      (await library.search('add', snippetsOnly: true)).single.hit.isSnippet,
      isTrue,
    );
    expect(
      await library.search(
        'add',
        snippetsOnly: false,
        types: {CorpusFileType.snippet},
      ),
      isEmpty,
    );
    expect(
      (await library.search('add helper')).single.hit.fileName,
      'Adder.vi',
    );

    final adder = (await library.search('name:adder')).single;
    expect(library.localFileOf(adder)?.existsSync(), isTrue);
    final snippet = (await library.search('type:png')).single;
    expect(library.localFileOf(snippet), isNull);
    expect(
      library.remoteUrlOf(snippet).toString(),
      'https://raw.githubusercontent.com/Bud-ro/vi-snippets/$_snippetsRef/ni-kb/Adding_Numbers.png',
    );
  });

  test(
    'fetch downloads each pinned release into the cache and reopens the indexes',
    () async {
      final library = CorpusLibrary.open(
        from: root,
        environment: env(),
        inIsolate: false,
      );
      addTearDown(library.close);
      final requested = <Uri>[];
      final messages = <String>[];
      await library.fetch(
        _github(Directory('${root.path}/scratch')..createSync(), requested),
        onProgress: messages.add,
      );
      expect(requested.map((u) => u.toString()), [
        'https://github.com/Bud-ro/vi-corpus/releases/download/index-aaaaaaaaaaaa/index.sqlite.xz',
        'https://github.com/Bud-ro/vi-snippets/releases/download/index-bbbbbbbbbbbb/index.sqlite.xz',
      ]);
      expect(messages.last, '3 files indexed');
      expect(library.databases.map((db) => db.commit), [
        _corpusRef,
        _snippetsRef,
      ]);
      expect(File('${cache.path}/vi-corpus.sqlite').existsSync(), isTrue);
      expect(cache.listSync().where((e) => e.path.endsWith('.part')), isEmpty);
    },
  );

  test(
    'fetch reports a repository without the release and keeps going',
    () async {
      final library = CorpusLibrary.open(
        from: root,
        environment: env(),
        inIsolate: false,
      );
      addTearDown(library.close);
      final messages = <String>[];
      final snippets = File('${root.path}/s.sqlite');
      _writeIndex(
        snippets,
        _snippetRows,
        repository: 'vi-snippets',
        commit: _snippetsRef,
      );
      await library.fetch((url) async {
        if (url.pathSegments[1] == 'vi-corpus')
          throw const HttpException('404');
        return XZEncoder().encodeBytes(snippets.readAsBytesSync());
      }, onProgress: messages.add);
      expect(messages, contains(startsWith('vi-corpus: HttpException')));
      expect(library.databases.map((db) => db.repository), ['vi-snippets']);
    },
  );

  /// Lets the debounced search run and the frames settle.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(kCorpusSearchDebounce + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    Future<CorpusLibrary> Function() loadCorpus, {
    List<Uri>? requested,
  }) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ViInspectorScreen(
          fetchBytes: _github(
            Directory('${root.path}/scratch')..createSync(),
            requested ?? [],
          ),
          loadCorpus: loadCorpus,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('examples')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'the Examples browser searches the cached indexes, splits snippets from files, and opens a hit',
    (tester) async {
      _fillCache(cache);
      final library = CorpusLibrary.open(
        from: root,
        environment: env(),
        inIsolate: false,
      );
      addTearDown(library.close);
      await pumpScreen(tester, () async => library);
      expect(
        find.text('Featured (${kRepresentativeVis.length})'),
        findsOneWidget,
      );
      expect(
        find.textContaining('3 files indexed in 2 repositories'),
        findsOneWidget,
      );
      expect(find.text('Refetch index'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('corpus-search')), 'add');
      await settle(tester);
      expect(find.text('Snippets (1)'), findsOneWidget);
      expect(find.text('VIs & files (2)'), findsOneWidget);
      expect(find.text('Adding_Numbers.png'), findsOneWidget);
      expect(find.text('Adder.vi'), findsOneWidget);
      expect(find.text('Maths.lvlib'), findsOneWidget);
      expect(find.textContaining('· Add'), findsNWidgets(2));
      expect(find.textContaining('member Adder.vi'), findsOneWidget);
      expect(
        find.text('Featured (${kRepresentativeVis.length})'),
        findsNothing,
      );

      await tester.tap(find.text('Snippets'));
      await tester.pumpAndSettle();
      expect(find.text('Snippets (1)'), findsOneWidget);
      expect(find.text('VIs & files (2)'), findsNothing);

      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('corpus-type-lvlib')));
      await tester.pumpAndSettle();
      expect(find.text('Snippets (0)'), findsOneWidget);
      expect(find.text('VIs & files (1)'), findsOneWidget);
      expect(find.text('Adder.vi'), findsNothing);

      await tester.tap(find.byKey(const Key('corpus-type-lvlib')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('corpus-search')),
        'prim:add type:vi',
      );
      await settle(tester);
      expect(find.text('VIs & files (1)'), findsOneWidget);
      await tester.tap(find.text('Adder.vi'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('corpus-browser')), findsNothing);
      expect(find.text('Block Diagram'), findsOneWidget);
      expect(find.textContaining('Adder.vi'), findsWidgets);
    },
  );

  testWidgets('a file that is not checked out opens from GitHub', (
    tester,
  ) async {
    _fillCache(cache);
    final library = CorpusLibrary.open(
      from: root,
      environment: env(),
      inIsolate: false,
    );
    addTearDown(library.close);
    final requested = <Uri>[];
    await pumpScreen(tester, () async => library, requested: requested);
    await tester.enterText(find.byKey(const Key('corpus-search')), 'type:png');
    await settle(tester);
    await tester.tap(find.text('Adding_Numbers.png'));
    await tester.pumpAndSettle();
    expect(requested.map((u) => u.toString()), [
      'https://raw.githubusercontent.com/Bud-ro/vi-snippets/$_snippetsRef/ni-kb/Adding_Numbers.png',
    ]);
    expect(find.text('Block Diagram'), findsOneWidget);
  });

  testWidgets(
    'with an empty cache the browser offers to fetch the index, and searches it once fetched',
    (tester) async {
      final library = CorpusLibrary.open(
        from: root,
        environment: env(),
        inIsolate: false,
      );
      addTearDown(library.close);
      await pumpScreen(tester, () async => library);
      expect(
        find.textContaining('No corpus index is cached under ${cache.path}'),
        findsOneWidget,
      );
      expect(find.text('3DBaxter.vi'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('corpus-fetch')));
        for (var i = 0; i < 200 && library.databases.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      });
      await tester.pumpAndSettle();
      expect(
        find.textContaining('3 files indexed in 2 repositories'),
        findsOneWidget,
      );
      expect(find.text('Refetch index'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('corpus-search')),
        'subtract',
      );
      await settle(tester);
      expect(find.text('Snippets (1)'), findsOneWidget);
      expect(find.text('VIs & files (0)'), findsOneWidget);
    },
  );
}
