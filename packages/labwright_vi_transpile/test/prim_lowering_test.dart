import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart' show PrimOp;
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

/// A call to [op] drawn with the holders of its signature in heap order: [wired] maps a
/// terminal name to the expression on its wire (an input) or the local it binds (an output);
/// [labels] overrides the type label a terminal's record carries.
LvPrimCall _call(
  PrimOp op,
  Map<String, String> wired, {
  Map<String, LvWireType> types = const {},
  Map<String, String> labels = const {},
  Map<String, String> constants = const {},
  int? nodeFlags,
  Set<String>? imports,
}) {
  final signature = kLvPrimSignatures[op]!.single;
  final ports = [for (var i = 0; i < signature.length; i++) 100 + i];
  final inputs = <LvPrimTerminal>[], outputs = <LvPrimTerminal>[];
  final memberNames = <int, String>{};
  for (var i = 0; i < signature.length; i++) {
    final spec = signature.terminals[i];
    final label = labels[spec.name] ?? (spec.labels.isEmpty ? null : spec.labels.first);
    if (label != null) memberNames[ports[i]] = label;
    final expression = wired[spec.name];
    if (expression == null) continue;
    final type = types[spec.name] ?? _i32;
    final terminal = LvPrimTerminal(
      port: ports[i],
      type: type,
      roleFlags: spec.isInput ? 0 : 1,
      expression: expression,
      memberName: label,
      constantText: constants[spec.name],
    );
    (spec.isInput ? inputs : outputs).add(terminal);
  }
  return LvPrimCall(
    op: op,
    classCode: 0x2f,
    inputs: inputs,
    outputs: outputs,
    outputPorts: [
      for (var i = 0; i < signature.length; i++)
        if (!signature.terminals[i].isInput || !wired.containsKey(signature.terminals[i].name)) ports[i],
    ],
    ports: ports,
    portMemberName: memberNames,
    portRoleFlags: {for (var i = 0; i < signature.length; i++) ports[i]: signature.terminals[i].isInput ? 0 : 1},
    portDrawnTop: const {},
    requireImport: (import) => imports?.add(import),
    names: LvNaming(),
    nodeFlags: nodeFlags,
  );
}

final LvWireType _string = mapLvWireType(const ViSignalType(0x0230));
final LvWireType _i32 = mapLvWireType(const ViSignalType(0x0103));
final LvWireType _u16 = mapLvWireType(const ViSignalType(0x0106));
final LvWireType _bool = mapLvWireType(const ViSignalType(0x0121));
final LvWireType _path = mapLvWireType(const ViSignalType(0x0232));
final LvWireType _error = LvWireType.scalarOf(const LvTypeMapping.mapped(LvCarrier.error));
final LvWireType _refnum = LvWireType.scalarOf(const LvTypeMapping.mapped(LvCarrier.refnum));
final LvWireType _variant = LvWireType.scalarOf(const LvTypeMapping.mapped(LvCarrier.variant));

void main() {
  test('Strip Path binds the outputs its signature names and refuses a non-path', () {
    expect(
      lvPrimLowering(
        _call(
          PrimOp.stripPath,
          {'path': 'p', 'stripped path': 'dir', 'name': 'leaf'},
          types: {
            'path': _path,
            'stripped path': _path,
            'name': _string,
          },
        ),
      ),
      ['final (strippedPath: LvPath dir, name: String leaf) = lvStripPath(p);'],
    );
    expect(
      lvPrimLowering(_call(PrimOp.stripPath, {'path': 'p', 'name': 'leaf'}, types: {'path': _path, 'name': _string})),
      [
        'final (strippedPath: _, name: String leaf) = lvStripPath(p);',
      ],
    );
    final wrong = _call(PrimOp.stripPath, {'path': 'p', 'name': 'leaf'}, types: {'path': _string, 'name': _string});
    expect(lvPrimLowering(wrong), isNull);
    expect(wrong.refusal, contains('"path" terminal carrying String'));
  });

  test('Search and Replace String takes its defaults from the signature and its regex option from the node', () {
    final imports = <String>{};
    final plain = _call(
      PrimOp.searchAndReplaceString,
      {'input string': 's', 'search string': 'needle', 'result string': 'out'},
      types: {'input string': _string, 'search string': _string, 'result string': _string},
      imports: imports,
    );
    expect(lvPrimLowering(plain), [
      "final (result: String out, replacements: _, offsetPastReplacement: _) = lvSearchAndReplaceString(s, needle, '', "
          'offset: 0, replaceAll: false, ignoreCase: false, multiline: false);',
    ]);
    expect(imports, contains(kLvRuntimeImport));
    final regex = _call(
      PrimOp.searchAndReplaceString,
      {'input string': 's', 'search string': 'needle', 'replace all?': 'all', 'number of replacements': 'n'},
      types: {'input string': _string, 'search string': _string, 'replace all?': _bool, 'number of replacements': _i32},
      nodeFlags: kLvSearchReplaceRegularExpressionBit,
    );
    expect(lvPrimLowering(regex), [
      "final (result: _, replacements: int n, offsetPastReplacement: _) = lvSearchAndReplaceString(s, needle, '', "
          'offset: 0, replaceAll: all, ignoreCase: false, multiline: false, regularExpression: true);',
    ]);
  });

  test('a labelled terminal drawn with another label is a revision with another order and refuses', () {
    final call = _call(
      PrimOp.fileDialog,
      {'prompt': 'p', 'selected path': 'chosen'},
      types: {'prompt': _string, 'selected path': _path},
      labels: {'prompt': 'pattern (all files)'},
    );
    expect(lvPrimLowering(call), isNull);
    expect(call.refusal, contains('another terminal order'));
  });

  test('Enqueue Element runs for its effect and reads the queue back as the same refnum', () {
    final call = _call(
      PrimOp.enqueueElement,
      {'queue': 'q', 'element': 'x', 'queue out': 'q2', 'error out': 'e'},
      types: {'queue': _refnum, 'element': _string, 'queue out': _refnum, 'error out': _error},
    );
    expect(lvPrimLowering(call), [
      'final LvRefnum q2 = q;',
      'final (errorOut: LvError e, timedOut: _) = LvQueue.enqueue<String>(q, x, timeoutMs: -1, errorIn: LvError.none);',
    ]);
    final silent = _call(
      PrimOp.enqueueElement,
      {'queue': 'q', 'element': 'x'},
      types: {'queue': _refnum, 'element': _string},
    );
    expect(lvPrimLowering(silent), ['LvQueue.enqueue<String>(q, x, timeoutMs: -1, errorIn: LvError.none);']);
    expect(lvPrimHasSideEffect(op: PrimOp.enqueueElement, classCode: 0x2f), isTrue);
    expect(lvPrimHasSideEffect(op: PrimOp.stripPath, classCode: 0x2f), isFalse);
  });

  test('Variant To Data takes its type from the data wire and spells that type\'s default', () {
    final call = _call(
      PrimOp.variantToData,
      {'variant': 'v', 'data': 'n', 'error out': 'e'},
      types: {'variant': _variant, 'data': _i32, 'error out': _error},
    );
    expect(lvPrimLowering(call), [
      'final (data: int n, errorOut: LvError e) = lvVariantToData<int>(v, defaultValue: 0, errorIn: LvError.none);',
    ]);
  });

  test('the primitives the corpus does not decide stay without a rule', () {
    for (final op in [PrimOp.inRangeAndCoerce, PrimOp.booleanArrayToNumber, PrimOp.flattenedStringToVariant]) {
      expect(kLvMappedPrimOps, isNot(contains(op)), reason: op.opName);
    }
    final split = _call(
      PrimOp.searchSplitString,
      {'string': 's', 'substring before match': 'b'},
      types: {'string': _string, 'substring before match': _string},
      nodeFlags: kLvSearchSplitOptionBit,
    );
    expect(lvPrimLowering(split), isNull);
    expect(split.refusal, contains('0x1000000'));
  });

  test('a seam operation passes every input in signature order and reads outputs back by slot', () {
    final call = _call(
      PrimOp.tcpOpenConnection,
      {'address': 'host', 'remote port': 'port', 'connection ID': 'id', 'error out': 'e'},
      types: {'address': _string, 'remote port': _u16, 'connection ID': _refnum, 'error out': _error},
    );
    expect(lvPrimLowering(call), [
      "final value = lvEnvironment.session('TCP Open Connection', <Object?>[0, LvError.none, 60000, port, host]);",
      'final LvError e = value[0] as LvError;',
      'final LvRefnum id = value[1] as LvRefnum;',
    ]);
  });

  test('a float function wired to an integer output refuses instead of spelling a value', () {
    final call = _call(PrimOp.squareRoot, {'x': 'a', 'sqrt(x)': 'r'}, types: {'x': _i32, 'sqrt(x)': _i32});
    expect(lvPrimLowering(call), isNull);
    expect(call.refusal, contains('a floating-point number'));
    final sgl = mapLvWireType(const ViSignalType(0x0109));
    final imports = <String>{};
    expect(
      lvPrimLowering(
        _call(PrimOp.sine, {'x': 'a', 'sin(x)': 'r'}, types: {'x': _i32, 'sin(x)': sgl}, imports: imports),
      ),
      [
        'final double r = (Float32List(1)..[0] = lvSine(a))[0];',
      ],
    );
    expect(imports, contains('dart:typed_data'));
    final square = _call(
      PrimOp.square,
      {'x': 'a', 'x^2': 'r'},
      types: {'x': _i32, 'x^2': mapLvWireType(const ViSignalType(0x010a))},
    );
    expect(lvPrimLowering(square), isNull);
  });

  test('To Variant records the numeric representation of a number', () {
    expect(
      lvPrimLowering(
        _call(PrimOp.toVariant, {'anything': 'n', 'variant': 'v'}, types: {'anything': _i32, 'variant': _variant}),
      ),
      [
        'final LvVariant v = lvToVariant(n, numeric: LvNumericType.i32);',
      ],
    );
    expect(
      lvPrimLowering(
        _call(PrimOp.toVariant, {'anything': 's', 'variant': 'v'}, types: {'anything': _string, 'variant': _variant}),
      ),
      [
        'final LvVariant v = lvToVariant(s);',
      ],
    );
  });

  test('a spreadsheet function needs its format wired and spells integers by it', () {
    final i32Array = mapLvWireType(const ViSignalType(0x0203));
    final unwired = _call(
      PrimOp.arrayToSpreadsheetString,
      {'array': 'a', 'spreadsheet string': 'out'},
      types: {
        'array': i32Array,
        'spreadsheet string': _string,
      },
    );
    expect(lvPrimLowering(unwired), isNull);
    expect(unwired.refusal, contains('format string unwired'));
    final hex = _call(
      PrimOp.arrayToSpreadsheetString,
      {'array': 'a', 'format string': '\'%04X\'', 'spreadsheet string': 'out'},
      types: {'array': i32Array, 'format string': _string, 'spreadsheet string': _string},
      constants: {'format string': '%04X'},
    );
    expect(lvPrimLowering(hex), [
      "final String out = lvArrayToSpreadsheetString([a], (value) => lvFormatRadix(value as int, 16, 32, width: 4, zeroPad: true, upper: true), delimiter: '\\t');",
    ]);
  });

  test('Register For Events names each event source by its terminal label', () {
    final refnum = _refnum, error = _error;
    final call = LvPrimCall(
      op: null,
      classCode: LvNodeClass.registerForEvents.code,
      inputs: [LvPrimTerminal(port: 5, type: refnum, roleFlags: 0, expression: 'source')],
      outputs: [LvPrimTerminal(port: 2, type: refnum, roleFlags: 0x40001, expression: 'registration')],
      outputPorts: const [1, 2, 3, 4],
      ports: const [1, 2, 3, 4, 5],
      portRoleFlags: const {1: 0x10000, 2: 0x40001, 3: 0x20000, 4: 0x80001, 5: 0},
      portMemberName: const {5: 'Stop Event'},
      portDrawnTop: const {},
      requireImport: (_) {},
      names: LvNaming(),
      nodeFlags: null,
    );
    expect(error.isErrorCluster, isTrue);
    expect(lvPrimLowering(call), [
      "final value = lvRegisterForEvents(<LvRefnum>[source], events: <String>['Stop Event'], existing: LvRefnum.none, errorIn: LvError.none);",
      'final LvRefnum registration = value.registration;',
    ]);
  });
}
