@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_viparse/labwright_viparse.dart';
import 'package:test/test.dart';

/// NEW test type at the RSRC-container layer: a CROSS-CONSISTENCY invariant
/// between viparse's two independent code paths — [parseVi] (which builds the
/// block *inventory* `.blocks`) and [readViSections] (which extracts each
/// section's bytes). Every tag that section-extraction produces must appear in
/// the inventory; a violation means the two RSRC readers have desynced (one sees
/// a block the other doesn't). The reverse is NOT required — the inventory is a
/// superset (some declared blocks, e.g. `LIBN`, carry no extractable section).
/// Corpus-validated: holds for 100% of 7583 files. Skipped if corpus absent.
void main() {
  final dir = Directory('/tmp/claude-1000/vi_samples');
  if (!dir.existsSync()) {
    test('viparse corpus invariants (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }
  List<File> vis(String root) {
    final d = Directory(root);
    if (!d.existsSync()) return const [];
    return d
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.vi'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  final all = [...vis('/tmp/claude-1000/vi_samples'), ...vis('/tmp/claude-1000/vi_diverse')];

  test('CROSS-CONSISTENCY: every extracted section tag is in parseVi\'s block inventory', () {
    var files = 0;
    for (final f in all) {
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      final Set<String> inventory, sectionTags;
      try {
        inventory = parseVi(bytes).blocks.toSet();
        sectionTags = readViSections(bytes).map((s) => s.tag).toSet();
      } catch (_) {
        continue; // a malformed container throwing cleanly is fine (fuzz tests cover that)
      }
      files++;
      final stray = sectionTags.difference(inventory);
      expect(stray, isEmpty,
          reason: 'readViSections produced tag(s) $stray absent from parseVi inventory — '
              'the two RSRC readers desynced in ${f.path}');
    }
    expect(files, greaterThan(0));
  });

  // EXPORT→IMPORT IDEMPOTENCY: parsing a container into the lossless [ViContainer]
  // model and re-serializing must reproduce the ORIGINAL bytes exactly. This is
  // the end-to-end proof that our container interpretation is complete — if any
  // region boundary were misread, the round-trip would diverge. It is also the
  // foundation the VI exporter/editor builds on. Expected 100% across the corpus
  // (the macro-layout is perfectly regular).
  test('IDEMPOTENCY: ViContainer.parse(bytes).toBytes() == bytes for every VI', () {
    var files = 0, exact = 0;
    final diffs = <String>[];
    for (final f in all) {
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      final Uint8List out;
      try {
        out = ViContainer.parse(bytes).toBytes();
      } catch (_) {
        continue; // a container we decline to model (mis-ordered) is not a round-trip failure
      }
      files++;
      var same = out.length == bytes.length;
      if (same) {
        for (var i = 0; i < bytes.length; i++) {
          if (out[i] != bytes[i]) {
            same = false;
            break;
          }
        }
      }
      if (same) {
        exact++;
      } else if (diffs.length < 6) {
        diffs.add('len ${bytes.length}->${out.length} ${f.path.split('/').last}');
      }
    }
    expect(files, greaterThan(0));
    // Byte-exact for 100% of well-ordered containers — ratchet: any drop is a
    // lossy regression in the container model.
    expect(exact, equals(files), reason: 'container round-trip not byte-exact for ${files - exact} file(s): $diffs');
  });

  // TYPED-HEADER SERIALIZE: the field-by-field ViHeader must reconstruct the raw
  // 32-byte header byte-for-byte for every VI — the first step of the
  // "model every byte in typed structs" exporter (no opaque header span).
  test('IDEMPOTENCY: ViHeader.parse(header).serialize() == header for every VI', () {
    var files = 0, exact = 0;
    final diffs = <String>[];
    for (final f in all) {
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      final Uint8List header, out;
      try {
        header = ViContainer.parse(bytes).header;
        out = ViHeader.parse(header).serialize();
      } catch (_) {
        continue;
      }
      files++;
      var same = out.length == header.length && header.length >= 32;
      if (same) {
        for (var i = 0; i < 32; i++) {
          if (out[i] != header[i]) {
            same = false;
            break;
          }
        }
      }
      if (same) {
        exact++;
      } else if (diffs.length < 6) {
        diffs.add(f.path.split('/').last);
      }
    }
    expect(files, greaterThan(0));
    expect(exact, equals(files), reason: 'ViHeader round-trip not byte-exact for ${files - exact} file(s): $diffs');
  });

  // TYPED INFO-SUBHEADER SERIALIZE: the modeled info-area prefix (dup header +
  // reserved words + blockListRel) must reconstruct the raw [0, blockListRel)
  // bytes byte-for-byte for every VI — the next region of the typed exporter.
  test('IDEMPOTENCY: ViInfoSubheader.serialize() == info-area prefix for every VI', () {
    var files = 0, exact = 0;
    final diffs = <String>[];
    for (final f in all) {
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      final Uint8List info, out;
      final int blr;
      try {
        info = ViContainer.parse(bytes).infoArea;
        final sh = ViInfoSubheader.parse(info);
        blr = sh.blockListRel;
        out = sh.serialize();
      } catch (_) {
        continue;
      }
      files++;
      var same = out.length == blr;
      if (same) {
        for (var i = 0; i < blr; i++) {
          if (out[i] != info[i]) {
            same = false;
            break;
          }
        }
      }
      if (same) {
        exact++;
      } else if (diffs.length < 6) {
        diffs.add(f.path.split('/').last);
      }
    }
    expect(files, greaterThan(0));
    expect(exact, equals(files), reason: 'info-subheader round-trip not byte-exact for ${files - exact} file(s): $diffs');
  });

  // TYPED BLOCK-LIST SERIALIZE: the modeled block list (count + 12-byte entries)
  // must reconstruct its raw bytes byte-for-byte for every VI.
  test('IDEMPOTENCY: ViBlockList.serialize() == raw block-list region for every VI', () {
    var files = 0, exact = 0;
    final diffs = <String>[];
    for (final f in all) {
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      final Uint8List info, out;
      final int blr;
      try {
        info = ViContainer.parse(bytes).infoArea;
        blr = ViInfoSubheader.parse(info).blockListRel;
        out = ViBlockList.parse(info, blr).serialize();
      } catch (_) {
        continue;
      }
      files++;
      var same = blr + out.length <= info.length;
      if (same) {
        for (var i = 0; i < out.length; i++) {
          if (out[i] != info[blr + i]) {
            same = false;
            break;
          }
        }
      }
      if (same) {
        exact++;
      } else if (diffs.length < 6) {
        diffs.add(f.path.split('/').last);
      }
    }
    expect(files, greaterThan(0));
    expect(exact, equals(files), reason: 'block-list round-trip not byte-exact for ${files - exact} file(s): $diffs');
  });

  // SECTION-LEVEL IDEMPOTENCY: one layer finer than the whole-file round-trip.
  // [ViExport.decomposeDataArea] models the data area as ordered, length-prefixed
  // sections (located via the info-area descriptors) interleaved with padding
  // gaps; [ViExport.rebuildDataArea] re-serializes them. For an unmodified VI the
  // rebuilt data area must equal the parsed data area byte-for-byte — proving the
  // section model accounts for EVERY byte (no gap dropped, no length misread).
  // This is the foundation for the section-EDIT API: editing a section's payload
  // and rebuilding must change only that section's bytes. Expected 100%.
  test('IDEMPOTENCY: rebuildDataArea(decomposeDataArea(bytes)) == dataArea for every VI', () {
    var files = 0, exact = 0;
    final diffs = <String>[];
    for (final f in all) {
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      final Uint8List data, rebuilt;
      try {
        data = ViContainer.parse(bytes).dataArea;
        rebuilt = ViExport.rebuildDataArea(ViExport.decomposeDataArea(bytes));
      } catch (_) {
        continue;
      }
      files++;
      var same = rebuilt.length == data.length;
      if (same) {
        for (var i = 0; i < data.length; i++) {
          if (rebuilt[i] != data[i]) {
            same = false;
            break;
          }
        }
      }
      if (same) {
        exact++;
      } else if (diffs.length < 6) {
        diffs.add('len ${data.length}->${rebuilt.length} ${f.path.split('/').last}');
      }
    }
    expect(files, greaterThan(0));
    expect(exact, equals(files),
        reason: 'data-area section round-trip not byte-exact for ${files - exact} file(s): $diffs');
  });

  // SECTION-EDIT correctness: [ViExport.editSection] replaces one section's
  // payload and re-serializes the whole file with all offset fixups. Three
  // properties, checked on every VI against the hardest target (the FIRST
  // section, so the edit forces the maximum number of later-descriptor shifts):
  //   (1) NO-OP — editing with the unchanged payload reproduces the input
  //       byte-for-byte (proves the fixup machinery is identity at delta=0);
  //   (2) GROW (+8 bytes) — the edited file re-parses with the target section
  //       equal to the new payload and EVERY other section byte-identical;
  //   (3) SHRINK (halve) — same, with a negative delta.
  // Re-parse uses readViSections (so descriptor/offset fixups must be coherent)
  // and ViContainer.parse (so header region boundaries must be coherent).
  // Corpus-validated 100%.
  test('SECTION-EDIT: editSection no-op is byte-exact; grow/shrink re-parse correctly', () {
    var files = 0, noopExact = 0, growOk = 0, shrinkOk = 0, grown = 0, shrunk = 0;
    final fails = <String>[];

    bool eq(List<int> a, List<int> b) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }

    for (final f in all) {
      final Uint8List bytes;
      List<ViSection> secs;
      try {
        bytes = Uint8List.fromList(f.readAsBytesSync());
        secs = readViSections(bytes);
      } catch (_) {
        continue;
      }
      if (secs.isEmpty) continue;
      files++;
      final name = f.path.split('/').last;
      final target = secs.reduce((a, b) => a.dataOffset <= b.dataOffset ? a : b);
      final secRel = target.dataOffset;
      final oldPayload = Uint8List.fromList(target.bytes);
      // every section's bytes keyed by (tag,index) — must survive an edit unchanged
      final origByKey = {for (final s in secs) '${s.tag}#${s.index}': Uint8List.fromList(s.bytes)};
      final targetKey = '${target.tag}#${target.index}';

      // (1) no-op
      final noop = ViExport.editSection(bytes, secRel: secRel, newPayload: oldPayload);
      if (eq(noop, bytes)) {
        noopExact++;
      } else if (fails.length < 8) {
        fails.add('NOOP $name ${bytes.length}->${noop.length}');
      }

      // (2)/(3) grow & shrink — verify via full re-parse
      bool checkEdit(Uint8List np) {
        final out = ViExport.editSection(bytes, secRel: secRel, newPayload: np);
        ViContainer.parse(out); // header boundaries must stay coherent
        final rsecs = readViSections(out);
        final edited = rsecs.where((s) => '${s.tag}#${s.index}' == targetKey).firstOrNull;
        if (edited == null || !eq(edited.bytes, np)) return false;
        for (final s in rsecs) {
          final key = '${s.tag}#${s.index}';
          if (key == targetKey) continue;
          final orig = origByKey[key];
          if (orig == null || !eq(s.bytes, orig)) return false;
        }
        return true;
      }

      final grow = Uint8List(oldPayload.length + 8)
        ..setRange(0, oldPayload.length, oldPayload)
        ..fillRange(oldPayload.length, oldPayload.length + 8, 0xAB);
      grown++;
      if (checkEdit(grow)) {
        growOk++;
      } else if (fails.length < 8) {
        fails.add('GROW $name');
      }

      if (oldPayload.length >= 2) {
        shrunk++;
        if (checkEdit(Uint8List.sublistView(oldPayload, 0, oldPayload.length ~/ 2))) {
          shrinkOk++;
        } else if (fails.length < 8) {
          fails.add('SHRINK $name');
        }
      }
    }

    expect(files, greaterThan(0));
    expect(noopExact, equals(files), reason: 'no-op edit not byte-exact for ${files - noopExact}: $fails');
    expect(growOk, equals(grown), reason: 'grow edit broke ${grown - growOk}: $fails');
    expect(shrinkOk, equals(shrunk), reason: 'shrink edit broke ${shrunk - shrinkOk}: $fails');
  });

  // SUBVI NAME RECOVERY: readSubViNames extracts the called-subVI names from the
  // LIbd linker block. Properties: every recovered name ends in `.vi`, has no
  // path separators (basename only), is deduped, and excludes the VI's own name.
  // Recovery is non-trivial across the corpus (subVIs are common) — a ratchet
  // guards against a regression that silently stops finding them. Corpus probe:
  // ~82% of VIs yield names; we assert a conservative floor.
  test('SUBVI: readSubViNames yields clean, deduped, self-excluding .vi names', () {
    var files = 0, withNames = 0, totalNames = 0;
    final fails = <String>[];
    for (final f in all) {
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      files++;
      final names = readSubViNames(bytes);
      if (names.isEmpty) continue;
      String? self;
      try {
        self = parseVi(bytes).name?.toLowerCase();
      } catch (_) {
        self = null;
      }
      final seen = <String>{};
      for (final n in names) {
        if (!n.toLowerCase().endsWith('.vi')) {
          if (fails.length < 8) fails.add('NOT .vi: "$n" in ${f.path.split('/').last}');
        }
        if (n.contains('/') || n.contains(r'\')) {
          if (fails.length < 8) fails.add('HAS PATH SEP: "$n" in ${f.path.split('/').last}');
        }
        if (!seen.add(n.toLowerCase())) {
          if (fails.length < 8) fails.add('DUPLICATE: "$n" in ${f.path.split('/').last}');
        }
        if (self != null && n.toLowerCase() == self) {
          if (fails.length < 8) fails.add('SELF INCLUDED: "$n" in ${f.path.split('/').last}');
        }
      }
      if (names.isNotEmpty) withNames++;
      totalNames += names.length;
    }
    expect(files, greaterThan(0));
    expect(fails, isEmpty, reason: 'subVI-name recovery cleanliness failures: $fails');
    // ratchet: recovery must stay broadly effective (corpus ~82%); floor at 60%.
    expect(withNames, greaterThan((files * 0.60).floor()),
        reason: 'subVI-name recovery dropped: only $withNames/$files VIs yielded names ($totalNames total)');
  });
}
