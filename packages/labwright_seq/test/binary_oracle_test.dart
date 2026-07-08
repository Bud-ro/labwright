@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Rosetta-twin validation of the binary decoder: each `*_BIN.seq` is the same
/// sequence as its XML/python twin (`OutputVoltage_{BIN,XML}` is CONTENT-exact,
/// the others are toolchain twins), so everything the binary decodes must
/// equal what the XML parse materializes. Whole-corpus honesty sweeps live in
/// `binary_sweep_test.dart`.
///
/// Twin pairing is by shared prefix before the toolchain tag: the binary is
/// `<prefix>_labview_BIN.seq` or `<prefix>_BIN.seq`, the model twin
/// `<prefix>_python_XML.seq` / `<prefix>_XML.seq` / `<prefix>_python.seq`.
File? _twin(Directory dir, String binName) {
  final prefix = binName.replaceAll('_labview_BIN.seq', '').replaceAll('_BIN.seq', '');
  for (final suffix in ['_python_XML.seq', '_XML.seq', '_python.seq']) {
    final f = File('${dir.path}/$prefix$suffix');
    if (f.existsSync()) return f;
  }
  return null;
}

/// `<PropName ...><value>V</value>` occurrences grouped by property name.
Map<String, Set<String>> _xmlValues(String xml) {
  final out = <String, Set<String>>{};
  final re = RegExp(r'<([A-Za-z_][A-Za-z0-9_]*)\b[^>]*>\s*<value>([^<]*)</value>');
  for (final m in re.allMatches(xml)) {
    (out[m.group(1)!] ??= <String>{}).add(m.group(2)!.replaceAll('"', '').trim());
  }
  return out;
}

String _asXmlText(Object? value) {
  if (value is bool) return value ? 'true' : 'false';
  if (value is double) {
    return value == value.truncateToDouble() ? value.toInt().toString() : value.toString();
  }
  return (value ?? '').toString().replaceAll('"', '').trim();
}

Set<String> _xmlStepNames(SeqFile file) => {
  for (final seq in file.sequences)
    for (final step in seq.steps) step.name,
};

void main() {
  final rosetta = Directory('${corpusSeqDir.path}/rosetta');
  final oracleBinFile = File('${rosetta.path}/OutputVoltage_BIN.seq');
  final oracleXmlFile = File('${rosetta.path}/OutputVoltage_XML.seq');
  if (!oracleBinFile.existsSync() || !oracleXmlFile.existsSync()) {
    test('binary oracle (skipped: Rosetta corpus not fetched)', () {}, skip: true);
    return;
  }

  final binaries = rosetta.listSync().whereType<File>().where((f) => f.path.endsWith('_BIN.seq')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('every fetched binary has a model twin (else the twin validation is vacuous)', () {
    expect(binaries, isNotEmpty);
    final unpaired = [
      for (final bin in binaries)
        if (_twin(rosetta, bin.uri.pathSegments.last) == null) bin.uri.pathSegments.last,
    ];
    expect(unpaired, isEmpty, reason: 'binaries without a model twin');
  });

  test('rosetta-wide: every decoded surface of every binary matches its twin', () {
    var pairs = 0, headsCompared = 0, decodedBodies = 0, bodyExtents = 0;
    var anchors = 0, twinnedSequences = 0;

    // Compares a decoded binary field against its XML-twin subprop, recursing
    // into plain nested declarations (toolchain-stable). Override subsets and
    // typed references are compared shallowly here; the content-exact oracle
    // tests below pin them at full depth.
    void compareField(String path, BinaryTypeField got, SeqProperty want) {
      expect(got.name, want.name, reason: '$path field name');
      final intrinsic = got.typeNameEngineIntrinsic;
      expect(
        intrinsic ? got.className : got.typeName ?? got.className,
        intrinsic ? want.className : want.typeName ?? want.className,
        reason: '$path.${got.name}: class/type',
      );
      expect(got.value, want.scalar, reason: '$path.${got.name}: value');
      if (got.isPlainDeclaration) {
        expect(got.children.length, want.subProps.length, reason: '$path.${got.name}: child count');
        for (var i = 0; i < got.children.length; i++) {
          compareField('$path.${got.name}', got.children[i], want.subProps[i]);
        }
      }
    }

    int? boundCount(String? lb, String? ub) {
      if (lb == null || ub == null || ub == '[]') return null;
      List<int>? dims(String t) {
        final out = <int>[];
        for (final m in RegExp(r'\[(\d*)\]').allMatches(t)) {
          final v = int.tryParse(m.group(1)!);
          if (v == null) return null;
          out.add(v);
        }
        return out.isEmpty ? null : out;
      }

      final l = dims(lb), u = dims(ub);
      if (l == null || u == null || l.length != u.length) return null;
      var count = 1;
      for (var i = 0; i < l.length; i++) {
        count *= u[i] - l[i] + 1;
      }
      return count;
    }

    for (final bin in binaries) {
      final name = bin.uri.pathSegments.last;
      final bytes = Uint8List.fromList(bin.readAsBytesSync());
      final twin = _twin(rosetta, name)!;
      final twinFile = parseSeqFile(twin.readAsBytesSync());
      pairs++;

      // Sequence NAMES equal the twin's; step COUNTS match (only the
      // content-exact oracle has identical step NAMES — pinned below).
      expect(
        binarySequenceNames(bytes),
        twinFile.sequences.map((s) => s.name).toList(),
        reason: '$name: sequence names',
      );
      final stepNames = binaryStepNames(bytes);
      expect(stepNames, isNotEmpty, reason: name);
      expect(stepNames.length, _xmlStepNames(twinFile).length, reason: '$name: step count ($stepNames)');

      // Byte-coverage invariants and the per-file semantic floor.
      final cov = binaryByteCoverage(bytes)!;
      expect(
        cov.recordSemanticBytes + cov.recordStructuralBytes + cov.recordUndecodedBytes,
        cov.recordRegionBytes,
        reason: name,
      );
      expect(cov.recordSemanticRatio, greaterThanOrEqualTo(0.70), reason: '$name: semantic floor');

      // Aligned type-index base 0, and it must be a CORRECT alignment: every
      // decoded anchor field resolves to Expression under it (a give-up 0
      // would mis-resolve to a wrong record and surface here).
      expect(binaryTypeIndexBase(bytes), 0, reason: '$name must be aligned');

      // Type-record HEADS + BODIES against the twin's root typedefs; save
      // timestamps/version stamps legitimately differ between toolchains.
      final twinByName = {for (final t in twinFile.types) t.name: t};
      const saveDependent = {'timestamp', 'typeversion', 'typelastmodversion', 'typeminprodversion'};
      void anchorWalk(List<BinaryTypeField> fs) {
        for (final field in fs) {
          if ((field.name == 'DescriptionFormat' || field.name == 'DefaultNameFormat') && field.typeName != null) {
            anchors++;
            expect(field.typeName, 'Expression', reason: '$name ${field.name}');
          }
          anchorWalk(field.children);
        }
      }

      for (final record in binaryTypeRecords(bytes)) {
        anchorWalk(record.fields ?? const []);
        final expected = twinByName[record.name];
        if (expected == null) continue;
        headsCompared++;
        final fields = record.fields;
        if (fields != null && fields.isNotEmpty) {
          decodedBodies++;
          expect(fields.length, expected.subProps.length, reason: '$name ${record.name}: field count');
          for (var i = 0; i < fields.length; i++) {
            compareField('$name ${record.name}', fields[i], expected.subProps[i]);
          }
        }
        expect(record.className, expected.className, reason: '$name ${record.name}: classname');
        record.toAttributes().forEach((key, value) {
          if (saveDependent.contains(key)) return;
          expect(value, expected.attributes[key], reason: '$name ${record.name}: attribute $key');
        });
      }

      // Every typedef body decodes end-to-end (zero bailing bodies).
      for (final extent in binaryTypeBodyExtents(bytes)) {
        bodyExtents++;
        expect(extent.bail, isNull, reason: '$name ${extent.name} bails at ${extent.bail}');
      }

      // Sequence-record walk: all three group arrays decode, agree with the
      // independently scan-assembled step lists, and honor declared bounds.
      final outlines = binarySequenceOutlines(bytes);
      expect(outlines, hasLength(1), reason: name);
      final o = outlines.single;
      expect(o.groupArrays.map((g) => g.name).toList(), ['Main', 'Setup', 'Cleanup'], reason: name);
      for (final g in o.groupArrays) {
        expect(g.className, 'Objs', reason: '$name ${g.name}');
        final scanSteps = switch (g.name) {
          'Setup' => o.setup,
          'Main' => o.main,
          _ => o.cleanup,
        };
        expect(
          g.children.map((s) => '${s.name}:${s.typeName}').toList(),
          scanSteps.map((s) => '${s.name}:${s.typeName}').toList(),
          reason: '$name ${g.name}: walk elements vs scan steps',
        );
        final count = boundCount(g.arrayLBound, g.arrayUBound);
        if (count != null) {
          expect(g.children, hasLength(count), reason: '$name ${g.name}: bounds vs elements');
        }
      }

      // Typed-model sequences: locals/parameters (name:type), post-group
      // scalars, requirement links, and RTS children match the twin.
      final binFile = parseSeqFile(bytes);
      final xmlByName = {for (final s in twinFile.sequences) s.name: s};
      for (final bs in binFile.sequences) {
        final xs = xmlByName[bs.name];
        if (xs == null) continue;
        twinnedSequences++;
        expect(
          bs.locals.map((l) => '${l.name}:${l.type}').toList(),
          xs.locals.map((l) => '${l.name}:${l.type}').toList(),
          reason: '$name ${bs.name}: locals',
        );
        expect(
          bs.parameters.map((p) => '${p.name}:${p.type}').toList(),
          xs.parameters.map((p) => '${p.name}:${p.type}').toList(),
          reason: '$name ${bs.name}: parameters',
        );
        if (bs.recordsResults != null) {
          expect(bs.recordsResults, xs.recordsResults, reason: '$name ${bs.name}: recordsResults');
        }
        if (bs.failureActionCode != null) {
          expect(bs.failureActionCode, xs.failureActionCode, reason: '$name ${bs.name}: failureActionCode');
        }
        if (bs.raw.prop('Requirements') != null) {
          expect(bs.requirementLinks, xs.requirementLinks, reason: '$name ${bs.name}: requirementLinks');
        }
        if (bs.runtimeSettings != null) {
          expect(
            bs.raw.prop('RTS')?.subProps.map((p) => '${p.name}:${p.className}=${p.scalar}').toList(),
            xs.raw.prop('RTS')?.subProps.map((p) => '${p.name}:${p.className}=${p.scalar}').toList(),
            reason: '$name ${bs.name}: RTS children (name:class=value)',
          );
        }
      }
    }

    print(
      'rosetta: $pairs pairs · $headsCompared typedef heads · $decodedBodies bodies '
      '· $bodyExtents extents · $anchors anchors · $twinnedSequences twinned sequences',
    );
    expect(pairs, greaterThanOrEqualTo(5));
    expect(headsCompared, greaterThanOrEqualTo(100), reason: 'the twins carry hundreds of comparable typedefs');
    expect(decodedBodies, greaterThanOrEqualTo(90), reason: 'every twinned typedef body decodes at the current tier');
    expect(bodyExtents, greaterThanOrEqualTo(140), reason: 'rosetta typedef-record count drifted');
    expect(
      anchors,
      greaterThanOrEqualTo(6),
      reason: 'aligned anchor fields did not decode — base-0 resolution regressed',
    );
    expect(twinnedSequences, greaterThanOrEqualTo(5));
  });

  // ── Content-exact oracle: OutputVoltage_{BIN,XML} ──
  final binBytes = Uint8List.fromList(oracleBinFile.readAsBytesSync());
  final binFile = parseSeqFile(binBytes);
  final xmlFile = parseSeqFile(oracleXmlFile.readAsBytesSync());

  Step stepOf(SeqFile file, String name) => file.sequences.first.steps.firstWhere((step) => step.name == name);

  test('oracle: step NAMES (grouped, ordered) and per-step TYPES match exactly', () {
    expect(binaryStepNames(binBytes).toSet(), _xmlStepNames(xmlFile));
    expect(binFile.sequences.map((s) => s.name).toList(), xmlFile.sequences.map((s) => s.name).toList());
    for (var i = 0; i < xmlFile.sequences.length; i++) {
      final xs = xmlFile.sequences[i];
      final bs = binFile.sequences[i];
      for (final group in StepGroup.values) {
        expect(
          bs.stepsIn(group).map((s) => s.name).toList(),
          xs.stepsIn(group).map((s) => s.name).toList(),
          reason: '${xs.name}.${group.key} step names',
        );
        expect(
          bs.stepsIn(group).map((s) => s.type).toList(),
          xs.stepsIn(group).map((s) => s.type).toList(),
          reason: '${xs.name}.${group.key} step types',
        );
      }
    }
    expect(binFile.sequences.single.steps.map((s) => '${s.name}=${s.type}'), [
      'Update pin map=NI_UpdatePinMap',
      'Create and register NI-DCPower Sessions=Action',
      'Create and register NI-DMM Sessions=Action',
      'Output voltage test=NI_Measurement',
      'Destroy and unregister NI-DCPower sessions=Action',
      'Destroy and unregister NI-DMM sessions=Action',
    ]);
  });

  test('oracle: recovered types are honest — every name is a twin typedef/typename', () {
    // A raw substring check would let short fabricated tokens ride inside
    // longer attribute names, so match against the twin's type vocabulary.
    expect(binFile.types.length, 25);
    final xmlText = oracleXmlFile.readAsStringSync();
    final twinTypeNames = <String>{
      for (final m in RegExp(r"<([A-Za-z_][\w.\-]*)\b[^>]*\bisroottypedef='true'").allMatches(xmlText)) m.group(1)!,
      for (final m in RegExp(r"(?:typename|xsi:type)='([^']+)'").allMatches(xmlText)) m.group(1)!,
    };
    for (final type in binFile.types) {
      expect(twinTypeNames, contains(type.name), reason: '${type.name} is not a typedef or typename in the twin');
    }
    expect(binFile.types.map((t) => t.name), containsAll(['NI_Measurement', 'NI_UpdatePinMap', 'Action']));
  });

  test('oracle: typedef HEADS match the twin — classname and every attribute', () {
    final twinByName = {for (final t in xmlFile.types) t.name: t};
    var compared = 0;
    for (final type in binFile.types) {
      final twin = twinByName[type.name];
      if (twin == null) continue; // step-stored typedefs live off-typelist
      compared++;
      expect(type.className, twin.className, reason: '${type.name}: classname');
      type.attributes.forEach((key, value) {
        expect(value, twin.attributes[key], reason: '${type.name}: attribute $key');
      });
    }
    expect(compared, greaterThanOrEqualTo(20), reason: 'most recovered types are root typedefs in the twin');
  });

  test('oracle: typedef BODIES decode field-for-field or stay empty — no partial trees', () {
    final twinByName = {for (final t in xmlFile.types) t.name: t};
    var decoded = 0;
    void compare(String path, SeqProperty got, SeqProperty want) {
      expect(got.name, want.name, reason: '$path: name');
      expect(got.className, want.className, reason: '$path: classname');
      // Inline custom instances and intrinsically-typed arrays legitimately
      // carry no typename (engine-intrinsic types are not serialized).
      if (got.typeName != null ||
          (got.attributes[BinAttr.overrides] == null && got.attributes[BinAttr.intrinsic] == null)) {
        expect(got.typeName, want.typeName, reason: '$path: typename');
      }
      expect(got.scalar, want.scalar, reason: '$path: value');
      expect(got.array == null, want.array == null, reason: '$path: array-ness');
      // Anti-fabrication: a populated twin array must be MARKED undecoded,
      // never flattened to a decoded-empty array.
      if (want.array != null && want.array!.isNotEmpty) {
        expect(
          got.attributes[BinAttr.arrayUndecoded],
          isNotNull,
          reason: '$path: populated array must be marked undecoded, not shown empty',
        );
      }
      if (got.attributes[BinAttr.overrides] == 'true') {
        // An inline custom instance serializes ONLY its overrides — a subset
        // of the twin's materialized fields, matching where valued.
        final wantByName = {for (final w in want.subProps) w.name: w};
        for (final child in got.subProps) {
          final twinChild = wantByName[child.name];
          expect(twinChild, isNotNull, reason: '$path.${child.name}: override not in twin');
          if (child.scalar != null) {
            expect(child.scalar, twinChild!.scalar, reason: '$path.${child.name}: override value');
          }
        }
        expect(got.subProps.length, lessThanOrEqualTo(want.subProps.length), reason: '$path: overrides are a subset');
        return;
      }
      // Plain declarations recurse; typed default-instance REFERENCES carry
      // no children (the binary stores only the ref).
      if (got.subProps.isNotEmpty || (got.typeName == null && want.subProps.isNotEmpty)) {
        expect(got.subProps.length, want.subProps.length, reason: '$path: child count');
        for (var i = 0; i < got.subProps.length; i++) {
          compare('$path.${got.subProps[i].name}', got.subProps[i], want.subProps[i]);
        }
      }
    }

    for (final type in binFile.types) {
      if (type.subProps.isEmpty) continue;
      final twin = twinByName[type.name];
      if (twin == null) continue;
      decoded++;
      expect(type.subProps.length, twin.subProps.length, reason: '${type.name}: field count');
      for (var i = 0; i < type.subProps.length; i++) {
        compare('${type.name}.${twin.subProps[i].name}', type.subProps[i], twin.subProps[i]);
      }
    }
    expect(decoded, greaterThanOrEqualTo(15), reason: '18 oracle typedefs decode at the current tier');
  });

  test('oracle: sequence LOCALS/PARAMETERS and post-group subprops match the twin', () {
    for (var i = 0; i < xmlFile.sequences.length; i++) {
      final xs = xmlFile.sequences[i];
      final bs = binFile.sequences[i];
      expect(
        bs.locals.map((l) => '${l.name}:${l.type}').toList(),
        xs.locals.map((l) => '${l.name}:${l.type}').toList(),
        reason: '${xs.name}: locals (name:type)',
      );
      expect(
        bs.parameters.map((p) => '${p.name}:${p.type}').toList(),
        xs.parameters.map((p) => '${p.name}:${p.type}').toList(),
        reason: '${xs.name}: parameters (name:type)',
      );
      expect(bs.recordsResults, xs.recordsResults, reason: '${xs.name}: recordsResults');
      expect(bs.failureActionCode, xs.failureActionCode, reason: '${xs.name}: failureActionCode');
      expect(bs.requirementLinks, xs.requirementLinks, reason: '${xs.name}: requirementLinks');
      expect(bs.runtimeSettings != null, xs.runtimeSettings != null, reason: '${xs.name}: runtimeSettings presence');
      expect(
        bs.raw.prop('RTS')?.subProps.map((p) => '${p.name}:${p.className}=${p.scalar}').toList(),
        xs.raw.prop('RTS')?.subProps.map((p) => '${p.name}:${p.className}=${p.scalar}').toList(),
        reason: '${xs.name}: RTS children (name:class=value)',
      );
    }
    // Concretely: one implicit ResultList local, no parameters, results
    // recorded with failure action 2, and a 15-field RTS whose Priority and
    // entry-point expressions decode exactly.
    expect(binFile.sequences.single.locals.map((l) => l.name), ['ResultList']);
    expect(binFile.sequences.single.parameters, isEmpty);
    expect(binFile.sequences.single.recordsResults, isTrue);
    expect(binFile.sequences.single.failureActionCode, 2);
    expect(binFile.sequences.single.requirementLinks, isEmpty);
    final rts = binFile.sequences.single.raw.prop('RTS')!;
    expect(rts.subProps.length, 15);
    expect(rts.prop('Priority')?.scalar, '2953567917');
    expect(rts.prop('EPNameExpr')?.scalar, '"Unnamed Entry Point"');
  });

  test('oracle: per-step TS subprops are an override subset of the twin; unique Ids exact', () {
    for (var i = 0; i < xmlFile.sequences.length; i++) {
      final xSteps = xmlFile.sequences[i].steps;
      final bSteps = binFile.sequences[i].steps;
      for (var j = 0; j < bSteps.length; j++) {
        final decoded =
            bSteps[j].raw.prop('TS')?.subProps.where((p) => p.name != 'SData').toList() ?? const <SeqProperty>[];
        if (decoded.isEmpty) continue; // TS not decoded for this step: honest, not fabricated
        final twinByName = {
          for (final p in xSteps[j].raw.prop('TS')?.subProps ?? const <SeqProperty>[]) p.name: p,
        };
        for (final got in decoded) {
          final want = twinByName[got.name];
          expect(want, isNotNull, reason: '${bSteps[j].name}.TS.${got.name}: not in twin TS');
          if (got.scalar != null) {
            expect(got.scalar, want!.scalar, reason: '${bSteps[j].name}.TS.${got.name}: value');
          }
        }
      }
    }
    String? idOf(Step s) =>
        s.raw.prop('TS')?.subProps.firstWhere((p) => p.name == 'Id', orElse: () => SeqProperty(name: 'Id')).scalar;
    expect(
      {for (final s in binFile.sequences.single.steps) s.name: idOf(s)},
      {
        'Update pin map': 'ID#:oWmczOOU7hGhxWDjK76h1B',
        'Create and register NI-DCPower Sessions': 'ID#:PZz20+wm7hG/g0xEW1VriB',
        'Create and register NI-DMM Sessions': 'ID#:0U7o5ewm7hG/g0xEW1VriB',
        'Output voltage test': 'ID#:lSaDme0m7hG/g0xEW1VriB',
        'Destroy and unregister NI-DCPower sessions': 'ID#:HKlD0e0m7hG/g0xEW1VriB',
        'Destroy and unregister NI-DMM sessions': 'ID#:ZU8H3e0m7hG/g0xEW1VriB',
      },
    );
  });

  test('oracle: per-step MODULES match the twin (adapter, python module + function)', () {
    for (var i = 0; i < xmlFile.sequences.length; i++) {
      final xs = xmlFile.sequences[i].steps;
      final bs = binFile.sequences[i].steps;
      for (var j = 0; j < xs.length; j++) {
        expect(bs[j].module.adapter, xs[j].module.adapter, reason: '${xs[j].name}: adapter');
        expect(
          bs[j].module.pythonModulePath,
          xs[j].module.pythonModulePath,
          reason: '${xs[j].name}: python module path',
        );
        expect(bs[j].module.pythonFunction, xs[j].module.pythonFunction, reason: '${xs[j].name}: python function');
      }
    }
    expect(binFile.sequences.single.steps.map((s) => s.module.pythonFunction ?? '-'), [
      '-',
      'create_nidcpower_sessions',
      'create_nivisa_dmm_sessions',
      '-',
      'destroy_nidcpower_sessions',
      'destroy_nivisa_dmm_sessions',
    ]);
  });

  group('oracle: property records (old-format TOF1 grammar)', () {
    final records = binaryPropertyRecords(binBytes);
    final xmlValues = _xmlValues(oracleXmlFile.readAsStringSync());

    test('exact record counts, well-formed names/types, no framing false positives', () {
      expect(records.length, 37);
      expect(records.where((r) => r.value != null).length, 14);
      final printable = RegExp(r'^[\x20-\x7e]+$');
      for (final record in records) {
        expect(
          record.name,
          matches(printable),
          reason: 'garbage name at offset ${record.offset}: ${record.name.codeUnits}',
        );
        expect(record.typeName, matches(printable), reason: 'garbage type at offset ${record.offset}');
        final value = record.value;
        if (value is double) {
          expect(value.isFinite, isTrue, reason: 'non-finite Num for ${record.name} at ${record.offset}');
        }
      }
    });

    test('every decoded value matches the content-exact XML twin (membership)', () {
      // A flat scan cannot pin WHICH occurrence of a duplicated name it is,
      // so membership — not position — is the honest check.
      var checked = 0, confirmed = 0;
      final unmatched = <String>[];
      for (final record in records) {
        if (record.value == null) continue;
        final xmlForName = xmlValues[record.name];
        if (xmlForName == null) continue; // nested-only / absent name: not checkable here
        checked++;
        if (xmlForName.contains(_asXmlText(record.value))) {
          confirmed++;
        } else if (unmatched.length < 6) {
          unmatched.add('${record.name}=${_asXmlText(record.value)} not in {${xmlForName.join(', ')}}');
        }
      }
      expect(checked, greaterThanOrEqualTo(8), reason: 'the twin should share several checkable property names');
      expect(confirmed, checked, reason: 'unmatched: ${unmatched.join(' | ')}');
    });

    test('specific TestStand defaults decode exactly (incl. a non-round double)', () {
      Object? valueOf(String name) => records.where((r) => r.name == name && r.value != null).firstOrNull?.value;
      expect(valueOf('Priority'), 2953567917.0, reason: 'clean-bits heuristics would drop this non-round double');
      expect(valueOf('BatchSync'), 1.0);
      expect(valueOf('RecordResults'), isTrue);
      expect(valueOf('OptimizeNonReentrantCalls'), isTrue);
      expect(valueOf('EPNameExpr'), contains('Unnamed Entry Point'));
    });
  });

  group('oracle: populated array elements and step data subprops', () {
    test('measurement step: Measurement name + all 11 parameter elements match the twin', () {
      final binMeas = stepOf(binFile, 'Output voltage test').raw.prop('Measurement')!;
      final xmlMeas = stepOf(xmlFile, 'Output voltage test').raw.prop('Measurement')!;
      expect(binMeas.prop('Name')!.scalar, xmlMeas.prop('Name')!.scalar);
      final binParams = binMeas.prop('Parameters')!;
      final xmlParams = xmlMeas.prop('Parameters')!;
      expect(binParams.array!.length, xmlParams.array!.length);
      expect(binParams.array!.length, 11);
      for (var i = 0; i < xmlParams.array!.length; i++) {
        final binEl = binParams.array![i];
        final xmlEl = xmlParams.array![i];
        expect(binEl.typeName, xmlEl.typeName, reason: 'element $i typename');
        // The binary stores the element's SERIALIZED SUBSET (defaults are
        // omitted); every stored field must match the twin exactly.
        expect(binEl.subProps, isNotEmpty, reason: 'element $i decoded no fields');
        for (final field in binEl.subProps) {
          final twin = xmlEl.prop(field.name);
          expect(twin, isNotNull, reason: 'element $i field ${field.name} not in twin');
          if (field.scalar != null || twin!.scalar != null) {
            expect(field.scalar, twin!.scalar, reason: 'element $i field ${field.name}');
          }
        }
      }
    });

    test('i64 Num values decode through the typedef representation context', () {
      // Plain [0x2] Nums whose i64 encoding is implied by
      // NI_MeasurementParameter's typedef — an f64 read yields a denormal.
      final params = stepOf(binFile, 'Output voltage test').raw.prop('Measurement')!.prop('Parameters')!;
      expect(
        [for (final el in params.array!) el.prop('ID')!.scalar],
        ['1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '1'],
      );
    });

    test('populated EnumDefinition members decode with explicit representations', () {
      final params = stepOf(binFile, 'Output voltage test').raw.prop('Measurement')!.prop('Parameters')!;
      final enumParam = params.array!.firstWhere((el) => el.prop('Name')?.scalar == 'measurement_type');
      final members = enumParam.prop('EnumDefinition')!.array!;
      expect(members.map((m) => m.name).toList(), ['DC_VOLTS', 'AC_VOLTS']);
      // DC_VOLTS stores no value (inherits the 0 default); AC_VOLTS stores
      // the twin's Int64 1 with the explicit representation.
      expect(members[0].scalar, isNull);
      expect(members[1].scalar, '1');
      expect(members[1].valueAttributes['representation'], 'Int64');
    });

    test('update-pin-map step surfaces its PinMapPath data subprop', () {
      expect(
        stepOf(binFile, 'Update pin map').raw.prop('PinMapPath')?.scalar,
        stepOf(xmlFile, 'Update pin map').raw.prop('PinMapPath')!.scalar,
      );
    });

    test('NI_MeasurementParameter typedef (binary-only, cat-2 record) decodes with reprs', () {
      final record = binaryTypeRecords(binBytes).firstWhere((r) => r.name == 'NI_MeasurementParameter');
      expect(record.undecodedBody, isFalse);
      final fields = record.fields!;
      expect(fields.map((f) => f.name).toList(), [
        'MessageType',
        'Name',
        'ArgumentValue',
        'Direction',
        'Log',
        'Dimension',
        'Type',
        'ID',
        'TypeSpecialization',
      ]);
      // The 0x800 representation words the twin materializes as UInt64/Int64.
      expect(
        fields.firstWhere((f) => f.name == 'Dimension').numericRepresentation,
        BinaryNumericRepresentation.uint64.code,
      );
      expect(fields.firstWhere((f) => f.name == 'ID').numericRepresentation, BinaryNumericRepresentation.int64.code);
    });

    test('record-walk oracle: Main step element content matches the twin', () {
      BinaryTypeField? child(BinaryTypeField f, String name) => f.children.where((c) => c.name == name).firstOrNull;
      final main = binarySequenceOutlines(binBytes).single.groupArrays.firstWhere((g) => g.name == 'Main');
      final twinMain = xmlFile.sequences.firstWhere((s) => s.name == 'MainSequence').main;
      expect(main.children, hasLength(twinMain.length));
      final step = main.children.single;
      final twinStep = twinMain.single;
      expect(step.name, twinStep.name);
      expect(step.typeName, 'NI_Measurement');
      final ts = child(step, 'TS')!;
      expect(child(ts, 'Id')!.value, twinStep.raw.prop('TS')?.prop('Id')?.scalar);
      final measurement = child(step, 'Measurement')!;
      final twinMeasurement = twinStep.raw.prop('Measurement')!;
      expect(child(measurement, 'Name')!.value, twinMeasurement.prop('Name')?.scalar);
      final parameters = child(measurement, 'Parameters')!;
      final twinParameters = twinMeasurement.prop('Parameters')!.array!;
      expect(parameters.children, hasLength(twinParameters.length));
      for (var i = 0; i < twinParameters.length; i++) {
        for (final field in ['Name', 'Direction', 'Type', 'ID', 'TypeSpecialization']) {
          // Assert the field DECODED before comparing: a null-safe compare of
          // two absent values would pass vacuously.
          final got = child(parameters.children[i], field);
          expect(got, isNotNull, reason: 'parameter $i missing decoded field $field');
          expect(got!.value, twinParameters[i].prop(field)?.scalar, reason: 'parameter $i $field');
        }
      }
    });
  });

  test('oracle: byte-coverage tiers sum to the region, span map agrees, floors hold', () {
    final cov = binaryByteCoverage(binBytes)!;
    expect(cov.recordSemanticBytes + cov.recordStructuralBytes + cov.recordUndecodedBytes, cov.recordRegionBytes);
    expect(cov.recordRegionBytes + cov.poolBytes, cov.bodyBytes);
    final spanTotal = binaryUndecodedSpans(binBytes, max: 1 << 30).fold(0, (sum, s) => sum + (s.$2 - s.$1));
    expect(spanTotal, cov.recordUndecodedBytes);
    expect(cov.recordSemanticRatio, greaterThanOrEqualTo(0.70));
    expect(cov.recordAccountedRatio, greaterThanOrEqualTo(0.985));
  });

  test('cross-format substep oracle: binary NI_Wait Substeps match the XML typedef', () {
    // Two INDEPENDENT corpus files materialize the same engine-versioned
    // NI_Wait step type — one XML, one binary. The substep decode must
    // reproduce the XML side value-for-value (names, typenames, Ids, module
    // LibPath/Func bindings).
    final files = corpusSeqDir.listSync(recursive: true).whereType<File>().toList();
    File? pin(String suffix) => files.where((f) => f.path.replaceAll(r'\', '/').endsWith(suffix)).firstOrNull;
    final xmlPin = pin('Server/ExampleFiles/TraceExecution.seq');
    final binPin = pin('Tests/Sequence File 1.seq');
    expect(xmlPin, isNotNull, reason: 'substep oracle XML pin missing — rename/partial checkout?');
    expect(binPin, isNotNull, reason: 'substep oracle binary pin missing — rename/partial checkout?');

    final xmlWait = parseSeqFile(xmlPin!.readAsBytesSync()).types.where((t) => t.name == 'NI_Wait').first;
    final xmlSubsteps = xmlWait.prop('Substeps')!.array!;
    // Value-less slots are dropped: the XML side materializes every member,
    // the binary stores the override subset — only set values exist on both.
    List<String> xmlPairs(SeqProperty p) => [
      if (const {'Id', 'LibPath', 'Func'}.contains(p.name) && (p.scalar ?? '').isNotEmpty) '${p.name}=${p.scalar}',
      for (final c in p.subProps.followedBy(p.array ?? const <SeqProperty>[])) ...xmlPairs(c),
    ];

    final binWait = binaryTypeRecords(binPin!.readAsBytesSync()).where((r) => r.name == 'NI_Wait').first;
    final binSubsteps = binWait.fields!.where((f) => f.name == 'Substeps').first.children;
    List<String> binPairs(BinaryTypeField f) => [
      if (const {'Id', 'LibPath', 'Func'}.contains(f.name) && (f.value ?? '').isNotEmpty) '${f.name}=${f.value}',
      for (final c in f.children) ...binPairs(c),
    ];

    expect(
      [for (final s in binSubsteps) '${s.name}:${s.typeName}'],
      [for (final s in xmlSubsteps) '${s.name}:${s.typeName}'],
      reason: 'substep names/types differ across the two encodings',
    );
    for (var i = 0; i < binSubsteps.length; i++) {
      expect(
        binPairs(binSubsteps[i]),
        xmlPairs(xmlSubsteps[i]),
        reason: 'substep ${binSubsteps[i].name}: Id/LibPath/Func values',
      );
    }
    expect(binSubsteps, hasLength(3)); // OnNewStep, Post, Edit
  });
}
