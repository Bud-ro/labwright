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

/// A parsed TestStand sequence file: the header, the type list, and the root
/// `Data` property object, with a typed lens over the sequences and their steps.
///
/// Built fully from the **XML** and **INI** encodings. The binary `TOF1`
/// encoding parses to a **partial** model: the sequence/step skeleton is
/// reconstructed from the decoded record structures (see [binarySequenceOutlines]),
/// while sequence properties, variables, and step modules are not yet decoded.
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

  /// The XML flavor's line terminator, `'\n'` or `'\r\n'` — corpus files use
  /// one uniformly (36 LF, 6 CRLF; none mixed), and the byte-exact writer
  /// re-emits it. `'\n'` for non-XML sources and hand-built models.
  final String newline;

  /// The `<typelist>` entries (each a type's root property object).
  final List<SeqProperty> types;

  /// The full `<typelist>` entries in document order, INCLUDING each
  /// `<typedef>` wrapper's own attributes (`alwayssavetype`/
  /// `additionaltypeflags`/`typelistordernum`, present on all 834 corpus
  /// typedefs) and the `<protected>` blobs interleaved among them (87 across
  /// 29 corpus files) — what the XML writer needs, since [types] holds only
  /// the wrapped plaintext roots. null when the file has no `<typelist>` or
  /// the source encoding carries no wrappers (INI/binary).
  final List<SeqTypelistEntry>? typelistEntries;

  /// Every attribute on the root `<teststandfileheader>` element (qualified
  /// name → value, document order) — beyond the type/fileversion/productname
  /// trio the header sniffer reads, the corpus carries `productversion`,
  /// `compatibleversion`, `buildversion`, sometimes `origfilepath`, and the
  /// two double-quoted `xmlns` declarations. null for non-XML sources.
  final Map<String, String>? rootAttributes;

  /// The `<typelist>` entries as typed [SeqType] wrappers — each type's name,
  /// base class, and declared fields. The raw roots remain available as [types].
  List<SeqType> get typeDefs => [for (final type in types) SeqType(type)];

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

  String? _str(String key) => nonEmpty(data.prop(key)?.scalar);
  int? _int(String key) => int.tryParse(data.prop(key)?.scalar ?? '');

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
  List<String> get requirementLinks => scalarValues(data.prop('Requirements')?.prop('Links'));

  /// The file's global variables (`Data.FileGlobalDefaults` children) — the
  /// FileGlobals a sequence references as `FileGlobals.…`. Empty when the file
  /// declares none. (The Semiconductor-Test-System resource block among them is
  /// also surfaced, typed, via [measurementPlugIns].)
  List<SeqVariable> get fileGlobals => [
    for (final prop in data.prop('FileGlobalDefaults')?.subProps ?? const <SeqProperty>[]) SeqVariable(prop),
  ];

  /// The sequences in the file (`Data > Seq` array). Empty if the path is absent
  /// (e.g. a type-palette file) — honest rather than throwing.
  List<Sequence> get sequences => [for (final seq in data.prop('Seq')?.array ?? const <SeqProperty>[]) Sequence(seq)];

  /// The sequence named [name] in this file, or null.
  Sequence? sequence(String name) {
    for (final seq in sequences) {
      if (seq.name == name) return seq;
    }
    return null;
  }

  /// Maps each step's unique id (`TS.Id`, e.g. `ID#:HWpAiIXA…`) to its display
  /// name, across every sequence in the file. Built once and cached. Lets an
  /// `ID#:` reference (a flow-action target like `CustFalseActTarget`) be shown as
  /// the destination step's name instead of an opaque id.
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

  /// Resolves a step reference [idRef] (a `TS.Id` value, with or without the
  /// `ID#:` prefix) to the destination step's name, or null when no step in the
  /// file has that id. Used to make `ID#:`-form flow-action targets readable.
  String? stepNameForId(String idRef) =>
      _stepNamesById[idRef] ?? (idRef.startsWith('ID#:') ? null : _stepNamesById['ID#:$idRef']);

  /// For a SequenceCall [step], the called sequence **within this file**, or null
  /// when the step isn't a sequence call or the target lives in another file
  /// (an external call — see [Step.module] `sequenceFile`).
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

/// The three ordered step groups a sequence runs, in execution order. The single
/// source of truth for the group names: [key] is the TestStand property name
/// under which a group's steps live in the `.seq` model (matched by
/// [Sequence.stepsIn] / [Sequence.setup] etc.), so callers iterate
/// `StepGroup.values` rather than hard-coding `'Setup'`/`'Main'`/`'Cleanup'`.
enum StepGroup {
  setup('Setup'),
  main('Main'),
  cleanup('Cleanup')
  ;

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
  String? get comment => nonEmpty(raw.directiveAttribute('%COMMENT'));

  /// The steps in [group] (its array property), in declaration order.
  List<Step> stepsIn(StepGroup group) => [
    for (final stepProp in raw.prop(group.key)?.array ?? const <SeqProperty>[]) Step(stepProp),
  ];

  List<Step> get setup => stepsIn(StepGroup.setup);
  List<Step> get main => stepsIn(StepGroup.main);
  List<Step> get cleanup => stepsIn(StepGroup.cleanup);

  /// All steps in editor order (Setup, then Main, then Cleanup).
  List<Step> get steps => [for (final group in StepGroup.values) ...stepsIn(group)];

  /// The sequence's local variables (`Locals`), in declaration order.
  List<SeqVariable> get locals => _vars('Locals');

  /// The sequence's parameters (`Parameters`), in declaration order. Empty when
  /// the sequence takes none.
  List<SeqVariable> get parameters => _vars('Parameters');

  List<SeqVariable> _vars(String group) => [
    for (final prop in raw.prop(group)?.subProps ?? const <SeqProperty>[]) SeqVariable(prop),
  ];

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
  List<String> get requirementLinks => scalarValues(raw.prop('Requirements')?.prop('Links'));

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
  String? get comment => nonEmpty(raw.directiveAttribute('%COMMENT'));

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
/// The **XML** and **INI** encodings parse to the complete typed model. The
/// binary `TOF1` encoding parses to an explicitly **partial** model — the
/// decoded sequence/step skeleton only (see [parseBinarySeqFile] for the exact
/// scope; `types` carries recovered type NAMES only, step types are bound
/// from the type table, and `locals` read empty there). Throws
/// [FormatException] for unrecognized input or a binary header without an
/// inflatable body.
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

/// One `<typelist>` entry, in document order — either a plaintext `<typedef>`
/// (its wrapper [attributes] plus the wrapped type [root]) or a `<protected>`
/// blob ([protectedData]). Kept whole (rather than only the roots, as
/// [SeqFile.types] does) so the XML writer can re-emit the list byte-exactly:
/// the corpus interleaves protected blobs among typedefs (e.g.
/// `…typedef ×19, protected ×3, typedef ×4`), so a split pair of lists would
/// lose the order. [root] is null for an empty `<typedef/>` wrapper — none
/// exist in the current corpus, but the shape is retained rather than
/// silently dropped.
class SeqTypelistEntry {
  SeqTypelistEntry({this.attributes = const {}, this.root, this.protectedData});

  /// The `<typedef>` element's own attributes (qualified name → value, document
  /// order): `alwayssavetype`, `additionaltypeflags`, `typelistordernum` on
  /// every corpus typedef. Empty for a `<protected>` entry (corpus: all 87
  /// blobs are attribute-less).
  final Map<String, String> attributes;

  /// The wrapped type root property; null for a `<protected>` entry or an
  /// (unobserved) empty `<typedef/>` wrapper.
  final SeqProperty? root;

  /// The verbatim text of a `<protected>` entry — a password-protected type
  /// serialized as an obfuscated single-line blob (contents not yet decoded;
  /// kept byte-faithful, never interpreted). null for a plaintext typedef.
  final String? protectedData;

  /// Whether this entry is a `<protected>` blob rather than a plaintext typedef.
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

/// The file's line terminator, from its first LF: `'\r\n'` when a CR precedes
/// it, else `'\n'` (also the LF-less degenerate default). Corpus XML files
/// are uniformly one or the other — none mixes terminators.
String _sniffNewline(Uint8List bytes) {
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] == 0x0A) return (i > 0 && bytes[i - 1] == 0x0D) ? '\r\n' : '\n';
  }
  return '\n';
}

/// Builds the **partial** typed model for a binary `TOF1` file from the decoded
/// record structures: each [BinarySequenceOutline] becomes a [Sequence] with its
/// named steps grouped into Setup/Main/Cleanup (corpus-validated against the
/// content-exact Rosetta twin), each step bound to its TYPE via the
/// reference's 1-based type-table index (see [BinaryStepRef]), the file's
/// recovered type names, the module bindings, the sequence Locals /
/// Parameters (from the sequence record's field tree), and each step's
/// serialized `TS` subprops (Id and overrides, from the step-data
/// descriptor node). The sequence-level properties that follow the group
/// arrays (RTS, Requirements, FailureAction) and the TS subprops of steps
/// whose data frames in a not-yet-covered shape are **not yet decoded**,
/// so those lenses read empty/null.
///
/// A caller that has already inflated the zlib body (e.g. `SeqDocument.parse`,
/// which also feeds [analyzeBinary]) can pass it as [body] to skip re-inflating;
/// it must be the inflated body OF [bytes].
/// Throws [FormatException] when the body does not inflate (not a TOF1 binary).
SeqFile parseBinarySeqFile(Uint8List bytes, {Uint8List? body}) {
  // Single inflate: reuse the body for layout + outlines rather than letting
  // each helper re-inflate (review-measured: the previous shape inflated the
  // same zlib body up to three times per document).
  body ??= inflateBinaryBody(bytes);
  if (body == null) {
    throw const FormatException('binary .seq body does not inflate (not TOF1?)');
  }
  // Single scan: outlines + type names share one layout framing and one
  // ordered string pool (each is an O(body) pass the per-lens helpers would
  // otherwise repeat).
  final (:outlines, :typeRecords) = binaryOutlinesAndTypeRecordsFromBody(body);
  // The step's TS node carries the decoded TS subprops (Id, … — the
  // step's serialized overrides) plus the synthesized SData>ViCall/
  // PythonCall module shape (recovered separately from the step span),
  // so the typed lens reads the same TS>SData shape the XML parse yields.
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
        // The step's own serialized data subprops beyond TS (Measurement
        // with its decoded parameter elements, PinMapPath) — the same
        // flat-sibling shape the XML parse yields.
        for (final field in step.dataSubProps) _typeFieldProp(field),
      ],
    );
  }

  return SeqFile(
    header: detectSeqHeader(bytes),
    // Recovered typedef HEADS (name, classname, XML-shaped attributes)
    // plus decoded FIELD lists where the body grammar covers the typedef —
    // bodies with not-yet-covered shapes stay empty (all-or-nothing per
    // typedef; see BinaryTypeField).
    types: [
      for (final record in typeRecords)
        SeqProperty(
          name: record.name,
          className: record.className,
          attributes: {
            ...record.toAttributes(),
            // A bailed body is marked undecoded so it is not shown as a
            // type that genuinely declares no fields.
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
                className: 'Sequence',
                subProps: [
                  // Sequence-record subprops decoded from the field tree —
                  // the leading Parameters/Locals plus the post-group
                  // scalars RecordResults/FailureAction — light up the
                  // typed Sequence.locals/parameters/recordsResults/
                  // failureActionCode lenses. The group step arrays are
                  // synthesized below from the decoded step outlines.
                  for (final field in outline.leadingSubProps) _typeFieldProp(field),
                  for (final field in outline.tailSubProps) _typeFieldProp(field),
                  SeqProperty(name: 'Setup', array: [...outline.setup.map(stepProp)]),
                  SeqProperty(name: 'Main', array: [...outline.main.map(stepProp)]),
                  SeqProperty(name: 'Cleanup', array: [...outline.cleanup.map(stepProp)]),
                ],
              ),
          ],
        ),
      ],
    ),
  );
}

/// Synthetic attribute keys the binary decoder attaches to a
/// [SeqProperty] to surface facts the XML encoding carries structurally
/// but the binary model cannot yet place inline. The `%BIN` prefix marks
/// them synthetic — NOT real file attributes — and it is the ONLY
/// synthetic namespace: an attribute-diffing or round-tripping consumer
/// must drop exactly the `%BIN*` keys. Other `%`-prefixed keys are REAL
/// file directives kept verbatim under their literal names (the legacy
/// INI `%FLG` / `%INSTFLG` / `%INSTOVRD` / `%HI` / `%LO` / `%EPTYPE` /
/// `%COMMENT`) and must round-trip. Cataloged here (rather than as
/// inline literals in producer and tests) so there is one source of
/// truth per the repo's magic-constant rule.
abstract final class BinAttr {
  /// The property's children are an OVERRIDE SUBSET of the type default
  /// (an inline instance / descriptor node), not the full field list.
  static const overrides = '%BINOVERRIDES';

  /// Byte length of the trailing, undecoded element-type-spec blob (plus
  /// any populated-array element content).
  static const elementSpec = '%BINELEMENTSPEC';

  /// Engine-intrinsic array-type id (the framed valued-array X word).
  static const intrinsic = '%BININTRINSIC';

  /// Present on a POPULATED array whose elements are not yet decoded;
  /// value is the ubound token (e.g. `'[0]'`). Absent on empty arrays.
  /// Distinguishes "array of undecoded elements" from a genuine empty
  /// array so the `array: []` mapping is not read as a false emptiness.
  static const arrayUndecoded = '%BINARRAYUNDECODED';

  /// Present on a TYPE whose body region exists but did not decode
  /// (all-or-nothing bail) — distinguishes it from a type that genuinely
  /// declares no fields.
  static const bodyUndecoded = '%BINBODYUNDECODED';

  /// A `Num` field's raw numeric-representation code when it is NOT one of
  /// the twin-evidenced [BinaryNumericRepresentation] codes (those map to
  /// the XML `representation` value attribute instead). Carried verbatim,
  /// never named.
  static const numericRep = '%BINNUMERICREP';
}

/// A decoded typedef field as a [SeqProperty], recursively (nested Obj
/// declarations carry their children; typed default-instance references
/// carry none — the binary stores only the reference).
SeqProperty _typeFieldProp(BinaryTypeField field) {
  // A populated array whose ELEMENTS decoded (children present on an
  // array field) surfaces them as real array elements — the same shape
  // the XML parse yields; one whose elements did not decode is marked
  // undecoded rather than presented as falsely empty.
  final elementsDecoded = field.isArray && field.children.isNotEmpty;
  // A `representation` VALUE attribute needs a `<value>` element to live on;
  // an UNVALUED field (an instance member whose value is inherited) writes
  // none, so its code rides the raw-code element attribute below instead —
  // otherwise the XML write/reparse loop silently drops the hint (caught by
  // the corpus retention gate).
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

/// Removes a leading UTF-8 BOM (`U+FEFF`) so the XML parser sees a clean prolog.
String _stripBom(String text) => text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF ? text.substring(1) : text;
