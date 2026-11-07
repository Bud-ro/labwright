import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'scalar_read.dart';
import 'seq_binary_grammar.dart';
import 'seq_binary_model.dart';
import 'seq_format.dart';
import 'seq_ini.dart';
import 'seq_module.dart';
import 'seq_property.dart';
import 'seq_step.dart';
import 'seq_typedefs.dart';

class SeqFile {
  SeqFile({
    required this.header,
    required this.types,
    required this.data,
    this.typelistEntries,
    this.rootAttributes,
    this.newline = '\n',
    this.binary,
  });

  final SeqFileHeader header;

  /// The decoded `TOF1` body this model was lifted from; null for XML and INI files.
  final Tof1Body? binary;

  final String newline;

  final List<SeqProperty> types;

  final List<SeqTypelistEntry>? typelistEntries;

  final Map<String, String>? rootAttributes;

  List<SeqType> get typeDefs => [for (final type in types) SeqType(type)];

  MeasurementPlugIns? get measurementPlugIns {
    final mp = data.prop('FileGlobalDefaults')?.prop('MeasurementPlugIns');
    return mp == null ? null : MeasurementPlugIns(mp);
  }

  final SeqProperty data;

  String? _str(String key) => nonEmpty(data.prop(key)?.scalar);
  int? _int(String key) => int.tryParse(data.prop(key)?.scalar ?? '');

  String? get modelFile => _str('ModelFile');

  int? get modelOptionCode => _int('ModelOption');

  String? get loadOption => _str('LoadOpt');
  String? get unloadOption => _str('UnloadOpt');

  String? get contentVersion => _str('Version');

  int? get batchSyncCode => _int('BatchSync');

  int? get sequenceFileGlobalsScopeCode => _int('SFGlobalsScope');

  int? get fileTypeCode => _int('Type');

  List<String> get requirementLinks => scalarValues(data.prop('Requirements')?.prop('Links'));

  List<SeqVariable> get fileGlobals => [
    for (final prop in data.prop('FileGlobalDefaults')?.subProps ?? const <SeqProperty>[]) SeqVariable(prop),
  ];

  List<Sequence> get sequences => [for (final seq in data.prop('Seq')?.array ?? const <SeqProperty>[]) Sequence(seq)];

  Sequence? sequence(String name) {
    for (final seq in sequences) {
      if (seq.name == name) return seq;
    }
    return null;
  }

  late final Map<String, String> _stepNamesById = _buildStepIdIndex();

  Map<String, String> _buildStepIdIndex() {
    final namesById = <String, String>{};
    for (final seq in sequences) {
      for (final step in seq.steps) {
        final id = step.id;
        if (id != null) namesById[id] = step.name;
      }
    }
    return namesById;
  }

  String? stepNameForId(String idRef) =>
      _stepNamesById[idRef] ?? (idRef.startsWith('ID#:') ? null : _stepNamesById['ID#:$idRef']);

  Sequence? resolveCall(Step step) {
    final module = step.module;
    if (module.adapter != SeqAdapter.sequenceCall || module.sequenceName == null) return null;
    return sequence(module.sequenceName!);
  }

  @override
  String toString() =>
      'SeqFile(${header.fileType}, v${header.fileVersion}, '
      '${types.length} types, ${sequences.length} sequences)';
}

enum StepGroup {
  setup('Setup'),
  main('Main'),
  cleanup('Cleanup');

  const StepGroup(this.key);

  final String key;

  static StepGroup? byKey(String name) => _byKey[name];

  static final Map<String, StepGroup> _byKey = {for (final group in values) group.key: group};
}

class Sequence {
  Sequence(this.raw);

  final SeqProperty raw;

  String get name => raw.name;

  String? get comment => nonEmpty(raw.directiveAttribute('%COMMENT')) ?? nonEmpty(raw.xmlComment);

  List<Step> stepsIn(StepGroup group) => [
    for (final stepProp in raw.prop(group.key)?.array ?? const <SeqProperty>[]) Step(stepProp),
  ];

  List<Step> get setup => stepsIn(StepGroup.setup);
  List<Step> get main => stepsIn(StepGroup.main);
  List<Step> get cleanup => stepsIn(StepGroup.cleanup);

  List<Step> get steps => [for (final group in StepGroup.values) ...stepsIn(group)];

  List<SeqVariable> get locals => _vars('Locals');

  List<SeqVariable> get parameters => _vars('Parameters');

  List<SeqVariable> _vars(String group) => [
    for (final prop in raw.prop(group)?.subProps ?? const <SeqProperty>[]) SeqVariable(prop),
  ];

  bool? get recordsResults => parseFlag(raw.prop('RecordResults')?.scalar);

  bool? get gotoCleanupOnFail => parseFlag(raw.prop('GotoCleanupOnFail')?.scalar);

  int? get failureActionCode => int.tryParse(raw.prop('FailureAction')?.scalar ?? '');

  List<String> get requirementLinks => scalarValues(raw.prop('Requirements')?.prop('Links'));

  SequenceRuntimeSettings? get runtimeSettings {
    final rts = raw.prop('RTS');
    return rts == null ? null : SequenceRuntimeSettings(rts);
  }

  @override
  String toString() => 'Sequence($name, ${steps.length} steps)';
}

class SequenceRuntimeSettings {
  SequenceRuntimeSettings(this.raw);

  final SeqProperty raw;

  bool? _bool(String key) => parseFlag(raw.prop(key)?.scalar);
  String? _str(String key) => nonEmpty(raw.prop(key)?.scalar);

  String? get entryPointNameExpression => _str('EPNameExpr');

  String? get entryPointEnabledExpression => _str('EPEnabledExpr');

  String? get entryPointMenuHint => _str('EPMenuHint');

  bool? get entryPointInitiallyHidden => _bool('EPInitiallyHidden');

  bool? get showEntryPointAlways => _bool('ShowEPAlways');
  bool? get showEntryPointForEditorOnly => _bool('ShowEPForEditorOnly');
  bool? get showEntryPointForExecutionWindow => _bool('ShowEPForExeWin');
  bool? get showEntryPointForFileWindow => _bool('ShowEPForFileWin');

  bool? get allowInteractiveExecution => _bool('AllowIntExeOfEP');

  bool? get copyStepsOnOverriding => _bool('CopyStepsOnOverriding');

  bool? get entryPointCheckToSaveTitledFile => _bool('EPCheckToSaveTitledFile');
  bool? get entryPointIgnoreClient => _bool('EPIgnoreClient');

  bool? get optimizeNonReentrantCalls => _bool('OptimizeNonReentrantCalls');

  int? get priorityCode => int.tryParse(raw.prop('Priority')?.scalar ?? '');

  int? get typeCode => int.tryParse(raw.prop('Type')?.scalar ?? '');
}

class SeqVariable {
  SeqVariable(this.raw);

  final SeqProperty raw;

  String get name => raw.name;

  String? get type => raw.typeName ?? raw.className;

  String? get comment => nonEmpty(raw.directiveAttribute('%COMMENT')) ?? nonEmpty(raw.xmlComment);

  String? get value => nonEmpty(raw.scalar);

  bool get isContainer => raw.isArray || raw.subProps.isNotEmpty;

  bool get isArray => raw.isArray;

  int? get containerCount {
    if (raw.isArray) return raw.array?.length ?? 0;
    if (raw.subProps.isNotEmpty) return raw.subProps.length;
    return null;
  }

  @override
  String toString() => 'SeqVariable($name : ${type ?? '?'}${value != null ? ' = $value' : ''})';
}

SeqFile parseSeqFile(Uint8List bytes) {
  final fmt = detectSeqFormat(bytes);
  switch (fmt) {
    case SeqFormat.xml:
      return _parseXml(bytes);
    case SeqFormat.binary:
      return parseBinarySeqFile(bytes);
    case SeqFormat.ini:
      return parseIniSeqFile(bytes);
    case SeqFormat.unknown:
      throw FormatException('not a recognized XML TestStand sequence file ($fmt)');
  }
}

class SeqTypelistEntry {
  SeqTypelistEntry({this.attributes = const {}, this.root, this.protectedData});

  final Map<String, String> attributes;

  final SeqProperty? root;

  final String? protectedData;

  bool get isProtected => protectedData != null;
}

SeqFile _parseXml(Uint8List bytes) {
  final root = XmlDocument.parse(_stripBom(utf8.decode(bytes))).rootElement;
  if (root.name.local != 'teststandfileheader') {
    throw FormatException('unexpected root element <${root.name.local}>');
  }
  final typelist = childElement(root, 'typelist');
  final entries = typelist == null
      ? null
      : [
          for (final entry in typelist.childElements)
            if (entry.name.local == 'protected')
              SeqTypelistEntry(protectedData: entry.innerText)
            else
              SeqTypelistEntry(
                attributes: {
                  for (final attribute in entry.attributes) attribute.name.qualified: attribute.value,
                },
                root: entry.childElements.isEmpty ? null : buildProperty(entry.childElements.first),
              ),
        ];
  final dataEl = childElement(root, 'Data');
  if (dataEl == null) throw const FormatException('missing <Data> element');
  return SeqFile(
    header: detectSeqHeader(bytes),
    types: [
      if (entries != null)
        for (final entry in entries)
          if (entry.root != null) entry.root!,
    ],
    data: buildProperty(dataEl),
    typelistEntries: entries,
    rootAttributes: {
      for (final attribute in root.attributes) attribute.name.qualified: attribute.value,
    },
    newline: _sniffNewline(bytes),
  );
}

String _sniffNewline(Uint8List bytes) {
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] == 0x0A) return (i > 0 && bytes[i - 1] == 0x0D) ? '\r\n' : '\n';
  }
  return '\n';
}

String _stripBom(String text) => text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF ? text.substring(1) : text;
