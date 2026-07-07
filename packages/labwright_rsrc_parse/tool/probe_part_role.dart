import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'corpus_base.dart';

/// Full-corpus probe for the `0xDF` / `0xAF` / `0xCB` attribute ids on the
/// object-tree axes exposed by [walkHeapObjects]:
///
///   0xDF — value vs the ENCLOSING object's header kind (purity of the
///          value→dominant-kind mapping; the <8000 vs ≥8000 range split).
///   0xCB — value vs enclosing kind, vs storage width nibble, and vs the
///          co-occurring 0xDF value on the same object.
///   0xAF — value vs the OWNING CONTROL's kind (nearest enclosing object,
///          self included, whose kind is a control-terminal class) and vs the
///          co-occurring 0xDF value on the same object.
///
/// Run: `dart run tool/probe_part_role.dart [corpusRoot=<pkg>/corpus/vi]`

/// Control-terminal class codes (the placed control/constant/indicator
/// terminals from the `HeapObjectClass` catalog — NOT their label/chrome/
/// connector sub-parts).
const Set<int> kControlKinds = {
  0x4e,
  0x4f,
  0x50,
  0x51,
  0x55,
  0x56,
  0x57,
  0x59,
  0x5b,
  0x5e,
  0xc2,
  0xdf,
  0x10c,
};

class _Node {
  _Node(this.kind, this.parent);
  final int kind;
  final _Node? parent;
  List<int>? dfValues;
  List<int>? afValues;
  List<(int, int)>? cbValues; // (widthNibbleIndex, value)
}

class _Agg {
  int dfTotal = 0, dfNoEnclosing = 0;
  final Map<int, Map<int, int>> dfValueKind = {};
  final Map<int, Map<int, int>> cbValueKind = {};
  final Map<int, Map<int, int>> cbValueWidth = {};
  final Map<int, Map<int, int>> cbValueDf = {};
  int cbTotal = 0, cbNoEnclosing = 0;
  final Map<int, Map<int, int>> afValueOwner = {};
  final Map<int, Map<int, int>> afValueSelfKind = {};
  final Map<int, Map<int, int>> afValueDf = {};
  int afTotal = 0, afNoEnclosing = 0;

  static void _bump(Map<int, Map<int, int>> table, int a, int b) {
    final row = table[a] ??= <int, int>{};
    row[b] = (row[b] ?? 0) + 1;
  }

  void merge(_Agg other) {
    dfTotal += other.dfTotal;
    dfNoEnclosing += other.dfNoEnclosing;
    cbTotal += other.cbTotal;
    cbNoEnclosing += other.cbNoEnclosing;
    afTotal += other.afTotal;
    afNoEnclosing += other.afNoEnclosing;
    void mergeTable(Map<int, Map<int, int>> into, Map<int, Map<int, int>> from) {
      from.forEach((k, row) {
        final target = into[k] ??= <int, int>{};
        row.forEach((b, n) => target[b] = (target[b] ?? 0) + n);
      });
    }

    mergeTable(dfValueKind, other.dfValueKind);
    mergeTable(cbValueKind, other.cbValueKind);
    mergeTable(cbValueWidth, other.cbValueWidth);
    mergeTable(cbValueDf, other.cbValueDf);
    mergeTable(afValueOwner, other.afValueOwner);
    mergeTable(afValueSelfKind, other.afValueSelfKind);
    mergeTable(afValueDf, other.afValueDf);
  }
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
    final nodes = <_Node>[];
    walkHeapObjects<_Node>(
      sec.bytes,
      onObjectOpen: (span, kind, oid, parent) {
        final node = _Node(kind, parent);
        nodes.add(node);
        return node;
      },
      onRecord: (span, enclosing) {
        final attr = decodeHeapAttr(sec.bytes, span.offset);
        if (attr == null) return;
        final id = attr.id;
        if (id != 0xdf && id != 0xaf && id != 0xcb) return;
        final value = attr.asInt;
        if (value == null) return;
        if (enclosing == null) {
          if (id == 0xdf) agg.dfNoEnclosing++;
          if (id == 0xaf) agg.afNoEnclosing++;
          if (id == 0xcb) agg.cbNoEnclosing++;
          if (id == 0xdf) agg.dfTotal++;
          if (id == 0xaf) agg.afTotal++;
          if (id == 0xcb) agg.cbTotal++;
          return;
        }
        switch (id) {
          case 0xdf:
            (enclosing.dfValues ??= []).add(value);
          case 0xaf:
            (enclosing.afValues ??= []).add(value);
          case 0xcb:
            (enclosing.cbValues ??= []).add((attr.width.index, value));
        }
      },
    );
    for (final node in nodes) {
      final dfValues = node.dfValues;
      if (dfValues != null) {
        for (final v in dfValues) {
          agg.dfTotal++;
          _Agg._bump(agg.dfValueKind, v, node.kind);
        }
      }
      final afValues = node.afValues;
      if (afValues != null) {
        _Node? owner = node;
        while (owner != null && !kControlKinds.contains(owner.kind)) {
          owner = owner.parent;
        }
        final ownerKind = owner?.kind ?? -1;
        for (final v in afValues) {
          agg.afTotal++;
          _Agg._bump(agg.afValueOwner, v, ownerKind);
          _Agg._bump(agg.afValueSelfKind, v, node.kind);
          if (dfValues != null) {
            for (final df in dfValues) {
              _Agg._bump(agg.afValueDf, v, df);
            }
          }
        }
      }
      final cbValues = node.cbValues;
      if (cbValues != null) {
        for (final (width, v) in cbValues) {
          agg.cbTotal++;
          _Agg._bump(agg.cbValueKind, v, node.kind);
          _Agg._bump(agg.cbValueWidth, v, width);
          if (dfValues != null) {
            for (final df in dfValues) {
              _Agg._bump(agg.cbValueDf, v, df);
            }
          }
        }
      }
    }
  }
}

String _hx(int v) => '0x${v.toRadixString(16)}';

void _printTable(String title, Map<int, Map<int, int>> table, {int topValues = 40, int topCells = 4}) {
  stdout.writeln('\n== $title ==');
  final entries = table.entries.toList()
    ..sort((a, b) {
      final na = a.value.values.fold<int>(0, (x, y) => x + y);
      final nb = b.value.values.fold<int>(0, (x, y) => x + y);
      return nb - na;
    });
  var shown = 0;
  var dominantSum = 0, totalSum = 0;
  for (final e in entries) {
    final total = e.value.values.fold<int>(0, (x, y) => x + y);
    final cells = e.value.entries.toList()..sort((a, b) => b.value - a.value);
    dominantSum += cells.first.value;
    totalSum += total;
    if (shown++ < topValues) {
      final cellStr = cells
          .take(topCells)
          .map((c) => '${_hx(c.key)}:${c.value}(${(100 * c.value / total).toStringAsFixed(1)}%)')
          .join(' ');
      stdout.writeln(
        '  v=${e.key} n=$total  $cellStr${cells.length > topCells ? ' +${cells.length - topCells}more' : ''}',
      );
    }
  }
  if (entries.length > topValues) stdout.writeln('  ... ${entries.length - topValues} more values');
  stdout.writeln(
    '  distinct values=${entries.length} records=$totalSum '
    'dominant-cell purity=${totalSum == 0 ? 0 : (100 * dominantSum / totalSum).toStringAsFixed(2)}%',
  );
}

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

  stdout.writeln('\n#### 0xDF ####');
  stdout.writeln('records=${agg.dfTotal} noEnclosingObject=${agg.dfNoEnclosing}');
  _printTable('0xDF value -> enclosing object kind', agg.dfValueKind, topValues: 60);
  // Range split: which kinds host the >=8000 values vs <8000.
  final geKinds = <int, int>{};
  agg.dfValueKind.forEach((v, row) {
    if (v >= 8000) row.forEach((k, n) => geKinds[k] = (geKinds[k] ?? 0) + n);
  });
  final geInControl = geKinds.entries.where((e) => kControlKinds.contains(e.key)).fold<int>(0, (a, e) => a + e.value);
  final geTotal = geKinds.values.fold<int>(0, (a, b) => a + b);
  stdout.writeln(
    '  >=8000 records: $geTotal, in control-kind objects: $geInControl '
    '(kinds: ${(geKinds.entries.toList()..sort((a, b) => b.value - a.value)).map((e) => '${_hx(e.key)}:${e.value}').join(' ')})',
  );

  stdout.writeln('\n#### 0xCB ####');
  stdout.writeln('records=${agg.cbTotal} noEnclosingObject=${agg.cbNoEnclosing}');
  _printTable('0xCB value -> enclosing object kind', agg.cbValueKind);
  _printTable('0xCB value -> width (HeapAttrWidth.index)', agg.cbValueWidth);
  _printTable('0xCB value -> co-occurring 0xDF value (same object)', agg.cbValueDf);

  stdout.writeln('\n#### 0xAF ####');
  stdout.writeln('records=${agg.afTotal} noEnclosingObject=${agg.afNoEnclosing}');
  _printTable('0xAF value -> owning-control kind (-1 = none)', agg.afValueOwner);
  _printTable('0xAF value -> self (enclosing) kind', agg.afValueSelfKind);
  _printTable('0xAF value -> co-occurring 0xDF value (same object)', agg.afValueDf);
}
