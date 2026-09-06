import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

void main() {
  Uint8List synthetic(Uint8List body) {
    const headerLen = 64;
    final compressed = ZLibCodec().encode(body);
    final out = Uint8List(headerLen + compressed.length);
    out.setRange(0, 4, 'TOF1'.codeUnits);
    out.setRange(headerLen - 8, headerLen - 4, 'PMCZ'.codeUnits);
    ByteData.sublistView(out).setUint32(headerLen - 4, body.length, Endian.little);
    out.setRange(headerLen, out.length, compressed);
    return out;
  }

  final unframedBody = Uint8List.fromList([for (var i = 0; i < 96; i++) (i * 7 + 1) & 0x3f]);

  final framedBody = Uint8List.fromList([
    for (var i = 0; i < 40; i++) 0x11,
    ...'alpha\x00beta\x00gamma\x00delta\x00epsilon\x00'.codeUnits,
  ]);

  test('unframed body: whole-body copy plan is byte-exact and the container patches', () {
    final bytes = synthetic(unframedBody);
    final model = parseBinarySeqWriteModel(bytes)!;
    expect(model.pool, isEmpty);
    expect(model.writeBody(), unframedBody);
    expect(model.headerHasSizeWord, isTrue);
    final rewritten = model.writeFile();
    expect(detectSeqFormat(rewritten), SeqFormat.binary);
    expect(Uint8List.sublistView(rewritten, 0, model.header.length), model.header);
    expect(inflateBinaryBody(rewritten), unframedBody);
  });

  test('framed body: pool is model-sourced, re-emits byte-exactly, scoreboard accounts all', () {
    final model = parseBinarySeqWriteModel(synthetic(framedBody))!;
    expect(model.pool, ['alpha', 'beta', 'gamma', 'delta', 'epsilon']);
    expect(model.poolEndsWithoutNul, isFalse);
    expect(model.recordRegionLength, 40);
    expect(model.writeBody(), framedBody);
    final score = model.scoreboard;
    expect(score.bodyBytes, framedBody.length);
    expect(score.poolBytes, framedBody.length - 40);
    expect(score.copiedBytes, 40, reason: 'nothing decodes in the synthetic record region: all copied');
    expect(score.modelBytes + score.structuralBytes, 0);
  });

  test('pool mutation flows through the model pool, record region untouched', () {
    final model = parseBinarySeqWriteModel(synthetic(framedBody))!;
    expect(model.replacePoolEntry('gamma', 'gamma-longer'), 1);
    expect(model.replacePoolEntry('absent', 'x'), 0);
    final written = model.writeBody();
    expect(Uint8List.sublistView(written, 0, 40), Uint8List.sublistView(framedBody, 0, 40));
    expect(
      String.fromCharCodes(Uint8List.sublistView(written, 40)),
      'alpha\x00beta\x00gamma-longer\x00delta\x00epsilon\x00',
    );
    final (start, end) = model.poolEntryRange(2);
    expect(start, 40 + 'alpha\x00beta\x00'.length);
    expect(end - start, 'gamma-longer'.length);
  });

  test('a body ending without a NUL re-emits without a trailing NUL', () {
    final body = Uint8List.fromList([...framedBody, ...'tail'.codeUnits]);
    final model = parseBinarySeqWriteModel(synthetic(body))!;
    expect(model.poolEndsWithoutNul, isTrue);
    expect(model.pool.last, 'tail');
    expect(model.writeBody(), body);
  });

  test('non-byte-valued pool mutations are rejected', () {
    final model = parseBinarySeqWriteModel(synthetic(framedBody))!;
    model.pool[0] = 'π';
    expect(model.writeBody, throwsArgumentError);
  });
}
