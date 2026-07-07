import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'corpus_base.dart';

/// Round-2 discriminating probes:
///
///  1. Cross-heap references: do the `14 53` (tag 52) and unresolved `14 4F`
///     (tag 48) uid values resolve against the OTHER heap's object ids
///     (BDHb <-> FPHb) within the same VI?
///  2. ASCII-int hypothesis: raw tags 0x022 / 0x0C4 / 0x08C carry magnitude-
///     encoded integers whose bytes look like short ASCII strings ("Page",
///     "VI", "21"). Measure: fraction of nonzero int values whose value bytes
///     (no leading zeros) are all printable ASCII.
///  3. Narrow color forms: per (width) class histogram + top values for raw
///     0x020 / 0x021 — do the u1/u2/u3 populations live in different classes
///     than the u4 (RGB) population?
///  4. `02 FE` records: hex context samples + count.
///
/// Run: `dart run tool/probe_tag_verify2.dart [corpusRoot=<pkg>/corpus/vi]`

class Hist {
  final Map<int, int> counts = {};
  int total = 0;
  void add(int v) {
    total++;
    if (counts.length < 4096 || counts.containsKey(v)) counts[v] = (counts[v] ?? 0) + 1;
  }

  void merge(Hist o) {
    total += o.total;
    o.counts.forEach((k, n) {
      if (counts.length < 4096 || counts.containsKey(k)) counts[k] = (counts[k] ?? 0) + n;
    });
  }

  List<MapEntry<int, int>> top(int n) => (counts.entries.toList()..sort((a, b) => b.value - a.value)).take(n).toList();
}

class _Agg {
  // 1. cross-heap
  int t53Total = 0, t53Same = 0, t53Other = 0;
  int t4fTotal = 0, t4fSame = 0, t4fOther = 0;
  // 2. ascii-int
  final Map<int, (int, int, int)> ascii = {}; // raw -> (nonzeroTrials, allPrintable, zeroes)
  // 3. narrow colors: (raw<<4)|width -> class hist ; and value hist
  final Map<int, Hist> colorClasses = {};
  final Map<int, Hist> colorValues = {};
  // 4. 02 fe
  int fe02 = 0;
  final List<String> fe02Samples = [];

  void merge(_Agg o) {
    t53Total += o.t53Total;
    t53Same += o.t53Same;
    t53Other += o.t53Other;
    t4fTotal += o.t4fTotal;
    t4fSame += o.t4fSame;
    t4fOther += o.t4fOther;
    o.ascii.forEach((k, v) {
      final cur = ascii[k] ?? (0, 0, 0);
      ascii[k] = (cur.$1 + v.$1, cur.$2 + v.$2, cur.$3 + v.$3);
    });
    void mh(Map<int, Hist> into, Map<int, Hist> from) => from.forEach((k, h) => (into[k] ??= Hist()).merge(h));
    mh(colorClasses, o.colorClasses);
    mh(colorValues, o.colorValues);
    fe02 += o.fe02;
    if (fe02Samples.length < 12) fe02Samples.addAll(o.fe02Samples.take(12 - fe02Samples.length));
  }
}

bool _printable(int b) => b >= 0x20 && b < 0x7f;

/// Whether the magnitude bytes of [v] (no leading zeros) are all printable ASCII.
bool _asciiInt(int v) {
  if (v <= 0) return false;
  var x = v;
  while (x > 0) {
    if (!_printable(x & 0xff)) return false;
    x >>= 8;
  }
  return true;
}

void _probeVi(Uint8List bytes, _Agg agg) {
  final List<DecodedSection> secs;
  try {
    secs = decodeSections(bytes);
  } catch (_) {
    return;
  }
  // Gather per-heap oid sets first (BDHb/FPHb families).
  final oidsBySec = <String, Set<int>>{};
  final pending = <(String, int, int)>[]; // (sectionTag, rawTag, uid)

  for (final sec in secs) {
    if (!kHeapSectionTags.contains(sec.tag) || sec.bytes.length < 6) continue;
    final body = sec.bytes;
    final oids = oidsBySec[sec.tag] ??= <int>{};
    walkHeapObjects<int>(
      body,
      onObjectOpen: (span, kind, oid, parent) {
        oids.add(oid);
        return kind;
      },
      onRecord: (span, kind) {
        final offset = span.offset;
        final lead = span.lead;
        if (offset + 2 > body.length) return;
        final raw = ((lead & 3) << 8) | body[offset + 1];

        if (lead == 0x14 &&
            (raw == 0x053 || raw == 0x04f) &&
            offset + 6 <= body.length &&
            body[offset + 2] == 0x01 &&
            body[offset + 3] == 0xfd &&
            (body[offset + 4] & 0x80) == 0) {
          pending.add((sec.tag, raw, (body[offset + 4] << 8) | body[offset + 5]));
          return;
        }

        // ASCII-int candidates + narrow colors: nibble-family leafs only.
        final lo = lead & 0xf, hi = lead >> 4;
        if ((lo == 4 || lo == 5 || lo == 6) && hi != 0xc) {
          final a = decodeHeapAttr(body, offset);
          final v = a?.asInt;
          if (a == null || v == null) return;
          if (raw == 0x022 || raw == 0x0c4 || raw == 0x08c || raw == 0x0c8) {
            final cur = agg.ascii[raw] ?? (0, 0, 0);
            agg.ascii[raw] = v == 0
                ? (cur.$1, cur.$2, cur.$3 + 1)
                : (cur.$1 + 1, cur.$2 + (_asciiInt(v) ? 1 : 0), cur.$3);
          }
          if (raw == 0x020 || raw == 0x021) {
            final key = (raw << 4) | a.width.index;
            (agg.colorClasses[key] ??= Hist()).add(kind ?? -1);
            (agg.colorValues[key] ??= Hist()).add(v);
          }
        }

        if (lead == 0x02 && body[offset + 1] == 0xfe && agg.fe02Samples.length < 12) {
          agg.fe02++;
          final end = (offset + 16).clamp(0, body.length);
          final hex = [
            for (var i = offset; i < end; i++) body[i].toRadixString(16).padLeft(2, '0'),
          ].join(' ');
          agg.fe02Samples.add('${sec.tag}@$offset: $hex');
        } else if (lead == 0x02 && offset + 2 <= body.length && body[offset + 1] == 0xfe) {
          agg.fe02++;
        }
      },
    );
  }

  for (final (tag, raw, uid) in pending) {
    final same = oidsBySec[tag]?.contains(uid) ?? false;
    var other = false;
    oidsBySec.forEach((t, s) {
      if (t != tag && s.contains(uid)) other = true;
    });
    if (raw == 0x053) {
      agg.t53Total++;
      if (same) agg.t53Same++;
      if (other) agg.t53Other++;
    } else {
      agg.t4fTotal++;
      if (same) agg.t4fSame++;
      if (other) agg.t4fOther++;
    }
  }
}

String _pct(int a, int b) => b == 0 ? '-' : (100 * a / b).toStringAsFixed(2);

Future<void> main(List<String> args) async {
  final root = args.isNotEmpty ? args[0] : '${corpusBaseDir().path}/vi';
  final files = listCorpusVis(Directory(root));
  stdout.writeln('corpus: ${files.length} VIs under $root');

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

  stdout.writeln('\n== cross-heap uid resolution ==');
  stdout.writeln(
    '14 53 (tag 52): total=${agg.t53Total} sameHeap=${agg.t53Same} (${_pct(agg.t53Same, agg.t53Total)}%) '
    'otherHeap=${agg.t53Other} (${_pct(agg.t53Other, agg.t53Total)}%)',
  );
  stdout.writeln(
    '14 4f (tag 48): total=${agg.t4fTotal} sameHeap=${agg.t4fSame} (${_pct(agg.t4fSame, agg.t4fTotal)}%) '
    'otherHeap=${agg.t4fOther} (${_pct(agg.t4fOther, agg.t4fTotal)}%)',
  );

  stdout.writeln('\n== ASCII-int hypothesis ==');
  agg.ascii.forEach((raw, v) {
    stdout.writeln(
      'raw 0x${raw.toRadixString(16)}: nonzero=${v.$1} allPrintable=${v.$2} '
      '(${_pct(v.$2, v.$1)}%) zeros=${v.$3}',
    );
  });

  stdout.writeln('\n== narrow color forms (raw 0x020/0x021 per width) ==');
  const widthNames = ['u8', 'u16', 'u24', 'rgb', 'flag'];
  for (final key in agg.colorClasses.keys.toList()..sort()) {
    final raw = key >> 4, w = key & 0xf;
    final ch = agg.colorClasses[key]!, vh = agg.colorValues[key]!;
    stdout.writeln(
      'raw 0x${raw.toRadixString(16)} ${w < widthNames.length ? widthNames[w] : 'w$w'}: n=${ch.total} '
      'classes ${ch.top(5).map((e) => '0x${e.key.toRadixString(16)}:${_pct(e.value, ch.total)}%').join(' ')} '
      '| values ${vh.top(5).map((e) => '0x${e.key.toRadixString(16)}:${_pct(e.value, vh.total)}%').join(' ')}',
    );
  }

  stdout.writeln('\n== 02 fe records ==');
  stdout.writeln('count=${agg.fe02}');
  for (final s in agg.fe02Samples) {
    stdout.writeln('  $s');
  }
}
