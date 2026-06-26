import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'seq_format.dart';
import 'seq_ini.dart';
import 'seq_property.dart';

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

  /// The root `Data` property object holding the file's contents.
  final SeqProperty data;

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
        final id = step.raw.prop('TS')?.prop('Id')?.scalar;
        if (id != null && id.isNotEmpty) m[id] = step.name;
      }
    }
    return m;
  }

  /// Resolves a step reference [idRef] (a `TS.Id` value, with or without the
  /// `ID#:` prefix) to the destination step's name, or null when no step in the
  /// file has that id. Used to make `ID#:`-form flow-action targets readable.
  String? stepNameForId(String idRef) {
    final hit = _stepNamesById[idRef];
    if (hit != null) return hit;
    // Tolerate a bare uid (no `ID#:` prefix) against `ID#:`-prefixed ids.
    return idRef.startsWith('ID#:') ? null : _stepNamesById['ID#:$idRef'];
  }

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
  String? get comment => _nz(raw.attributes['%COMMENT']);

  /// The steps in [group] (its array property), in declaration order.
  List<Step> stepsIn(StepGroup group) => _group(group.key);

  List<Step> get setup => stepsIn(StepGroup.setup);
  List<Step> get main => stepsIn(StepGroup.main);
  List<Step> get cleanup => stepsIn(StepGroup.cleanup);

  /// All steps in editor order (Setup, then Main, then Cleanup).
  List<Step> get steps => [for (final g in StepGroup.values) ...stepsIn(g)];

  List<Step> _group(String name) =>
      [for (final s in raw.prop(name)?.array ?? const <SeqProperty>[]) Step(s)];

  /// The sequence's local variables (`Locals`), in declaration order.
  List<SeqVariable> get locals => _vars('Locals');

  /// The sequence's parameters (`Parameters`), in declaration order. Empty when
  /// the sequence takes none.
  List<SeqVariable> get parameters => _vars('Parameters');

  List<SeqVariable> _vars(String group) =>
      [for (final p in raw.prop(group)?.subProps ?? const <SeqProperty>[]) SeqVariable(p)];

  @override
  String toString() => 'Sequence($name, ${steps.length} steps)';
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
  String? get comment => _nz(raw.attributes['%COMMENT']);

  /// The scalar default value, or null for container/array variables and empty
  /// values.
  String? get value => (raw.scalar == null || raw.scalar!.isEmpty) ? null : raw.scalar;

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

/// A single step within a sequence group.
class Step {
  Step(this.raw);

  /// The underlying property object — full access to every step property.
  final SeqProperty raw;

  /// The step's display name (its `name=` attribute).
  String get name => raw.name;

  /// The step type, e.g. `Statement`, `NI_MultipleNumericLimitTest`,
  /// `SequenceCall`, `MessagePopup`. null if untyped.
  String? get type => raw.typeName;

  /// The step's free-text comment — the editor's per-step note (e.g.
  /// `"Lock sequence"`), or null when the step has none. Recovered from the
  /// step's `%COMMENT`; long comments are reassembled from their continuation
  /// fragments. (Carried as a `%COMMENT` attribute by the INI reader; XML steps
  /// in the corpus store none, so this is null for them.)
  String? get comment => _nz(raw.attributes['%COMMENT']);

  /// The step's run-time settings (preconditions, looping, pass/fail actions),
  /// read from its `TS` (TestStand system) sub-container.
  StepSettings get settings => StepSettings(raw.prop('TS'));

  /// The code module the step invokes (its module-adapter binding), read from
  /// `TS > SData`. [StepModule.adapter] is [SeqAdapter.none] when the step has no
  /// SData.
  StepModule get module => StepModule.fromSData(raw.at(['TS', 'SData']));

  /// The test limits (pass/fail criteria) for a limit-test step, or null when
  /// this step is not a limit test (no `Comp`/`Limits`).
  StepLimits? get limits => StepLimits.fromStep(raw);

  @override
  String toString() => 'Step($name : ${type ?? '?'})';
}

String? _nz(String? s) => (s == null || s.isEmpty) ? null : s;

/// Unwraps a TestStand string-literal expression for display: strips one layer of
/// surrounding quotes, whether backslash-escaped (`\"…\"`, as the INI form stores
/// a quoted target after its own outer quotes are removed) or plain (`"…"`).
/// Returns the input unchanged when it is not a wrapped string literal, and null
/// for null. Used for flow-action targets like `\"<Cleanup>\"` → `<Cleanup>`.
String? _unwrapExprString(String? s) {
  if (s == null) return null;
  final t = s.trim();
  if (t.length >= 4 && t.startsWith(r'\"') && t.endsWith(r'\"')) {
    return t.substring(2, t.length - 2);
  }
  if (t.length >= 2 && t.startsWith('"') && t.endsWith('"')) {
    return t.substring(1, t.length - 1);
  }
  return t;
}

/// A limit-test step's pass/fail criteria: the comparison operator and the
/// numeric limits, read from the step's `Comp` + `Limits` + `DataSource`
/// properties. Fields are null when absent/empty or not yet decoded (e.g. units,
/// which TestStand does not store here). Comparison codes seen: `GELE`
/// (low ≤ x ≤ high); others include `EQ`/`NE`/`LT`/`LE`/`GT`/`GE`/`GTLT`/`LTGT`.
class StepLimits {
  StepLimits({
    this.comparison,
    this.low,
    this.high,
    this.nominal,
    this.thresholdType,
    this.dataSource,
    this.raw,
  });

  /// The comparison operator (`Comp`), e.g. `GELE`.
  final String? comparison;

  /// Lower / upper / nominal limit values (`Limits.Low/High/Nominal`).
  final String? low;
  final String? high;
  final String? nominal;

  /// How limits are interpreted (`Limits.ThresholdType`), e.g. `PERCENTAGE`.
  final String? thresholdType;

  /// The measured value expression being tested (`DataSource`).
  final String? dataSource;

  /// The raw `Limits` property for full access; null if the step had none.
  final SeqProperty? raw;

  /// Whether the step carries any limit information.
  static StepLimits? fromStep(SeqProperty step) {
    final comp = _nz(step.prop('Comp')?.scalar);
    final lim = step.prop('Limits');
    if (comp == null && lim == null) return null;
    return StepLimits(
      comparison: comp,
      low: _nz(lim?.prop('Low')?.scalar),
      high: _nz(lim?.prop('High')?.scalar),
      nominal: _nz(lim?.prop('Nominal')?.scalar),
      thresholdType: _nz(lim?.prop('ThresholdType')?.scalar),
      dataSource: _nz(step.prop('DataSource')?.scalar),
      raw: lim,
    );
  }

  /// A short readable summary, e.g. `GELE [9, 11]`.
  String get summary {
    final range = '[${low ?? '?'}, ${high ?? '?'}]';
    return '${comparison ?? '?'} $range';
  }

  @override
  String toString() => 'StepLimits($summary)';
}

/// The module-adapter kinds observed in the corpus — the bridge from a step to
/// the code it runs. Only kinds seen in real files are modeled (honesty); others
/// (e.g. .NET, HTBasic) surface as [unknown] until a sample is decoded.
enum SeqAdapter {
  /// LabVIEW VI adapter (`ViCall`/`VICall`) — calls a `.vi`.
  labView,

  /// C/CVI / DLL adapter (`Call`/`ExternalCall`) — calls a function in a DLL or
  /// a source module.
  cModule,

  /// Python adapter (`PythonCall`/`CPythonCall`). Recognized; its target fields
  /// are not yet decoded.
  python,

  /// Sequence Call (`SeqName`/`SFPath`) — calls another sequence.
  sequenceCall,

  /// The step carries no code module — either no `SData` at all, or an empty
  /// `SData` container (e.g. a flow-control step like `NI_Flow_If`/`NI_Flow_End`,
  /// a `Statement`, `Label`, `NI_Wait`/`NI_Lock`). Across the INI corpus every
  /// empty-`SData` step is one of these no-module types, so an empty `SData`
  /// (often inherited as a bare default from the step's type) means "no adapter",
  /// not "an adapter we failed to read".
  none,

  /// `SData` is present with members, but its adapter record is not yet
  /// recognized (e.g. .NET/HTBasic/an NI plug-in shape not yet decoded). No such
  /// step exists in the current corpus — reserved for shapes we have not seen.
  unknown;
}

/// A step's code-module binding: which adapter and what it targets. Fields are
/// null when absent/empty or not yet decoded — never fabricated.
class StepModule {
  StepModule({
    required this.adapter,
    this.target,
    this.viPath,
    this.libPath,
    this.function,
    this.sequenceName,
    this.sequenceFile,
    this.raw,
  });

  final SeqAdapter adapter;

  /// A best-effort human-readable target (VI path, `dll:function`, sequence
  /// name), or null when not yet recovered.
  final String? target;

  /// LabVIEW VI path ([SeqAdapter.labView]).
  final String? viPath;

  /// DLL/source path and function name ([SeqAdapter.cModule]).
  final String? libPath;
  final String? function;

  /// Called sequence name and file ([SeqAdapter.sequenceCall]).
  final String? sequenceName;
  final String? sequenceFile;

  /// The raw `SData` property for full access; null when the step had none.
  final SeqProperty? raw;

  /// The arguments this step's code-module call binds, in declaration order —
  /// the editor's "Module > Parameters" rows. Recovered from
  /// `SData.Call.Parameters` (the ActiveX/C-module adapter argument list).
  /// Empty when the call passes none, or when an adapter stores its arguments
  /// elsewhere (not yet decoded for other adapters).
  List<CallParameter> get callParameters {
    final params = raw?.prop('Call')?.prop('Parameters');
    if (params == null) return const [];
    final kids = params.array ?? params.subProps;
    return [for (final p in kids) CallParameter(p)];
  }

  static String? _e(String? s) => (s == null || s.isEmpty) ? null : s;

  factory StepModule.fromSData(SeqProperty? sdata) {
    // No SData, or an empty SData container (commonly an inherited bare default
    // on a flow-control/no-module step), means there is no code-module binding.
    if (sdata == null || sdata.subProps.isEmpty) {
      return StepModule(adapter: SeqAdapter.none);
    }

    final vi = sdata.prop('ViCall');
    if (vi != null) {
      final p = _e(vi.prop('VIPath')?.scalar);
      return StepModule(adapter: SeqAdapter.labView, viPath: p, target: p, raw: sdata);
    }

    // Older TestStand (e.g. versions 127/143) stores the LabVIEW adapter's path
    // as a direct `ViPath` member of SData (alongside `PassInBuf`/`PassInvocInfo`),
    // rather than nested under a `ViCall` sub-object.
    final directVi = _e(sdata.prop('ViPath')?.scalar);
    if (directVi != null) {
      return StepModule(
          adapter: SeqAdapter.labView, viPath: directVi, target: directVi, raw: sdata);
    }

    final call = sdata.prop('Call');
    if (call != null) {
      final lib = _e(call.prop('LibPath')?.scalar);
      final fn = _e(call.prop('Func')?.scalar);
      final target = lib == null ? fn : (fn == null ? lib : '$lib:$fn');
      return StepModule(
        adapter: SeqAdapter.cModule,
        libPath: lib,
        function: fn,
        target: target,
        raw: sdata,
      );
    }

    if (sdata.prop('PythonCall') != null) {
      return StepModule(adapter: SeqAdapter.python, raw: sdata);
    }

    if (sdata.prop('SeqName') != null || sdata.prop('SFPath') != null) {
      final sn = _e(sdata.prop('SeqName')?.scalar);
      final sf = _e(sdata.prop('SFPath')?.scalar);
      return StepModule(
        adapter: SeqAdapter.sequenceCall,
        sequenceName: sn,
        sequenceFile: sf,
        target: sn ?? sf,
        raw: sdata,
      );
    }

    return StepModule(adapter: SeqAdapter.unknown, raw: sdata);
  }

  @override
  String toString() => 'StepModule(${adapter.name}${target != null ? ': $target' : ''})';
}

/// A single argument a step's code-module call binds — one "Module >
/// Parameters" row in the Sequence Editor: a parameter [name], the
/// [boundExpression] supplying its value, the declared [displayType], and the
/// [direction] (in/out). Read from a `Call.Parameters[n]` property object.
class CallParameter {
  CallParameter(this.raw);

  /// The underlying parameter property object — full access to its details.
  final SeqProperty raw;

  /// The parameter's name (`Name`), e.g. `LoginName`, `Return Value`.
  String get name => _nz(raw.prop('Name')?.scalar) ?? raw.name;

  /// The expression bound to the parameter (`ArgVal`) — what the call passes,
  /// e.g. `Locals.userToLogin`, `FileGlobals.UserToAutoLogin` — or null when
  /// the call leaves it unbound.
  String? get boundExpression => _nz(raw.prop('ArgVal')?.scalar);

  /// The human-readable parameter type the editor shows (`DisplayType`), e.g.
  /// `String`, `User (Object Reference)`; null when absent.
  String? get displayType => _nz(raw.prop('DisplayType')?.scalar);

  /// The raw `Direction` code exactly as stored (`1`, `2`, `3`, …), or null
  /// when absent. Exposed alongside [direction] so an unrecognized code is left
  /// readable rather than dropped.
  String? get directionCode => _nz(raw.prop('Direction')?.scalar);

  /// A readable parameter direction — `in` (`1`), `out` (`2`), `in/out` (`3`) —
  /// mapped from [directionCode] using the standard TestStand parameter
  /// directions (consistent across the corpus: a `Return Value` reads `2`,
  /// supplied inputs read `1`). null for an absent or unrecognized code, which
  /// stays available raw in [directionCode] rather than being guessed.
  String? get direction => switch (directionCode) {
        '1' => 'in',
        '2' => 'out',
        '3' => 'in/out',
        _ => null,
      };

  @override
  String toString() =>
      'CallParameter($name${boundExpression != null ? ' ← $boundExpression' : ''})';
}

/// The step settings the Sequence Editor surfaces — flow control and the
/// pre/post expressions — read from a step's `TS` sub-container. Every getter is
/// null when the underlying property is absent or empty (no fabricated default),
/// so "not set" is honestly distinguishable from a real value.
class StepSettings {
  StepSettings(this._ts);

  /// The `TS` property object, or null if the step has none.
  final SeqProperty? _ts;

  String? _scalar(String key) {
    final s = _ts?.prop(key)?.scalar;
    return (s == null || s.isEmpty) ? null : s;
  }

  /// The run mode (`Mode`): `Normal`, `Skip`, `Pass`, `Fail`, … — how the step
  /// executes (Skip/force-pass/force-fail are editor-visible overrides).
  String? get mode => _scalar('Mode');

  /// True unless the step is forced to a non-normal run mode.
  bool get isNormalMode => mode == null || mode == 'Normal';

  /// The module load timing (`LoadOpt`), e.g. `PreloadWhenExecuted` (the common
  /// default), `DynamicLoad`.
  String? get loadOption => _scalar('LoadOpt');

  /// The module unload timing (`UnloadOpt`), e.g. `UnloadWithFile` (the common
  /// default), `UnloadAfterStepExecution`, `UnloadAfterSequenceExecution`. The
  /// symmetric counterpart to [loadOption].
  String? get unloadOption => _scalar('UnloadOpt');

  /// The step's editor icon (`TS.Icon`), as a readable basename without its
  /// folder or `.ico` extension (e.g. `NI_While`, `Measurement`, `MsgBox`), or
  /// null when the step uses the default blank icon (`ni_blank`) or has none.
  /// This is the glyph TestStand shows beside the step in the editor.
  String? get icon {
    var name = _scalar('Icon');
    if (name == null) return null;
    final slash = name.lastIndexOf(RegExp(r'[\\/]'));
    if (slash >= 0) name = name.substring(slash + 1);
    if (name.toLowerCase().endsWith('.ico')) {
      name = name.substring(0, name.length - 4);
    }
    return (name.isEmpty || name.toLowerCase() == 'ni_blank') ? null : name;
  }

  /// The precondition expression (`PreCond`); null when the step runs
  /// unconditionally.
  String? get precondition => _scalar('PreCond');

  /// The looping mode (`LoopType`), e.g. `NoLooping`, `FixedNumLoops`,
  /// `WhileBreak`, `PassFailCount`. null if unspecified.
  String? get loopType => _scalar('LoopType');

  /// The loop expressions a looping step runs. TestStand loops are
  /// expression-driven: [loopInitialize] sets up the loop (`LoopInitialize`,
  /// e.g. `RunState.LoopIndex = 0`), [loopWhile] is the continue condition
  /// (`LoopWhile`), [loopIncrement] advances each pass (`LoopIncrement`), and
  /// [loopStatus] computes the loop's overall status (`LoopStatus`). Each is null
  /// when absent — non-looping steps have none.
  String? get loopInitialize => _scalar('LoopInitialize');
  String? get loopWhile => _scalar('LoopWhile');
  String? get loopIncrement => _scalar('LoopIncrement');
  String? get loopStatus => _scalar('LoopStatus');

  /// True when the step loops (any `LoopType` other than `NoLooping`).
  bool get isLooping => loopType != null && loopType != 'NoLooping';

  /// The on-pass flow action (`PassAct`), e.g. `Next`, `Goto`. null if unset.
  String? get passAction => _scalar('PassAct');

  /// The on-fail flow action (`FailAct`). null if unset.
  String? get failAction => _scalar('FailAct');

  /// The pass-action jump target (`PassActTarget`), e.g. the bookmark
  /// `<Cleanup>` or a step reference `ID#:…`, for a non-`Next` [passAction];
  /// null when the action just falls through. The stored value is a TestStand
  /// expression (a quoted string literal); the surrounding quotes are unwrapped
  /// for display.
  String? get passActionTarget => _flowTarget('PassActTarget');

  /// The fail-action jump target (`FailActTarget`); see [passActionTarget].
  String? get failActionTarget => _flowTarget('FailActTarget');

  /// The custom-condition jump targets (`CustTrueActTarget` /
  /// `CustFalseActTarget`) of a step with a custom pass/fail condition, or null
  /// when unset. Stored like the other targets — a bookmark (`<Cleanup>`) or a
  /// step reference (`ID#:…`), the latter resolvable via [SeqFile.stepNameForId].
  String? get customTrueTarget => _flowTarget('CustTrueActTarget');
  String? get customFalseTarget => _flowTarget('CustFalseActTarget');

  String? _flowTarget(String key) => _nz(_unwrapExprString(_scalar(key)));

  /// A compact flow-action summary `pass[→target]/fail[→target]` (e.g.
  /// `Next/Goto→<Cleanup>`), or null when neither action is set. The `→target`
  /// suffix is added only for a non-`Next` action that carries a jump target.
  String? get flowSummary {
    if (passAction == null && failAction == null) return null;
    String side(String? act, String? target) {
      final a = act ?? '?';
      return (a != 'Next' && target != null) ? '$a→$target' : a;
    }

    return '${side(passAction, passActionTarget)}/'
        '${side(failAction, failActionTarget)}';
  }

  /// Pre-/post-/status expressions evaluated around the step, if any.
  String? get preExpression => _scalar('PreExpr');
  String? get postExpression => _scalar('PostExpr');
  String? get statusExpression => _scalar('StatusExpr');
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
      // The legacy INI form maps onto the same PropertyObject model — build a
      // SeqFile via the INI reader so the typed lens works on it too.
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
  final types = <SeqProperty>[];
  final typelist = childElement(root, 'typelist');
  if (typelist != null) {
    for (final typedef in childElementsNamed(typelist, 'typedef')) {
      // A typedef wraps exactly one type root element.
      final kids = typedef.childElements;
      if (kids.isNotEmpty) types.add(buildProperty(kids.first));
    }
  }
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
