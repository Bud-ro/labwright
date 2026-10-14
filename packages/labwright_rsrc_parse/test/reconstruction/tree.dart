import 'dart:io';
import 'dart:typed_data';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import '../corpus_dirs.dart';
import 'reconstruction_test.dart';

/// Writes a snippet's and its reconstruction's heap records as trees without object ids:
/// `dart run test/reconstruction/tree.dart snippet.png` leaves `orig-BDHb.txt`,
/// `built-BDHb.txt` and the panel pair under `$TMPDIR` for diffing.
String hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');

void dump(List<HeapNode> nodes, String pad, StringSink out) {
  for (final n in nodes) {
    switch (n) {
      case HeapObjectNode():
        out.writeln(
          '$pad${HeapObjectClass.fromCode(n.kind).name}(0x${n.kind.toRadixString(16)}) tag=0x${((n.lead & 3) << 8 | n.tag).toRadixString(16)}',
        );
        dump(n.children, '$pad  ', out);
      case HeapGroupNode():
        out.writeln('$pad[g 0x${n.rawId.toRadixString(16)}${n.counted ? '' : ' ${hex(n.open.sublist(2))}'}]');
        dump(n.children, '$pad  ', out);
      case HeapRecordNode():
        final a = decodeHeapAttr(n.bytes, 0);
        if (a != null && a.length == n.bytes.length) {
          final v = a.value;
          final skip = a.attribute == HeapAttribute.typeDescIndex;
          final vs = skip
              ? '*'
              : v is int
              ? '0x${v.toRadixString(16)}'
              : v is Uint8List
              ? hex(v)
              : '$v';
          out.writeln('$pad${a.attribute.name}(0x${a.rawTag.toRadixString(16)}) ${a.width.name} = $vs');
          continue;
        }
        final r = decodeHeapRef(n.bytes, 0);
        if (r != null && r.length == n.bytes.length) {
          out.writeln('$pad-> ${r.kind.name}(0x${((n.bytes[0] & 3) << 8 | n.bytes[1]).toRadixString(16)})');
          continue;
        }
        if (n.bytes[0] == kHeapRecordPrefix) {
          final c = c4FrameAt(n.bytes, 0, '');
          final op = HeapOpcode.fromByte(n.bytes[1]);
          out.writeln(
            '$pad${op.name}: ${c?.rect ?? (op == HeapOpcode.caption ? String.fromCharCodes(n.bytes, 3) : hex(n.bytes))}',
          );
          continue;
        }
        out.writeln('$pad?? ${hex(n.bytes)}');
    }
  }
}

void main(List<String> args) {
  final name = args[0];
  final original = buildViModel(extractSnippetVi(snippetPng(name).readAsBytesSync())!);
  final built = reconstructions[name]!();
  final t = Platform.environment['TMPDIR'];
  for (final (label, model) in [('orig', original), ('built', built)]) {
    for (final tag in ['BDHb', 'FPHb']) {
      final out = StringBuffer();
      dump(parseHeapTree(model.section(tag)!.bytes), '', out);
      File('$t/$label-$tag.txt').writeAsStringSync(out.toString());
    }
  }
}
