import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// The repo-relative directory [relative] (e.g. the fetched corpus), found by
/// walking up from the test working directory; null when absent (corpus-backed
/// tests then skip). One walk shared by every corpus-backed test in the app.
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

/// The snippet references: the tracked flat set under `corpus/snippets`, or —
/// when a checkout predates it — the same PNGs from the fetched oracle repos.
/// These carry embedded VIs and are the project's concrete render/parse
/// feedback loop, so they are committed and CI always has them. Snippet-ness
/// is decided by extraction, not by listing: plain art PNGs carry no niVI and
/// are filtered here.
List<File> snippetCorpusPngs() {
  final tracked = repoDir('packages/labwright_rsrc_parse/corpus/snippets');
  final dirs = tracked != null
      ? [tracked]
      : [
          for (final repo in const [
            'rcpacini_LabVIEW-VI-Snippet',
            'rcpacini_VI-Snippets',
          ])
            repoDir('packages/labwright_rsrc_parse/corpus/vi/$repo'),
        ].whereType<Directory>();
  final files = <File>[];
  for (final dir in dirs) {
    files.addAll(
      dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.png'))
          .where((f) => extractSnippetVi(f.readAsBytesSync()) != null),
    );
  }
  return files..sort((a, b) => a.path.compareTo(b.path));
}

/// The snippet reference PNG named [pngName] (e.g. `crc8.png`), from the
/// tracked flat set or — in a checkout that predates it — the fetched oracle
/// repos. Null when no corpus is present, so corpus-backed tests skip.
File? snippetPng(String pngName) {
  for (final relative in const [
    'packages/labwright_rsrc_parse/corpus/snippets',
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

/// Pumps [body] inside MaterialApp/Scaffold at a fixed [view] size.
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

/// Loads the app's bundled Selawik faces into the test binding under the
/// family the diagram painter uses, so canvas text rasterises with real
/// glyphs. Without this every glyph is the test binding's Ahem block — solid
/// squares that swamp the oracle's ink/edge masks and drag its registration.
///
/// Fails loudly when a face is missing: the paths are relative to the working
/// directory, so a run started elsewhere would otherwise register nothing and
/// every metric would silently read Ahem's widths.
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

/// Splices a `niVI` chunk carrying [vi] into the PNG [png] (before `IEND`),
/// CRC framed — a synthetic VI-snippet built without LabVIEW.
Uint8List spliceNiVi(Uint8List png, Uint8List vi) {
  final chunk = Uint8List(12 + vi.length);
  final d = ByteData.sublistView(chunk);
  d.setUint32(0, vi.length);
  chunk.setAll(4, 'niVI'.codeUnits);
  chunk.setAll(8, vi);
  d.setUint32(8 + vi.length, crc32(chunk, 4, 8 + vi.length));
  final iend = png.length - 12; // [len=0][IEND][crc]
  return Uint8List.fromList([
    ...png.sublist(0, iend),
    ...chunk,
    ...png.sublist(iend),
  ]);
}

// Heap record builders (mirror the videcode bracket model).
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

/// Frames [records] with the u32 heap content-length header as a section.
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

/// A ViHeapObject with the commonly-poked fields settable in one call.
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
