import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'corpus_base.dart';

/// Census of walked heap records in the **10-bit tag-id space**.
///
/// The two header bytes of every heap record decompose as
/// `byte0 = sizeSpec(3b)<<5 | hasAttrList(1b)<<4 | scope(2b)<<2 | rawTagHi(2b)`,
/// `byte1 = rawTagLo` — so the "attribute id byte" is only the LOW 8 bits of a
/// 10-bit raw tag id, and e.g. `C5 E7` (raw 0x1E7) is a different tag than
/// `44 E7` (raw 0x0E7). This tool re-buckets every walked span by
/// (tier, scope, rawTagId, sizeSpec) to itemize the non-semantic byte mass in
/// the true tag space.
///
/// Also probes the `64 CB 26` framing special-case: under the header grammar a
/// `64 CB` record is a leaf with sizeSpec 3 (3 value bytes, 5 total), but
/// [recordSkip] frames it as 3 bytes total. Re-walk affected sections with the
/// 5-byte reading and compare walk completeness corpus-wide.
///
/// Run: `dart run tool/probe_tag_census.dart [corpusRoot=<pkg>/corpus/vi]`

class _Agg {
  final Map<String, int> tierKeyBytes = {};
  final Map<String, int> tierKeyCount = {};

  // 64 CB 26 experiment.
  int cb26Sections = 0; // sections containing >=1 `64 cb 26` span
  int cb26Complete3 = 0, cb26Complete5 = 0; // walk reaches EOF under 3B vs 5B
  int cb26Covered3 = 0, cb26Covered5 = 0, cb26Body = 0;

  void bump(Map<String, int> m, String k, int n) => m[k] = (m[k] ?? 0) + n;

  void merge(_Agg o) {
    o.tierKeyBytes.forEach((k, v) => bump(tierKeyBytes, k, v));
    o.tierKeyCount.forEach((k, v) => bump(tierKeyCount, k, v));
    cb26Sections += o.cb26Sections;
    cb26Complete3 += o.cb26Complete3;
    cb26Complete5 += o.cb26Complete5;
    cb26Covered3 += o.cb26Covered3;
    cb26Covered5 += o.cb26Covered5;
    cb26Body += o.cb26Body;
  }
}

String _tagKey(Uint8List body, int offset, int lead) {
  if (offset + 2 > body.length) return 'trunc:${lead.toRadixString(16)}';
  final sizeSpec = lead >> 5;
  final hasAttrs = (lead >> 4) & 1;
  final scope = (lead >> 2) & 3;
  final raw = ((lead & 3) << 8) | body[offset + 1];
  final scopeCh = const ['o', 'l', 'c', 'x'][scope];
  final sz = switch (sizeSpec) {
    0 => 's0',
    7 => 'b1',
    6 => 'lp',
    _ => 'u$sizeSpec',
  };
  return '$scopeCh${hasAttrs == 1 ? 'a' : '-'}:${raw.toRadixString(16).padLeft(3, '0')}:$sz';
}

/// Local re-walk with the `64 cb 26` case read as the grammar-correct 5 bytes.
({bool complete, int covered}) _walk5(Uint8List body) {
  final length = body.length;
  var i = 4, covered = 0;
  while (i < length) {
    int? step;
    if (body[i] == 0x64 && i + 3 <= length && body[i + 1] == 0xcb && body[i + 2] == 0x26) {
      step = 5;
    } else {
      step = recordSkip(body, i);
    }
    if (step == null || i + step > length) return (complete: false, covered: covered);
    covered += step;
    i += step;
  }
  return (complete: true, covered: covered);
}

void _probeVi(Uint8List bytes, _Agg agg) {
  final List<DecodedSection> secs;
  try {
    secs = decodeSections(bytes);
  } catch (_) {
    return;
  }
  for (final sec in secs) {
    if (!kHeapSectionTags.contains(sec.tag) || sec.bytes.length < 6) continue;
    final body = sec.bytes;
    final walk = walkHeapBody(body);
    var sawCb26 = false;
    for (final span in walk.spans) {
      final tier = heapDecodeTier(body, span.offset, span.lead, sec.tag);
      final tk = '${tier.index}|${_tagKey(body, span.offset, span.lead)}';
      agg.bump(agg.tierKeyBytes, tk, span.length);
      agg.bump(agg.tierKeyCount, tk, 1);
      if (span.lead == 0x64 && span.length == 3) sawCb26 = true;
    }
    if (sawCb26) {
      agg.cb26Sections++;
      if (walk.complete) agg.cb26Complete3++;
      agg.cb26Covered3 += walk.coveredBytes;
      final w5 = _walk5(body);
      if (w5.complete) agg.cb26Complete5++;
      agg.cb26Covered5 += w5.covered;
      agg.cb26Body += walk.bodyBytes;
    }
  }
}

String _pct(int a, int b) => b == 0 ? '-' : (100 * a / b).toStringAsFixed(2);

Future<void> main(List<String> args) async {
  final root = args.isNotEmpty ? args[0] : '${corpusBaseDir().path}/vi';
  final files = listCorpusVis(Directory(root));
  stdout.writeln('corpus: ${files.length} VIs under $root');
  final sw = Stopwatch()..start();

  final workers = (Platform.numberOfProcessors - 2).clamp(1, 16);
  final chunks = List.generate(workers, (_) => <String>[]);
  for (var i = 0; i < files.length; i++) {
    chunks[i % workers].add(files[i].path);
  }
  final aggs = await Future.wait(
    chunks.map(
      (chunk) => Isolate.run(() {
        final agg = _Agg();
        for (final p in chunk) {
          _probeVi(File(p).readAsBytesSync(), agg);
        }
        return agg;
      }),
    ),
  );
  final agg = _Agg();
  for (final a in aggs) {
    agg.merge(a);
  }
  stdout.writeln('probe pass: ${sw.elapsedMilliseconds} ms');

  final totalBytes = agg.tierKeyBytes.values.fold<int>(0, (a, b) => a + b);
  stdout.writeln('\n#### TAG CENSUS (span bytes by tier | scope+attrs : rawTagId : size) ####');
  stdout.writeln('total span bytes: $totalBytes');
  for (final tier in [0, 1, 2]) {
    final rows = agg.tierKeyBytes.entries.where((e) => e.key.startsWith('$tier|')).toList()
      ..sort((a, b) => b.value - a.value);
    final tierTotal = rows.fold<int>(0, (a, e) => a + e.value);
    final label = const ['semantic', 'valueKindKnown', 'framed-only'][tier];
    stdout.writeln('\n-- tier $label ($tierTotal bytes = ${_pct(tierTotal, totalBytes)}%) --');
    const show = 100000;
    for (final e in rows.take(show)) {
      stdout.writeln(
        '  ${e.key.substring(2).padRight(16)} bytes=${e.value.toString().padLeft(10)} '
        '(${_pct(e.value, totalBytes)}%)  n=${agg.tierKeyCount[e.key]}',
      );
    }
    if (rows.length > show) {
      final rest = rows.skip(show).fold<int>(0, (a, e) => a + e.value);
      stdout.writeln('  ... ${rows.length - show} more keys ($rest bytes = ${_pct(rest, totalBytes)}%)');
    }
  }

  stdout.writeln('\n#### 64 CB 26 framing experiment ####');
  stdout.writeln(
    'sections with a 3-byte 64CB26 span: ${agg.cb26Sections}\n'
    '  3-byte reading: complete=${agg.cb26Complete3} (${_pct(agg.cb26Complete3, agg.cb26Sections)}%) '
    'covered=${_pct(agg.cb26Covered3, agg.cb26Body)}%\n'
    '  5-byte reading: complete=${agg.cb26Complete5} (${_pct(agg.cb26Complete5, agg.cb26Sections)}%) '
    'covered=${_pct(agg.cb26Covered5, agg.cb26Body)}%',
  );
}
