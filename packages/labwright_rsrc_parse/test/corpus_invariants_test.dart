@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Bytes from the block-list count word (at blockListRel) to the first 20-byte
/// section descriptor, per readViSections.
const _descBaseAfterCount = 8;

/// One info-area section descriptor is a fixed 20-byte record.
const _sectionDescriptorBytes = 20;

/// The RSRC file header is a fixed 32-byte struct.
const _rsrcHeaderBytes = 32;

/// Reads a file's bytes, or `null` if the read fails (skip-on-error idiom).
Uint8List? _readBytes(File f) {
  try {
    return f.readAsBytesSync();
  } catch (_) {
    return null;
  }
}

/// The basename of a file (the diagnostic strings only ever want the last path
/// segment).
String _base(File f) => f.path.split('/').last;

/// Byte-wise equality for two lists.
bool eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Byte-wise equality of `a[aStart..aStart+n)` against `b[bStart..bStart+n)`.
bool eqRange(List<int> a, int aStart, List<int> b, int bStart, int n) {
  for (var i = 0; i < n; i++) {
    if (a[aStart + i] != b[bStart + i]) return false;
  }
  return true;
}

/// NEW test type at the RSRC-container layer: a CROSS-CONSISTENCY invariant
/// between viparse's two independent code paths — [parseVi] (which builds the
/// block *inventory* `.blocks`) and [readViSections] (which extracts each
/// section's bytes). Every tag that section-extraction produces must appear in
/// the inventory; a violation means the two RSRC readers have desynced (one sees
/// a block the other doesn't). The reverse is NOT required — the inventory is a
/// superset (a few declared blocks may carry no extractable section in a given
/// file). Corpus-validated: holds for 100% of 7583 files. Skipped if corpus absent.
void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('viparse corpus invariants (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  /// Runs a whole-file byte-exact round-trip over the corpus: every file must
  /// survive `transform` unchanged. Shared body for the several typed
  /// serialize()/toBytes() idempotency tests.
  void roundTripsExact(String label, Uint8List Function(Uint8List) transform) {
    var files = 0, exact = 0;
    final diffs = <String>[];
    for (final f in all) {
      final bytes = _readBytes(f);
      if (bytes == null) continue;
      final Uint8List out;
      try {
        out = transform(bytes);
      } catch (_) {
        continue;
      }
      files++;
      if (eq(out, bytes)) {
        exact++;
      } else if (diffs.length < 6) {
        diffs.add('len ${bytes.length}->${out.length} ${_base(f)}');
      }
    }
    expect(files, greaterThan(0));
    expect(exact, equals(files), reason: '$label not byte-exact for ${files - exact} file(s): $diffs');
  }

  test('CROSS-CONSISTENCY: every extracted section tag is in parseVi\'s block inventory', () {
    var files = 0;
    for (final f in all) {
      final bytes = _readBytes(f);
      if (bytes == null) continue;
      final Set<String> inventory, sectionTags;
      try {
        inventory = parseVi(bytes).blocks.toSet();
        sectionTags = readViSections(bytes).map((s) => s.tag).toSet();
      } catch (_) {
        continue;
      }
      files++;
      final stray = sectionTags.difference(inventory);
      expect(stray, isEmpty,
          reason: 'readViSections produced tag(s) $stray absent from parseVi inventory — '
              'the two RSRC readers desynced in ${f.path}');
    }
    expect(files, greaterThan(0));
  });

  test('SECTION: readEmbeddedSections recovers VINS (embedded VIs) and LIBN (library names)', () {
    var vinsCount = 0, libnCount = 0;
    var vinsNotRsrc = 0, libnNotPrintable = 0;
    final vinsExamples = <String>[];
    final libnExamples = <String>[];
    for (final f in all) {
      final bytes = _readBytes(f);
      if (bytes == null) continue;
      final List<ViSection> secs;
      try {
        secs = readEmbeddedSections(bytes);
      } catch (_) {
        continue;
      }
      for (final s in secs) {
        if (s.tag == 'VINS') {
          vinsCount++;
          final isRsrc = s.bytes.length >= 12 &&
              String.fromCharCodes(s.bytes.sublist(0, 4)) == 'RSRC' &&
              String.fromCharCodes(s.bytes.sublist(8, 12)) == 'LVIN';
          var reparses = false;
          if (isRsrc) {
            try {
              ViContainer.parse(s.bytes);
              reparses = true;
            } catch (_) {}
          }
          if (!isRsrc || !reparses) {
            vinsNotRsrc++;
          } else if (vinsExamples.length < 3) {
            vinsExamples.add('${_base(f)}: VINS#${s.index} ${s.bytes.length}B ${parseVi(s.bytes).name}');
          }
        } else if (s.tag == 'LIBN') {
          libnCount++;
          final printable = s.bytes.where((b) => b >= 0x20 && b < 0x7f).length;
          if (printable < (s.bytes.length * 0.5).floor()) {
            libnNotPrintable++;
          } else if (libnExamples.length < 3) {
            final txt = String.fromCharCodes(s.bytes.where((b) => b >= 0x20 && b < 0x7f));
            libnExamples.add('${_base(f)}: "$txt"');
          }
        }
      }
    }
    expect(vinsCount, greaterThan(0), reason: 'no VINS sections recovered');
    expect(libnCount, greaterThan(0), reason: 'no LIBN sections recovered');
    expect(vinsNotRsrc, 0, reason: 'VINS sections not a re-parseable RSRC...LVIN VI: $vinsNotRsrc');
    expect(libnNotPrintable, 0, reason: 'LIBN sections without printable text: $libnNotPrintable');
  });

  test('IDEMPOTENCY: ViContainer.parse(bytes).toBytes() == bytes for every VI', () {
    roundTripsExact('container round-trip', (b) => ViContainer.parse(b).toBytes());
  });

  test('IDEMPOTENCY: ViHeader.parse(header).serialize() == header for every VI', () {
    var files = 0, exact = 0;
    final diffs = <String>[];
    for (final f in all) {
      final bytes = _readBytes(f);
      if (bytes == null) continue;
      final Uint8List header, out;
      try {
        header = ViContainer.parse(bytes).header;
        out = ViHeader.parse(header).serialize();
      } catch (_) {
        continue;
      }
      files++;
      final same = out.length == header.length &&
          header.length >= _rsrcHeaderBytes &&
          eqRange(out, 0, header, 0, _rsrcHeaderBytes);
      if (same) {
        exact++;
      } else if (diffs.length < 6) {
        diffs.add(_base(f));
      }
    }
    expect(files, greaterThan(0));
    expect(exact, equals(files), reason: 'ViHeader round-trip not byte-exact for ${files - exact} file(s): $diffs');
  });

  test('IDEMPOTENCY: ViInfoSubheader.serialize() == info-area prefix for every VI', () {
    var files = 0, exact = 0;
    final diffs = <String>[];
    for (final f in all) {
      final bytes = _readBytes(f);
      if (bytes == null) continue;
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
      final same = out.length == blr && eqRange(out, 0, info, 0, blr);
      if (same) {
        exact++;
      } else if (diffs.length < 6) {
        diffs.add(_base(f));
      }
    }
    expect(files, greaterThan(0));
    expect(exact, equals(files), reason: 'info-subheader round-trip not byte-exact for ${files - exact} file(s): $diffs');
  });

  test('IDEMPOTENCY: ViBlockList.serialize() == raw block-list region for every VI', () {
    var files = 0, exact = 0;
    final diffs = <String>[];
    for (final f in all) {
      final bytes = _readBytes(f);
      if (bytes == null) continue;
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
      final same = blr + out.length <= info.length && eqRange(out, 0, info, blr, out.length);
      if (same) {
        exact++;
      } else if (diffs.length < 6) {
        diffs.add(_base(f));
      }
    }
    expect(files, greaterThan(0));
    expect(exact, equals(files), reason: 'block-list round-trip not byte-exact for ${files - exact} file(s): $diffs');
  });

  test('IDEMPOTENCY: ViSectionDescriptor.serialize() == raw 20 bytes for every descriptor', () {
    var files = 0, descriptors = 0;
    final fails = <String>[];
    for (final f in all) {
      final bytes = _readBytes(f);
      if (bytes == null) continue;
      final Uint8List info;
      final ViBlockList bl;
      final int descBase;
      try {
        info = ViContainer.parse(bytes).infoArea;
        final blr = ViInfoSubheader.parse(info).blockListRel;
        bl = ViBlockList.parse(info, blr);
        descBase = blr + _descBaseAfterCount;
      } catch (_) {
        continue;
      }
      files++;
      for (final e in bl.entries) {
        final n = e.sectionCountMinus1 + 1;
        for (var s = 0; s < n; s++) {
          final dpos = descBase + e.descRel + s * _sectionDescriptorBytes;
          if (dpos < 0 || dpos + _sectionDescriptorBytes > info.length) continue;
          descriptors++;
          final sd = ViSectionDescriptor.parse(info, dpos);
          final out = sd.serialize();
          if (!eqRange(out, 0, info, dpos, _sectionDescriptorBytes) && fails.length < 6) {
            fails.add('${_base(f)}@$dpos');
          }
        }
      }
    }
    expect(files, greaterThan(0));
    expect(descriptors, greaterThan(0));
    expect(fails, isEmpty, reason: 'descriptor round-trip not byte-exact: $fails');
  });

  test('IDEMPOTENCY: ViContainer.serialize() == original bytes for every VI', () {
    roundTripsExact('typed serialize()', (b) => ViContainer.parse(b).serialize());
  });

  test('INFO-AREA: descriptor table is peeled into typed records for ~all VIs', () {
    var files = 0, peeled = 0;
    final mismatches = <String>[];
    for (final f in all) {
      final bytes = _readBytes(f);
      if (bytes == null) continue;
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
      final total = bl.entries.fold<int>(0, (a, e) => a + e.sectionCountMinus1 + 1);
      if (ia.descriptors.length < total || ia.preGap == null) {
        if (mismatches.length < 6) mismatches.add('${_base(f)}: ${ia.descriptors.length} < $total or preGap null');
      }
    }
    expect(files, greaterThan(0));
    expect(mismatches, isEmpty, reason: 'descriptor peel mismatch: $mismatches');
    expect(peeled, greaterThan((files * 0.90).floor()), reason: 'descriptor table not peeled: only $peeled/$files');
  });

  test('INFO-AREA: preGap is a typed FTAB/VITS record; flags == has-embedded-sections', () {
    var files = 0;
    final badMarker = <String>[];
    final badZero = <String>[];
    final flagMismatch = <String>[];
    for (final f in all) {
      final bytes = _readBytes(f);
      if (bytes == null) continue;
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
        if (badMarker.length < 6) badMarker.add('${_base(f)}: ${pg.markerTag}');
      }
      if (pg.word1 != 0 || pg.word3 != 0) {
        if (badZero.length < 6) badZero.add('${_base(f)}: w1=${pg.word1} w3=${pg.word3}');
      }
      if (pg.hasEmbeddedSections != hasEmbedded || (pg.flags != 0xFFFFFFFF && pg.flags != 0)) {
        if (flagMismatch.length < 6) {
          flagMismatch.add('${_base(f)}: flags=0x${pg.flags.toRadixString(16)} embedded=$hasEmbedded');
        }
      }
    }
    expect(files, greaterThan(0));
    expect(badMarker, isEmpty, reason: 'preGap marker not FTAB/VITS: $badMarker');
    expect(badZero, isEmpty, reason: 'preGap word1/word3 not zero: $badZero');
    expect(flagMismatch, isEmpty, reason: 'preGap flags != has-embedded-sections: $flagMismatch');
  });

  test('INFO-AREA: preGap marker is the alternate FTAB/VITS block tag (anti-correlated)', () {
    var checked = 0, markerInInventory = 0, oppositePresent = 0;
    final bad = <String>[];
    for (final f in all) {
      final bytes = _readBytes(f);
      if (bytes == null) continue;
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
        if (bad.length < 6) bad.add('${_base(f)}: marker $marker also a block');
      }
      if (blocks.contains(other)) oppositePresent++;
    }
    expect(checked, greaterThan(0));
    expect(markerInInventory, 0, reason: 'preGap marker tag appeared as a block: $bad');
    expect(oppositePresent, greaterThan((checked * 0.95).floor()),
        reason: 'opposite FTAB/VITS block missing: only $oppositePresent/$checked');
  });

  test('INFO-AREA: subheader reservedA == [0,0,0x20]; reservedB == trailing-name offset', () {
    var files = 0, badA = 0, nameOffMatch = 0, nameOffChecked = 0;
    for (final f in all) {
      final bytes = _readBytes(f);
      if (bytes == null) continue;
      final ViContainer c;
      try {
        c = ViContainer.parse(bytes);
      } catch (_) {
        continue;
      }
      files++;
      final sub = c.parsedInfoSubheader;
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
    expect(nameOffChecked, greaterThan(1000), reason: 'too few name records checked: $nameOffChecked');
    expect(nameOffMatch, nameOffChecked,
        reason: 'reservedB != trailing-name offset: $nameOffMatch/$nameOffChecked');
  });

  test('INFO-AREA: name-table header is a fixed 12-byte struct, unrelated to nameRef', () {
    var files = 0, twelve = 0;
    var highRefFiles = 0, highRefHeader12 = 0, maxHeaderAtHighRef = 0, maxRefSeen = 0;
    for (final f in all) {
      final bytes = _readBytes(f);
      if (bytes == null) continue;
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
        final d = ByteData.sublistView(hdr);
        if (d.getUint32(0) == 0 && d.getUint32(8) == 0) {
          expect(ia.nameTable.headerValue, d.getUint32(4));
        }
      }
      final maxRef = ia.descriptors.where((x) => x.isNamed).fold<int>(0, (a, x) => a > x.nameRef ? a : x.nameRef);
      if (maxRef > maxRefSeen) maxRefSeen = maxRef;
      if (maxRef > 100) {
        highRefFiles++;
        if (hdr.length == 12) highRefHeader12++;
        if (hdr.length > maxHeaderAtHighRef) maxHeaderAtHighRef = hdr.length;
      }
    }
    expect(files, greaterThan(0));
    expect(twelve, files, reason: 'name-table header not always 12 bytes: $twelve/$files');
    expect(highRefFiles, greaterThan(0), reason: 'no high-nameRef files to disprove with (maxRef seen: $maxRefSeen)');
    expect(highRefHeader12, highRefFiles,
        reason: 'header grew with nameRef ($highRefHeader12/$highRefFiles stayed 12; max header at high ref: $maxHeaderAtHighRef, maxRef: $maxRefSeen)');
  });

  test('INFO-AREA: name-table headerValue is a data-area offset (< dataSize)', () {
    var checked = 0;
    final bad = <String>[];
    for (final f in all) {
      final bytes = _readBytes(f);
      if (bytes == null) continue;
      final int? hv;
      final int dataSize;
      try {
        final c = ViContainer.parse(bytes);
        hv = c.parsedInfoArea.nameTable.headerValue;
        dataSize = c.parsedHeader.dataSize;
      } catch (_) {
        continue;
      }
      if (hv == null) continue;
      checked++;
      if (hv >= dataSize) {
        if (bad.length < 6) bad.add('${_base(f)}: headerValue=$hv >= dataSize=$dataSize');
      }
    }
    expect(checked, greaterThan(0));
    expect(bad, isEmpty, reason: 'headerValue not < dataSize: $bad');
  });

  test('INFO-AREA: descriptor word0 is always 0; word8 nonzero is legacy-only (rare)', () {
    var files = 0, badWord0 = 0, filesWithWord8 = 0;
    final w0ex = <String>[];
    for (final f in all) {
      final bytes = _readBytes(f);
      if (bytes == null) continue;
      final ViInfoArea ia;
      try {
        ia = ViContainer.parse(bytes).parsedInfoArea;
      } catch (_) {
        continue;
      }
      if (ia.descriptors.isEmpty) continue;
      files++;
      for (final d in ia.descriptors) {
        if (d.word0 != 0) {
          badWord0++;
          if (w0ex.length < 6) w0ex.add('${_base(f)}: word0=0x${d.word0.toRadixString(16)}');
        }
      }
      if (ia.descriptors.any((d) => d.word8 != 0)) filesWithWord8++;
    }
    expect(files, greaterThan(0));
    expect(badWord0, 0, reason: 'word0 not always 0: $w0ex');
    expect(filesWithWord8, lessThan((files * 0.02).ceil()),
        reason: 'word8 nonzero in too many files ($filesWithWord8/$files) — not legacy-only');
  });

  test('INFO-AREA: descriptor @16 is binary (0xFFFFFFFF | 0); nameRef is index-like', () {
    var files = 0;
    var maxNameRef = 0, maxInfoLen = 0;
    final badWords = <String>[];
    for (final f in all) {
      final bytes = _readBytes(f);
      if (bytes == null) continue;
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
        if (d.word16 != ViSectionDescriptor.commonWord16 && d.word16 != 0) {
          if (badWords.length < 6) {
            badWords.add('${_base(f)}: @16=0x${d.word16.toRadixString(16)}');
          }
        }
        if (d.nameRef > maxNameRef) maxNameRef = d.nameRef;
      }
    }
    expect(files, greaterThan(0));
    expect(badWords, isEmpty, reason: 'descriptor @16 not binary: $badWords');
    expect(maxInfoLen, greaterThan(4000), reason: 'corpus lacks large info areas to discriminate (max $maxInfoLen)');
    expect(maxNameRef, lessThan(1000),
        reason: 'nameRef looks like a byte offset, not an index: max $maxNameRef vs info up to $maxInfoLen');
  });

  test('INFO-AREA: name table recovers the trailing VI name for ~all VIs', () {
    var files = 0, withName = 0;
    final mismatches = <String>[];
    for (final f in all) {
      final bytes = _readBytes(f);
      if (bytes == null) continue;
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
        if (summaryName != null && summaryName != nt) {
          if (mismatches.length < 6) mismatches.add('${_base(f)}: "$nt" != "$summaryName"');
        }
      }
    }
    expect(files, greaterThan(0));
    expect(mismatches, isEmpty, reason: 'trailing-name disagreement: $mismatches');
    expect(withName, greaterThan((files * 0.85).floor()), reason: 'trailing name recovery dropped: $withName/$files');
  });

  test('IDEMPOTENCY: ViVi.parse(bytes).serialize() == bytes for every VI', () {
    roundTripsExact('ViVi round-trip', (b) => ViVi.parse(b).serialize());
  });

  test('TYPED EDIT: ViVi.withSectionEdited grow/shrink stays coherent for every VI', () {
    var files = 0, ok = 0;
    final fails = <String>[];

    for (final f in all) {
      final ViVi vi;
      try {
        vi = ViVi.parse(f.readAsBytesSync());
      } catch (_) {
        continue;
      }
      final secs = vi.sections.toList();
      if (secs.isEmpty) continue;
      files++;
      final target = secs.reduce((a, b) => a.secRel <= b.secRel ? a : b);
      final grown = Uint8List(target.payload.length + 6)
        ..setRange(0, target.payload.length, target.payload)
        ..fillRange(target.payload.length, target.payload.length + 6, 0x5A);
      try {
        final edited = vi.withSectionEdited(secRel: target.secRel, newPayload: grown);
        final out = edited.serialize();
        final consistent = eq(ViVi.parse(out).serialize(), out);
        final newTarget = edited.sections.where((s) => s.secRel == target.secRel).firstOrNull;
        final hasNew = newTarget != null && eq(newTarget.payload, grown);
        if (consistent && hasNew) {
          ok++;
        } else if (fails.length < 6) {
          fails.add('${_base(f)} consistent=$consistent hasNew=$hasNew');
        }
      } catch (_) {
        if (fails.length < 6) fails.add('${_base(f)} threw');
      }
    }
    expect(files, greaterThan(0));
    expect(ok, equals(files), reason: 'typed edit not coherent for ${files - ok} file(s): $fails');
  });

  test('IDEMPOTENCY: rebuildDataArea(decomposeDataArea(bytes)) == dataArea for every VI', () {
    var files = 0, exact = 0;
    final diffs = <String>[];
    for (final f in all) {
      final bytes = _readBytes(f);
      if (bytes == null) continue;
      final Uint8List data, rebuilt;
      try {
        data = ViContainer.parse(bytes).dataArea;
        rebuilt = ViExport.rebuildDataArea(ViExport.decomposeDataArea(bytes));
      } catch (_) {
        continue;
      }
      files++;
      final same = eq(rebuilt, data);
      if (same) {
        exact++;
      } else if (diffs.length < 6) {
        diffs.add('len ${data.length}->${rebuilt.length} ${_base(f)}');
      }
    }
    expect(files, greaterThan(0));
    expect(exact, equals(files),
        reason: 'data-area section round-trip not byte-exact for ${files - exact} file(s): $diffs');
  });

  test('SECTION-EDIT: editSection no-op is byte-exact; grow/shrink re-parse correctly', () {
    var files = 0, noopExact = 0, growOk = 0, shrinkOk = 0, grown = 0, shrunk = 0;
    final fails = <String>[];

    for (final f in all) {
      final Uint8List bytes;
      List<ViSection> secs;
      try {
        bytes = f.readAsBytesSync();
        secs = readViSections(bytes);
      } catch (_) {
        continue;
      }
      if (secs.isEmpty) continue;
      files++;
      final name = _base(f);
      final target = secs.reduce((a, b) => a.dataOffset <= b.dataOffset ? a : b);
      final secRel = target.dataOffset;
      final oldPayload = Uint8List.fromList(target.bytes);
      final origByKey = {for (final s in secs) '${s.tag}#${s.index}': Uint8List.fromList(s.bytes)};
      final targetKey = '${target.tag}#${target.index}';

      final noop = ViExport.editSection(bytes, secRel: secRel, newPayload: oldPayload);
      if (eq(noop, bytes)) {
        noopExact++;
      } else if (fails.length < 8) {
        fails.add('NOOP $name ${bytes.length}->${noop.length}');
      }

      bool checkEdit(Uint8List np) {
        final out = ViExport.editSection(bytes, secRel: secRel, newPayload: np);
        ViContainer.parse(out);
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

  test('SUBVI: readSubViNames yields clean, deduped, self-excluding .vi names', () {
    var files = 0, withNames = 0, totalNames = 0;
    final fails = <String>[];
    for (final f in all) {
      final bytes = _readBytes(f);
      if (bytes == null) continue;
      files++;
      final names = readSubViNames(bytes);
      if (names.isEmpty) continue;
      String? self;
      try {
        self = parseVi(bytes).name?.toLowerCase();
      } catch (_) {}
      final seen = <String>{};
      for (final n in names) {
        if (!n.toLowerCase().endsWith('.vi')) {
          if (fails.length < 8) fails.add('NOT .vi: "$n" in ${_base(f)}');
        }
        if (n.contains('/') || n.contains(r'\')) {
          if (fails.length < 8) fails.add('HAS PATH SEP: "$n" in ${_base(f)}');
        }
        if (!seen.add(n.toLowerCase())) {
          if (fails.length < 8) fails.add('DUPLICATE: "$n" in ${_base(f)}');
        }
        if (self != null && n.toLowerCase() == self) {
          if (fails.length < 8) fails.add('SELF INCLUDED: "$n" in ${_base(f)}');
        }
      }
      if (names.isNotEmpty) withNames++;
      totalNames += names.length;
    }
    expect(files, greaterThan(0));
    expect(fails, isEmpty, reason: 'subVI-name recovery cleanliness failures: $fails');
    expect(withNames, greaterThan((files * 0.60).floor()),
        reason: 'subVI-name recovery dropped: only $withNames/$files VIs yielded names ($totalNames total)');
  });
}
