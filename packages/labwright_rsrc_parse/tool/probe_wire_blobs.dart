import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Second wire hunt: scan heap ATTRIBUTES (not C4 records) in BD heaps for
/// blob payloads that read as runs of plausible i16 coordinate pairs, and
/// report which attribute ids carry them. Also inventories blob attr sizes.
String _corpusBase() {
  const pkgRel = 'packages/labwright_rsrc_parse/corpus';
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/$pkgRel/sources.json').existsSync()) return '${dir.path}/$pkgRel';
    if (File('${dir.path}/corpus/sources.json').existsSync()) return '${dir.path}/corpus';
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return 'corpus';
}

void main(List<String> args) {
  final dir = Directory('${_corpusBase()}/vi');
  final vis =
      dir.listSync(recursive: true).whereType<File>().where((f) => f.path.toLowerCase().endsWith('.vi')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final sample = vis.take(args.isNotEmpty ? int.parse(args[0]) : 150).toList();

  final pointyBlobsByAttr = <int, int>{};
  final blobsByAttr = <int, int>{};
  var blobCount = 0;
  var pointyBlobs = 0;

  for (final file in sample) {
    try {
      for (final decoded in decodeSections(file.readAsBytesSync())) {
        if (decoded.tag != 'BDHb' && decoded.tag != 'BDHc') continue;
        final body = decoded.bytes;
        for (final span in walkHeapBody(body).spans) {
          final attr = decodeHeapAttr(body, span.offset);
          if (attr == null) continue;
          final value = attr.value;
          if (value is! Uint8List || value.length < 8) continue;
          final blob = value;
          blobCount++;
          blobsByAttr.update(attr.id, (v) => v + 1, ifAbsent: () => 1);
          if (blob.length % 4 != 0) continue;
          final view = ByteData.sublistView(blob);
          var plausible = true;
          for (var at = 0; at + 4 <= blob.length; at += 4) {
            final a = view.getInt16(at);
            final b = view.getInt16(at + 2);
            if (a < -50 || a > 8000 || b < -50 || b > 8000) {
              plausible = false;
              break;
            }
          }
          if (plausible && blob.length >= 12) {
            pointyBlobs++;
            pointyBlobsByAttr.update(attr.id, (v) => v + 1, ifAbsent: () => 1);
          }
        }
      }
    } catch (_) {}
  }

  stdout.writeln('sample ${sample.length} VIs · BD blob attrs: $blobCount · point-like: $pointyBlobs');
  final sorted = pointyBlobsByAttr.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  for (final entry in sorted.take(12)) {
    stdout.writeln(
      '  attr 0x${entry.key.toRadixString(16)}: ${entry.value} point-like '
      '(of ${blobsByAttr[entry.key]} blobs)',
    );
  }
}
