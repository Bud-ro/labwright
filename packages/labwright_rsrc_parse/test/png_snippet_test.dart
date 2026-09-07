import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../tool/corpus_base.dart';
import 'corpus_dirs.dart';

Uint8List png(List<(String, List<int>)> chunks, {String? corruptCrcOf}) {
  final b = BytesBuilder()..add([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  for (final (type, data) in chunks) {
    final frame = Uint8List(12 + data.length);
    final d = ByteData.sublistView(frame);
    d.setUint32(0, data.length);
    frame.setAll(4, type.codeUnits);
    frame.setAll(8, data);
    var crc = crc32(frame, 4, 8 + data.length);
    if (type == corruptCrcOf) crc ^= 1;
    d.setUint32(8 + data.length, crc);
    b.add(frame);
  }
  return b.toBytes();
}

const rsrc = [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a, 0x00, 0x03];

const kTrackedSnippetCount = 46;

void main() {
  final ihdr = ('IHDR', List<int>.filled(13, 0));
  final iend = ('IEND', <int>[]);

  test('extractSnippetVi over framing cases', () {
    final cases = <(String, Uint8List, List<int>?)>[
      ('snippet', png([ihdr, ('niVI', rsrc), iend]), rsrc),
      (
        'niVI after IDAT',
        png([
          ihdr,
          ('IDAT', [1, 2]),
          ('niVI', rsrc),
          iend,
        ]),
        rsrc,
      ),
      (
        'no niVI',
        png([
          ihdr,
          ('IDAT', [1, 2]),
          iend,
        ]),
        null,
      ),
      ('bad CRC', png([ihdr, ('niVI', rsrc), iend], corruptCrcOf: 'niVI'), null),
      (
        'payload not RSRC',
        png([
          ihdr,
          ('niVI', [1, 2, 3, 4, 5, 6, 7]),
          iend,
        ]),
        null,
      ),
      (
        'payload shorter than magic',
        png([
          ihdr,
          ('niVI', [0x52]),
          iend,
        ]),
        null,
      ),
      ('niVI after IEND is not reached', png([ihdr, iend, ('niVI', rsrc)]), null),
      ('truncated chunk', Uint8List.sublistView(png([ihdr, ('niVI', rsrc), iend]), 0, 30), null),
      ('not a PNG', Uint8List.fromList(rsrc), null),
      ('empty', Uint8List(0), null),
    ];
    for (final (name, bytes, want) in cases) {
      expect(extractSnippetVi(bytes), want, reason: name);
    }
  });

  test('isPngBytes', () {
    expect(isPngBytes(png([ihdr])), isTrue);
    expect(isPngBytes(Uint8List.fromList(rsrc)), isFalse);
    expect(isPngBytes(Uint8List(4)), isFalse);
  });

  test('snippetDiagramInterior is the inside of the measured chrome frame', () {
    expect(
      snippetDiagramInterior(210, 83),
      (left: 2, top: 26, right: 208, bottom: 81),
    );
  });

  group('corpus snippets', () {
    final repos = <(String, bool Function(String), int)>[
      (
        'rcpacini_LabVIEW-VI-Snippet',
        (p) => p.contains('Examples/Snippets'),
        12,
      ),
      (
        'rcpacini_VI-Snippets',
        (p) => !p.endsWith('VI_Anatomy.png') && !p.endsWith('isometric.png'),
        34,
      ),
    ];

    test('every snippet PNG extracts to a parseable VI with a positioned BD', () {
      for (final (repoDir, isSnippet, count) in repos) {
        final dir = Directory('${corpusViDir.path}/$repoDir');
        if (!dir.existsSync()) continue;
        final pngs = dir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.png')).toList();
        bool inSnippets(File f) => isSnippet(f.path.replaceAll(r'\', '/'));
        final snippets = pngs.where(inSnippets).toList();
        expect(snippets, hasLength(count), reason: repoDir);
        for (final f in snippets) {
          final vi = extractSnippetVi(f.readAsBytesSync());
          expect(vi, isNotNull, reason: f.path);
          final model = buildViModel(vi!);
          final positioned = [
            for (final d in model.blockDiagrams) d.objects.where((o) => o.absBounds != null).length,
          ];
          expect(positioned.any((n) => n > 0), isTrue, reason: f.path);
        }
        for (final f in pngs.where((f) => !inSnippets(f))) {
          expect(extractSnippetVi(f.readAsBytesSync()), isNull, reason: f.path);
        }
      }
    });

    Future<List<(String, bool?)>> decodeAll(Directory dir) async {
      final pngs = dir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.png')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      return corpusParallel(pngs, (bytes, path) {
        final vi = extractSnippetVi(bytes);
        if (vi == null) return (path, null);
        final positioned = buildViModel(vi).blockDiagrams.any((d) => d.objects.any((o) => o.absBounds != null));
        return (path, positioned);
      });
    }

    test('every tracked snippet extracts to a parseable VI with a positioned BD', () async {
      final results = await decodeAll(Directory('${corpusBaseDir().path}/snippets'));
      final snippets = results
          .where((r) => r.$2 != null && !r.$1.replaceAll(r'\', '/').contains('/snippets/bulk/'))
          .toList();
      expect(snippets, hasLength(kTrackedSnippetCount));
      for (final (path, positioned) in snippets) {
        expect(positioned, isTrue, reason: path);
      }
    });

    test('every fetched snippet collection extracts to a parseable VI with a positioned BD', () async {
      final snippets = Directory('${corpusBaseDir().path}/snippets');
      final sources = (jsonDecode(File('${snippets.path}/sources.json').readAsStringSync())['sources'] as List)
          .cast<Map<String, dynamic>>();
      for (final source in sources) {
        final repo = source['repo'] as String;
        final dir = Directory('${snippets.path}/bulk/${repo.replaceAll('/', '_')}');
        if (!dir.existsSync()) {
          markTestSkipped('$repo not fetched');
          continue;
        }
        final results = await decodeAll(dir);
        final decoded = results.where((r) => r.$2 != null).toList();
        expect(decoded, hasLength(source['files']), reason: repo);
        for (final (path, positioned) in decoded) {
          expect(positioned, isTrue, reason: path);
        }
      }
    });
  });
}
