// Grammar-iteration aid for the binary typedef-body decoder: prints each
// type record's body extent — decoded records with their end offset and
// the gap to the next record's head (17 = the contiguous preamble), and
// bailing records with the first uncovered field's offset and its
// surrounding words pool-resolved (the exact spot to point the prober
// at). Usage: dart run tool/type_body_extents.dart [file.seq]
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';

void main(List<String> argv) {
  final path =
      argv.isEmpty ? 'corpus/seq/rosetta/OutputVoltage_BIN.seq' : argv.first;
  final bytes = File(path).readAsBytesSync();
  final body = inflateBinaryBody(bytes);
  final layout = body == null ? null : analyzeBinaryBody(bytes);
  if (body == null || layout == null) {
    stderr.writeln('$path: not a decodable binary .seq');
    exitCode = 1;
    return;
  }
  final rr = layout.recordRegionLength;
  final view = ByteData.sublistView(body);
  final pool = <String>[];
  var p = rr;
  while (p < body.length) {
    final start = p;
    while (p < body.length && body[p] != 0) {
      p++;
    }
    pool.add(String.fromCharCodes(body, start, p));
    p++;
  }
  int u32(int at) => view.getUint32(at, Endian.little);
  String show(int v) {
    final t = v > 0 && v < pool.length && pool[v].isNotEmpty ? pool[v] : null;
    final hex = '0x${v.toRadixString(16)}';
    if (v == 0xffffffff) return 'DELIM';
    if (t == null) return hex;
    return "$hex'${t.length > 24 ? t.substring(0, 24) : t}'";
  }

  final extents = binaryTypeBodyExtents(bytes);
  for (var i = 0; i < extents.length; i++) {
    final e = extents[i];
    if (e.bail == null) {
      final nextHead = i + 1 < extents.length ? extents[i + 1].headAt : null;
      final gap = nextHead == null ? '?' : '${nextHead - 4 - e.end!}';
      print('OK    ${e.name} body=${e.bodyAt} end=${e.end} '
          'gapToNextHead=$gap');
    } else {
      final at = e.bail!;
      if (at < 0 || at + 52 > rr) {
        print('BAIL  ${e.name} body=${e.bodyAt} @$at (head rejected or '
            'out of range)');
        continue;
      }
      final words = [for (var o = -8; o <= 48; o += 4) show(u32(at + o))];
      print('BAIL  ${e.name} body=${e.bodyAt} @$at  '
          '«${words.sublist(0, 2).join(' ')}» ${words.sublist(2).join(' ')}');
    }
  }
}
