import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'seq_format.dart';
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

  @override
  String toString() =>
      'SeqFile(${header.fileType}, v${header.fileVersion}, '
      '${types.length} types, ${sequences.length} sequences)';
}

/// A single sequence: a name and its three ordered step groups.
class Sequence {
  Sequence(this.raw);

  /// The underlying property object — full access to every sequence property.
  final SeqProperty raw;

  String get name => raw.name;

  List<Step> get setup => _group('Setup');
  List<Step> get main => _group('Main');
  List<Step> get cleanup => _group('Cleanup');

  /// All steps in editor order (Setup, then Main, then Cleanup).
  List<Step> get steps => [...setup, ...main, ...cleanup];

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

  /// The scalar default value, or null for container/array variables and empty
  /// values.
  String? get value => (raw.scalar == null || raw.scalar!.isEmpty) ? null : raw.scalar;

  /// True for an array/object container variable (no scalar value).
  bool get isContainer => raw.isArray || raw.subProps.isNotEmpty;

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

  /// The step's run-time settings (preconditions, looping, pass/fail actions),
  /// read from its `TS` (TestStand system) sub-container.
  StepSettings get settings => StepSettings(raw.prop('TS'));

  /// The code module the step invokes (its module-adapter binding), read from
  /// `TS > SData`. [StepModule.adapter] is [SeqAdapter.none] when the step has no
  /// SData.
  StepModule get module => StepModule.fromSData(raw.at(['TS', 'SData']));

  @override
  String toString() => 'Step($name : ${type ?? '?'})';
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

  /// The step carries no `SData` (e.g. a flow-control step, or an adapter whose
  /// binding lives elsewhere such as the NI measurement plug-in).
  none,

  /// `SData` is present but its adapter record is not yet recognized.
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

  static String? _e(String? s) => (s == null || s.isEmpty) ? null : s;

  factory StepModule.fromSData(SeqProperty? sdata) {
    if (sdata == null) return StepModule(adapter: SeqAdapter.none);

    final vi = sdata.prop('ViCall');
    if (vi != null) {
      final p = _e(vi.prop('VIPath')?.scalar);
      return StepModule(adapter: SeqAdapter.labView, viPath: p, target: p, raw: sdata);
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

  /// The precondition expression (`PreCond`); null when the step runs
  /// unconditionally.
  String? get precondition => _scalar('PreCond');

  /// The looping mode (`LoopType`), e.g. `NoLooping`, `FixedNumLoops`,
  /// `WhileBreak`, `PassFailCount`. null if unspecified.
  String? get loopType => _scalar('LoopType');

  /// The loop-continuation condition expression (`LoopWhile`), if any.
  String? get loopWhile => _scalar('LoopWhile');

  /// True when the step loops (any `LoopType` other than `NoLooping`).
  bool get isLooping => loopType != null && loopType != 'NoLooping';

  /// The on-pass flow action (`PassAct`), e.g. `Next`, `GotoStep`. null if unset.
  String? get passAction => _scalar('PassAct');

  /// The on-fail flow action (`FailAct`). null if unset.
  String? get failAction => _scalar('FailAct');

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
