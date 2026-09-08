@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

const _descBaseAfterCount = 8;
const _sectionDescriptorBytes = 20;
const _rsrcHeaderBytes = 32;

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _eqRange(List<int> a, int aStart, List<int> b, int bStart, int len) {
  for (var i = 0; i < len; i++) {
    if (a[aStart + i] != b[bStart + i]) return false;
  }
  return true;
}

Map<String, int> _inv(Uint8List bytes, String path) {
  final c = <String, int>{};
  void bad(String key) => c[key] = (c[key] ?? 0) + 1;

  void roundTrip(String key, Uint8List Function() transform, {bool Function(Uint8List out)? same}) {
    final Uint8List out;
    try {
      out = transform();
    } catch (_) {
      return;
    }
    if (!(same != null ? same(out) : _eq(out, bytes))) bad(key);
  }

  try {
    final inventory = parseVi(bytes).blocks.toSet();
    final sectionTags = readViSections(bytes).map((s) => s.tag).toSet();
    if (sectionTags.difference(inventory).isNotEmpty) bad('cross');
  } catch (_) {}

  try {
    for (final s in readEmbeddedSections(bytes)) {
      if (s.tag == 'VINS') {
        final isRsrc =
            s.bytes.length >= 12 &&
            String.fromCharCodes(s.bytes.sublist(0, 4)) == 'RSRC' &&
            String.fromCharCodes(s.bytes.sublist(8, 12)) == 'LVIN';
        var reparses = false;
        if (isRsrc) {
          try {
            ViContainer.parse(s.bytes);
            reparses = true;
          } catch (_) {}
        }
        if (!isRsrc || !reparses) bad('vinsNotRsrc');
      } else if (s.tag == 'LIBN') {
        final printable = s.bytes.where((b) => b >= 0x20 && b < 0x7f).length;
        if (printable < (s.bytes.length * 0.5).floor()) bad('libnNotPrintable');
      }
    }
  } catch (_) {}

  roundTrip('rtBytes', () => ViContainer.parse(bytes).toBytes());
  roundTrip('rtSerialize', () => ViContainer.parse(bytes).serialize());
  roundTrip('rtVivi', () => ViVi.parse(bytes).serialize());

  try {
    final header = ViContainer.parse(bytes).header;
    final out = ViHeader.parse(header).serialize();
    if (!(out.length == header.length &&
        header.length >= _rsrcHeaderBytes &&
        _eqRange(out, 0, header, 0, _rsrcHeaderBytes))) {
      bad('rtHeader');
    }
  } catch (_) {}

  try {
    final info = ViContainer.parse(bytes).infoArea;
    final sh = ViInfoSubheader.parse(info);
    final out = sh.serialize();
    if (!(out.length == sh.blockListRel && _eqRange(out, 0, info, 0, sh.blockListRel))) bad('rtSub');
  } catch (_) {}

  try {
    final info = ViContainer.parse(bytes).infoArea;
    final blr = ViInfoSubheader.parse(info).blockListRel;
    final out = ViBlockList.parse(info, blr).serialize();
    if (!(blr + out.length <= info.length && _eqRange(out, 0, info, blr, out.length))) bad('rtBl');
  } catch (_) {}

  try {
    final info = ViContainer.parse(bytes).infoArea;
    final blr = ViInfoSubheader.parse(info).blockListRel;
    final bl = ViBlockList.parse(info, blr);
    final descBase = blr + _descBaseAfterCount;
    for (final e in bl.entries) {
      for (var s = 0; s < e.sectionCountMinus1 + 1; s++) {
        final dpos = descBase + e.descRel + s * _sectionDescriptorBytes;
        if (dpos < 0 || dpos + _sectionDescriptorBytes > info.length) continue;
        final out = ViSectionDescriptor.parse(info, dpos).serialize();
        if (!_eqRange(out, 0, info, dpos, _sectionDescriptorBytes)) bad('desc');
      }
    }
  } catch (_) {}

  try {
    final data = ViContainer.parse(bytes).dataArea;
    final rebuilt = ViExport.rebuildDataArea(ViExport.decomposeDataArea(bytes));
    if (!_eq(rebuilt, data)) bad('rtData');
  } catch (_) {}

  try {
    final cont = ViContainer.parse(bytes);
    final ia = cont.parsedInfoArea;
    final bl = cont.parsedBlockList;
    if (ia.descriptors.isNotEmpty) {
      final total = bl.entries.fold<int>(0, (a, e) => a + e.sectionCountMinus1 + 1);
      if (ia.descriptors.length < total || ia.preGap == null) bad('peel');
    }
  } catch (_) {}

  try {
    final ia = ViContainer.parse(bytes).parsedInfoArea;
    final pg = ia.preGap;
    final fe = ia.blockList.finalEntry;
    final hasEmbedded = readEmbeddedSections(bytes).isNotEmpty;
    if (pg != null && fe != null) {
      if (fe.tag != 'FTAB' && fe.tag != 'VITS') bad('preGapMarker');
      if (fe.sectionCountMinus1 != 0 || pg.word0 != 0) bad('preGapZero');
      if (pg.hasEmbeddedSections != hasEmbedded || (pg.flags != 0xFFFFFFFF && pg.flags != 0)) bad('preGapFlags');
      if (ia.finalEntrySecRel == null) bad('finalEntryDesc');
      if ((fe.tag == 'FTAB' || fe.tag == 'VITS') && !parseVi(bytes).blocks.contains(fe.tag)) bad('finalEntry');
    }
  } catch (_) {}

  try {
    final cont = ViContainer.parse(bytes);
    final sub = cont.parsedInfoSubheader;
    var aOk = sub.reservedA.length == 12;
    if (aOk) {
      final d = ByteData.sublistView(sub.reservedA);
      aOk = d.getUint32(0) == 0 && d.getUint32(4) == 0 && d.getUint32(8) == 0x20;
    }
    if (!aOk) bad('subReservedA');
    final off = sub.viNameOffset;
    final rec = cont.parsedInfoArea.nameTable.trailingNameRecord;
    if (off != null && rec.isNotEmpty && off != cont.infoArea.length - rec.length) bad('nameOff');
  } catch (_) {}

  try {
    final cont = ViContainer.parse(bytes);
    final ia = cont.parsedInfoArea;
    if (ia.descriptors.isNotEmpty) {
      final hdr = ia.nameTable.header;
      if (hdr.length != 12) {
        bad('ntHeaderNot12');
      } else {
        final d = ByteData.sublistView(hdr);
        if (d.getUint32(0) == 0 && d.getUint32(8) == 0 && ia.nameTable.headerValue != d.getUint32(4)) {
          bad('ntHeaderValue');
        }
      }
      for (final d in ia.descriptors) {
        if (d.word0 != 0) bad('word0');
        if (d.word16 != ViSectionDescriptor.commonWord16 && d.word16 != 0) bad('word16');
      }
      final nt = ia.nameTable.trailingName;
      if (nt != null) {
        final summaryName = parseVi(bytes).name;
        if (summaryName != null && summaryName != nt) bad('tnMismatch');
      }
    }
  } catch (_) {}

  try {
    final cont = ViContainer.parse(bytes);
    final hv = cont.parsedInfoArea.nameTable.headerValue;
    if (hv != null && hv >= cont.parsedHeader.dataSize) bad('hvRange');
  } catch (_) {}

  try {
    final vi = ViVi.parse(bytes);
    final secs = vi.sections.toList();
    if (secs.isNotEmpty) {
      final target = secs.reduce((a, b) => a.secRel <= b.secRel ? a : b);
      final grown = Uint8List(target.payload.length + 6)
        ..setRange(0, target.payload.length, target.payload)
        ..fillRange(target.payload.length, target.payload.length + 6, 0x5A);
      try {
        final edited = vi.withSectionEdited(secRel: target.secRel, newPayload: grown);
        final out = edited.serialize();
        final consistent = _eq(ViVi.parse(out).serialize(), out);
        final newTarget = edited.sections.where((s) => s.secRel == target.secRel).firstOrNull;
        final hasNew = newTarget != null && _eq(newTarget.payload, grown);
        if (!consistent || !hasNew) bad('edit');
      } catch (_) {
        bad('edit');
      }
    }
  } catch (_) {}

  try {
    final secs = readViSections(bytes);
    if (secs.isNotEmpty) {
      final target = secs.reduce((a, b) => a.dataOffset <= b.dataOffset ? a : b);
      final secRel = target.dataOffset;
      final oldPayload = Uint8List.fromList(target.bytes);
      final origByKey = {for (final s in secs) '${s.tag}#${s.index}': Uint8List.fromList(s.bytes)};
      final targetKey = '${target.tag}#${target.index}';

      if (!_eq(ViExport.editSection(bytes, secRel: secRel, newPayload: oldPayload), bytes)) bad('seditNoop');

      bool checkEdit(Uint8List np) {
        final out = ViExport.editSection(bytes, secRel: secRel, newPayload: np);
        ViContainer.parse(out);
        final rsecs = readViSections(out);
        final edited = rsecs.where((s) => '${s.tag}#${s.index}' == targetKey).firstOrNull;
        if (edited == null || !_eq(edited.bytes, np)) return false;
        for (final s in rsecs) {
          final key = '${s.tag}#${s.index}';
          if (key == targetKey) continue;
          final orig = origByKey[key];
          if (orig == null || !_eq(s.bytes, orig)) return false;
        }
        return true;
      }

      final grow = Uint8List(oldPayload.length + 8)
        ..setRange(0, oldPayload.length, oldPayload)
        ..fillRange(oldPayload.length, oldPayload.length + 8, 0xAB);
      if (!checkEdit(grow)) bad('seditGrow');
      if (oldPayload.length >= 2 && !checkEdit(Uint8List.sublistView(oldPayload, 0, oldPayload.length ~/ 2))) {
        bad('seditShrink');
      }
    }
  } catch (_) {}

  final names = readSubViNames(bytes);
  if (names.isNotEmpty) {
    String? self;
    try {
      self = parseVi(bytes).name?.toLowerCase();
    } catch (_) {}
    final seen = <String>{};
    for (final name in names) {
      if (!name.toLowerCase().endsWith('.vi')) bad('subviClean');
      if (name.contains('/') || name.contains(r'\')) bad('subviClean');
      if (!seen.add(name.toLowerCase())) bad('subviClean');
      if (self != null && name.toLowerCase() == self) bad('subviClean');
    }
  }

  final pathNames = <String>{};
  for (final path in readSubViPaths(bytes)) {
    if (path.fileName.isEmpty) bad('subviPathClean');
    if (!pathNames.add(path.fileName.toLowerCase())) bad('subviPathClean');
    if (path.kind == ViSubViPathKind.relative && path.segments.isEmpty) bad('subviPathClean');
    if (path.kind == ViSubViPathKind.relative && path.upLevels > 20) bad('subviPathClean');
  }

  return c;
}

void main() {
  final all = corpusVis();
  late final List<Map<String, int>> res;
  setUpAll(() async {
    res = await corpusParallel(all, _inv);
  });

  Map<String, Map<String, int>> violations(Set<String> laws) => perFileNonzero(all, res, laws);

  test('CROSS-CONSISTENCY: every extracted section tag is in parseVi\'s block inventory', () {
    expect(violations({'cross'}), const <String, Map<String, int>>{});
  });

  test('SECTION: recovered VINS re-parse as VIs and LIBN carries printable names', () {
    expect(violations({'vinsNotRsrc', 'libnNotPrintable'}), const <String, Map<String, int>>{});
  });

  test('IDEMPOTENCY: every container layer re-serializes byte-exact for every VI', () {
    expect(
      violations({'rtBytes', 'rtSerialize', 'rtVivi', 'rtHeader', 'rtSub', 'rtBl', 'rtData', 'desc'}),
      const <String, Map<String, int>>{},
    );
  });

  test('INFO-AREA: descriptor peel, final entry, subheader, name table and trailing name laws', () {
    expect(
      violations({
        'peel',
        'preGapMarker',
        'preGapZero',
        'preGapFlags',
        'finalEntry',
        'finalEntryDesc',
        'subReservedA',
        'nameOff',
        'ntHeaderNot12',
        'ntHeaderValue',
        'word0',
        'word16',
        'tnMismatch',
        'hvRange',
      }),
      const <String, Map<String, int>>{},
    );
  });

  test('EDIT: typed and raw section edits stay coherent for every VI', () {
    expect(violations({'edit', 'seditNoop', 'seditGrow', 'seditShrink'}), const <String, Map<String, int>>{});
  });

  test('SUBVI: names and paths are clean, deduped and plausible', () {
    expect(violations({'subviClean', 'subviPathClean'}), const <String, Map<String, int>>{});
  });
}
