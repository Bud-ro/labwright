import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Run: `dart run tool/probe_tags.dart VITS DSIM LIbd ...`
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

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

String _printableRuns(Uint8List bytes, {int minLen = 4, int cap = 5}) {
  final runs = <String>[];
  final current = StringBuffer();
  for (final byte in bytes) {
    if (byte >= 0x20 && byte < 0x7f) {
      current.writeCharCode(byte);
    } else {
      if (current.length >= minLen) runs.add(current.toString());
      current.clear();
      if (runs.length >= cap) break;
    }
  }
  if (current.length >= minLen && runs.length < cap) runs.add(current.toString());
  return runs.join(' | ');
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: probe_tags <TAG>...');
    exit(1);
  }
  final dir = Directory('${_corpusBase()}/vi');
  final vis =
      dir.listSync(recursive: true).whereType<File>().where((f) => f.path.toLowerCase().endsWith('.vi')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final samples = <String, List<Uint8List>>{for (final tag in args) tag: []};
  final sizes = <String, Map<int, int>>{for (final tag in args) tag: {}};
  for (final file in vis) {
    try {
      for (final decoded in decodeSections(file.readAsBytesSync())) {
        if (!samples.containsKey(decoded.tag)) continue;
        sizes[decoded.tag]!.update(decoded.bytes.length, (v) => v + 1, ifAbsent: () => 1);
        if (samples[decoded.tag]!.length < 400) samples[decoded.tag]!.add(decoded.bytes);
      }
    } catch (_) {}
  }

  for (final tag in args) {
    final sizeDist = sizes[tag]!;
    final total = sizeDist.values.fold<int>(0, (a, b) => a + b);
    final topSizes = sizeDist.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    stdout.writeln('════════ $tag: $total sections, ${sizeDist.length} distinct sizes');
    stdout.writeln('  top sizes: ${topSizes.take(8).map((e) => '${e.key}B x${e.value}').join(', ')}');
    final sample = samples[tag]!;
    if (sample.isEmpty) continue;
    final leads = <String, int>{};
    for (final bytes in sample) {
      final lead = _hex(bytes.sublist(0, bytes.length < 16 ? bytes.length : 16));
      leads.update(lead, (v) => v + 1, ifAbsent: () => 1);
    }
    final topLeads = leads.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    for (final entry in topLeads.take(4)) {
      stdout.writeln('  lead x${entry.value}: ${entry.key}');
    }
    final varied = sample.where((s) => s.length >= 12).take(200).toList();
    var u32beCount = 0, u32leCount = 0, u16beCount = 0;
    for (final bytes in varied) {
      final view = ByteData.sublistView(bytes);
      final u32be = view.getUint32(0);
      final u32le = view.getUint32(0, Endian.little);
      final u16be = view.getUint16(0);
      if (u32be > 0 && u32be < 10000 && (bytes.length - 4) % u32be == 0) u32beCount++;
      if (u32le > 0 && u32le < 10000 && (bytes.length - 4) % u32le == 0) u32leCount++;
      if (u16be > 0 && u16be < 10000 && (bytes.length - 2) % u16be == 0) u16beCount++;
    }
    stdout.writeln('  count-header fits over ${varied.length}: u32be=$u32beCount u32le=$u32leCount u16be=$u16beCount');
    final biggest = sample.reduce((a, b) => a.length >= b.length ? a : b);
    stdout.writeln('  strings(${biggest.length}B sample): ${_printableRuns(biggest)}');
    stdout.writeln();
  }
}
