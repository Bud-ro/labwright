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

  test('every tracked snippet extracts to a parseable VI with a positioned BD', () async {
    final results = await decodeSnippetPngs(Directory('${corpusBaseDir().path}/snippets'));
    final snippets = results
        .where((r) => r.$2 != null && !r.$1.replaceAll(r'\', '/').contains('/snippets/bulk/'))
        .toList();
    expect(snippets, hasLength(kTrackedSnippetCount));
    for (final (path, positioned) in snippets) {
      expect(positioned, isTrue, reason: path);
    }
  });
}
