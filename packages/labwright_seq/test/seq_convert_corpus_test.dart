@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Corpus gates for the cross-flavor converters: every loop must retain 100%
/// of the information its source model carries.
///
/// Equality tiers achieved (asserted below, per file):
/// - **INI → XML → INI: byte-exact** (58/58). The intermediate XML also
///   writes + reparses to a deep-equal XML-flavor model, and a further
///   INI → XML hop is a fixpoint.
/// - **XML → INI → XML: byte-exact** (36/36) — the rebuilt model deep-equals
///   the original parse, so the byte-exact XML writer reproduces the original
///   bytes. The intermediate INI also writes + reparses deep-equal
///   ([iniDeepEquals]), and a further XML → INI hop is a fixpoint.
/// - **binary → XML / INI: decoded-surface-exact** (294/294). The binary
///   reader is a PARTIAL decoder with no writer, so the gate asserts
///   retention of exactly the decoded surface: the lifted model (marked
///   partial via its root attribute) survives XML write/reparse and the
///   XML ↔ INI loop deep-equal. A binary whose body does not inflate refuses
///   with [FormatException] (0 in the current corpus) — refusal is honest,
///   fabrication is not.
///
/// Counts are pinned so a corpus refresh consciously extends the gates.
const _pinnedIniSeqCount = 58;
const _pinnedXmlSeqCount = 36;
const _pinnedBinarySeqCount = 294;

void main() {
  if (!corpusSeqDir.existsSync()) {
    test('cross-flavor corpus gates (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  final byFormat = <SeqFormat, List<File>>{};
  final files = corpusSeqDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.seq')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    byFormat.putIfAbsent(detectSeqFormat(_read(f)), () => []).add(f);
  }

  test('INI → XML → INI is byte-exact for every INI corpus file (and the XML hop is stable)', () {
    final iniFiles = byFormat[SeqFormat.ini] ?? const <File>[];
    expect(iniFiles.length, _pinnedIniSeqCount, reason: 'INI corpus count drifted');
    var byteExact = 0;
    for (final f in iniFiles) {
      final bytes = _read(f);
      final doc = parseIniSeqBytes(bytes);
      final xml = iniToXmlSeqFile(doc);

      // The intermediate is a real XML-flavor file: it writes and reparses to
      // a deep-equal model.
      final xmlBytes = writeSeqFileXml(xml);
      expect(detectSeqFormat(xmlBytes), SeqFormat.xml, reason: '${f.path}: intermediate must sniff as XML');
      final reparsed = parseSeqFile(xmlBytes);
      expect(seqFileDeepEquals(xml, reparsed), isTrue, reason: '${f.path}: XML intermediate must reparse deep-equal');

      // Byte-exact return trip from the REPARSED intermediate (the whole
      // journey crosses the on-disk XML encoding).
      final back = xmlToIniSeqFile(reparsed);
      expect(iniDeepEquals(doc, back), isTrue, reason: '${f.path}: INI model must return deep-equal');
      expect(writeIniSeq(back), bytes, reason: '${f.path}: INI → XML → INI must be byte-exact');
      byteExact++;

      // Longer loops stabilize after the first hop.
      expect(
        seqFileDeepEquals(xml, iniToXmlSeqFile(back)),
        isTrue,
        reason: '${f.path}: INI → XML must be a fixpoint',
      );
    }
    // ignore: avoid_print
    print('retention INI → XML → INI: byte-exact $byteExact/${iniFiles.length}');
    expect(byteExact, _pinnedIniSeqCount);
  });

  test('iniDataTree keeps instance directives on an inherited container member', () {
    // The byte-exact INI → XML → INI trip rides the verbatim x-ini-source
    // channel, which bypasses the decoded data tree — so its inheritance
    // expansion (iniDataTree) is otherwise checked only for write/reparse
    // self-consistency, not correctness. This pins the load-bearing case: a
    // member that is a container ONLY through its type (inherited), carrying an
    // instance-level directive on the object that inherits it. The expansion
    // must materialize that member with the instance directive attached; the
    // shared inherited-subtree cache must NOT be allowed to serve a copy that
    // has dropped it.
    final iniFiles = byFormat[SeqFormat.ini] ?? const <File>[];
    final f = iniFiles.firstWhere(
      (f) => f.path.endsWith('Non-Hardware Express VIs.seq'),
      orElse: () => throw StateError('representative inherited-container corpus file missing'),
    );
    final root = iniDataTree(parseIniSeqBytes(_read(f)));
    expect(root, isNotNull, reason: '${f.path}: data root must decode');
    // Data → Seq[0] (MainSequence) → Locals → signal (typed LabVIEWDynamicData,
    // a container only via its type) → Element1 (inherited, instance %HI).
    final signal = root!.prop('Seq')?.array?.first.prop('Locals')?.prop('signal');
    expect(signal?.typeName, 'LabVIEWDynamicData', reason: '${f.path}: signal must resolve its inherited type');
    final element1 = signal?.prop('Element1');
    expect(element1, isNotNull, reason: '${f.path}: inherited container member must materialize');
    expect(
      element1!.attributes['%HI'],
      isNotNull,
      reason: '${f.path}: the instance %HI directive on the inherited container must survive expansion',
    );
  });

  test('XML → INI → XML is byte-exact for every XML corpus file (and the INI hop is stable)', () {
    final xmlFiles = byFormat[SeqFormat.xml] ?? const <File>[];
    expect(xmlFiles.length, _pinnedXmlSeqCount, reason: 'XML corpus count drifted');
    var byteExact = 0;
    for (final f in xmlFiles) {
      final bytes = _read(f);
      final file = parseSeqFile(bytes);
      final ini = xmlToIniSeqFile(file);

      // The intermediate is a real INI file: it writes and reparses to a
      // deep-equal section model.
      final iniBytes = writeIniSeq(ini);
      expect(detectSeqFormat(iniBytes), SeqFormat.ini, reason: '${f.path}: intermediate must sniff as INI');
      final reparsed = parseIniSeqBytes(iniBytes);
      expect(iniDeepEquals(ini, reparsed), isTrue, reason: '${f.path}: INI intermediate must reparse deep-equal');

      // Deep-equal model return from the reparsed intermediate; the
      // byte-exact XML writer then reproduces the original file.
      final back = iniToXmlSeqFile(reparsed);
      expect(seqFileDeepEquals(file, back), isTrue, reason: '${f.path}: XML model must return deep-equal');
      expect(writeSeqFileXml(back), bytes, reason: '${f.path}: XML → INI → XML must be byte-exact');
      byteExact++;

      // Longer loops stabilize after the first hop.
      expect(iniDeepEquals(ini, xmlToIniSeqFile(back)), isTrue, reason: '${f.path}: XML → INI must be a fixpoint');
    }
    // ignore: avoid_print
    print('retention XML → INI → XML: byte-exact $byteExact/${xmlFiles.length}');
    expect(byteExact, _pinnedXmlSeqCount);
  });

  test('binary → XML/INI loops retain exactly the decoded surface, marked partial', () {
    final binFiles = byFormat[SeqFormat.binary] ?? const <File>[];
    expect(binFiles.length, _pinnedBinarySeqCount, reason: 'binary corpus count drifted');
    var surfaceExact = 0;
    var refused = 0;
    for (final f in binFiles) {
      final bytes = _read(f);
      SeqFile bin;
      try {
        bin = parseSeqFile(bytes);
      } on FormatException {
        // No inflatable body: the decoder refuses rather than fabricating.
        refused++;
        continue;
      }
      final xml = binaryToXmlSeqFile(bin);
      expect(
        xml.rootAttributes?[ConvKey.partialDecodeAttr],
        ConvKey.partialDecodeBinary,
        reason: '${f.path}: binary-derived output must be marked partial',
      );
      // Compare the lifted output's decoded surface against the SOURCE decode
      // directly (not just against its own reparse): a converter that dropped
      // or fabricated a node/scalar/type would diverge here even while staying
      // self-consistent through the write/reparse loops below.
      expect(_surface(xml.data), _surface(bin.data), reason: '${f.path}: lifted data surface must match the decode');
      expect(xml.types.length, bin.types.length, reason: '${f.path}: type count must match the decode');
      for (var i = 0; i < bin.types.length; i++) {
        expect(_surface(xml.types[i]), _surface(bin.types[i]), reason: '${f.path}: type[$i] surface must match');
      }
      final reparsed = parseSeqFile(writeSeqFileXml(xml));
      expect(seqFileDeepEquals(xml, reparsed), isTrue, reason: '${f.path}: lifted XML must reparse deep-equal');

      final ini = xmlToIniSeqFile(reparsed);
      final iniReparsed = parseIniSeqBytes(writeIniSeq(ini));
      expect(iniDeepEquals(ini, iniReparsed), isTrue, reason: '${f.path}: INI hop must reparse deep-equal');
      expect(
        seqFileDeepEquals(xml, iniToXmlSeqFile(iniReparsed)),
        isTrue,
        reason: '${f.path}: XML ↔ INI loop must retain the decoded surface',
      );
      surfaceExact++;
    }
    // ignore: avoid_print
    print(
      'retention binary → XML/INI: decoded-surface-exact $surfaceExact/${binFiles.length} '
      '($refused refused, no inflatable body)',
    );
    expect(surfaceExact, _pinnedBinarySeqCount, reason: 'every corpus binary currently inflates and converts');
    expect(refused, 0, reason: 'refused-binary count drifted');
  });
}

Uint8List _read(File f) => f.readAsBytesSync();

/// A structural fingerprint of a property's DECODED surface — the fields the
/// binary reader recovers, independent of the XML decoration [binaryToXmlSeqFile]
/// adds (synthesized tags, the `% → x-` directive rename, array `<value>`
/// bounds). Equal fingerprints mean the lift neither dropped nor fabricated
/// content. `%NUMFMT` is normalized because the lift promotes it from an
/// attribute to the dedicated [SeqProperty.numericFormat] field.
Object? _surface(SeqProperty p) => [
  p.name,
  p.className,
  p.typeName,
  p.scalar,
  p.numericFormat ?? p.attributes['%NUMFMT'],
  p.extData,
  [for (final c in p.subProps) _surface(c)],
  p.array == null ? null : [for (final e in p.array!) _surface(e)],
  p.elemProto == null ? null : _surface(p.elemProto!),
];
