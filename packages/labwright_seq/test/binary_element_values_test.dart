@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Oracle tests for the populated-array ELEMENT decode and the step-level
/// data subprops (`Measurement` / `PinMapPath`) — validated value-for-value
/// against the content-exact `OutputVoltage_XML.seq` twin — plus the
/// numeric-representation (0x800) decode and a whole-corpus fabrication
/// sweep. Skips when the corpus is not fetched.
void main() {
  final rosetta = Directory('${corpusSeqDir.path}/rosetta');
  final bin = File('${rosetta.path}/OutputVoltage_BIN.seq');
  final xml = File('${rosetta.path}/OutputVoltage_XML.seq');
  if (!bin.existsSync() || !xml.existsSync()) {
    test('binary element values (skipped: Rosetta corpus not fetched)', () {}, skip: true);
    return;
  }

  final binBytes = Uint8List.fromList(bin.readAsBytesSync());
  final binFile = parseSeqFile(binBytes);
  final xmlFile = parseSeqFile(xml.readAsBytesSync());

  Step stepOf(SeqFile file, String name) => file.sequences.first.steps.firstWhere((step) => step.name == name);

  test('measurement step Measurement name + all 11 parameter elements match the twin', () {
    final binMeas = stepOf(binFile, 'Output voltage test').raw.prop('Measurement');
    final xmlMeas = stepOf(xmlFile, 'Output voltage test').raw.prop('Measurement');
    expect(binMeas, isNotNull);
    expect(binMeas!.prop('Name')!.scalar, xmlMeas!.prop('Name')!.scalar);

    final binParams = binMeas.prop('Parameters')!;
    final xmlParams = xmlMeas.prop('Parameters')!;
    expect(binParams.array!.length, xmlParams.array!.length);
    expect(binParams.array!.length, 11);
    for (var i = 0; i < xmlParams.array!.length; i++) {
      final binEl = binParams.array![i];
      final xmlEl = xmlParams.array![i];
      expect(binEl.typeName, xmlEl.typeName, reason: 'element $i typename');
      // The binary stores the element's SERIALIZED SUBSET (defaults such as
      // MessageType ''/Dimension 0 are omitted); every stored field must
      // match the twin's materialized value exactly.
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
    // The parameter IDs are stored as plain [0x2] Nums whose i64 encoding is
    // implied by NI_MeasurementParameter's typedef (an f64 read yields a
    // denormal, not these integers) — the hard oracle for the repr context.
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
    // DC_VOLTS stores no value (inherits the 0 default inside the instance);
    // AC_VOLTS stores the twin's Int64 1 with the explicit representation.
    expect(members[0].scalar, isNull);
    expect(members[1].scalar, '1');
    expect(members[1].valueAttributes['representation'], 'Int64');
  });

  test('update-pin-map step surfaces its PinMapPath data subprop', () {
    final binPath = stepOf(binFile, 'Update pin map').raw.prop('PinMapPath');
    final xmlPath = stepOf(xmlFile, 'Update pin map').raw.prop('PinMapPath');
    expect(binPath, isNotNull);
    expect(binPath!.scalar, xmlPath!.scalar);
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
    // The 0x800 representation words: the codes whose XML twin materializes
    // representation='UInt64' / 'Int64' on every instance of these fields.
    expect(
      fields.firstWhere((f) => f.name == 'Dimension').numericRepresentation,
      BinaryNumericRepresentation.uint64.code,
    );
    expect(fields.firstWhere((f) => f.name == 'ID').numericRepresentation, BinaryNumericRepresentation.int64.code);
  });

  test('corpus sweep: element decode emits no structural tokens, data subprops stay gated', () {
    const structural = {'Objs', 'Obj', 'Seq', 'Data', 'Step', 'Sequence', 'SequenceFileData', '[0]', '[]'};
    var elementArrays = 0;
    var elements = 0;
    var dataSubProps = 0;
    for (final f in corpusSeqDir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.seq')) continue;
      final bytes = Uint8List.fromList(f.readAsBytesSync());
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      void walk(BinaryTypeField field, bool isElement) {
        if (isElement) {
          elements++;
          for (final child in field.children) {
            expect(
              structural.contains(child.name),
              isFalse,
              reason: '${f.path}: element child "${child.name}" is a structural token',
            );
          }
        }
        final elementContext = field.isArray && field.children.isNotEmpty;
        if (elementContext) elementArrays++;
        for (final child in field.children) {
          walk(child, elementContext);
        }
      }

      for (final record in binaryTypeRecords(bytes)) {
        for (final field in record.fields ?? const <BinaryTypeField>[]) {
          walk(field, false);
        }
      }
      for (final outline in binarySequenceOutlines(bytes)) {
        for (final step in [...outline.setup, ...outline.main, ...outline.cleanup, ...outline.ungrouped]) {
          dataSubProps += step.dataSubProps.length;
          for (final field in step.dataSubProps) {
            expect(const {'Measurement', 'PinMapPath'}.contains(field.name), isTrue);
          }
          for (final field in [...step.tsSubProps, ...step.dataSubProps]) {
            walk(field, false);
          }
        }
      }
    }
    // Floors pin the decode's reach (measured 22 arrays / 201 elements / 28
    // step data subprops); growth is fine, silent loss is not.
    expect(elementArrays, greaterThanOrEqualTo(22));
    expect(elements, greaterThanOrEqualTo(200));
    expect(dataSubProps, greaterThanOrEqualTo(28));
  });
}
