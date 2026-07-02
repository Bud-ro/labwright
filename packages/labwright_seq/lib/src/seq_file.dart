import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'scalar_read.dart';
import 'seq_format.dart';
import 'seq_ini.dart';
import 'seq_module.dart';
import 'seq_property.dart';
import 'seq_step.dart';
import 'seq_typedefs.dart';

/// A parsed TestStand sequence file: the header, the type list, and the root
/// `Data` property object, with a typed lens over the sequences and their steps.
///
/// Built from the **XML** encoding (M1). The binary `TOF1` encoding maps onto the
/// same model and is a later milestone — [parseSeqFile] throws for it rather than
/// guessing.
class SeqFile {
  SeqFile({required this.header, required this.types, required this.data});

  final SeqFileHeader header;

  /// The `<typelist>` entries (each a type's root property object).
  final List<SeqProperty> types;

  /// The `<typelist>` entries as typed [SeqType] wrappers — each type's name,
  /// base class, and declared fields. The raw roots remain available as [types].
  List<SeqType> get typeDefs => [for (final t in types) SeqType(t)];

  /// The Semiconductor-Test-System measurement plug-in resource set this file
  /// declares (`Data > FileGlobalDefaults > MeasurementPlugIns`) — the pin map
  /// and specifications/levels/timing/pattern files the test program depends on.
  /// null when the file declares no such block. See [MeasurementPlugIns].
  MeasurementPlugIns? get measurementPlugIns {
    final mp = data.prop('FileGlobalDefaults')?.prop('MeasurementPlugIns');
    return mp == null ? null : MeasurementPlugIns(mp);
  }

  /// The root `Data` property object holding the file's contents.
  final SeqProperty data;

  String? _str(String k) => nonEmpty(data.prop(k)?.scalar);
  int? _int(String k) => int.tryParse(data.prop(k)?.scalar ?? '');

  /// The process model file this sequence file uses (`Data.ModelFile`), e.g. a
  /// `.seq` station-model path; null when it inherits the station default.
  String? get modelFile => _str('ModelFile');

  /// The model-option code (`Data.ModelOption`) — how the file selects its model
  /// (use station model / require specific / none). Verbatim; NI-internal
  /// code→name not invented. null when absent.
  int? get modelOptionCode => _int('ModelOption');

  /// The file-wide default module load/unload options (`Data.LoadOpt` /
  /// `Data.UnloadOpt`), e.g. `UseStepLoadOpt` — the fallback a step inherits when
  /// it defers to the file. null when absent.
  String? get loadOption => _str('LoadOpt');
  String? get unloadOption => _str('UnloadOpt');

  /// The file's content version string (`Data.Version`, e.g. `2022.2.9`) — the
  /// TestStand version stamp on the file contents, distinct from the
  /// header/format version ([SeqFileHeader.fileVersion]). null when absent.
  String? get contentVersion => _str('Version');

  /// The file's batch-synchronization code (`Data.BatchSync`). Verbatim;
  /// NI-internal code→name not invented. null when absent.
  int? get batchSyncCode => _int('BatchSync');

  /// The file-globals scope code (`Data.SFGlobalsScope`) governing how this
  /// file's globals are shared. Verbatim; null when absent.
  int? get sequenceFileGlobalsScopeCode => _int('SFGlobalsScope');

  /// The file-type code (`Data.Type`) classifying the sequence file (model /
  /// ordinary / …). Verbatim; NI-internal code→name not invented. null when
  /// absent.
  int? get fileTypeCode => _int('Type');

  /// The requirement-traceability links the file declares (`Data.Requirements.
  /// Links`). Empty when none.
  List<String> get requirementLinks =>
      scalarValues(data.prop('Requirements')?.prop('Links'));

  /// The file's global variables (`Data.FileGlobalDefaults` children) — the
  /// FileGlobals a sequence references as `FileGlobals.…`. Empty when the file
  /// declares none. (The Semiconductor-Test-System resource block among them is
  /// also surfaced, typed, via [measurementPlugIns].)
  List<SeqVariable> get fileGlobals => [
        for (final p in data.prop('FileGlobalDefaults')?.subProps ??
            const <SeqProperty>[])
          SeqVariable(p),
      ];

  /// The sequences in the file (`Data > Seq` array). Empty if the path is absent
  /// (e.g. a type-palette file) — honest rather than throwing.
  List<Sequence> get sequences =>
      [for (final s in data.prop('Seq')?.array ?? const <SeqProperty>[]) Sequence(s)];

  /// The sequence named [name] in this file, or null.
  Sequence? sequence(String name) {
    for (final s in sequences) {
      if (s.name == name) return s;
    }
    return null;
  }

  /// Maps each step's unique id (`TS.Id`, e.g. `ID#:HWpAiIXA…`) to its display
  /// name, across every sequence in the file. Built once and cached. Lets an
  /// `ID#:` reference (a flow-action target like `CustFalseActTarget`) be shown as
  /// the destination step's name instead of an opaque id.
  late final Map<String, String> _stepNamesById = _buildStepIdIndex();

  Map<String, String> _buildStepIdIndex() {
    final m = <String, String>{};
    for (final seq in sequences) {
      for (final step in seq.steps) {
        final id = step.id;
        if (id != null) m[id] = step.name;
      }
    }
    return m;
  }

  /// Resolves a step reference [idRef] (a `TS.Id` value, with or without the
  /// `ID#:` prefix) to the destination step's name, or null when no step in the
  /// file has that id. Used to make `ID#:`-form flow-action targets readable.
  String? stepNameForId(String idRef) =>
      _stepNamesById[idRef] ??
      (idRef.startsWith('ID#:') ? null : _stepNamesById['ID#:$idRef']);

  /// For a SequenceCall [step], the called sequence **within this file**, or null
  /// when the step isn't a sequence call or the target lives in another file
  /// (an external call — see [Step.module] `sequenceFile`).
  Sequence? resolveCall(Step step) {
    final m = step.module;
    if (m.adapter != SeqAdapter.sequenceCall || m.sequenceName == null) return null;
    return sequence(m.sequenceName!);
  }

  @override
  String toString() =>
      'SeqFile(${header.fileType}, v${header.fileVersion}, '
      '${types.length} types, ${sequences.length} sequences)';
}

/// The three ordered step groups a sequence runs, in execution order. The single
/// source of truth for the group names: [key] is the TestStand property name
/// under which a group's steps live in the `.seq` model (matched by
/// [Sequence.stepsIn] / [Sequence.setup] etc.), so callers iterate
/// `StepGroup.values` rather than hard-coding `'Setup'`/`'Main'`/`'Cleanup'`.
enum StepGroup {
  setup('Setup'),
  main('Main'),
  cleanup('Cleanup');

  const StepGroup(this.key);

  /// The property name holding this group's step array.
  final String key;
}

/// A single sequence: a name and its three ordered step groups.
class Sequence {
  Sequence(this.raw);

  /// The underlying property object — full access to every sequence property.
  final SeqProperty raw;

  String get name => raw.name;

  /// The sequence's free-text comment — the editor's per-sequence note (e.g. a
  /// callback's "This entry point is executed only once…" description) — or null
  /// when it has none. Recovered from the sequence object's `%COMMENT`; long
  /// comments are reassembled from continuation fragments. (Carried as a
  /// `%COMMENT` attribute by the INI reader; XML sequences in the corpus store
  /// none, so this is null for them.)
  String? get comment => nonEmpty(raw.attributes['%COMMENT']);

  /// The steps in [group] (its array property), in declaration order.
  List<Step> stepsIn(StepGroup group) =>
      [for (final s in raw.prop(group.key)?.array ?? const <SeqProperty>[]) Step(s)];

  List<Step> get setup => stepsIn(StepGroup.setup);
  List<Step> get main => stepsIn(StepGroup.main);
  List<Step> get cleanup => stepsIn(StepGroup.cleanup);

  /// All steps in editor order (Setup, then Main, then Cleanup).
  List<Step> get steps => [for (final g in StepGroup.values) ...stepsIn(g)];

  /// The sequence's local variables (`Locals`), in declaration order.
  List<SeqVariable> get locals => _vars('Locals');

  /// The sequence's parameters (`Parameters`), in declaration order. Empty when
  /// the sequence takes none.
  List<SeqVariable> get parameters => _vars('Parameters');

  List<SeqVariable> _vars(String group) =>
      [for (final p in raw.prop(group)?.subProps ?? const <SeqProperty>[]) SeqVariable(p)];

  /// Whether the sequence records its steps' results into the report
  /// (`RecordResults`). null when the sequence stores no value.
  bool? get recordsResults => parseFlag(raw.prop('RecordResults')?.scalar);

  /// Whether a step failure jumps straight to the Cleanup group
  /// (`GotoCleanupOnFail`). null when unset.
  bool? get gotoCleanupOnFail => parseFlag(raw.prop('GotoCleanupOnFail')?.scalar);

  /// The sequence-level on-failure action code (`FailureAction`) — what the
  /// sequence does when it fails. Surfaced verbatim; the NI-internal code→name
  /// mapping is not invented. null when unset.
  int? get failureActionCode => int.tryParse(raw.prop('FailureAction')?.scalar ?? '');

  /// The requirement-traceability links the sequence declares
  /// (`Requirements.Links`) — free-text requirement identifiers the sequence is
  /// tagged with. Empty when the sequence declares none.
  List<String> get requirementLinks =>
      scalarValues(raw.prop('Requirements')?.prop('Links'));

  /// The sequence's run-time / entry-point settings (`RTS`) — how it appears and
  /// behaves as a callable entry point — or null when it carries none.
  SequenceRuntimeSettings? get runtimeSettings {
    final rts = raw.prop('RTS');
    return rts == null ? null : SequenceRuntimeSettings(rts);
  }

  @override
  String toString() => 'Sequence($name, ${steps.length} steps)';
}

/// A sequence's run-time / entry-point settings (`RTS`) — the editor's
/// "Sequence Properties" run-time tab. A sequence usable as an *entry point*
/// (e.g. `MainSequence`, a process-model callback) carries display rules for
/// where it appears (`ShowEPFor…`), its menu name/hint, an enabled expression,
/// and execution options (reentrancy optimization, priority). Every getter is
/// null/empty when its field is absent — no fabricated default.
class SequenceRuntimeSettings {
  SequenceRuntimeSettings(this.raw);

  /// The underlying `RTS` property object — full access to every field.
  final SeqProperty raw;

  bool? _bool(String key) => parseFlag(raw.prop(key)?.scalar);
  String? _str(String key) => nonEmpty(raw.prop(key)?.scalar);

  /// The expression the editor evaluates to display the entry point's name
  /// (`EPNameExpr`, e.g. `"MainSequence"`); null when unset.
  String? get entryPointNameExpression => _str('EPNameExpr');

  /// The expression that enables/disables the entry point (`EPEnabledExpr`);
  /// null when unset.
  String? get entryPointEnabledExpression => _str('EPEnabledExpr');

  /// The entry point's menu hint/category (`EPMenuHint`); null when unset.
  String? get entryPointMenuHint => _str('EPMenuHint');

  /// Whether the entry point starts hidden (`EPInitiallyHidden`). null when unset.
  bool? get entryPointInitiallyHidden => _bool('EPInitiallyHidden');

  /// Where the entry point is offered — always (`ShowEPAlways`), in the editor
  /// only (`ShowEPForEditorOnly`), in execution windows (`ShowEPForExeWin`), and
  /// in file windows (`ShowEPForFileWin`). Each null when unset.
  bool? get showEntryPointAlways => _bool('ShowEPAlways');
  bool? get showEntryPointForEditorOnly => _bool('ShowEPForEditorOnly');
  bool? get showEntryPointForExecutionWindow => _bool('ShowEPForExeWin');
  bool? get showEntryPointForFileWindow => _bool('ShowEPForFileWin');

  /// Whether the entry point may be run interactively (`AllowIntExeOfEP`). null
  /// when unset.
  bool? get allowInteractiveExecution => _bool('AllowIntExeOfEP');

  /// Whether the editor copies steps when overriding the sequence
  /// (`CopyStepsOnOverriding`). null when unset.
  bool? get copyStepsOnOverriding => _bool('CopyStepsOnOverriding');

  /// Whether the entry point prompts to save a titled file (`EPCheckToSaveTitledFile`)
  /// / ignores its client (`EPIgnoreClient`). Each null when unset.
  bool? get entryPointCheckToSaveTitledFile => _bool('EPCheckToSaveTitledFile');
  bool? get entryPointIgnoreClient => _bool('EPIgnoreClient');

  /// Whether non-reentrant calls into this sequence are optimized
  /// (`OptimizeNonReentrantCalls`). null when unset.
  bool? get optimizeNonReentrantCalls => _bool('OptimizeNonReentrantCalls');

  /// The sequence's run priority (`Priority`) as the raw stored integer; null
  /// when unset. The value is TestStand's internal priority encoding.
  int? get priorityCode => int.tryParse(raw.prop('Priority')?.scalar ?? '');

  /// The sequence run-time `Type` code; surfaced verbatim, NI-internal meaning
  /// not invented. null when unset.
  int? get typeCode => int.tryParse(raw.prop('Type')?.scalar ?? '');
}

/// A sequence variable — a local or a parameter. Locals/Parameters are property
/// containers whose sub-properties are the variables, so a variable is just a
/// property with a name, a type, and an optional default value.
class SeqVariable {
  SeqVariable(this.raw);

  /// The underlying property object — full access to the variable's details.
  final SeqProperty raw;

  String get name => raw.name;

  /// The custom type name (`typename`) if any, else the built-in value-kind
  /// (`classname`: `Num`, `Str`, `Boolean`, `Obj`, `Objs`, …). null if neither.
  String? get type => raw.typeName ?? raw.className;

  /// The variable's free-text comment — the editor's note describing what it
  /// holds (e.g. `"InfoTableRC: [row][col]"`) — or null when it has none.
  /// Recovered from the variable's `%COMMENT`. (Carried as a `%COMMENT` attribute
  /// by the INI reader; XML variables in the corpus store none.)
  String? get comment => nonEmpty(raw.attributes['%COMMENT']);

  /// The scalar default value, or null for container/array variables and empty
  /// values.
  String? get value => nonEmpty(raw.scalar);

  /// True for an array/object container variable (no scalar value).
  bool get isContainer => raw.isArray || raw.subProps.isNotEmpty;

  /// True when this container is an array (vs. an object/cluster). Only
  /// meaningful when [isContainer].
  bool get isArray => raw.isArray;

  /// The container's size: the number of array elements for an array, or the
  /// number of fields (sub-properties) for an object/cluster. null for a scalar
  /// variable. An array recovered with no stored elements is `0` (e.g. an empty
  /// default `ResultList`), distinct from a scalar's null.
  int? get containerCount {
    if (raw.isArray) return raw.array?.length ?? 0;
    if (raw.subProps.isNotEmpty) return raw.subProps.length;
    return null;
  }

  @override
  String toString() => 'SeqVariable($name : ${type ?? '?'}${value != null ? ' = $value' : ''})';
}

/// Parses TestStand sequence-file [bytes] into a [SeqFile].
///
/// Supports the **XML** encoding. Throws [UnsupportedError] for the binary
/// `TOF1` encoding (not yet decoded) and [FormatException] for unrecognized
/// input — never a silent partial result.
SeqFile parseSeqFile(Uint8List bytes) {
  final fmt = detectSeqFormat(bytes);
  switch (fmt) {
    case SeqFormat.xml:
      return _parseXml(bytes);
    case SeqFormat.binary:
      throw UnsupportedError('binary TOF1 .seq decoding is not yet implemented (M2)');
    case SeqFormat.ini:
      return parseIniSeqFile(bytes);
    case SeqFormat.unknown:
      throw FormatException('not a recognized XML TestStand sequence file ($fmt)');
  }
}

SeqFile _parseXml(Uint8List bytes) {
  final root = XmlDocument.parse(_stripBom(utf8.decode(bytes))).rootElement;
  if (root.name.local != 'teststandfileheader') {
    throw FormatException('unexpected root element <${root.name.local}>');
  }
  final typelist = childElement(root, 'typelist');
  final types = [
    if (typelist != null)
      for (final typedef in childElementsNamed(typelist, 'typedef'))
        if (typedef.childElements.isNotEmpty)
          buildProperty(typedef.childElements.first),
  ];
  final dataEl = childElement(root, 'Data');
  if (dataEl == null) throw const FormatException('missing <Data> element');
  return SeqFile(
    header: detectSeqHeader(bytes),
    types: types,
    data: buildProperty(dataEl),
  );
}

/// Removes a leading UTF-8 BOM (`U+FEFF`) so the XML parser sees a clean prolog.
String _stripBom(String s) =>
    s.isNotEmpty && s.codeUnitAt(0) == 0xFEFF ? s.substring(1) : s;
