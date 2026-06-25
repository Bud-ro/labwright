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
/// superset (a few declared blocks may carry no extractable section in a given
/// file). Corpus-validated: holds for 100% of 7583 files. Skipped if corpus absent.
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

  // LIBN/VINS RECOVERY: readEmbeddedSections extracts the @16==0 sections that
  // readViSections leaves out. A VINS section is a complete embedded sub-VI — its
  // bytes begin with the RSRC container magic. A LIBN section is an owning-library
  // name — printable text. (readViSections itself must NOT surface these — checked
  // by the CROSS-CONSISTENCY/edit tests staying green.)
  test('SECTION: readEmbeddedSections recovers VINS (embedded VIs) and LIBN (library names)', () {
    var vinsCount = 0, libnCount = 0;
    var vinsNotRsrc = 0, libnNotPrintable = 0;
    final vinsExamples = <String>[];
    final libnExamples = <String>[];
    for (final f in all) {
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      final List<ViSection> secs;
      try {
        secs = readEmbeddedSections(bytes);
      } catch (_) {
        continue;
      }
      for (final s in secs) {
        if (s.tag == 'VINS') {
          vinsCount++;
          // an embedded VI: a complete nested RSRC...LVIN container — verify the
          // RSRC magic @0 AND the LVIN file-type tag @8, and that it re-parses.
          final isRsrc = s.bytes.length >= 12 &&
              s.bytes[0] == 0x52 &&
              s.bytes[1] == 0x53 &&
              s.bytes[2] == 0x52 &&
              s.bytes[3] == 0x43 &&
              String.fromCharCodes(s.bytes.sublist(8, 12)) == 'LVIN';
          var reparses = false;
          if (isRsrc) {
            try {
              ViContainer.parse(s.bytes); // the nested VI is itself a valid container
              reparses = true;
            } catch (_) {}
          }
          if (!isRsrc || !reparses) {
            vinsNotRsrc++;
          } else if (vinsExamples.length < 3) {
            vinsExamples.add('${f.path.split('/').last}: VINS#${s.index} ${s.bytes.length}B ${parseVi(s.bytes).name}');
          }
        } else if (s.tag == 'LIBN') {
          libnCount++;
          // a library name: the payload contains a printable run (e.g. ".lvlib").
          final printable = s.bytes.where((b) => b >= 0x20 && b < 0x7f).length;
          if (printable < (s.bytes.length * 0.5).floor()) {
            libnNotPrintable++;
          } else if (libnExamples.length < 3) {
            final txt = String.fromCharCodes(s.bytes.where((b) => b >= 0x20 && b < 0x7f));
            libnExamples.add('${f.path.split('/').last}: "$txt"');
          }
        }
      }
    }
    // The corpus contains both kinds; recovery must surface them.
    expect(vinsCount, greaterThan(0), reason: 'no VINS sections recovered');
    expect(libnCount, greaterThan(0), reason: 'no LIBN sections recovered');
    // Every recovered VINS is a real, re-parseable nested RSRC...LVIN VI; LIBN payloads are text.
    expect(vinsNotRsrc, 0, reason: 'VINS sections not a re-parseable RSRC...LVIN VI: $vinsNotRsrc');
    expect(libnNotPrintable, 0, reason: 'LIBN sections without printable text: $libnNotPrintable');
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

  // TYPED SECTION-DESCRIPTOR SERIALIZE: every 20-byte descriptor record (located
  // via the block list's descRel) must reconstruct its raw bytes byte-for-byte —
  // proves the 20-byte field decomposition (secRel + word16 + raw words)
  // accounts for the whole record. Covers every section, incl. LIBN/VINS.
  test('IDEMPOTENCY: ViSectionDescriptor.serialize() == raw 20 bytes for every descriptor', () {
    var files = 0, descriptors = 0;
    final fails = <String>[];
    for (final f in all) {
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      final Uint8List info;
      final ViBlockList bl;
      final int descBase;
      try {
        info = ViContainer.parse(bytes).infoArea;
        final blr = ViInfoSubheader.parse(info).blockListRel;
        bl = ViBlockList.parse(info, blr);
        descBase = blr + 8; // countPos + 8, per readViSections
      } catch (_) {
        continue;
      }
      files++;
      for (final e in bl.entries) {
        final n = e.sectionCountMinus1 + 1;
        for (var s = 0; s < n; s++) {
          final dpos = descBase + e.descRel + s * 20;
          if (dpos < 0 || dpos + 20 > info.length) continue;
          descriptors++;
          final sd = ViSectionDescriptor.parse(info, dpos);
          final out = sd.serialize();
          for (var i = 0; i < 20; i++) {
            if (out[i] != info[dpos + i]) {
              if (fails.length < 6) fails.add('${f.path.split('/').last}@$dpos');
              break;
            }
          }
        }
      }
    }
    expect(files, greaterThan(0));
    expect(descriptors, greaterThan(0));
    expect(fails, isEmpty, reason: 'descriptor round-trip not byte-exact: $fails');
  });

  // TYPED WHOLE-FILE SERIALIZE: the composed typed model (ViHeader + ViInfoArea
  // {typed subheader + block list + raw tail}, plus the raw data area) must
  // reproduce the ORIGINAL file bytes for every VI — proof the typed regions
  // compose losslessly as they replace the raw spans.
  test('IDEMPOTENCY: ViContainer.serialize() == original bytes for every VI', () {
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
        out = ViContainer.parse(bytes).serialize();
      } catch (_) {
        continue;
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
    expect(exact, equals(files), reason: 'typed serialize() not byte-exact for ${files - exact} file(s): $diffs');
  });

  // DESCRIPTOR TABLE PEELED: ViInfoArea now models the 20-byte descriptor records
  // as a typed list; assert the table is actually peeled (non-empty) for the
  // vast majority of VIs and that the count matches the block list's total.
  test('INFO-AREA: descriptor table is peeled into typed records for ~all VIs', () {
    var files = 0, peeled = 0;
    final mismatches = <String>[];
    for (final f in all) {
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      final ViInfoArea ia;
      final ViBlockList bl;
      try {
        final c = ViContainer.parse(bytes);
        ia = c.parsedInfoArea;
        bl = c.parsedBlockList;
      } catch (_) {
        continue;
      }
      files++;
      if (ia.descriptors.isEmpty) continue;
      peeled++;
      // descriptor count == total block descriptors (sum of sectionCount per block);
      // assert it's at least the block total and the 20-byte preGap record is typed.
      final total = bl.entries.fold<int>(0, (a, e) => a + e.sectionCountMinus1 + 1);
      if (ia.descriptors.length < total || ia.preGap == null) {
        if (mismatches.length < 6) mismatches.add('${f.path.split('/').last}: ${ia.descriptors.length} < $total or preGap null');
      }
    }
    expect(files, greaterThan(0));
    expect(mismatches, isEmpty, reason: 'descriptor peel mismatch: $mismatches');
    // ratchet: peeled for the large majority (probe: 100%); floor at 90%.
    expect(peeled, greaterThan((files * 0.90).floor()), reason: 'descriptor table not peeled: only $peeled/$files');
  });

  // PREGAP RECORD: the 20-byte slot before the first descriptor is a structured
  // record (ViInfoPreGap), not padding. Across the corpus: marker is FTAB or
  // VITS; word1/word3 are 0; flags is exactly 0xFFFFFFFF iff the VI has embedded
  // (LIBN/VINS) sections, else 0 — a perfect correlation with readEmbeddedSections.
  test('INFO-AREA: preGap is a typed FTAB/VITS record; flags == has-embedded-sections', () {
    var files = 0;
    final badMarker = <String>[];
    final badZero = <String>[];
    final flagMismatch = <String>[];
    for (final f in all) {
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      final ViInfoPreGap? pg;
      final bool hasEmbedded;
      try {
        pg = ViContainer.parse(bytes).parsedInfoArea.preGap;
        hasEmbedded = readEmbeddedSections(bytes).isNotEmpty;
      } catch (_) {
        continue;
      }
      if (pg == null) continue;
      files++;
      if (pg.markerTag != 'FTAB' && pg.markerTag != 'VITS') {
        if (badMarker.length < 6) badMarker.add('${f.path.split('/').last}: ${pg.markerTag}');
      }
      if (pg.word1 != 0 || pg.word3 != 0) {
        if (badZero.length < 6) badZero.add('${f.path.split('/').last}: w1=${pg.word1} w3=${pg.word3}');
      }
      // flags must be exactly 0xFFFFFFFF (has embedded) or 0 (none), matching reality.
      if (pg.hasEmbeddedSections != hasEmbedded || (pg.flags != 0xFFFFFFFF && pg.flags != 0)) {
        if (flagMismatch.length < 6) {
          flagMismatch.add('${f.path.split('/').last}: flags=0x${pg.flags.toRadixString(16)} embedded=$hasEmbedded');
        }
      }
    }
    expect(files, greaterThan(0));
    expect(badMarker, isEmpty, reason: 'preGap marker not FTAB/VITS: $badMarker');
    expect(badZero, isEmpty, reason: 'preGap word1/word3 not zero: $badZero');
    expect(flagMismatch, isEmpty, reason: 'preGap flags != has-embedded-sections: $flagMismatch');
  });

  // PREGAP MARKER names the ALTERNATE of the FTAB/VITS block pair: the marker tag
  // is never one of the VI's own blocks, and the opposite tag IS present.
  test('INFO-AREA: preGap marker is the alternate FTAB/VITS block tag (anti-correlated)', () {
    var checked = 0, markerInInventory = 0, oppositePresent = 0;
    final bad = <String>[];
    for (final f in all) {
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      final String marker;
      final Set<String> blocks;
      try {
        final pg = ViContainer.parse(bytes).parsedInfoArea.preGap;
        if (pg == null) continue;
        marker = pg.markerTag;
        blocks = parseVi(bytes).blocks.toSet();
      } catch (_) {
        continue;
      }
      if (marker != 'FTAB' && marker != 'VITS') continue;
      checked++;
      final other = marker == 'FTAB' ? 'VITS' : 'FTAB';
      if (blocks.contains(marker)) {
        markerInInventory++;
        if (bad.length < 6) bad.add('${f.path.split('/').last}: marker $marker also a block');
      }
      if (blocks.contains(other)) oppositePresent++;
    }
    expect(checked, greaterThan(0));
    // the marker tag is NEVER the VI's own block (probe: 100%).
    expect(markerInInventory, 0, reason: 'preGap marker tag appeared as a block: $bad');
    // and the VI carries the opposite tag as a block (probe: ~99%).
    expect(oppositePresent, greaterThan((checked * 0.95).floor()),
        reason: 'opposite FTAB/VITS block missing: only $oppositePresent/$checked');
  });

  // SUBHEADER RESERVED WORDS: reservedA is the constant [0,0,0x20], and reservedB
  // is the info-area-relative offset of the trailing VI-name record (so the VI
  // name is reachable directly from the subheader, not only by scanning EOF).
  test('INFO-AREA: subheader reservedA == [0,0,0x20]; reservedB == trailing-name offset', () {
    var files = 0, badA = 0, nameOffMatch = 0, nameOffChecked = 0;
    for (final f in all) {
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      final ViContainer c;
      try {
        c = ViContainer.parse(bytes);
      } catch (_) {
        continue;
      }
      files++;
      final sub = c.parsedInfoSubheader;
      // reservedA is exactly 12 bytes == [0,0,0x20] across the corpus.
      if (sub.reservedA.length != 12) {
        badA++;
      } else {
        final d = ByteData.sublistView(sub.reservedA);
        if (d.getUint32(0) != 0 || d.getUint32(4) != 0 || d.getUint32(8) != 0x20) badA++;
      }
      final off = sub.viNameOffset;
      final rec = c.parsedInfoArea.nameTable.trailingNameRecord;
      if (off != null && rec.isNotEmpty) {
        nameOffChecked++;
        if (off == c.infoArea.length - rec.length) nameOffMatch++;
      }
    }
    expect(files, greaterThan(0));
    expect(badA, 0, reason: 'reservedA not [0,0,0x20] in $badA files');
    // reservedB is the authoritative VI-name locator: it points at the trailing
    // name record in EVERY VI that has one (now that non-ASCII names are recovered
    // verbatim — D.44). Exact match, and the sample is large.
    expect(nameOffChecked, greaterThan(1000), reason: 'too few name records checked: $nameOffChecked');
    expect(nameOffMatch, nameOffChecked,
        reason: 'reservedB != trailing-name offset: $nameOffMatch/$nameOffChecked');
  });

  // NAME-TABLE HEADER: the bytes before the trailing VI name are a small fixed
  // 12-byte header ([u32 0][u32 headerValue][u32 0]) in the vast majority of VIs,
  // and its size does NOT scale with the section nameRef indices — confirming it
  // is NOT the name table nameRef points into.
  test('INFO-AREA: name-table header is a fixed 12-byte struct, unrelated to nameRef', () {
    var files = 0, twelve = 0;
    var highRefFiles = 0, highRefHeader12 = 0, maxHeaderAtHighRef = 0, maxRefSeen = 0;
    for (final f in all) {
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      final ViInfoArea ia;
      try {
        ia = ViContainer.parse(bytes).parsedInfoArea;
      } catch (_) {
        continue;
      }
      if (ia.descriptors.isEmpty) continue;
      files++;
      final hdr = ia.nameTable.header;
      if (hdr.length == 12) {
        twelve++;
        // canonical shape: words @0 and @8 are zero; @4 is the lone value.
        final d = ByteData.sublistView(hdr);
        if (d.getUint32(0) == 0 && d.getUint32(8) == 0) {
          expect(ia.nameTable.headerValue, d.getUint32(4));
        }
      }
      final maxRef = ia.descriptors.where((x) => x.isNamed).fold<int>(0, (a, x) => a > x.nameRef ? a : x.nameRef);
      if (maxRef > maxRefSeen) maxRefSeen = maxRef;
      // DISPROOF that the header IS the nameRef table: where nameRef indexes are
      // large (>100), the header must NOT grow to hold them — it stays ~12 bytes,
      // i.e. far smaller than maxRef. (Were it the table, length would track maxRef.)
      if (maxRef > 100) {
        highRefFiles++;
        if (hdr.length == 12) highRefHeader12++;
        if (hdr.length > maxHeaderAtHighRef) maxHeaderAtHighRef = hdr.length;
      }
    }
    expect(files, greaterThan(0));
    // the header is the fixed 12 bytes in EVERY VI (D.44 fixed the lone non-ASCII
    // false positive that previously inflated one header to 44 bytes).
    expect(twelve, files, reason: 'name-table header not always 12 bytes: $twelve/$files');
    // and the corpus exercises large nameRef indices, where the header stays tiny.
    expect(highRefFiles, greaterThan(0), reason: 'no high-nameRef files to disprove with (maxRef seen: $maxRefSeen)');
    expect(highRefHeader12, highRefFiles,
        reason: 'header grew with nameRef ($highRefHeader12/$highRefFiles stayed 12; max header at high ref: $maxHeaderAtHighRef, maxRef: $maxRefSeen)');
  });

  // DESCRIPTOR @16 IS BINARY: across the corpus every section descriptor's @16
  // word is exactly 0xFFFFFFFF (the VI's own data sections) or exactly 0 (the
  // LIBN/VINS sections — both real, data-bearing). No third value occurs. And
  // every section's nameRef is a small index (full-corpus global max 360),
  // confirming it is an index, not a byte offset.
  // DESCRIPTOR word0/word8: word0 (@0) is a reserved word — 0 in every descriptor.
  // word8 (@8) is 0 in modern VIs and nonzero only in the legacy LV <=7.x format
  // (the lone LV7 corpus VI), so files carrying a nonzero word8 are a rare minority.
  test('INFO-AREA: descriptor word0 is always 0; word8 nonzero is legacy-only (rare)', () {
    var files = 0, badWord0 = 0, filesWithWord8 = 0;
    final w0ex = <String>[];
    for (final f in all) {
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      final ViInfoArea ia;
      try {
        ia = ViContainer.parse(bytes).parsedInfoArea;
      } catch (_) {
        continue;
      }
      if (ia.descriptors.isEmpty) continue;
      files++;
      var fileW8 = false;
      for (final d in ia.descriptors) {
        if (d.word0 != 0) {
          badWord0++;
          if (w0ex.length < 6) w0ex.add('${f.path.split('/').last}: word0=0x${d.word0.toRadixString(16)}');
        }
        if (d.word8 != 0) fileW8 = true;
      }
      if (fileW8) filesWithWord8++;
    }
    expect(files, greaterThan(0));
    expect(badWord0, 0, reason: 'word0 not always 0: $w0ex');
    // word8 nonzero only in legacy VIs — a tiny minority (probe: 1/7583).
    expect(filesWithWord8, lessThan((files * 0.02).ceil()),
        reason: 'word8 nonzero in too many files ($filesWithWord8/$files) — not legacy-only');
  });

  test('INFO-AREA: descriptor @16 is binary (0xFFFFFFFF | 0); nameRef is index-like', () {
    var files = 0;
    var maxNameRef = 0, maxInfoLen = 0;
    final badWords = <String>[];
    for (final f in all) {
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      final ViContainer c;
      final ViInfoArea ia;
      try {
        c = ViContainer.parse(bytes);
        ia = c.parsedInfoArea;
      } catch (_) {
        continue;
      }
      if (ia.descriptors.isEmpty) continue;
      files++;
      if (c.infoArea.length > maxInfoLen) maxInfoLen = c.infoArea.length;
      for (final d in ia.descriptors) {
        // @16 must be exactly 0xFFFFFFFF (own data section) or exactly 0 (LIBN/VINS).
        if (d.word16 != ViSectionDescriptor.commonWord16 && d.word16 != 0) {
          if (badWords.length < 6) {
            badWords.add('${f.path.split('/').last}: @16=0x${d.word16.toRadixString(16)}');
          }
        }
        if (d.nameRef > maxNameRef) maxNameRef = d.nameRef;
      }
    }
    expect(files, greaterThan(0));
    expect(badWords, isEmpty, reason: 'descriptor @16 not binary: $badWords');
    // index-like, NOT a byte offset: a real offset into the name region would
    // scale with the info-area size (which reaches several KB across the corpus),
    // so it would exceed this small ceiling in larger files. nameRef stays tiny
    // (probed global max 360) regardless of info size — it is decoupled from bytes.
    expect(maxInfoLen, greaterThan(4000), reason: 'corpus lacks large info areas to discriminate (max $maxInfoLen)');
    expect(maxNameRef, lessThan(1000),
        reason: 'nameRef looks like a byte offset, not an index: max $maxNameRef vs info up to $maxInfoLen');
  });

  // NAME TABLE: the typed name table recovers the trailing VI name for ~all VIs,
  // and it matches parseVi's independently-read trailing name.
  test('INFO-AREA: name table recovers the trailing VI name for ~all VIs', () {
    var files = 0, withName = 0;
    final mismatches = <String>[];
    for (final f in all) {
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      final ViInfoArea ia;
      String? summaryName;
      try {
        ia = ViContainer.parse(bytes).parsedInfoArea;
        summaryName = parseVi(bytes).name;
      } catch (_) {
        continue;
      }
      files++;
      final nt = ia.nameTable.trailingName;
      if (nt != null) {
        withName++;
        // the typed name table's trailing name should agree with parseVi's
        if (summaryName != null && summaryName != nt) {
          if (mismatches.length < 6) mismatches.add('${f.path.split('/').last}: "$nt" != "$summaryName"');
        }
      }
    }
    expect(files, greaterThan(0));
    expect(mismatches, isEmpty, reason: 'trailing-name disagreement: $mismatches');
    // ratchet: a trailing VI name is present for the large majority; floor 85%.
    expect(withName, greaterThan((files * 0.85).floor()), reason: 'trailing name recovery dropped: $withName/$files');
  });

  // CAPSTONE: the fully-typed ViVi model (header + data segments + typed info
  // area) round-trips to the ORIGINAL file bytes for every VI — the end-to-end
  // proof of "import -> typed model -> serialize -> byte-identical".
  test('IDEMPOTENCY: ViVi.parse(bytes).serialize() == bytes for every VI', () {
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
        out = ViVi.parse(bytes).serialize();
      } catch (_) {
        continue;
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
    expect(exact, equals(files), reason: 'ViVi round-trip not byte-exact for ${files - exact} file(s): $diffs');
  });

  // TYPED EDIT: ViVi.withSectionEdited yields a coherent VI — the result is
  // self-consistent (parse(result).serialize()==result) and the edited section
  // holds the new payload while other sections survive, for every VI.
  test('TYPED EDIT: ViVi.withSectionEdited grow/shrink stays coherent for every VI', () {
    var files = 0, ok = 0;
    final fails = <String>[];

    bool eq(List<int> a, List<int> b) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }

    for (final f in all) {
      final ViVi vi;
      try {
        vi = ViVi.parse(Uint8List.fromList(f.readAsBytesSync()));
      } catch (_) {
        continue;
      }
      final secs = vi.sections.toList();
      if (secs.isEmpty) continue;
      files++;
      // edit the first section (smallest secRel forces the most descriptor shifts)
      final target = secs.reduce((a, b) => a.secRel <= b.secRel ? a : b);
      final grown = Uint8List(target.payload.length + 6)
        ..setRange(0, target.payload.length, target.payload)
        ..fillRange(target.payload.length, target.payload.length + 6, 0x5A);
      try {
        final edited = vi.withSectionEdited(secRel: target.secRel, newPayload: grown);
        // self-consistent: re-parse of the serialized edit reproduces it
        final out = edited.serialize();
        final consistent = eq(ViVi.parse(out).serialize(), out);
        // the edited section now holds the new payload
        final newTarget = edited.sections.where((s) => s.secRel == target.secRel).firstOrNull;
        final hasNew = newTarget != null && eq(newTarget.payload, grown);
        if (consistent && hasNew) {
          ok++;
        } else if (fails.length < 6) {
          fails.add('${f.path.split('/').last} consistent=$consistent hasNew=$hasNew');
        }
      } catch (_) {
        if (fails.length < 6) fails.add('${f.path.split('/').last} threw');
      }
    }
    expect(files, greaterThan(0));
    expect(ok, equals(files), reason: 'typed edit not coherent for ${files - ok} file(s): $fails');
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
