import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'scalar_read.dart';
import 'seq_binary.dart';
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
  });

  final SeqFileHeader header;

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
  cleanup('Cleanup')
  ;

  const StepGroup(this.key);

  final String key;

  static StepGroup? byKey(String name) => _byKey[name];

  static final Map<String, StepGroup> _byKey = {for (final group in values) group.key: group};
}

class Sequence {
  Sequence(this.raw);

  final SeqProperty raw;

  String get name => raw.name;

  String? get comment => nonEmpty(raw.directiveAttribute('%COMMENT'));

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

  String? get comment => nonEmpty(raw.directiveAttribute('%COMMENT'));

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

SeqFile parseBinarySeqFile(Uint8List bytes, {Uint8List? body}) {
  body ??= inflateBinaryBody(bytes);
  if (body == null) {
    throw const FormatException('binary .seq body does not inflate (not TOF1?)');
  }
  final (:outlines, :typeRecords) = binaryOutlinesAndTypeRecordsFromBody(body);
  SeqProperty stepProp(BinaryStepRef step) {
    final hasModule = step.viPath != null || step.pythonModule != null || step.pythonFunction != null;
    final tsChildren = <SeqProperty>[
      for (final field in step.tsSubProps) _typeFieldProp(field),
      if (hasModule)
        SeqProperty(
          name: 'SData',
          subProps: [
            if (step.viPath != null)
              SeqProperty(
                name: 'ViCall',
                subProps: [
                  SeqProperty(name: 'VIPath', scalar: step.viPath),
                ],
              ),
            if (step.pythonModule != null || step.pythonFunction != null)
              SeqProperty(
                name: 'PythonCall',
                subProps: [
                  if (step.pythonModule != null) SeqProperty(name: 'ModulePath', scalar: step.pythonModule),
                  if (step.pythonFunction != null)
                    SeqProperty(name: 'FunctionOrAttributeName', scalar: step.pythonFunction),
                ],
              ),
          ],
        ),
    ];
    return SeqProperty(
      name: step.name,
      typeName: step.typeName,
      subProps: [
        if (tsChildren.isNotEmpty) SeqProperty(name: 'TS', subProps: tsChildren),
        for (final field in step.dataSubProps) _typeFieldProp(field),
      ],
    );
  }

  return SeqFile(
    header: detectSeqHeader(bytes),
    types: [
      for (final record in typeRecords)
        SeqProperty(
          name: record.name,
          className: record.className,
          attributes: {
            ...record.toAttributes(),
            if (record.undecodedBody) BinAttr.bodyUndecoded: 'true',
          },
          subProps: [
            for (final field in record.fields ?? const <BinaryTypeField>[]) _typeFieldProp(field),
          ],
        ),
    ],
    data: SeqProperty(
      name: 'Data',
      subProps: [
        SeqProperty(
          name: 'Seq',
          array: [
            for (final outline in outlines)
              SeqProperty(
                name: outline.name,
                className: SeqValueClass.sequence.wire,
                subProps: [
                  for (final field in outline.leadingSubProps) _typeFieldProp(field),
                  for (final field in outline.tailSubProps) _typeFieldProp(field),
                  SeqProperty(name: StepGroup.setup.key, array: [...outline.setup.map(stepProp)]),
                  SeqProperty(name: StepGroup.main.key, array: [...outline.main.map(stepProp)]),
                  SeqProperty(name: StepGroup.cleanup.key, array: [...outline.cleanup.map(stepProp)]),
                ],
              ),
          ],
        ),
      ],
    ),
  );
}

/// `%BIN*` attribute keys are synthesized by the binary decoder; they are not file attributes.
abstract final class BinAttr {
  static const overrides = '%BINOVERRIDES';

  static const elementSpec = '%BINELEMENTSPEC';

  static const intrinsic = '%BININTRINSIC';

  static const arrayUndecoded = '%BINARRAYUNDECODED';

  static const bodyUndecoded = '%BINBODYUNDECODED';

  static const numericRep = '%BINNUMERICREP';
}

SeqProperty _typeFieldProp(BinaryTypeField field) {
  final elementsDecoded = field.isArray && field.children.isNotEmpty;
  final representation = field.numericRepresentation != null && field.value != null
      ? BinaryNumericRepresentation.of(field.numericRepresentation!)
      : null;
  return SeqProperty(
    name: field.name,
    className: field.className,
    typeName: field.typeName,
    scalar: field.value,
    array: field.isArray
        ? (elementsDecoded ? [for (final child in field.children) _typeFieldProp(child)] : const [])
        : null,
    valueAttributes: {
      if (field.arrayLBound != null) 'lbound': field.arrayLBound!,
      if (field.arrayUBound != null) 'ubound': field.arrayUBound!,
      if (representation != null) 'representation': representation.xmlName,
    },
    attributes: {
      if (field.instanceOverrides) BinAttr.overrides: 'true',
      if (field.elementSpecBytes != null) BinAttr.elementSpec: '${field.elementSpecBytes}',
      if (field.intrinsicTypeId != null) BinAttr.intrinsic: '${field.intrinsicTypeId}',
      if (field.isArray && !field.isEmptyArray && !elementsDecoded) BinAttr.arrayUndecoded: field.arrayUBound!,
      if (field.numericRepresentation != null && representation == null)
        BinAttr.numericRep: '${field.numericRepresentation}',
    },
    subProps: [
      if (!elementsDecoded)
        for (final child in field.children) _typeFieldProp(child),
    ],
  );
}

String _stripBom(String text) => text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF ? text.substring(1) : text;
