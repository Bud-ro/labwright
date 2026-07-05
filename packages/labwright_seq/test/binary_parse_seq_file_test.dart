@Tags(['corpus'])
library;

import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// End-to-end oracle test for the binary → typed-model path: [parseSeqFile] on
/// the content-exact `OutputVoltage_BIN.seq` must reconstruct the same sequence
/// with the same grouped, ordered step names as its XML twin. Skips when the
/// corpus is not fetched.
void main() {
  final rosetta = Directory('${corpusSeqDir.path}/rosetta');
  final bin = File('${rosetta.path}/OutputVoltage_BIN.seq');
  final xml = File('${rosetta.path}/OutputVoltage_XML.seq');
  if (!bin.existsSync() || !xml.existsSync()) {
    test('binary parseSeqFile (skipped: Rosetta corpus not fetched)', () {},
        skip: true);
    return;
  }

  final binFile = parseSeqFile(bin.readAsBytesSync());
  final xmlFile = parseSeqFile(xml.readAsBytesSync());

  test('binary parses to the same sequences as the content-exact XML twin', () {
    expect(binFile.sequences.map((s) => s.name).toList(),
        xmlFile.sequences.map((s) => s.name).toList());
  });

  test('grouped, ordered step names match the XML twin exactly', () {
    for (var i = 0; i < xmlFile.sequences.length; i++) {
      final xs = xmlFile.sequences[i];
      final bs = binFile.sequences[i];
      expect(bs.setup.map((s) => s.name).toList(),
          xs.setup.map((s) => s.name).toList(),
          reason: '${xs.name}.Setup');
      expect(bs.main.map((s) => s.name).toList(),
          xs.main.map((s) => s.name).toList(),
          reason: '${xs.name}.Main');
      expect(bs.cleanup.map((s) => s.name).toList(),
          xs.cleanup.map((s) => s.name).toList(),
          reason: '${xs.name}.Cleanup');
    }
  });

  test('the partial model is honest: undecoded lenses read empty, not fabricated', () {
    // Types carry recovered NAMES (25 on the oracle: root typedefs + the
    // step/parameter types) with empty bodies — the typedef contents are not
    // yet decoded. Every recovered name must appear in the XML twin AS A TYPE
    // (a root typedef element or a typename/xsi:type reference) — a raw
    // substring check would let short fabricated tokens ride inside longer
    // attribute names.
    expect(binFile.types.length, 25);
    final xmlText = xml.readAsStringSync();
    final twinTypeNames = <String>{
      for (final m in RegExp(r"<([A-Za-z_][\w.\-]*)\b[^>]*\bisroottypedef='true'")
          .allMatches(xmlText))
        m.group(1)!,
      for (final m
          in RegExp(r"(?:typename|xsi:type)='([^']+)'").allMatches(xmlText))
        m.group(1)!,
    };
    for (final type in binFile.types) {
      expect(twinTypeNames, contains(type.name),
          reason: 'recovered type ${type.name} is not a typedef or typename '
              'in the XML twin');
      expect(type.subProps, isEmpty,
          reason: 'typedef bodies are not decoded — must not be fabricated');
    }
    expect(binFile.types.map((t) => t.name),
        containsAll(['NI_Measurement', 'NI_UpdatePinMap', 'Action']),
        reason: 'the step types used by this file must be among the names');
    for (final seq in binFile.sequences) {
      expect(seq.locals, isEmpty, reason: 'locals are not yet decoded from binary');
      expect(seq.parameters, isEmpty);
    }
  });

  test('per-step TYPES match the twin exactly (the type-index binding)', () {
    // The step reference's second word is the 1-based type-table index —
    // differential-sweep discovered, and pinned here against the
    // content-exact twin: every step's bound type equals the XML's
    // `<Step typename='...'>`, position by position.
    for (var i = 0; i < xmlFile.sequences.length; i++) {
      final xs = xmlFile.sequences[i];
      final bs = binFile.sequences[i];
      for (final group in StepGroup.values) {
        final xSteps = xs.stepsIn(group);
        final bSteps = bs.stepsIn(group);
        expect(bSteps.map((s) => s.type).toList(),
            xSteps.map((s) => s.type).toList(),
            reason: '${xs.name}.${group.key} step types');
      }
    }
    // And concretely, the oracle's six steps:
    expect(binFile.sequences.single.steps.map((s) => '${s.name}=${s.type}'), [
      'Update pin map=NI_UpdatePinMap',
      'Create and register NI-DCPower Sessions=Action',
      'Create and register NI-DMM Sessions=Action',
      'Output voltage test=NI_Measurement',
      'Destroy and unregister NI-DCPower sessions=Action',
      'Destroy and unregister NI-DMM sessions=Action',
    ]);
  });

  test('typedef HEADS match the twin: classname and every attribute', () {
    // The type-record head decodes the same attributes the XML typedef
    // element carries: classname, typecategory, timestamp, the version
    // triple, and the ordered flags (typeflags / flagsforinstances /
    // instanceoverrideflags / valueflags). Every emitted value must EQUAL
    // the twin's — attribute for attribute.
    final twinByName = {for (final t in xmlFile.types) t.name: t};
    var compared = 0;
    for (final type in binFile.types) {
      final twin = twinByName[type.name];
      if (twin == null) continue; // step-stored typedefs live off-typelist
      compared++;
      expect(type.className, twin.className,
          reason: '${type.name}: classname');
      type.attributes.forEach((key, value) {
        expect(value, twin.attributes[key],
            reason: '${type.name}: attribute $key');
      });
    }
    expect(compared, greaterThanOrEqualTo(20),
        reason: 'most recovered types are root typedefs in the twin');
  });

  test('per-step MODULES match the twin (the name→value pair binding)', () {
    // The module payload serializes fields as [nameIdx][valueIdx] word
    // pairs inside the step's span — adapter, module path, and function
    // must equal the XML twin's for every step (module-less steps
    // included: nothing may be fabricated for them).
    for (var i = 0; i < xmlFile.sequences.length; i++) {
      final xs = xmlFile.sequences[i].steps;
      final bs = binFile.sequences[i].steps;
      for (var j = 0; j < xs.length; j++) {
        final xm = xs[j].module;
        final bm = bs[j].module;
        expect(bm.adapter, xm.adapter,
            reason: '${xs[j].name}: adapter');
        expect(bm.pythonModulePath, xm.pythonModulePath,
            reason: '${xs[j].name}: python module path');
        expect(bm.pythonFunction, xm.pythonFunction,
            reason: '${xs[j].name}: python function');
      }
    }
    // Concretely: four Python calls, two module-less steps.
    expect(
        binFile.sequences.single.steps
            .map((s) => s.module.pythonFunction ?? '-'),
        [
          '-',
          'create_nidcpower_sessions',
          'create_nivisa_dmm_sessions',
          '-',
          'destroy_nidcpower_sessions',
          'destroy_nivisa_dmm_sessions',
        ]);
  });
}
