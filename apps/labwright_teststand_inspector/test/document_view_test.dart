import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_teststand/labwright_teststand.dart';
import 'package:labwright_teststand_inspector/src/document_view.dart';
import 'package:labwright_teststand_inspector/src/property_outline.dart';
import 'package:labwright_teststand_inspector/src/recent_files.dart';
import 'package:labwright_teststand_inspector/src/sequence_outline.dart';

Uint8List _xml() => Uint8List.fromList([
  0xef,
  0xbb,
  0xbf,
  ...utf8.encode(
    "<?xml version='1.0'?>\n"
    "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
    "<typelist/><Data classname='Obj'><subprops>"
    "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Sequence name='MainSequence' classname='Obj'><subprops>"
    "<Main classname='Objs'><value lbound='[0]' ubound='[1]'>"
    "<value><Step typename='Statement' name='S1'/></value></value></Main>"
    "</subprops></Sequence></value></value></Seq></subprops></Data>"
    "</teststandfileheader>",
  ),
]);

Uint8List _xmlWithLimits() => Uint8List.fromList([
  0xef,
  0xbb,
  0xbf,
  ...utf8.encode(
    "<?xml version='1.0'?>\n"
    "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
    "<typelist/><Data classname='Obj'><subprops>"
    "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Sequence name='MainSequence' classname='Obj'><subprops>"
    "<Main classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Step typename='NumericLimitTest' name='Check V'><subprops>"
    "<Comp><value>GELE</value></Comp>"
    "<Limits classname='Obj'><subprops>"
    "<Low><value>9</value></Low><High><value>11</value></High>"
    "</subprops></Limits>"
    "<DataSource><value>Locals.V</value></DataSource>"
    "</subprops></Step>"
    "</value></value></Main>"
    "</subprops></Sequence></value></value></Seq></subprops></Data>"
    "</teststandfileheader>",
  ),
]);

Uint8List _xmlWithSkip() => Uint8List.fromList([
  0xef,
  0xbb,
  0xbf,
  ...utf8.encode(
    "<?xml version='1.0'?>\n"
    "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
    "<typelist/><Data classname='Obj'><subprops>"
    "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Sequence name='MainSequence' classname='Obj'><subprops>"
    "<Main classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Step typename='Statement' name='Skipped'><subprops>"
    "<TS classname='Obj'><subprops>"
    "<Mode><value>Skip</value></Mode>"
    "</subprops></TS>"
    "</subprops></Step>"
    "</value></value></Main>"
    "</subprops></Sequence></value></value></Seq></subprops></Data>"
    "</teststandfileheader>",
  ),
]);

Uint8List _xmlWithStatusExpr() => Uint8List.fromList([
  0xef,
  0xbb,
  0xbf,
  ...utf8.encode(
    "<?xml version='1.0'?>\n"
    "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
    "<typelist/><Data classname='Obj'><subprops>"
    "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Sequence name='MainSequence' classname='Obj'><subprops>"
    "<Main classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Step typename='Statement' name='Decide'><subprops>"
    "<TS classname='Obj'><subprops>"
    "<StatusExpr><value>Locals.x == 1</value></StatusExpr>"
    "</subprops></TS>"
    "</subprops></Step>"
    "</value></value></Main>"
    "</subprops></Sequence></value></value></Seq></subprops></Data>"
    "</teststandfileheader>",
  ),
]);

Uint8List _binary() {
  final pool = <int>[];
  for (final n in [
    'PaddingNameSoTheInflatedBodyExceedsTheSixtyFourByteGuardHere',
    'SequenceFileData',
    'MainSequence',
    'Step',
    'Locals',
    'Parameters',
  ]) {
    pool
      ..addAll(ascii.encode(n))
      ..add(0);
  }
  final header = Uint8List(0x108);
  header.setAll(0, ascii.encode('TOF1'));
  header.setAll(0x0a, ascii.encode('SequenceFile'));
  header.setAll(0x40, ascii.encode('TestStand'));
  final b = BytesBuilder()
    ..add(header)
    ..add(zlib.encode(pool));
  return Uint8List.fromList(b.toBytes());
}

void main() {
  test('documentText/Title render an XML document', () {
    final doc = SeqDocument.parse(_xml());
    expect(doc, isA<XmlSeqDocument>());
    expect(documentTitle(doc), contains('1 sequences'));
    expect(documentTitle(doc), contains('xml'));
    final text = documentText(doc);
    expect(text, contains('MainSequence'));
    expect(text, contains('S1'));
  });

  test('documentText/Title render a legacy INI document', () {
    final ini = ascii.encode([
      '[__Header__]',
      'ProductName = "TestStand"',
      'Version = 354',
      'Type = "SequenceFile"',
      '[DEF, %OBJROOT]',
      'SF = SequenceFileData',
      '[DEF, SF]',
      'Seq = Objs',
      '%NAME = "Data"',
      '[DEF, SF.Seq]',
      '%[0] = Sequence',
      '[DEF, SF.Seq[0]]',
      'Main = Objs',
      '%NAME = "MainSequence"',
      '[DEF, SF.Seq[0].Main]',
      '%[0] = Step',
      '%TYPE: %[0] = "Action"',
      '[DEF, SF.Seq[0].Main[0]]',
      '%NAME = "iniStep"',
      '',
    ].join('\n'));
    final doc = SeqDocument.parse(Uint8List.fromList(ini));
    expect(doc, isA<IniSeqDocument>());
    expect(documentTitle(doc), contains('1 sequences'));
    expect(documentTitle(doc), contains('ini'));
    final text = documentText(doc);
    expect(text, contains('MainSequence'));
    expect(text, contains('iniStep'));
    // The structured outline shapes the INI doc just like XML.
    final outline = SeqOutline.of((doc as IniSeqDocument).file);
    expect(outline.sequences.single.name, 'MainSequence');
  });

  test('SeqOutline.of shapes sequences → groups → steps', () {
    final doc = SeqDocument.parse(_xml()) as XmlSeqDocument;
    final outline = SeqOutline.of(doc.file);

    expect(outline.sequences, hasLength(1));
    expect(outline.indexOf('MainSequence'), 0);
    expect(outline.indexOf('NoSuchSequence'), isNull);

    final seq = outline.sequences.single;
    expect(seq.name, 'MainSequence');
    expect(seq.stepCount, 1);
    expect(seq.groups.map((g) => g.name), ['Main']);

    final step = seq.groups.single.steps.single;
    expect(step.name, 'S1');
    expect(step.type, 'Statement');
    expect(step.isInFileCall, isFalse);
    expect(step.summary, contains('S1 [Statement]'));
  });

  test('addRecent moves to front, dedups, caps, and is non-mutating', () {
    expect(addRecent(const [], 'a'), ['a']);

    // New entry goes to the front.
    expect(addRecent(const ['a', 'b'], 'c'), ['c', 'a', 'b']);

    // Re-adding an existing entry moves it to the front (dedup, no growth).
    expect(addRecent(const ['a', 'b', 'c'], 'c'), ['c', 'a', 'b']);

    // Cap is respected (oldest dropped).
    expect(addRecent(const ['a', 'b', 'c'], 'd', cap: 3), ['d', 'a', 'b']);

    // Input is not mutated.
    final input = ['a', 'b'];
    final out = addRecent(input, 'x');
    expect(input, ['a', 'b']);
    expect(out, ['x', 'a', 'b']);
  });

  test(
    'StepOutline.of populates structured limits, omitting absent fields',
    () {
      final doc = SeqDocument.parse(_xmlWithLimits()) as XmlSeqDocument;
      final outline = SeqOutline.of(doc.file);
      final step = outline.sequences.single.groups.single.steps.single;

      expect(step.name, 'Check V');
      expect(step.limits, isNotNull); // summary string still present
      final d = step.limitsDetail;
      expect(d, isNotNull);
      expect(d!.comparison, 'GELE');
      expect(d.low, '9');
      expect(d.high, '11');
      expect(d.dataSource, 'Locals.V');
      // Absent fields stay null (not invented) and are dropped from rows.
      expect(d.nominal, isNull);
      expect(d.thresholdType, isNull);
      final rowLabels = d.rows.map((r) => r.$1);
      expect(
        rowLabels,
        containsAll(['Comparison', 'Low', 'High', 'Data source']),
      );
      expect(rowLabels, isNot(contains('Nominal')));
    },
  );

  test('StepOutline.of surfaces a forced run mode (Skip) as runMode', () {
    final doc = SeqDocument.parse(_xmlWithSkip()) as XmlSeqDocument;
    final step = SeqOutline.of(doc.file).sequences.single.groups.single.steps.single;
    expect(step.name, 'Skipped');
    expect(step.runMode, 'Skip');
    // It is also reflected in the one-line summary and is searchable.
    expect(step.summary, contains('{mode Skip}'));
    expect(stepMatches(step, 'skip'), isTrue);
  });

  test('StepOutline.of surfaces a step status expression', () {
    final doc = SeqDocument.parse(_xmlWithStatusExpr()) as XmlSeqDocument;
    final step = SeqOutline.of(doc.file).sequences.single.groups.single.steps.single;
    expect(step.name, 'Decide');
    expect(step.expressions, contains(('Status', 'Locals.x == 1')));
    // It is searchable and reflected in the one-line summary.
    expect(stepMatches(step, 'locals.x'), isTrue);
    expect(step.summary, contains('Status: Locals.x == 1'));
  });

  test('a Normal-mode step has no runMode (default is not noteworthy)', () {
    final doc = SeqDocument.parse(_xml()) as XmlSeqDocument;
    final step = SeqOutline.of(doc.file).sequences.single.groups.single.steps.single;
    expect(step.runMode, isNull);
    expect(step.summary, isNot(contains('mode')));
  });

  test('outlineSummary/totalSteps count sequences and steps (pluralized)', () {
    final doc = SeqDocument.parse(_xml()) as XmlSeqDocument;
    final outline = SeqOutline.of(doc.file);

    expect(outline.totalSteps, 1);
    // Fixture has 1 sequence / 1 step → singular forms.
    expect(outlineSummary(outline), '1 sequence · 1 step');
    // With a type count appended.
    expect(
      outlineSummary(outline, typeCount: 5),
      '1 sequence · 1 step · 5 types',
    );
  });

  test('pathBasename handles / and \\ separators and edge cases', () {
    expect(pathBasename(r'C:\a\b\Foo.vi'), 'Foo.vi');
    expect(pathBasename('/x/y/Bar.seq'), 'Bar.seq');
    expect(pathBasename('bare'), 'bare');
    expect(pathBasename(''), '');
    // Mixed separators: the last separator of either kind wins.
    expect(pathBasename(r'/x\y/z\End.seq'), 'End.seq');
    // Trailing separator → empty (callers add their own fallback).
    expect(pathBasename('/x/y/'), '');
  });

  test('StepOutline.targetDisplay shows basename + full-path tooltip', () {
    ({String label, String tooltip})? disp(String? target) => StepOutline(
      name: 'x',
      type: 'y',
      adapter: target == null ? null : 'labView',
      target: target,
      notes: const [],
    ).targetDisplay;

    expect(disp(r'C:\a\b\Foo.vi'), (
      label: 'Foo.vi',
      tooltip: r'C:\a\b\Foo.vi',
    ));
    expect(disp('/x/y/Bar.vi'), (label: 'Bar.vi', tooltip: '/x/y/Bar.vi'));
    // A bare (non-path) target is shown verbatim.
    expect(disp('MySequence'), (label: 'MySequence', tooltip: 'MySequence'));
    // No target → no display.
    expect(disp(null), isNull);
  });

  test('VarOutline.label shows scalar value or container size', () {
    // Scalar with a default value.
    expect(VarOutline(name: 'Count', type: 'Num', value: '3').label,
        'Count : Num = 3');
    // Array container → element count in brackets.
    expect(
      VarOutline(name: 'List', type: 'Objs', isArray: true, containerCount: 0)
          .label,
      'List : Objs [0]',
    );
    // Object/cluster container → field count (singular vs plural).
    expect(
      VarOutline(name: 'Limits', type: 'Obj', containerCount: 2).label,
      'Limits : Obj {2 fields}',
    );
    expect(
      VarOutline(name: 'One', type: 'Obj', containerCount: 1).label,
      'One : Obj {1 field}',
    );
    // Bare scalar with neither value nor container info.
    expect(VarOutline(name: 'X', type: 'Str').label, 'X : Str');
  });

  test('filterSequences keeps matches; empty query is identity', () {
    final doc = SeqDocument.parse(_xml()) as XmlSeqDocument;
    final outline = SeqOutline.of(doc.file);

    // Empty/blank query returns the same instance.
    expect(filterSequences(outline, ''), same(outline));
    expect(filterSequences(outline, '   '), same(outline));

    // A query matching the step 'S1' keeps its sequence (with the step).
    final byStep = filterSequences(outline, 's1');
    expect(byStep.sequences, hasLength(1));
    final seq = byStep.sequences.single;
    expect(seq.name, 'MainSequence');
    expect(
      seq.groups.expand((g) => g.steps).map((s) => s.name),
      contains('S1'),
    );

    // A query matching the sequence name keeps the whole sequence.
    final byName = filterSequences(outline, 'mainseq');
    expect(byName.sequences.single.name, 'MainSequence');

    // A non-matching query yields no sequences.
    expect(filterSequences(outline, 'zzz-nope').sequences, isEmpty);
  });

  test('propertyTree shapes the raw PropertyObject tree', () {
    final doc = SeqDocument.parse(_xml()) as XmlSeqDocument;
    final root = propertyTree(doc.file);

    // Root is the Data object; class Obj; has children (not a leaf).
    expect(root.name, 'Data');
    expect(root.className, 'Obj');
    expect(root.isLeaf, isFalse);
    expect(root.typeLabel, contains('Obj'));

    // Walk Data → Seq (Objs array) → its single element is the Sequence object
    // itself (name taken from the name= attribute).
    final seqContainer = root.children.firstWhere((c) => c.name == 'Seq');
    expect(seqContainer.isArray, isTrue);
    expect(seqContainer.typeLabel, contains('Objs['));
    final mainSeq = seqContainer.children.single;
    expect(mainSeq.name, 'MainSequence');
    expect(mainSeq.attributes['name'], 'MainSequence');
  });

  test('PropertyNode surfaces %INSTOVRD as isInstanceOverride', () {
    final overridden = PropertyNode.of(
      SeqProperty(name: 'TS', attributes: const {'%INSTOVRD': '5046297'}),
    );
    expect(overridden.isInstanceOverride, isTrue);
    // The raw flags stay visible in the attributes map (nothing hidden).
    expect(overridden.attributes['%INSTOVRD'], '5046297');

    final plain = PropertyNode.of(SeqProperty(name: 'Mode', scalar: 'Normal'));
    expect(plain.isInstanceOverride, isFalse);
  });

  test('filterTree keeps matches with ancestors; empty query is identity', () {
    final doc = SeqDocument.parse(_xml()) as XmlSeqDocument;
    final root = propertyTree(doc.file);

    // Empty query returns the tree unchanged (same instance).
    expect(filterTree(root, ''), same(root));
    expect(filterTree(root, '   '), same(root));

    // A query hitting the deep Step (name 'S1') keeps the ancestor chain.
    final f = filterTree(root, 'S1');
    expect(f, isNotNull);
    expect(f!.name, 'Data');
    final seq = f.children.firstWhere((c) => c.name == 'Seq');
    final mainSeq = seq.children.single; // MainSequence kept as an ancestor
    expect(mainSeq.name, 'MainSequence');
    // The matching leaf is reachable somewhere under MainSequence.
    bool hasStep(PropertyNode n) => n.name == 'S1' || n.children.any(hasStep);
    expect(hasStep(mainSeq), isTrue);

    // A query matching nothing prunes the whole tree to null.
    expect(filterTree(root, 'zzz-no-such-token'), isNull);
  });

  test('coverageLabel formats the modeled/total ratio', () {
    final doc = SeqDocument.parse(_xml()) as XmlSeqDocument;
    final c = measureCoverage(doc.file);
    final label = coverageLabel(c);
    expect(label, startsWith('model coverage '));
    expect(label, contains('${c.modeled}/${c.total}'));
    expect(label, matches(RegExp(r'\d+\.\d%')));
    // The fixture's typed lens recovers something but not everything.
    expect(c.modeled, greaterThan(0));
    expect(c.modeled, lessThanOrEqualTo(c.total));
  });

  test('binaryHeaderRows surfaces recon facts for a TOF1 file', () {
    final doc = SeqDocument.parse(_binary());
    expect(doc, isA<BinarySeqDocument>());
    final rows = binaryHeaderRows(doc as BinarySeqDocument);
    final map = {for (final (k, v) in rows) k: v};

    expect(map['Encoding'], 'binary');
    expect(map['File type'], 'SequenceFile');
    expect(map['Product'], 'TestStand');
    expect(map['Inflated body'], endsWith('bytes'));
    expect(int.parse(map['Strings recovered']!), greaterThan(0));
    // The framed-body layout rows are surfaced when the body frames.
    expect(map.containsKey('Record region'), isTrue);
    expect(map.containsKey('Record sentinels'), isTrue);
    expect(int.parse(map['Strings in region']!), greaterThanOrEqualTo(5));
    // The content-identified property-name table is surfaced.
    expect(map['Property-name table'], endsWith('entries'));
    expect(
      int.parse(map['Property-name table']!.split(' ').first),
      greaterThan(0),
    );
  });

  test('documentText lists recovered property names for a TOF1 file', () {
    final doc = SeqDocument.parse(_binary());
    final text = documentText(doc);
    expect(text, contains('recovered property names'));
    // The fixture pool's model names are surfaced as recovered names.
    for (final n in ['MainSequence', 'Step', 'Locals', 'Parameters']) {
      expect(text, contains(n), reason: 'missing recovered name $n');
    }
    // Honest framing: it must not claim the tree/values are decoded.
    expect(text, contains('record tree not yet decoded'));
  });

  test('writeCapped lists up to the cap, then an honest "and N more"', () {
    // Under the cap: every item listed, no summary line.
    final small = StringBuffer();
    writeCapped(small, ['a', 'b', 'c'], (s) => s);
    expect(small.toString(), '  a\n  b\n  c\n');
    expect(small.toString(), isNot(contains('more')));

    // Over the cap: exactly maxListedEntries listed + a truthful remainder line.
    final big = StringBuffer();
    final items = [for (var i = 0; i < maxListedEntries + 7; i++) 'n$i'];
    writeCapped(big, items, (s) => s);
    final lines = big.toString().trimRight().split('\n');
    expect(lines, hasLength(maxListedEntries + 1));
    expect(lines.first, '  n0');
    expect(lines[maxListedEntries - 1], '  n${maxListedEntries - 1}');
    expect(lines.last, '  … and 7 more');
  });

  test('documentText/Title handle unrecognized bytes without throwing', () {
    final doc = SeqDocument.parse(Uint8List.fromList([1, 2, 3, 4]));
    expect(doc, isA<UnknownSeqDocument>());
    expect(documentTitle(doc), contains('unrecognized'));
    expect(documentText(doc), contains('Not a recognized TestStand sequence.'));
  });
}
