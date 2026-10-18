import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'png_snippet_test.dart' show png;
import 'test_util.dart';

Uint8List _vi({String name = 'Adder.vi'}) => buildRsrc([
  (tag: 'LVSR', sections: [List.filled(6, 1)]),
  (
    tag: 'vers',
    sections: [
      [...pascal('13.0'), ...'VIDS'.codeUnits, ...pascal('Adder')],
    ],
  ),
  (
    tag: 'FPHb',
    sections: [
      compressedSection(heapBody([...open(0x12, 1), ...close(), ...open(0x12, 2), ...close()])),
    ],
  ),
  (
    tag: 'BDHb',
    sections: [
      compressedSection(
        heapBody([
          ...open(0x2f, 1),
          ...attrU16(0xea, 1051),
          ...close(),
          ...open(0x2f, 2),
          ...attrU16(0xea, 1051),
          ...close(),
          ...open(0x3a, 3),
          ...close(),
          ...open(0x120, 4),
          ...close(),
        ]),
      ),
    ],
  ),
], name: name);

const _lvlib = '''<?xml version='1.0' encoding='UTF-8'?>
<Library LVVersion="13008000">
  <Property Name="NI.Lib.Version" Type="Str">1.0.0.3</Property>
  <Item Name="Public" Type="Folder">
    <Item Name="Open.vi" Type="VI" URL="../Public/Open.vi"/>
    <Item Name="Close.vi" Type="VI" URL="../Public/Close.vi"/>
  </Item>
  <Item Name="Session.ctl" Type="VI" URL="../Session.ctl"/>
  <Item Name="Dependencies" Type="Dependencies"/>
</Library>
''';

void main() {
  group('indexCorpusFile', () {
    test('a VI records its name, version and the ids its heaps hold', () {
      final entry = indexCorpusFile('lib/Adder.vi', _vi())!;
      expect(entry.type, CorpusFileType.vi);
      expect(entry.fileName, 'Adder.vi');
      expect(entry.name, 'Adder.vi');
      expect(entry.version, '13.0');
      expect(entry.prims, {1051: 2});
      expect(entry.bdClasses, {0x2f: 2, 0x3a: 1, 0x120: 1});
      expect(entry.fpClasses, {0x12: 2});
      expect(entry.error, isNull);
      expect(entry.isSnippet, isFalse);
    });

    test('a snippet PNG is indexed as the VI it carries, a plain PNG is not indexed', () {
      final ihdr = ('IHDR', List<int>.filled(13, 0));
      final snippet = png([ihdr, ('niVI', _vi()), ('IEND', <int>[])]);
      final entry = indexCorpusFile('ni-kb/Adder.png', snippet)!;
      expect(entry.type, CorpusFileType.snippet);
      expect(entry.isSnippet, isTrue);
      expect(entry.bytes, snippet.length);
      expect(entry.prims, {1051: 2});
      expect(indexCorpusFile('a/plain.png', png([ihdr, ('IEND', <int>[])])), isNull);
    });

    test('files of other extensions are not indexed', () {
      expect(indexCorpusFile('README.md', u8('hello'.codeUnits)), isNull);
      expect(indexCorpusFile('noext', u8([1, 2])), isNull);
    });

    test('a library file lists the members that point at files', () {
      final entry = indexCorpusFile('src/Instr.lvlib', u8(utf8.encode(_lvlib)))!;
      expect(entry.type, CorpusFileType.library);
      expect(entry.name, 'Instr.lvlib');
      expect(entry.members, ['Open.vi', 'Close.vi', 'Session.ctl']);
      expect(entry.error, isNull);
    });

    test('a file that does not parse keeps its type and the reason', () {
      final entry = indexCorpusFile('x/broken.vi', u8([1, 2, 3]))!;
      expect(entry.type, CorpusFileType.vi);
      expect(entry.error, isNotNull);
      final xml = indexCorpusFile('x/broken.lvclass', u8('<Library/>'.codeUnits))!;
      expect(xml.type, CorpusFileType.lvClass);
      expect(xml.error, contains('<LVClass>'));
    });
  });

  group('CorpusIndex', () {
    test('encodes one record per line, sorted by path, and decodes to the same records', () {
      final index = CorpusIndex([
        indexCorpusFile('b/Adder.vi', _vi())!,
        indexCorpusFile('a/Instr.lvlib', u8(utf8.encode(_lvlib)))!,
        indexCorpusFile('c/broken.vi', u8([0]))!,
      ]);
      final text = index.encode();
      final lines = const LineSplitter().convert(text);
      expect(lines.first, '{"format": 1, "files": [');
      expect(lines.last, ']}');
      expect(lines.length, 2 + 3);
      expect(lines[1], startsWith('{"path":"a/Instr.lvlib"'));
      expect(lines[2], startsWith('{"path":"b/Adder.vi"'));
      final decoded = CorpusIndex.decode(text);
      expect([for (final e in decoded.entries) e.toJson()], [for (final e in index.entries) e.toJson()]);
      expect(decoded.entries[1].prims, {1051: 2});
      expect(decoded.entries[1].bdClasses, {0x2f: 2, 0x3a: 1, 0x120: 1});
    });

    test('an empty index is a single line and another format is refused', () {
      expect(CorpusIndex(const []).encode(), '{"format": 1, "files": []}\n');
      expect(() => CorpusIndex.decode('{"format": 2, "files": []}'), throwsFormatException);
    });
  });

  group('CorpusSearch', () {
    final entries = [
      const CorpusIndexEntry(
        path: 'math/Adder.vi',
        bytes: 1,
        type: CorpusFileType.vi,
        version: '13.0',
        prims: {1050: 1},
        bdClasses: {0x3a: 1, 0x7ff: 2},
        subVis: ['Scale Input.vi'],
        libraries: ['Numerics.lvlib'],
      ),
      const CorpusIndexEntry(
        path: 'ni-kb/Build_Array_Demo.png',
        bytes: 1,
        type: CorpusFileType.snippet,
        name: 'Untitled 3',
        prims: {1051: 1},
        bdClasses: {0x3a: 3},
        fpClasses: {0x12: 1},
      ),
      const CorpusIndexEntry(
        path: 'src/Numerics.lvlib',
        bytes: 1,
        type: CorpusFileType.library,
        name: 'Numerics.lvlib',
        members: ['Adder.vi', 'Scale Input.vi'],
      ),
    ];
    final search = CorpusSearch(entries);

    List<String> paths(List<CorpusSearchHit> hits) => [for (final hit in hits) hit.entry.path];

    test('a term matches names, paths, primitive and class names, sub-VIs, libraries and members', () {
      expect(paths(search.search('adder')), ['math/Adder.vi', 'src/Numerics.lvlib']);
      expect(paths(search.search('Add')), ['math/Adder.vi', 'src/Numerics.lvlib']);
      expect(paths(search.search('subtract')), ['ni-kb/Build_Array_Demo.png']);
      expect(paths(search.search('build array')), ['ni-kb/Build_Array_Demo.png', 'math/Adder.vi']);
      expect(paths(search.search('scale input')), ['math/Adder.vi', 'src/Numerics.lvlib']);
      expect(paths(search.search('numerics')), ['src/Numerics.lvlib', 'math/Adder.vi']);
      expect(paths(search.search('untitled')), ['ni-kb/Build_Array_Demo.png']);
      expect(paths(search.search('13.0')), ['math/Adder.vi']);
      expect(search.search('nothing like this'), isEmpty);
    });

    test('every term must match, quotes keep a phrase together', () {
      expect(paths(search.search('adder subtract')), isEmpty);
      expect(paths(search.search('adder 0x3a')), ['math/Adder.vi']);
      expect(paths(search.search('"scale input"')), ['math/Adder.vi', 'src/Numerics.lvlib']);
      expect(paths(search.search('"scale adder"')), isEmpty);
    });

    test('a prefix narrows a term to one field', () {
      expect(paths(search.search('prim:add')), ['math/Adder.vi']);
      expect(paths(search.search('name:add')), ['math/Adder.vi']);
      expect(paths(search.search('member:adder')), ['src/Numerics.lvlib']);
      expect(paths(search.search('sub:scale')), ['math/Adder.vi']);
      expect(paths(search.search('lib:numerics')), ['math/Adder.vi']);
      expect(paths(search.search('class:buildarray')), ['math/Adder.vi', 'ni-kb/Build_Array_Demo.png']);
      expect(paths(search.search('class:dco')), ['ni-kb/Build_Array_Demo.png']);
      expect(paths(search.search('type:snippet')), ['ni-kb/Build_Array_Demo.png']);
      expect(paths(search.search('type:lvlib')), ['src/Numerics.lvlib']);
      expect(paths(search.search('version:13')), ['math/Adder.vi']);
      expect(search.search('unknownprefix:adder'), isEmpty);
    });

    test('an uncatalogued class code is found by its number and as unknown', () {
      expect(paths(search.search('0x7ff')), ['math/Adder.vi']);
      expect(paths(search.search('class:unknown')), ['math/Adder.vi']);
      expect(
        search.search('0x7ff').single.matches,
        contains(const CorpusMatch(CorpusMatchField.blockDiagramClass, 'unknown block diagram class 0x7ff')),
      );
    });

    test('the hits say what matched and the file name outranks a mention elsewhere', () {
      final hits = search.search('adder');
      expect(hits.first.matches, [
        const CorpusMatch(CorpusMatchField.path, 'math/Adder.vi'),
        const CorpusMatch(CorpusMatchField.name, 'Adder.vi'),
      ]);
      expect(hits.last.matches, [const CorpusMatch(CorpusMatchField.member, 'Adder.vi')]);
      expect(hits.first.score, greaterThan(hits.last.score));
      expect(search.search('subtract').single.matches, [
        const CorpusMatch(CorpusMatchField.primitive, 'Subtract (1051)'),
      ]);
    });

    test('filters keep snippets or files of chosen types', () {
      expect(paths(search.search('', snippets: true)), ['ni-kb/Build_Array_Demo.png']);
      expect(paths(search.search('', snippets: false)), ['math/Adder.vi', 'src/Numerics.lvlib']);
      expect(paths(search.search('', types: {CorpusFileType.library})), ['src/Numerics.lvlib']);
      expect(paths(search.search('build array', types: {CorpusFileType.vi})), ['math/Adder.vi']);
      expect(paths(search.search('')), ['math/Adder.vi', 'ni-kb/Build_Array_Demo.png', 'src/Numerics.lvlib']);
    });
  });
}
