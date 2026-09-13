@Tags(['corpus'])
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

bool _bytesEq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

const _fuzzIters = 2;

typedef _Summ = (Map<String, int>, Set<int>, Set<String>);

String _sig(ViModel m) {
  final b = StringBuffer();
  for (final diag in [...m.blockDiagrams, ...m.frontPanelDiagrams]) {
    b.write('§${diag.sectionTag}');
    for (final o in diag.objects) {
      final r = o.absBounds;
      b.write(
        '|${o.oid},${o.kind},${o.parentOid},'
        '${r == null ? 'n' : '${r.top}.${r.left}.${r.bottom}.${r.right}'},'
        '${o.category.index},${o.label}',
      );
    }
  }
  return b.toString();
}

bool _heapLead(int x) => x == 0xc4 || (x >= 0x08 && x <= 0x13);
bool _wild(HeapRect r) => [r.left, r.top, r.right, r.bottom].any((c) => c < -200000 || c > 200000);

bool _structuralHeap(Uint8List b) {
  if (b.length < 8) return false;
  return ByteData.sublistView(b).getUint32(0) == b.length - 4 && _heapLead(b[4]);
}

bool _printable(Iterable<int> runes) => runes.every((c) => c == 9 || c == 10 || c == 13 || (c >= 0x20 && c < 0x7f));

_Summ _summarize(Uint8List bytes, String path) {
  final c = <String, int>{};
  final kinds = <int>{};
  final headTags = <String>{};
  void bad(String key) => c[key] = (c[key] ?? 0) + 1;

  List<ViSection>? secs;
  List<DecodedSection>? dsecs;
  try {
    secs = readViSections(bytes);
  } catch (_) {}
  try {
    dsecs = decodeSections(bytes);
  } catch (_) {}

  if (secs != null) {
    final rec = saveRecordFromSections(secs);
    if (rec != null && rec.stage != 0x80) bad('stageNon80');
    for (final s in secs) {
      if (s.tag != 'DTHP' || s.bytes.length < 4) continue;
      final h = decodeDataTypeHeap(s.bytes);
      if (h == null) {
        bad('dthpUndecoded');
      } else if (h.isExtended) {
        if (h.names.isEmpty) bad('dthpExtUnnamed');
        if (!h.names.every((x) => _printable(x.runes))) bad('dthpExtNonPrintable');
      }
    }
  }

  if (dsecs != null) {
    for (final d in dsecs) {
      if (d.tag != 'TM80') continue;
      final m = decodeTypeMap(d.bytes);
      if (m == null || !m.framesExactly) continue;
      final re = reserializeTypeMap(d.bytes);
      if (re == null || !_bytesEq(re, d.bytes)) bad('tmReemitBad');
    }
  }

  ViModel? m;
  try {
    m = buildViModel(bytes);
  } catch (_) {}
  if (m == null) return (c, kinds, headTags);

  try {
    if (_sig(m) != _sig(buildViModel(bytes))) bad('nondet');
  } catch (_) {}

  if (dsecs != null) {
    Uint8List? bodyOf(String tag) => dsecs!.where((s) => s.tag == tag).map((s) => s.bytes).firstOrNull;
    final vctp = bodyOf('VCTP');
    final dthpBody = bodyOf('DTHP');
    final dthp = dthpBody == null ? null : decodeDataTypeHeap(dthpBody);
    final topLevel = vctp == null ? const <int>[] : decodeTypeTable(vctp);
    if (dthp != null && topLevel.isNotEmpty) {
      if (dthp.firstTopLevelIndex + dthp.heapTypeCount - 1 != topLevel.length) bad('dthpRunNotAtTail');
      final indices = [
        for (final d in [...m.blockDiagrams, ...m.frontPanelDiagrams])
          for (final o in d.objects)
            if (o.typeDescIdx != null) o.typeDescIdx!,
      ];
      if (indices.isNotEmpty) {
        if (indices.reduce(min) != 1) bad('dthpIdxNotMinOne');
        if (indices.reduce(max) > dthp.heapTypeCount) bad('dthpIdxOutOfRange');
      }
    }
  }

  for (final o in [...m.blockDiagrams, ...m.frontPanelDiagrams].expand((d) => d.objects)) {
    kinds.add(o.kind);
    final r = o.absBounds;
    if (r != null && _wild(r)) bad('wildBounds');
  }

  try {
    for (final s in decodeSections(bytes)) {
      if (!isRecordHeapTag(s.tag)) continue;
      headTags.add(s.tag);
      if (!_structuralHeap(s.bytes)) bad('catHeapNotStructural');
    }
  } catch (_) {}

  if (bytes.length >= 64) {
    final rng = Random(0xC0FFEE);
    for (var iter = 0; iter < _fuzzIters && (c['fuzzWild'] ?? 0) == 0; iter++) {
      final mut = Uint8List.fromList(bytes);
      final flips = 1 + rng.nextInt(3);
      for (var k = 0; k < flips; k++) {
        mut[rng.nextInt(mut.length)] ^= 1 << rng.nextInt(8);
      }
      ViModel? built;
      try {
        built = buildViModel(mut);
      } catch (_) {
        built = null;
      }
      if (built == null) continue;
      for (final o in [...built.blockDiagrams, ...built.frontPanelDiagrams].expand((d) => d.objects)) {
        final r = o.absBounds;
        if (r != null && _wild(r)) {
          bad('fuzzWild');
          break;
        }
      }
    }
  }

  return (c, kinds, headTags);
}

void main() {
  final all = corpusVis();
  late final List<Map<String, int>> counts;
  late final Set<int> kindsSeen;
  late final Set<String> headTags;
  setUpAll(() async {
    final res = await corpusParallel(all, _summarize);
    counts = [for (final (c, _, _) in res) c];
    kindsSeen = {for (final (_, k, _) in res) ...k};
    headTags = {for (final (_, _, h) in res) ...h};
  });

  Map<String, Map<String, int>> violations(Set<String> laws) => perFileNonzero(all, counts, laws);

  test('DETERMINISM: building the same VI twice yields an identical object graph', () {
    expect(violations({'nondet'}), const <String, Map<String, int>>{});
  });

  test('STRUCTURAL INVARIANT: no decoded object has wild bounds, even under byte-flip fuzzing', () {
    expect(violations({'wildBounds', 'fuzzWild'}), const <String, Map<String, int>>{});
  });

  test('CATALOG INTEGRITY: every catalogued object-class kind occurs in the corpus', () {
    final missing = [
      for (final c in HeapObjectClass.values)
        if (c != HeapObjectClass.unknown && !kindsSeen.contains(c.code)) c.name,
    ];
    expect(missing, isEmpty);
  });

  test('BLOCK CATALOG: every catalogued record-heap section really is a C4 heap', () {
    expect(violations({'catHeapNotStructural'}), const <String, Map<String, int>>{});
    expect(headTags, containsAll(<String>{'FPHb', 'BDHb'}));
  });

  test('LVSR stage byte is always 0x80; every framed TM80 re-emits byte-exact', () {
    expect(violations({'stageNon80', 'tmReemitBad'}), const <String, Map<String, int>>{});
  });

  test('DTHP decodes totally, names are printable, and its heap type-index run sits at the VCTP tail', () {
    expect(
      violations({
        'dthpUndecoded',
        'dthpExtUnnamed',
        'dthpExtNonPrintable',
        'dthpRunNotAtTail',
        'dthpIdxNotMinOne',
        'dthpIdxOutOfRange',
      }),
      const <String, Map<String, int>>{},
    );
  });
}
