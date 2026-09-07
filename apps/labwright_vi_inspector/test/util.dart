import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

Directory? repoDir(String relative) {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final candidate = Directory('${dir.path}/$relative');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

const kOracleSnippetDirs = {
  'labviewwiki',
  'hampel-soft',
  'erdos-miller',
  'frc-docs',
  'wikimedia-commons',
};

const kOracleNiKbSnippets = {
  'snippet_frame.png',
  'prepopulated_structures.png',
  'vi_templates_undefined_wire.png',
  'code_that_goes_together.png',
  'preconfigured_vi_calls.png',
  'sample_input_data.png',
  'customized_comments.png',
};

Directory? fetchedSnippetCollection() {
  final bulk = repoDir('packages/labwright_rsrc_parse/corpus/snippets/bulk');
  if (bulk == null) return null;
  for (final dir in bulk.listSync(recursive: true).whereType<Directory>()) {
    if (File('${dir.path}/manifest.json').existsSync()) return dir;
  }
  return null;
}

bool _isCuratedWebSnippet(File f, Directory collection) {
  final rel = f.path
      .substring(collection.path.length + 1)
      .replaceAll(r'\', '/');
  final parts = rel.split('/');
  if (parts.length != 2) return false;
  return kOracleSnippetDirs.contains(parts[0]) ||
      (parts[0] == 'ni-kb' && kOracleNiKbSnippets.contains(parts[1]));
}

List<File> snippetCorpusPngs({bool includeWeb = true}) {
  final tracked = repoDir('packages/labwright_rsrc_parse/corpus/snippets');
  final files = <File>[];
  if (tracked != null) {
    files.addAll(
      tracked.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.png'),
      ),
    );
  } else {
    for (final repo in const [
      'rcpacini_LabVIEW-VI-Snippet',
      'rcpacini_VI-Snippets',
    ]) {
      final dir = repoDir('packages/labwright_rsrc_parse/corpus/vi/$repo');
      if (dir != null)
        files.addAll(
          dir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.png')),
        );
    }
  }
  final collection = includeWeb ? fetchedSnippetCollection() : null;
  if (collection != null) {
    files.addAll(
      collection
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (f) =>
                f.path.endsWith('.png') && _isCuratedWebSnippet(f, collection),
          ),
    );
  }
  return files
      .where((f) => extractSnippetVi(f.readAsBytesSync()) != null)
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

File? snippetPng(String pngName) {
  for (final relative in const [
    'packages/labwright_rsrc_parse/corpus/snippets',
    'packages/labwright_rsrc_parse/corpus/snippets/bulk',
    'packages/labwright_rsrc_parse/corpus/vi/rcpacini_VI-Snippets',
    'packages/labwright_rsrc_parse/corpus/vi/rcpacini_LabVIEW-VI-Snippet',
  ]) {
    final dir = repoDir(relative);
    if (dir == null) continue;
    for (final file in dir.listSync(recursive: true).whereType<File>()) {
      if (file.path.endsWith('/$pngName')) return file;
    }
  }
  return null;
}

Future<void> pumpBody(
  WidgetTester tester,
  Widget body, {
  Size view = const Size(1000, 1000),
}) async {
  tester.view.physicalSize = view;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: body)));
  await tester.pump();
}

Future<void> loadRealTextFont() async {
  final loader = FontLoader('Selawik');
  var faces = 0;
  for (final name in ['selawk.ttf', 'selawkb.ttf']) {
    final file = File('assets/fonts/$name');
    if (!file.existsSync()) continue;
    loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    faces++;
  }
  expect(
    faces,
    2,
    reason:
        'both bundled Selawik faces must be readable at assets/fonts — run '
        'the tests from the app package root',
  );
  await loader.load();
}

Uint8List spliceNiVi(Uint8List png, Uint8List vi) {
  final chunk = Uint8List(12 + vi.length);
  final d = ByteData.sublistView(chunk);
  d.setUint32(0, vi.length);
  chunk.setAll(4, 'niVI'.codeUnits);
  chunk.setAll(8, vi);
  d.setUint32(8 + vi.length, crc32(chunk, 4, 8 + vi.length));
  final iend = png.length - 12;
  return Uint8List.fromList([
    ...png.sublist(0, iend),
    ...chunk,
    ...png.sublist(iend),
  ]);
}

List<int> open(int kind, int oid, {int tag = 0x19}) => [
  0x10,
  tag,
  0x02,
  0xfe,
  kind >> 8,
  kind & 0xff,
  0xfd,
  oid >> 8,
  oid & 0xff,
];
List<int> close([int tag = 0x19]) => [0x08, tag];
List<int> bounds(int t, int l, int b, int r) => [
  0xc4,
  0x2d,
  0x08,
  t >> 8,
  t & 0xff,
  l >> 8,
  l & 0xff,
  b >> 8,
  b & 0xff,
  r >> 8,
  r & 0xff,
];
List<int> caption(String s) => [0xc4, 0x22, s.length, ...s.codeUnits];
List<int> helpRecord(String s) => [0xc4, 0x19, s.length, ...s.codeUnits];
List<int> enum2e(List<String> items) {
  final b = <int>[
    for (final it in items) ...[it.length, ...it.codeUnits],
  ];
  return [0xc4, 0x2e, b.length, ...b];
}

List<int> childRef(int oid) => [0x14, 0x19, 0x01, 0xfd, oid >> 8, oid & 0xff];
List<int> memberRef(int oid) => [0x14, 0x4f, 0x01, 0xfd, oid >> 8, oid & 0xff];

DecodedSection heapSection(
  List<int> records, {
  String tag = 'BDHb',
  bool compressed = false,
}) {
  final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
  return DecodedSection(
    section: ViSection(tag: tag, index: 0, dataOffset: 0, bytes: body),
    bytes: body,
    wasCompressed: compressed,
  );
}

ViModel modelFromRecords(List<int> records) =>
    buildViModelFromDecoded([heapSection(records)]);

ViHeapObject heapObj(
  int kind, {
  int oid = 1,
  ViObjectKind? cat,
  (int, int, int, int)? at,
  String? label,
  List<String>? items,
  List<String>? plotNames,
  List<int>? plotColors,
  double? min,
  double? max,
  String? help,
  ViTypeKind? typeKind,
}) {
  final o = ViHeapObject(oid: oid, kind: kind, offset: 0);
  if (cat != null) o.category = cat;
  if (plotColors != null) o.plotColors = plotColors;
  if (at != null) {
    o.absBounds = HeapRect(
      top: at.$1,
      left: at.$2,
      bottom: at.$3,
      right: at.$4,
    );
  }
  if (label != null) o.label = label;
  if (items != null) o.items = items;
  if (plotNames != null) o.plotNames = plotNames;
  if (min != null) o.controlMin = min;
  if (max != null) o.controlMax = max;
  if (help != null) o.helpText = help;
  if (typeKind != null) o.typeKind = typeKind;
  return o;
}
