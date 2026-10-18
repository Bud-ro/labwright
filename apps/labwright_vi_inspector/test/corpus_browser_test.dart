import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_rsrc_parse/testing.dart';
import 'package:labwright_vi_inspector/src/corpus_browser.dart';
import 'package:labwright_vi_inspector/src/representative_vis.dart';
import 'package:labwright_vi_inspector/src/vi_screen.dart';

/// A checkout with a `corpus/vi` holding two index files: a snippet collection and one vendored
/// source whose `Adder.vi` is a real minimal VI.
Directory _checkout() {
  final root = Directory.systemTemp.createTempSync('corpus_browser_test');
  File('${root.path}/corpus/repos.json')
    ..createSync(recursive: true)
    ..writeAsStringSync('{}');
  final source = Directory(
    '${root.path}/corpus/vi/vi-corpus/sources/acme__maths',
  )..createSync(recursive: true);
  File(
    '${source.path}/Adder.vi',
  ).writeAsBytesSync(minimalViBytes(name: 'Adder.vi'));
  File('${source.path}/index.json').writeAsStringSync(
    CorpusIndex([
      const CorpusIndexEntry(
        path: 'Adder.vi',
        bytes: 10,
        type: CorpusFileType.vi,
        version: '13.0',
        prims: {1050: 2},
        bdClasses: {0x3a: 1},
      ),
      const CorpusIndexEntry(
        path: 'lib/Maths.lvlib',
        bytes: 10,
        type: CorpusFileType.library,
        name: 'Maths.lvlib',
        members: ['Adder.vi'],
      ),
    ]).encode(),
  );
  final snippets = Directory('${root.path}/corpus/vi/vi-snippets')
    ..createSync(recursive: true);
  File('${snippets.path}/index.json').writeAsStringSync(
    CorpusIndex([
      const CorpusIndexEntry(
        path: 'ni-kb/Adding_Numbers.png',
        bytes: 10,
        type: CorpusFileType.snippet,
        name: 'Untitled 1',
        version: '20.0',
        prims: {1050: 1},
      ),
    ]).encode(),
  );
  return root;
}

void main() {
  late Directory root;

  setUp(() => root = _checkout());
  tearDown(() => root.deleteSync(recursive: true));

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
    'load merges every index file, with paths relative to corpus/vi',
    () async {
      final library = await CorpusLibrary.load(
        Directory('${root.path}/corpus/vi'),
        inIsolate: false,
      );
      expect(library.indexFiles, 2);
      expect(library.search.entries.map((e) => e.path), [
        'vi-corpus/sources/acme__maths/Adder.vi',
        'vi-corpus/sources/acme__maths/lib/Maths.lvlib',
        'vi-snippets/ni-kb/Adding_Numbers.png',
      ]);
      expect(library.typeCounts, {
        CorpusFileType.vi: 1,
        CorpusFileType.library: 1,
        CorpusFileType.snippet: 1,
      });
      final adder = library.search.search('name:adder').single.entry;
      expect(library.fileOf(adder).existsSync(), isTrue);
    },
  );

  Future<void> pumpScreen(
    WidgetTester tester,
    Future<CorpusLibrary?> Function() loadCorpus,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ViInspectorScreen(
          fetchBytes: (url) async => minimalViBytes(),
          loadCorpus: loadCorpus,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('examples')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'the Examples browser searches the corpus, splits snippets from files, and opens a hit',
    (tester) async {
      final library = await CorpusLibrary.load(
        Directory('${root.path}/corpus/vi'),
        inIsolate: false,
      );
      await pumpScreen(tester, () async => library);
      expect(
        find.text('Featured (${kRepresentativeVis.length})'),
        findsOneWidget,
      );
      expect(
        find.textContaining('3 files indexed from 2 index files'),
        findsOneWidget,
      );

      await tester.enterText(find.byKey(const Key('corpus-search')), 'add');
      await tester.pumpAndSettle();
      expect(find.text('Snippets (1)'), findsOneWidget);
      expect(find.text('VIs & files (2)'), findsOneWidget);
      expect(find.text('Adding_Numbers.png'), findsOneWidget);
      expect(find.text('Adder.vi'), findsNWidgets(2));
      expect(find.text('Maths.lvlib'), findsOneWidget);
      expect(find.textContaining('Add (1050)'), findsNWidgets(2));
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
      expect(find.text('Adder.vi'), findsOneWidget);

      await tester.tap(find.byKey(const Key('corpus-type-lvlib')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('corpus-search')),
        'prim:add type:vi',
      );
      await tester.pumpAndSettle();
      expect(find.text('VIs & files (1)'), findsOneWidget);
      await tester.tap(find.text('Adder.vi'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('corpus-browser')), findsNothing);
      expect(find.text('Block Diagram'), findsOneWidget);
      expect(find.text('Adder.vi'), findsWidgets);
    },
  );

  testWidgets(
    'without a fetched corpus the browser says how to fetch it and still lists the featured VIs',
    (tester) async {
      await pumpScreen(tester, () async => null);
      expect(find.textContaining(CorpusLibrary.fetchCommand), findsOneWidget);
      expect(find.text('3DBaxter.vi'), findsOneWidget);
      await tester.tap(find.text('3DBaxter.vi'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('corpus-browser')), findsNothing);
      expect(find.text('Block Diagram'), findsOneWidget);
    },
  );
}
