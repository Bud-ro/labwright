@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart' show Unknown;
import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Scalars the lift synthesizes without a pool string behind them.
const _synthesizedScalars = {'', '0', 'true', 'false'};

void main() {
  final files = corpusSeqDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.seq')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('every binary decodes end to end, writes back byte-exactly and lifts nothing the pool lacks', () {
    final offenders = <String>[];
    final generations = <Tof1Generation>{};
    var structureBits = 0;
    for (final f in files) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      final rel = corpusSeqRelativePath(f.path);
      final body = decodeTof1(bytes);
      final header = body.header;
      generations.add(header.generation);
      expect((header.fileType, header.productName), ('SequenceFile', 'TestStand'), reason: rel);
      for (final field in Tof1Header.layout.fields.whereType<Unknown>()) {
        expect(field.read(header.view), everyElement(0), reason: '$rel: reserved header bytes at ${field.offset}');
      }
      if (header.generation == Tof1Generation.ts2014) expect(header.savedPath, isEmpty, reason: rel);
      expect(body.data.end + 8, body.recordRegionLength, reason: '$rel: the data root ends at the pool');
      expect((body.tailWord, body.lastStringTerminated, body.poolTail.length), (0, true, 0), reason: rel);
      expect(body.types.map((t) => t.entryWord), everyElement(1), reason: rel);
      for (final record in body.records) {
        if (record.enumItems != null) expect(record.enumItemsWord, 1, reason: '$rel: ${record.name}');
        if (record.structureFlags case final bits?) structureBits |= bits;
      }

      final model = BinarySeqWriteModel(body);
      expect(model.writeBody(), body.bytes, reason: '$rel: the body writes back byte-exactly');
      final view = ByteData.sublistView(body.bytes);
      for (final slot in model.f64Slots) {
        final stored = view.getFloat64(slot.offset, Endian.little);
        if (!(stored == slot.value || (stored.isNaN && slot.value.isNaN))) {
          offenders.add('$rel: f64 slot ${slot.offset} holds $stored, not ${slot.value}');
        }
      }
      final rewritten = model.writeFile();
      expect(Uint8List.sublistView(rewritten, 0, Tof1Header.size), header.serialize(), reason: '$rel: header');
      final again = decodeTof1(rewritten);
      expect(again.bytes, body.bytes, reason: '$rel: the rewritten file re-inflates to the body');
      final file = tof1BodyToSeqFile(body);
      expect(seqPropertyDeepEquals(tof1BodyToSeqFile(again).data, file.data), isTrue, reason: '$rel: rewritten model');

      final pool = body.pool.toSet();
      void checkNames(SeqProperty p, String path) {
        if (p.name.isNotEmpty && !p.name.startsWith('%BIN') && !pool.contains(p.name)) {
          offenders.add('$rel: name "${p.name}" at $path is not in the pool');
        }
        if (p.typeName case final type? when !pool.contains(type)) offenders.add('$rel: type $type at $path');
        if (p.className case final cls? when !pool.contains(cls)) offenders.add('$rel: class $cls at $path');
        final scalar = p.scalar;
        if ((p.valueClass?.isText ?? false) && scalar != null && scalar.isNotEmpty && !pool.contains(scalar)) {
          offenders.add('$rel: text value "$scalar" at $path');
        }
        if (p.valueClass == SeqValueClass.boolean && scalar != null && !_synthesizedScalars.contains(scalar)) {
          offenders.add('$rel: boolean "$scalar" at $path');
        }
        for (final child in p.subProps) {
          checkNames(child, '$path/${child.name}');
        }
        for (final (i, element) in (p.array ?? const <SeqProperty>[]).indexed) {
          checkNames(element, '$path[$i]');
        }
        if (p.elemProto case final proto?) checkNames(proto, '$path/<proto>');
      }

      for (final type in file.types) {
        checkNames(type, 'type/${type.name}');
      }
      checkNames(file.data, 'Data');
      final typeNames = {for (final t in file.types) t.name};
      for (final sequence in file.sequences) {
        expect(sequence.name, isNotEmpty, reason: rel);
        for (final step in sequence.steps) {
          final where = '$rel: ${sequence.name}/${step.name}';
          if (step.name.isEmpty) expect(step.type, 'Label', reason: '$where: only Label steps go unnamed');
          expect(typeNames, contains(step.type), reason: where);
          if (step.id case final id?) expect(id, startsWith('ID#:'), reason: where);
          if (step.module.viPath case final vi?) expect(vi, contains('.vi'), reason: where);
          if (step.module.pythonModulePath case final py?) expect(py, endsWith('.py'), reason: where);
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.take(12).join('\n'));
    expect(generations, Tof1Generation.values.toSet(), reason: 'every generation is exercised');
    expect(structureBits, structureFlagMask, reason: 'every decoded structure bit occurs in the corpus');
  });

  group('pinned files', () {
    SeqFile load(String suffix) =>
        parseSeqFile(files.firstWhere((f) => f.path.replaceAll(r'\', '/').endsWith(suffix)).readAsBytesSync());

    test('PCBA FT Demo.seq: expression arrays, and a pool that starts with Obj still roots the data', () {
      final file = load('PCBA FT Demo/PCBA FT Demo.seq');
      final power = file.sequence('Power Diagnostics')!;
      final source = power.main.map((s) => s.raw.prop('DataSourceArray')).nonNulls.first.array!.single;
      expect((source.scalar, source.className), ('Locals.PS_Meas_Data.Max_Current', 'ExprValue'));
      expect((file.binary!.pool.first, file.data.className), ('Obj', 'SequenceFileData'));
    });

    test('SequentialModel.seq: the process model with its callbacks and entry points', () {
      final file = load('Patching Process Models/SequentialModel.seq');
      expect(file.sequence('Test UUTs')!.runtimeSettings?.entryPointNameExpression, isNotNull);
      expect(file.sequences.where((s) => s.steps.any((t) => t.module.adapter == SeqAdapter.sequenceCall)), isNotEmpty);
    });

    test('Test Sequence.seq: a sequence named `Sequence` with a typed sub-step', () {
      final step = load('sandbox/Test Sequence.seq').sequence('Sequence')!.main.single;
      expect((step.name, step.type), ('Subseq', 'DanfossStringValueTest'));
      expect(step.raw.prop('Limits')!.prop('String')!.scalar, 'String Limit');
    });

    test('LabVIEW Compiled Object Cache Preparation.seq: a substep typedef decodes through its substeps', () {
      final wait = load('LabVIEW Compiled Object Cache Preparation.seq').types.firstWhere((t) => t.name == 'NI_Wait');
      final substeps = wait.prop('Substeps')!.array!;
      expect([for (final s in substeps) s.name], ['OnNewStep', 'Post', 'Edit']);
      final edit = substeps[2];
      expect(edit.prop('MenuName')!.scalar, 'ResStr("NI_WAIT_STEP_TYPE", "EDIT_STEP_MENU_NAME")');
      expect(edit.prop('HasEditPanel')!.scalar, 'true');
      expect([for (final c in edit.prop('Result')!.subProps) c.name], ['Error', 'Status', 'ReportText', 'Common']);
      expect(edit.prop('Result')!.prop('Status')!.attributes[BinAttr.inherited], 'true');
    });

    test('PerformanceMeasurementLogger.seq: Ref parameters and locals with their value flags', () {
      final log = load('ModelPlugins/PerformanceMeasurementLogger.seq').sequence('Log Data to File')!;
      final params = log.raw.prop('Parameters')!, locals = log.raw.prop('Locals')!;
      expect(params.attributes['valueflags'], '4456448');
      final ref = params.subProps.single;
      expect((ref.name, ref.className, ref.scalar), ('PerformanceMeasurementLogger', 'Ref', null));
      expect(locals.attributes['valueflags'], '4194304');
      expect([for (final c in locals.subProps) c.name], ['SocketTime', 'ResultList']);
    });

    test('GetNIVSTokens.seq and CC Tests.seq: the TestStand 4.5 and 2013 generations', () {
      expect(load('Executable/GetNIVSTokens.seq').binary!.generation, Tof1Generation.ts4);
      final cc = load('TestStand Scripts/CC Tests.seq').binary!;
      expect(cc.generation, Tof1Generation.ts2013);
      expect(cc.types.where((t) => t.isProtected), isEmpty);
    });

    test('specifications.seq: protected types carry their digests and lift with their content', () {
      final file = load('systemtests/specifications.seq');
      final protectedTypes = file.binary!.types.where((t) => t.isProtected).toList();
      expect(protectedTypes.where((t) => t.hasSecondaryDigest), isNotEmpty);
      for (final type in protectedTypes) {
        expect(type.protectionDigest, isNotEmpty);
        final root = file.types.firstWhere((t) => t.name == type.name);
        expect(root.attributes[BinAttr.protected], type.protectionDigest);
        expect(root.subProps.isNotEmpty || root.array != null, isTrue, reason: type.name);
      }
    });

    test('Sensor Test.seq: pool strings are Windows-1252, curly quotes included', () {
      final pool = load('Sensor Tests/Sensor Test.seq').binary!.pool;
      expect(pool.where((p) => p.contains('“RTD Type”')), hasLength(1));
      expect(pool.any((p) => p.contains('\u0093')), isFalse);
    });

    test('Accelerometer.seq: enum typedefs decode with their enumerators', () {
      final types = load('TestPrograms/Accelerometer/Accelerometer.seq').binary!.types;
      final root = types.firstWhere((t) => t.root.kind == SeqValueClass.enumeration).root;
      final first = root.enumItems!.elements!.first as BinaryRecord;
      expect(first.child('EnumeratorName')!.value, isA<String>());
      expect(first.child('EnumeratorValue')!.value, isA<double>());
      expect(root.enumValueName, isNotNull);
    });
  });
}
