@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:isolate';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'snippets.dart';

Map<String, List<int>> sweepChunk(List<String> paths) {
  final seen = <int>{}, unaccounted = <int>{}, rootUnmapped = <int>{};
  var total = 0, mapped = 0, internal = 0, structuralFailure = 0;
  for (final path in paths) {
    List<ViType> pool;
    try {
      pool = typePoolFromDecoded(decodeSections(File(path).readAsBytesSync()));
    } catch (_) {
      continue;
    }
    for (final type in pool) {
      total++;
      seen.add(type.code);
      if (!lvTypeCodeIsAccountedFor(type.code)) unaccounted.add(type.code);
      final mapping = mapLvType(type, pool);
      switch (mapping.status) {
        case LvMapStatus.mapped:
          mapped++;
        case LvMapStatus.internal:
          internal++;
        case LvMapStatus.unmapped:
          if (mapping.unmappedCode case final code?) {
            rootUnmapped.add(code);
          } else {
            structuralFailure++;
          }
      }
    }
  }
  return {
    'seen': seen.toList(),
    'unaccounted': unaccounted.toList(),
    'rootUnmapped': rootUnmapped.toList(),
    'counts': [total, mapped, internal, structuralFailure],
  };
}

void main() {
  final corpus = corpusViDir();
  final vis = corpus == null ? const <String>[] : corpusViPaths(corpus);

  test(
    'every VCTP type code in the corpus is either modelled or on the documented review list',
    () async {
      final workers = (Platform.numberOfProcessors - 2).clamp(1, 16);
      final chunks = List.generate(workers, (_) => <String>[]);
      for (var i = 0; i < vis.length; i++) {
        chunks[i % workers].add(vis[i]);
      }
      final results = await Future.wait(chunks.map((chunk) => Isolate.run(() => sweepChunk(chunk))));
      final seen = <int>{}, rootUnmapped = <int>{}, unaccounted = <int>{};
      final counts = List.filled(4, 0);
      for (final result in results) {
        seen.addAll(result['seen']!);
        rootUnmapped.addAll(result['rootUnmapped']!);
        unaccounted.addAll(result['unaccounted']!);
        for (var i = 0; i < counts.length; i++) {
          counts[i] += result['counts']![i];
        }
      }
      String hex(Set<int> codes) => (codes.toList()..sort()).map((c) => '0x${c.toRadixString(16)}').join(', ');

      expect(vis.length, greaterThan(7000), reason: 'the sweep must actually see the corpus');
      expect(seen.length, greaterThan(30), reason: 'the corpus exercises the breadth of the code space');
      expect(counts[0], greaterThan(500000), reason: 'every descriptor of every pool is mapped');
      expect(
        unaccounted,
        isEmpty,
        reason:
            'type codes ${hex(unaccounted)} appear in the corpus but are neither mapped, '
            'internal, nor on the review list — add them to kUnmappedTypeCodes with a note',
      );
      expect(rootUnmapped.difference(kUnmappedTypeCodes.keys.toSet()), isEmpty);
      expect(
        counts[3],
        lessThan(100),
        reason: 'a descriptor that does not frame is the rare exception, not a mapping strategy',
      );
      printOnFailure(
        'descriptors ${counts[0]}: mapped ${counts[1]}, internal ${counts[2]}, '
        'structural failure ${counts[3]}\ncodes seen: ${hex(seen)}\n'
        'review-list roots hit: ${hex(rootUnmapped)}',
      );
    },
    skip: corpus == null ? 'corpus not fetched' : null,
  );
}
