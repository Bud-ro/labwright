@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// The binary TOF1 WRITER's corpus gates — the `write(parse(x)) == x`
/// discipline over every corpus binary:
///
///  * **body byte-exact**: [BinarySeqWriteModel.writeBody] reproduces the
///    inflated body byte-for-byte for every inflatable binary (169/169);
///  * **container structurally reproduced**: [BinarySeqWriteModel.writeFile]
///    emits the retained header (size field re-derived from the body) plus a
///    valid zlib stream that re-inflates to the byte-exact body. The original
///    DEFLATE bytes are not reproducible — no Dart `ZLibCodec` setting
///    matches NI's compressor on any corpus file (see `writeFile`) — so the
///    full-file gate is structural, not byte-exact;
///  * **scoreboard** ([BinaryWriteScoreboard]): how much of each body is
///    written FROM THE MODEL (pool strings, pool/type references, counts,
///    inline values) vs re-emitted retained structure vs copied verbatim —
///    the writer-side mirror of [BinaryByteCoverage], floored so decode
///    progress must move both.
void main() {
  if (!corpusSeqDir.existsSync()) {
    test('binary writer corpus gates (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  test('whole corpus: write(parse(f)) reproduces every inflated body byte-exactly', () {
    var binaries = 0, bodyExact = 0, containerOk = 0, sizeWords = 0;
    var total = const BinaryWriteScoreboard(
      bodyBytes: 0,
      poolBytes: 0,
      modelBytes: 0,
      structuralBytes: 0,
      copiedBytes: 0,
    );
    final failures = <String>[];
    for (final f in corpusSeqDir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.seq')) continue;
      final bytes = Uint8List.fromList(f.readAsBytesSync());
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      final model = parseBinarySeqWriteModel(bytes);
      if (model == null) continue;
      binaries++;
      final body = inflateBinaryBody(bytes)!;
      final written = model.writeBody();
      if (_bytesEqual(written, body)) {
        bodyExact++;
      } else {
        failures.add(f.path);
      }
      total = total + model.scoreboard;

      // Container: retained header re-emitted (with the size field derived
      // from the body), and the fresh zlib stream re-inflates byte-exactly.
      if (model.headerHasSizeWord) sizeWords++;
      final file = model.writeFile();
      final reBody = inflateBinaryBody(file);
      if (detectSeqFormat(file) == SeqFormat.binary &&
          _bytesEqual(
            Uint8List.sublistView(file, 0, model.header.length),
            Uint8List.sublistView(bytes, 0, model.header.length),
          ) &&
          reBody != null &&
          _bytesEqual(reBody, body)) {
        containerOk++;
      }
    }
    // ignore: avoid_print
    print(
      'binary writer: $bodyExact/$binaries bodies byte-exact · '
      '$containerOk containers structurally reproduced · '
      '$sizeWords size words · $total',
    );
    expect(failures, isEmpty, reason: 'body round-trip diverged:\n${failures.take(5).join('\n')}');
    expect(binaries, greaterThanOrEqualTo(165));
    expect(bodyExact, binaries);
    expect(containerOk, binaries);
    expect(sizeWords, binaries, reason: 'a header lost its PMCZ size field');
    // Measured 2026-07 on the clean 169-binary corpus: record region 23.1 MB;
    // written-from-model 15.4%, retained-structure 16.7%, copied 67.9%.
    // Model + structure tracks the coverage pass's semantic tier (32.4%) by
    // construction — the same pass captures both — minus the spec/extdata
    // blobs the coverage pass demotes (copied here). Floors under-pin
    // slightly; decode progress must raise them.
    expect(total.recordModelRatio, greaterThanOrEqualTo(0.15));
    expect(
      (total.modelBytes + total.structuralBytes) / total.recordRegionBytes,
      greaterThanOrEqualTo(0.30),
    );
    expect(total.bodyModelRatio, greaterThanOrEqualTo(0.22));
  });

  test('rosetta binaries: byte-exact bodies with a majority-model record region', () {
    var checked = 0;
    for (final f in Directory('${corpusSeqDir.path}/rosetta').listSync().whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.seq')) continue;
      final bytes = Uint8List.fromList(f.readAsBytesSync());
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      final model = parseBinarySeqWriteModel(bytes)!;
      expect(model.writeBody(), inflateBinaryBody(bytes), reason: f.path);
      final score = model.scoreboard;
      // Measured: 33.8% model / 40.7% structural on the six rosetta
      // binaries — every span the decoder covers re-serializes.
      expect(score.recordModelRatio, greaterThanOrEqualTo(0.25), reason: f.path);
      checked++;
    }
    expect(checked, greaterThanOrEqualTo(6), reason: 'rosetta binaries missing — partial checkout?');
  });
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
