import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Wire hunt: do block-diagram heaps carry (a) terminal-to-terminal
/// connectivity via typed refs, or (b) polyline point-list records?
///
/// For a sample of VIs: builds the diagram, then
///  1. counts terminal (0x68-class) objects and where their refs point,
///  2. scans every framed C4 record payload for runs of plausible i16
///     coordinate pairs (values within the diagram's bounds envelope),
///  3. reports undecoded record kinds by frequency inside BD heaps.
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
  final vis = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.vi'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final sample = args.isNotEmpty ? vis.take(int.parse(args[0])).toList() : vis.take(120).toList();

  var terminalCount = 0;
  var terminalWithRefs = 0;
  final refTargets = <String, int>{}; // terminal ref -> target kind name
  var polylineRecords = 0;
  var scannedRecords = 0;
  final polylineKinds = <int, int>{};

  for (final file in sample) {
    try {
      final bytes = file.readAsBytesSync();
      final model = buildViModel(bytes);
      for (final diagram in model.blockDiagrams) {
        final byOid = diagram.byId;
        for (final object in diagram.objects) {
          if (object.kind != 0x68) continue;
          terminalCount++;
          if (object.refs.isNotEmpty || object.typedRefs.isNotEmpty) terminalWithRefs++;
          for (final refs in object.typedRefs.entries) {
            for (final oid in refs.value) {
              final target = byOid[oid];
              final key = '${refs.key.refName}->${target == null ? 'unresolved' : 'class 0x${target.kind.toRadixString(16)}'}';
              refTargets.update(key, (v) => v + 1, ifAbsent: () => 1);
            }
          }
        }
      }
      // point-list scan over all BD C4 records
      for (final decoded in decodeSections(bytes)) {
        if (decoded.tag != 'BDHb' && decoded.tag != 'BDHc') continue;
        for (final record in scanC4Records(decoded.bytes, decoded.tag)) {
          scannedRecords++;
          final payload = record.payload;
          if (payload.length < 8 || payload.length % 4 != 0) continue;
          final view = ByteData.sublistView(payload);
          var pairs = 0;
          var plausible = true;
          for (var at = 0; at + 4 <= payload.length; at += 4) {
            final a = view.getInt16(at);
            final b = view.getInt16(at + 2);
            if (a < -50 || a > 8000 || b < -50 || b > 8000) {
              plausible = false;
              break;
            }
            pairs++;
          }
          if (plausible && pairs >= 3) {
            polylineRecords++;
            polylineKinds.update(record.kind.byte, (v) => v + 1, ifAbsent: () => 1);
          }
        }
      }
    } catch (_) {}
  }

  stdout.writeln('sample: ${sample.length} VIs');
  stdout.writeln('BD terminals(0x68): $terminalCount, with refs: $terminalWithRefs');
  final sortedTargets = refTargets.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  for (final entry in sortedTargets.take(12)) {
    stdout.writeln('  ${entry.key}: ${entry.value}');
  }
  stdout.writeln('C4 records scanned: $scannedRecords; >=3 plausible i16-pair runs: $polylineRecords');
  final sortedKinds = polylineKinds.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  for (final entry in sortedKinds.take(10)) {
    stdout.writeln('  op 0x${entry.key.toRadixString(16)}: ${entry.value}');
  }
}
