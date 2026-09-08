@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

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

(Map<String, int>, List<String>) _inv(Uint8List bytes, String path) {
  final c = <String, int>{};
  final diags = <String>[];
  final base = path.split('/').last;
  void n(String k, [int by = 1]) => c[k] = (c[k] ?? 0) + by;
  void mx(String k, int v) {
    if (v > (c[k] ?? 0)) c[k] = v;
  }

  void bad(String key, String msg) {
    n('bad:$key');
    if (diags.length < 6) diags.add('$key• $base: $msg');
  }

  void roundTrip(String key, Uint8List Function() transform, {bool Function(Uint8List out)? same}) {
    final Uint8List out;
    try {
      out = transform();
    } catch (_) {
      return;
    }
    n('$key.files');
    if (same != null ? same(out) : _eq(out, bytes)) {
      n('$key.exact');
    } else {
      bad(key, 'not byte-exact (len ${bytes.length}->${out.length})');
    }
  }

  try {
    final inventory = parseVi(bytes).blocks.toSet();
    final sectionTags = readViSections(bytes).map((s) => s.tag).toSet();
    n('cross.files');
    final stray = sectionTags.difference(inventory);
    if (stray.isNotEmpty) bad('cross', 'section tag(s) $stray absent from parseVi inventory — readers desynced');
  } catch (_) {}

  try {
    for (final s in readEmbeddedSections(bytes)) {
      if (s.tag == 'VINS') {
        n('vins');
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
        if (!isRsrc || !reparses) bad('vinsNotRsrc', 'VINS#${s.index} ${s.bytes.length}B');
      } else if (s.tag == 'LIBN') {
        n('libn');
        final printable = s.bytes.where((b) => b >= 0x20 && b < 0x7f).length;
        if (printable < (s.bytes.length * 0.5).floor()) bad('libnNotPrintable', '${s.bytes.length}B');
      }
    }
  } catch (_) {}

  roundTrip('rtBytes', () => ViContainer.parse(bytes).toBytes());
  roundTrip('rtSerialize', () => ViContainer.parse(bytes).serialize());
  roundTrip('rtVivi', () => ViVi.parse(bytes).serialize());

  try {
    final header = ViContainer.parse(bytes).header;
    final out = ViHeader.parse(header).serialize();
    n('rtHeader.files');
    if (out.length == header.length &&
        header.length >= _rsrcHeaderBytes &&
        _eqRange(out, 0, header, 0, _rsrcHeaderBytes)) {
      n('rtHeader.exact');
    } else {
      bad('rtHeader', 'mismatch');
    }
  } catch (_) {}

  try {
    final info = ViContainer.parse(bytes).infoArea;
    final sh = ViInfoSubheader.parse(info);
    final out = sh.serialize();
    n('rtSub.files');
    if (out.length == sh.blockListRel && _eqRange(out, 0, info, 0, sh.blockListRel)) {
      n('rtSub.exact');
    } else {
      bad('rtSub', 'mismatch');
    }
  } catch (_) {}

  try {
    final info = ViContainer.parse(bytes).infoArea;
    final blr = ViInfoSubheader.parse(info).blockListRel;
    final out = ViBlockList.parse(info, blr).serialize();
    n('rtBl.files');
    if (blr + out.length <= info.length && _eqRange(out, 0, info, blr, out.length)) {
      n('rtBl.exact');
    } else {
      bad('rtBl', 'mismatch');
    }
  } catch (_) {}

  try {
    final info = ViContainer.parse(bytes).infoArea;
    final blr = ViInfoSubheader.parse(info).blockListRel;
    final bl = ViBlockList.parse(info, blr);
    final descBase = blr + _descBaseAfterCount;
    n('desc.files');
    for (final e in bl.entries) {
      for (var s = 0; s < e.sectionCountMinus1 + 1; s++) {
        final dpos = descBase + e.descRel + s * _sectionDescriptorBytes;
        if (dpos < 0 || dpos + _sectionDescriptorBytes > info.length) continue;
        n('desc.count');
        final out = ViSectionDescriptor.parse(info, dpos).serialize();
        if (!_eqRange(out, 0, info, dpos, _sectionDescriptorBytes)) bad('desc', '@$dpos');
      }
    }
  } catch (_) {}

  try {
    final data = ViContainer.parse(bytes).dataArea;
    final rebuilt = ViExport.rebuildDataArea(ViExport.decomposeDataArea(bytes));
    n('rtData.files');
    if (_eq(rebuilt, data)) {
      n('rtData.exact');
    } else {
      bad('rtData', 'len ${data.length}->${rebuilt.length}');
    }
  } catch (_) {}

  try {
    final cont = ViContainer.parse(bytes);
    final ia = cont.parsedInfoArea;
    final bl = cont.parsedBlockList;
    n('peel.files');
    if (ia.descriptors.isNotEmpty) {
      n('peel.peeled');
      final total = bl.entries.fold<int>(0, (a, e) => a + e.sectionCountMinus1 + 1);
      if (ia.descriptors.length < total || ia.preGap == null) {
        bad('peel', '${ia.descriptors.length} < $total or preGap null');
      }
    }
  } catch (_) {}

  try {
    final ia = ViContainer.parse(bytes).parsedInfoArea;
    final pg = ia.preGap;
    final fe = ia.blockList.finalEntry;
    final hasEmbedded = readEmbeddedSections(bytes).isNotEmpty;
    if (pg != null && fe != null) {
      n('preGap.files');
      if (fe.tag != 'FTAB' && fe.tag != 'VITS') bad('preGapMarker', fe.tag);
      if (fe.sectionCountMinus1 != 0 || pg.word0 != 0) {
        bad('preGapZero', 'sections-1=${fe.sectionCountMinus1} w0=${pg.word0}');
      }
      if (pg.hasEmbeddedSections != hasEmbedded || (pg.flags != 0xFFFFFFFF && pg.flags != 0)) {
        bad('preGapFlags', 'flags=0x${pg.flags.toRadixString(16)} embedded=$hasEmbedded');
      }
      if (ia.finalEntrySecRel == null) bad('finalEntryDesc', 'final entry descriptor not at the name table');
      if (fe.tag == 'FTAB' || fe.tag == 'VITS') {
        final blocks = parseVi(bytes).blocks.toSet();
        n('anti.checked');
        if (!blocks.contains(fe.tag)) bad('finalEntry', 'final entry ${fe.tag} not read as a block');
      }
    }
  } catch (_) {}

  try {
    final cont = ViContainer.parse(bytes);
    final sub = cont.parsedInfoSubheader;
    n('sub.files');
    var aOk = sub.reservedA.length == 12;
    if (aOk) {
      final d = ByteData.sublistView(sub.reservedA);
      aOk = d.getUint32(0) == 0 && d.getUint32(4) == 0 && d.getUint32(8) == 0x20;
    }
    if (!aOk) bad('subReservedA', 'not [0,0,0x20]');
    final off = sub.viNameOffset;
    final rec = cont.parsedInfoArea.nameTable.trailingNameRecord;
    if (off != null && rec.isNotEmpty) {
      n('nameOff.checked');
      if (off == cont.infoArea.length - rec.length) n('nameOff.match');
    }
  } catch (_) {}

  try {
    final cont = ViContainer.parse(bytes);
    final ia = cont.parsedInfoArea;
    if (ia.descriptors.isNotEmpty) {
      n('nt.files');
      final hdr = ia.nameTable.header;
      if (hdr.length == 12) {
        n('nt.twelve');
        final d = ByteData.sublistView(hdr);
        if (d.getUint32(0) == 0 && d.getUint32(8) == 0 && ia.nameTable.headerValue != d.getUint32(4)) {
          bad('ntHeaderValue', '${ia.nameTable.headerValue} != ${d.getUint32(4)}');
        }
      }
      final maxRef = ia.descriptors.where((x) => x.isNamed).fold<int>(0, (a, x) => a > x.nameRef ? a : x.nameRef);
      mx('nt.maxRefSeen', maxRef);
      if (maxRef > 100) {
        n('nt.highRefFiles');
        if (hdr.length == 12) n('nt.highRefHeader12');
        mx('nt.maxHeaderAtHighRef', hdr.length);
      }

      for (final d in ia.descriptors) {
        if (d.word0 != 0) bad('word0', '0x${d.word0.toRadixString(16)}');
        if (d.word16 != ViSectionDescriptor.commonWord16 && d.word16 != 0) {
          bad('word16', '@16=0x${d.word16.toRadixString(16)}');
        }
        mx('desc.maxNameRef', d.nameRef);
      }
      if (ia.descriptors.any((d) => d.word8 != 0)) n('word8.files');
      mx('info.maxLen', cont.infoArea.length);

      final nt = ia.nameTable.trailingName;
      n('tn.files');
      if (nt != null) {
        n('tn.withName');
        final summaryName = parseVi(bytes).name;
        if (summaryName != null && summaryName != nt) bad('tnMismatch', '"$nt" != "$summaryName"');
      }
    }
  } catch (_) {}

  try {
    final cont = ViContainer.parse(bytes);
    final hv = cont.parsedInfoArea.nameTable.headerValue;
    if (hv != null) {
      n('hv.checked');
      if (hv >= cont.parsedHeader.dataSize) {
        bad('hvRange', 'headerValue=$hv >= dataSize=${cont.parsedHeader.dataSize}');
      }
    }
  } catch (_) {}

  try {
    final vi = ViVi.parse(bytes);
    final secs = vi.sections.toList();
    if (secs.isNotEmpty) {
      n('edit.files');
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
        if (consistent && hasNew) {
          n('edit.ok');
        } else {
          bad('edit', 'consistent=$consistent hasNew=$hasNew');
        }
      } catch (_) {
        bad('edit', 'threw');
      }
    }
  } catch (_) {}

  try {
    final secs = readViSections(bytes);
    if (secs.isNotEmpty) {
      n('sedit.files');
      final target = secs.reduce((a, b) => a.dataOffset <= b.dataOffset ? a : b);
      final secRel = target.dataOffset;
      final oldPayload = Uint8List.fromList(target.bytes);
      final origByKey = {for (final s in secs) '${s.tag}#${s.index}': Uint8List.fromList(s.bytes)};
      final targetKey = '${target.tag}#${target.index}';

      final noop = ViExport.editSection(bytes, secRel: secRel, newPayload: oldPayload);
      if (_eq(noop, bytes)) {
        n('sedit.noopExact');
      } else {
        bad('seditNoop', '${bytes.length}->${noop.length}');
      }

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
      n('sedit.grown');
      if (checkEdit(grow)) {
        n('sedit.growOk');
      } else {
        bad('seditGrow', '');
      }
      if (oldPayload.length >= 2) {
        n('sedit.shrunk');
        if (checkEdit(Uint8List.sublistView(oldPayload, 0, oldPayload.length ~/ 2))) {
          n('sedit.shrinkOk');
        } else {
          bad('seditShrink', '');
        }
      }
    }
  } catch (_) {}

  n('subvi.files');
  final names = readSubViNames(bytes);
  if (names.isNotEmpty) {
    n('subvi.withNames');
    n('subvi.totalNames', names.length);
    String? self;
    try {
      self = parseVi(bytes).name?.toLowerCase();
    } catch (_) {}
    final seen = <String>{};
    for (final name in names) {
      if (!name.toLowerCase().endsWith('.vi')) bad('subviClean', 'NOT .vi: "$name"');
      if (name.contains('/') || name.contains(r'\')) bad('subviClean', 'HAS PATH SEP: "$name"');
      if (!seen.add(name.toLowerCase())) bad('subviClean', 'DUPLICATE: "$name"');
      if (self != null && name.toLowerCase() == self) bad('subviClean', 'SELF INCLUDED: "$name"');
    }
  }

  final subViPaths = readSubViPaths(bytes);
  if (subViPaths.isNotEmpty) n('subvipath.withPaths');
  final pathNames = <String>{};
  for (final path in subViPaths) {
    n('subvipath.records');
    n('subvipath.${path.kind.name}');
    if (path.fileName.isEmpty) bad('subviPathClean', 'EMPTY FILENAME');
    if (!pathNames.add(path.fileName.toLowerCase())) {
      bad('subviPathClean', 'DUPLICATE: "${path.fileName}"');
    }
    if (path.kind == ViSubViPathKind.relative && path.segments.isEmpty) {
      bad('subviPathClean', 'RELATIVE WITHOUT SEGMENTS');
    }
    if (path.kind == ViSubViPathKind.relative && path.upLevels > 20) {
      bad('subviPathClean', 'IMPLAUSIBLE UP-LEVELS ${path.upLevels}');
    }
  }

  return (c, diags);
}

void main() {
  final all = corpusVis();

  late final Map<String, int> C;
  late final List<String> diags;
  setUpAll(() async {
    final res = await corpusParallel(all, _inv);
    C = {};
    diags = [];
    for (final (counts, d) in res) {
      counts.forEach((k, v) {
        C[k] = k.startsWith('nt.max') || k == 'desc.maxNameRef' || k == 'info.maxLen'
            ? (v > (C[k] ?? 0) ? v : (C[k] ?? 0))
            : (C[k] ?? 0) + v;
      });
      diags.addAll(d);
    }
  });

  int cnt(String k) => C[k] ?? 0;
  List<String> D(String key) => diags.where((d) => d.startsWith('$key•')).take(6).toList();

  void exactForAll(String name, String key) {
    test(name, () {
      expect(
        cnt('$key.exact'),
        cnt('$key.files'),
        reason: 'not byte-exact for ${cnt('$key.files') - cnt('$key.exact')} file(s): ${D(key)}',
      );
    });
  }

  test('CROSS-CONSISTENCY: every extracted section tag is in parseVi\'s block inventory', () {
    expect(D('cross'), isEmpty, reason: 'the two RSRC readers desynced');
  });

  test('SECTION: recovered VINS re-parse as VIs and LIBN carries printable names', () {
    expect(cnt('bad:vinsNotRsrc'), 0, reason: 'VINS not a re-parseable RSRC...LVIN VI: ${D('vinsNotRsrc')}');
    expect(cnt('bad:libnNotPrintable'), 0, reason: 'LIBN without printable text: ${D('libnNotPrintable')}');
  });

  exactForAll('IDEMPOTENCY: ViContainer.parse(bytes).toBytes() == bytes for every VI', 'rtBytes');
  exactForAll('IDEMPOTENCY: ViContainer.serialize() == original bytes for every VI', 'rtSerialize');
  exactForAll('IDEMPOTENCY: ViVi.parse(bytes).serialize() == bytes for every VI', 'rtVivi');
  exactForAll('IDEMPOTENCY: ViHeader.parse(header).serialize() == header for every VI', 'rtHeader');
  exactForAll('IDEMPOTENCY: ViInfoSubheader.serialize() == info-area prefix for every VI', 'rtSub');
  exactForAll('IDEMPOTENCY: ViBlockList.serialize() == raw block-list region for every VI', 'rtBl');
  exactForAll('IDEMPOTENCY: rebuildDataArea(decomposeDataArea(bytes)) == dataArea for every VI', 'rtData');

  test('IDEMPOTENCY: ViSectionDescriptor.serialize() == raw 20 bytes for every descriptor', () {
    expect(D('desc'), isEmpty, reason: 'descriptor round-trip not byte-exact');
  });

  test('INFO-AREA: the descriptor-table peel never mismatches', () {
    expect(D('peel'), isEmpty, reason: 'descriptor peel mismatch');
  });

  test('INFO-AREA: the final block-list entry and its descriptor; flags == has-embedded-sections', () {
    expect(D('preGapMarker'), isEmpty, reason: 'final block-list entry not FTAB/VITS');
    expect(D('preGapZero'), isEmpty, reason: 'final entry section count / preGap word0 not zero');
    expect(D('preGapFlags'), isEmpty, reason: 'preGap flags != has-embedded-sections');
    expect(cnt('bad:finalEntry'), 0, reason: 'final block-list entry not surfaced as a block: ${D('finalEntry')}');
    expect(
      cnt('bad:finalEntryDesc'),
      0,
      reason: 'final entry descriptor not at the name table: ${D('finalEntryDesc')}',
    );
  });

  test('INFO-AREA: subheader reservedA == [0,0,0x20]; reservedB == trailing-name offset', () {
    expect(cnt('bad:subReservedA'), 0, reason: 'reservedA not [0,0,0x20]: ${D('subReservedA')}');
    expect(
      cnt('nameOff.match'),
      cnt('nameOff.checked'),
      reason: 'reservedB != trailing-name offset: ${cnt('nameOff.match')}/${cnt('nameOff.checked')}',
    );
  });

  test('INFO-AREA: name-table header is a fixed 12-byte struct, unrelated to nameRef', () {
    expect(cnt('nt.twelve'), cnt('nt.files'), reason: 'name-table header not always 12 bytes');
    expect(cnt('bad:ntHeaderValue'), 0, reason: 'headerValue != u32@4: ${D('ntHeaderValue')}');
    expect(
      cnt('nt.highRefHeader12'),
      cnt('nt.highRefFiles'),
      reason:
          'header grew with nameRef (${cnt('nt.highRefHeader12')}/${cnt('nt.highRefFiles')} stayed 12; '
          'max header at high ref: ${cnt('nt.maxHeaderAtHighRef')}, maxRef: ${cnt('nt.maxRefSeen')})',
    );
  });

  test('INFO-AREA: name-table headerValue is a data-area offset (< dataSize)', () {
    expect(D('hvRange'), isEmpty, reason: 'headerValue not < dataSize');
  });

  test('INFO-AREA: descriptor word0 is always 0; @16 is binary (0xFFFFFFFF | 0)', () {
    expect(cnt('bad:word0'), 0, reason: 'word0 not always 0: ${D('word0')}');
    expect(D('word16'), isEmpty, reason: 'descriptor @16 not binary');
  });

  test('INFO-AREA: the trailing VI name never disagrees between recoveries', () {
    expect(D('tnMismatch'), isEmpty, reason: 'trailing-name disagreement');
  });

  test('TYPED EDIT: ViVi.withSectionEdited grow stays coherent for every VI', () {
    expect(
      cnt('edit.ok'),
      cnt('edit.files'),
      reason: 'typed edit not coherent for ${cnt('edit.files') - cnt('edit.ok')} file(s): ${D('edit')}',
    );
  });

  test('SECTION-EDIT: editSection no-op is byte-exact; grow/shrink re-parse correctly', () {
    expect(
      cnt('sedit.noopExact'),
      cnt('sedit.files'),
      reason: 'no-op edit not byte-exact for ${cnt('sedit.files') - cnt('sedit.noopExact')}: ${D('seditNoop')}',
    );
    expect(
      cnt('sedit.growOk'),
      cnt('sedit.grown'),
      reason: 'grow edit broke ${cnt('sedit.grown') - cnt('sedit.growOk')}: ${D('seditGrow')}',
    );
    expect(
      cnt('sedit.shrinkOk'),
      cnt('sedit.shrunk'),
      reason: 'shrink edit broke ${cnt('sedit.shrunk') - cnt('sedit.shrinkOk')}: ${D('seditShrink')}',
    );
  });

  test('SUBVI: readSubViNames yields clean, deduped, self-excluding .vi names', () {
    expect(cnt('bad:subviClean'), 0, reason: 'subVI-name cleanliness failures: ${D('subviClean')}');
  });

  test('SUBVI PATHS: readSubViPaths yields named, deduped, plausible records', () {
    expect(cnt('bad:subviPathClean'), 0, reason: 'subVI-path failures: ${D('subviPathClean')}');
  });

  test('container-layer censuses match the committed snapshot exactly', () {
    expectCorpusSnapshot('container', {
      for (final e in C.entries)
        if (!e.key.startsWith('bad:')) e.key: e.value,
    });
  });
}
