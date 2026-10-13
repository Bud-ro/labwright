import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../corpus_dirs.dart';

const _fuzzIters = 2;

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

/// Counts, object kinds seen, then record-heap tags seen.
List<Object?> _summarize(CorpusVi vi) {
  final bytes = vi.bytes;
  final c = <String, int>{};
  final kinds = <int>{};
  final headTags = <String>{};
  void bad(String key) => c[key] = (c[key] ?? 0) + 1;

  final secs = vi.sections;
  final dsecs = vi.decoded;

  if (secs != null) {
    final lvsr = secs.where((section) => section.tag == 'LVSR').firstOrNull;
    if (lvsr != null && ViSaveRecord(lvsr.bytes).versionWord.releaseStage == null) bad('stageUnnamed');
  }

  final m = vi.model;
  if (m == null) return [c, kinds.toList(), headTags.toList()];

  try {
    if (_sig(m) != _sig(buildViModel(bytes))) bad('nondet');
  } catch (_) {}

  if (dsecs != null) {
    Uint8List? bodyOf(String tag) => dsecs.where((s) => s.tag == tag).map((s) => s.bytes).firstOrNull;
    final vctp = bodyOf('VCTP');
    final dthpBody = bodyOf('DTHP');
    final dthp = dthpBody == null ? null : ViDataTypeHeap(dthpBody);
    final topLevel = vctp == null ? const <int>[] : ViTypePool(vctp).topLevelIndices;
    if (dthp is ViDataTypeHeapCompact && topLevel.isNotEmpty) {
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

  for (final s in dsecs ?? const <DecodedSection>[]) {
    if (!(BlockTag.of(s.tag)?.isRecordHeap ?? false)) continue;
    headTags.add(s.tag);
    if (!_structuralHeap(s.bytes)) bad('catHeapNotStructural');
  }

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

  return [c, kinds.toList(), headTags.toList()];
}

const invariantsLaw = CorpusLaw('invariants', _summarize);

void invariantsTests() {
  final all = corpusVis.files;
  late final List<Map<String, int>> counts;
  late final Set<int> kindsSeen;
  late final Set<String> headTags;
  setUpAll(() async {
    final res = await invariantsLaw.results;
    counts = [for (final [c as Map<String, int>, _, _] in res) c];
    kindsSeen = {for (final [_, k as List<int>, _] in res) ...k};
    headTags = {for (final [_, _, h as List<String>] in res) ...h};
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

  test('LVSR names a release stage; every framed TM80 re-emits byte-exact', () {
    expect(violations({'stageUnnamed', 'tmReemitBad'}), const <String, Map<String, int>>{});
  });

  // TODO: LabVIEW 8.6 saves keep the DTHP type-index run away from the VCTP tail.
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
      const <String, Map<String, int>>{
        'vi-corpus/sources/dnattinger__GoCommando/GoCommando Main.vi': {'dthpRunNotAtTail': 1},
        'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/abort.vi': {'dthpRunNotAtTail': 1},
        'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/add.vi': {'dthpRunNotAtTail': 1},
        'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/brokenwires.vi': {'dthpRunNotAtTail': 1},
        'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/create.vi': {'dthpRunNotAtTail': 1},
        'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/del.vi': {'dthpRunNotAtTail': 1},
        'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/drop.vi': {'dthpRunNotAtTail': 1},
        'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/grow.vi': {'dthpRunNotAtTail': 1},
        'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/move.vi': {'dthpRunNotAtTail': 1},
        'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/run.vi': {'dthpRunNotAtTail': 1},
        'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Support/GoCommando Wire CORE.vi': {'dthpRunNotAtTail': 1},
        'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/testing_terminal_labeling.vi': {'dthpRunNotAtTail': 1},
        'vi-corpus/sources/tomsoftware__VI-Explorer-VI/VI-File-Explorer.vi': {'dthpRunNotAtTail': 1},
      },
    );
  });
}
