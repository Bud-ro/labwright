import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'format_string.dart';
import 'naming.dart';
import 'numeric.dart';
import 'prim_map.dart';
import 'prim_signatures.dart';
import 'runtime.dart';
import 'type_map.dart';
import 'wire_type.dart';

/// A call read through its primitive's signature: terminals by name, with the labels the node
/// carries checked against the ones the signature lists.
class LvSignedCall {
  LvSignedCall._(this.call, this.signature);

  final LvPrimCall call;

  final LvPrimSignature signature;

  /// The call read through the signature its op and holder count select, or null (with the
  /// reason on the call) when none fits or a labelled terminal carries another label.
  static LvSignedCall? of(LvPrimCall call) {
    final op = call.op;
    if (op == null) return null;
    final signature = LvPrimSignature.of(op, call.ports.length);
    if (signature == null) {
      return call.refuse(
        'primitive ${op.opName} (primResID ${op.id}) is drawn with ${call.ports.length} terminals, a shape '
        'whose terminal order the corpus does not pin',
      );
    }
    for (var i = 0; i < signature.length; i++) {
      final spec = signature.terminals[i];
      final label = call.portMemberName[call.ports[i]];
      if (spec.labels.isNotEmpty && label != null && !spec.labels.contains(label)) {
        return call.refuse(
          'primitive ${op.opName} (primResID ${op.id}) labels terminal $i "$label" where its '
          'signature places "${spec.name}", so this node is drawn from a revision with another terminal order',
        );
      }
    }
    return LvSignedCall._(call, signature);
  }

  int _port(String name) => call.ports[signature.indexOf(name)];

  LvPrimTerminalSpec spec(String name) => signature.terminals[signature.indexOf(name)];

  /// The wired input named [name], or null when it is unwired.
  LvPrimTerminal? input(String name) {
    final port = _port(name);
    for (final terminal in call.inputs) {
      if (terminal.port == port) return terminal;
    }
    return null;
  }

  /// The consumed output named [name], or null when nothing reads it.
  LvPrimTerminal? output(String name) {
    final port = _port(name);
    for (final terminal in call.outputs) {
      if (terminal.port == port) return terminal;
    }
    return null;
  }

  /// The expression an input takes: its wire, else its default; null when it is unwired and
  /// has none (the call is refused).
  String? arg(String name) {
    final wired = input(name);
    if (wired != null) return wired.expression;
    final fallback = spec(name).defaultText;
    if (fallback == null) {
      call.refuse(
        'primitive ${call.op!.opName} (primResID ${call.op!.id}) has its "$name" terminal unwired, and '
        'the value LabVIEW takes then is not decoded',
      );
      return null;
    }
    if (fallback.startsWith('Lv') || fallback.startsWith('const Lv')) call.requireImport(kLvRuntimeImport);
    return fallback;
  }

  /// The local a consumed output binds to, or `_` when nothing reads it.
  String target(String name) => output(name)?.expression ?? '_';

  bool consumed(String name) => output(name) != null;

  bool get anyConsumed => call.outputs.isNotEmpty;

  /// Declines because [name] carries a [type] the lowering does not take.
  Null typeRefusal(String name, LvWireType type, String wanted) => call.refuse(
    'primitive ${call.op!.opName} (primResID ${call.op!.id}) has its "$name" terminal carrying '
    '${type.dartType ?? '?'} at ${type.dims} dimensions, and the lowering takes $wanted there',
  );

  Null refuse(String detail) => call.refuse('primitive ${call.op!.opName} (primResID ${call.op!.id}) $detail');
}

bool _isText(LvWireType type) => type.dims == 0 && type.carrier == LvCarrier.text;

bool _isBool(LvWireType type) => type.dims == 0 && type.carrier == LvCarrier.boolean;

bool _isInt(LvWireType type) => type.dims == 0 && type.numeric != null && !type.numeric!.isFloat;

bool _isFloat(LvWireType type) => type.dims == 0 && (type.numeric?.isFloat ?? false);

bool _isNumber(LvWireType type) => type.dims == 0 && type.numeric != null;

bool _isPath(LvWireType type) => type.dims == 0 && type.carrier == LvCarrier.path;

bool _isRefnum(LvWireType type) => type.dims == 0 && type.carrier == LvCarrier.refnum;

bool _isVariant(LvWireType type) => type.dims == 0 && type.carrier == LvCarrier.variant;

bool _isTimestamp(LvWireType type) => type.dims == 0 && type.carrier == LvCarrier.timestamp;

bool _isError(LvWireType type) => type.isErrorCluster;

bool _is1d(LvWireType type) => type.dims == 1;

bool _hazardous(LvWireType type, String operator) =>
    type.numeric?.hazards.any((hazard) => hazard.operators.contains(operator)) ?? false;

/// Checks each wired input in [checks] against its predicate, refusing on the first miss.
bool _inputsAre(LvSignedCall sig, Map<String, (bool Function(LvWireType), String)> checks) {
  for (final MapEntry(key: name, value: (test, wanted)) in checks.entries) {
    final terminal = sig.input(name);
    if (terminal != null && !test(terminal.type)) {
      sig.typeRefusal(name, terminal.type, wanted);
      return false;
    }
  }
  return true;
}

bool _outputsAre(LvSignedCall sig, Map<String, (bool Function(LvWireType), String)> checks) {
  for (final MapEntry(key: name, value: (test, wanted)) in checks.entries) {
    final terminal = sig.output(name);
    if (terminal != null && !test(terminal.type)) {
      sig.typeRefusal(name, terminal.type, wanted);
      return false;
    }
  }
  return true;
}

/// `final (a: x, b: _) = expr;`, or `expr;` when nothing is read and [sideEffect].
List<String> _bindFields(
  LvSignedCall sig,
  String expression,
  List<(String field, String terminal)> fields, {
  bool sideEffect = true,
}) {
  final consumed = fields.where((field) => sig.consumed(field.$2)).toList();
  if (consumed.isEmpty) return sideEffect ? ['$expression;'] : const [];
  final patterns = [
    for (final (field, terminal) in fields)
      '$field: ${sig.consumed(terminal) ? '${sig.output(terminal)!.type.dartType} ${sig.target(terminal)}' : '_'}',
  ];
  return ['final (${patterns.join(', ')}) = $expression;'];
}

List<String> _bindSingle(LvSignedCall sig, String terminal, String expression, {bool sideEffect = true}) {
  final out = sig.output(terminal);
  if (out == null) return sideEffect ? ['$expression;'] : const [];
  return ['final ${out.type.dartType} ${out.expression} = $expression;'];
}

List<String>? _unaryRuntime(
  LvPrimCall call,
  String input,
  String output,
  bool Function(LvWireType) accepts,
  String wanted,
  bool Function(LvWireType) produces,
  String produced,
  String Function(String operand, LvPrimTerminal source, LvPrimTerminal out) body, {
  bool runtime = true,
}) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final source = sig.input(input);
  if (source == null) return sig.refuse('has its "$input" terminal unwired');
  if (!accepts(source.type)) return sig.typeRefusal(input, source.type, wanted);
  final out = sig.output(output);
  if (out == null) return const [];
  if (!produces(out.type)) return sig.typeRefusal(output, out.type, produced);
  if (runtime) call.requireImport(kLvRuntimeImport);
  if (out.type.numeric == LvNumericKind.sgl) call.requireImport('dart:typed_data');
  return ['final ${out.type.dartType} ${out.expression} = ${body(source.expression!, source, out)};'];
}

// Numeric and comparison.

List<String>? _orderedBySignature(LvPrimCall call, String operator, {bool predicate = false}) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final x = sig.input('x'), y = sig.input('y');
  if (x == null || y == null) return sig.refuse('has an operand unwired');
  final out = call.outputs.singleOrNull;
  if (out == null) return const [];
  for (final operand in [x, y]) {
    if (!_isNumber(operand.type)) return sig.typeRefusal(operand == x ? 'x' : 'y', operand.type, 'a scalar number');
    if (_hazardous(operand.type, operator)) {
      return sig.refuse('compares or subtracts U64 operands, which Dart reads as signed');
    }
  }
  if (predicate) {
    if (!_isBool(out.type)) return sig.typeRefusal(sig.signature.terminals[0].name, out.type, 'a boolean');
    return ['final bool ${out.expression} = ${x.expression} $operator ${y.expression};'];
  }
  if (!_isNumber(out.type)) return sig.typeRefusal(sig.signature.terminals[0].name, out.type, 'a scalar number');
  return [
    'final ${out.type.dartType} ${out.expression} = ${lvWrapped(out.type, '${x.expression} $operator ${y.expression}')};',
  ];
}

List<String>? _divideBySignature(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final x = sig.input('x'), y = sig.input('y');
  if (x == null || y == null) return sig.refuse('has an operand unwired');
  final out = call.outputs.singleOrNull;
  if (out == null) return const [];
  if (!_isFloat(out.type)) return sig.typeRefusal('x/y', out.type, 'a floating-point number');
  for (final operand in [x, y]) {
    if (!_isNumber(operand.type)) return sig.typeRefusal(operand == x ? 'x' : 'y', operand.type, 'a scalar number');
    if (_hazardous(operand.type, 'toDouble')) return sig.refuse('divides a U64 operand, which Dart reads as signed');
  }
  String widened(LvPrimTerminal operand) =>
      operand.type.numeric!.isFloat ? operand.expression! : '${operand.expression}.toDouble()';
  if (out.type.numeric == LvNumericKind.sgl) call.requireImport('dart:typed_data');
  return ['final double ${out.expression} = ${lvWrapped(out.type, '${widened(x)} / ${widened(y)}')};'];
}

List<String>? _quotientRemainderBySignature(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final x = sig.input('x'), y = sig.input('y');
  if (x == null || y == null) return sig.refuse('has an operand unwired');
  final quotient = sig.output('floor(x/y)'), remainder = sig.output('x-y*floor(x/y)');
  if (quotient == null && remainder == null) return const [];
  for (final terminal in [x, y, quotient, remainder]) {
    if (terminal == null) continue;
    if (!_isNumber(terminal.type)) return sig.typeRefusal('x', terminal.type, 'a scalar number');
    if (_hazardous(terminal.type, '~/')) return sig.refuse('divides U64 operands, which Dart reads as signed');
  }
  final float = [x, y].any((operand) => operand.type.numeric!.isFloat);
  call.requireImport(kLvRuntimeImport);
  String widened(LvPrimTerminal operand) =>
      operand.type.numeric!.isFloat ? operand.expression! : '${operand.expression}.toDouble()';
  final body = float
      ? '${LvRuntimeCall.quotientRemainderFloat}(${widened(x)}, ${widened(y)})'
      : '${LvRuntimeCall.quotientRemainderInt}(${x.expression}, ${y.expression})';
  return ['final (${quotient?.expression ?? '_'}, ${remainder?.expression ?? '_'}) = $body;'];
}

List<String>? _maxAndMin(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final x = sig.input('x'), y = sig.input('y');
  if (x == null || y == null) return sig.refuse('has an operand unwired');
  final max = sig.output('max(x, y)'), min = sig.output('min(x, y)');
  if (max == null && min == null) return const [];
  final String body;
  if (_isNumber(x.type) && _isNumber(y.type)) {
    if (_hazardous(x.type, '<') || _hazardous(y.type, '<')) {
      return sig.refuse('compares U64 operands, which Dart reads as signed');
    }
    body = '${LvRuntimeCall.maxAndMin}(${x.expression}, ${y.expression})';
  } else if (_isText(x.type) && _isText(y.type)) {
    body = '${LvRuntimeCall.maxAndMinComparable}(${x.expression}, ${y.expression})';
  } else {
    return sig.typeRefusal('x', x.type, 'scalar numbers or strings on both operands');
  }
  call.requireImport(kLvRuntimeImport);
  return ['final (${max?.expression ?? '_'}, ${min?.expression ?? '_'}) = $body;'];
}

List<String>? _floatFunction(LvPrimCall call, String runtimeCall) => _unaryRuntime(
  call,
  'x',
  LvPrimSignature.of(call.op!, call.ports.length)?.terminals.first.name ?? '',
  _isNumber,
  'a scalar number',
  _isFloat,
  'a floating-point number',
  (operand, source, out) => lvWrapped(out.type, '$runtimeCall($operand)'),
);

List<String>? _square(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final x = sig.input('x');
  if (x == null) return sig.refuse('has its "x" terminal unwired');
  if (!_isNumber(x.type)) return sig.typeRefusal('x', x.type, 'a scalar number');
  final out = sig.output('x^2');
  if (out == null) return const [];
  if (out.type.dartType != x.type.dartType) {
    return sig.typeRefusal('x^2', out.type, 'the representation of x, ${x.type.dartType}');
  }
  if (out.type.numeric == LvNumericKind.sgl) call.requireImport('dart:typed_data');
  return [
    'final ${out.type.dartType} ${out.expression} = ${lvWrapped(out.type, '${x.expression} * ${x.expression}')};',
  ];
}

List<String>? _powerOfX(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final x = sig.input('x'), y = sig.input('y');
  if (x == null || y == null) return sig.refuse('has an operand unwired');
  if (!_isNumber(x.type) || !_isNumber(y.type)) return sig.typeRefusal('x', x.type, 'scalar numbers');
  final out = sig.output('x^y');
  if (out == null) return const [];
  if (!_isFloat(out.type)) return sig.typeRefusal('x^y', out.type, 'a floating-point number');
  call.requireImport(kLvRuntimeImport);
  return ['final double ${out.expression} = ${LvRuntimeCall.powerOfX}(${x.expression}, ${y.expression});'];
}

List<String>? _booleanToZeroOne(LvPrimCall call) => _unaryRuntime(
  call,
  'Boolean',
  '0, 1',
  _isBool,
  'a boolean',
  _isInt,
  'an integer',
  (operand, source, out) => '($operand ? 1 : 0)',
  runtime: false,
);

List<String>? _numberToBooleanArray(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final number = sig.input('number');
  if (number == null) return sig.refuse('has its "number" terminal unwired');
  if (!_isInt(number.type)) return sig.typeRefusal('number', number.type, 'an integer');
  final out = sig.output('Boolean array');
  if (out == null) return const [];
  if (!_is1d(out.type) || out.type.element.carrier != LvCarrier.boolean) {
    return sig.typeRefusal('Boolean array', out.type, 'a 1-D boolean array');
  }
  call.requireImport(kLvRuntimeImport);
  return [
    'final ${out.type.dartType} ${out.expression} = '
        '${LvRuntimeCall.numberToBooleanArray}(${number.expression}, ${number.type.numeric!.bits});',
  ];
}

// Strings.

List<String>? _toUpperCase(LvPrimCall call) => _unaryRuntime(
  call,
  'string',
  'all upper case string',
  _isText,
  'a string',
  _isText,
  'a string',
  (operand, source, out) => '${LvRuntimeCall.toUpperCase}($operand)',
);

List<String>? _reverseString(LvPrimCall call) => _unaryRuntime(
  call,
  'string',
  'reversed',
  _isText,
  'a string',
  _isText,
  'a string',
  (operand, source, out) => '${LvRuntimeCall.reverseString}($operand)',
);

List<String>? _numberToDecimalString(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final number = sig.input('number');
  if (number == null) return sig.refuse('has its "number" terminal unwired');
  if (!_inputsAre(sig, {'width': (_isInt, 'an integer')})) return null;
  final out = sig.output('decimal integer string');
  if (out == null) return const [];
  if (!_isText(out.type)) return sig.typeRefusal('decimal integer string', out.type, 'a string');
  final String value;
  if (_isInt(number.type)) {
    value = number.expression!;
  } else if (_isFloat(number.type)) {
    call.requireImport(kLvRuntimeImport);
    value = '${LvRuntimeCall.roundToInteger}(${number.expression}, 64, signed: true)';
  } else {
    return sig.typeRefusal('number', number.type, 'a scalar number');
  }
  final width = sig.input('width')?.expression;
  final runtimeCall = number.type.numeric == LvNumericKind.u64
      ? LvRuntimeCall.numberToDecimalStringU64
      : LvRuntimeCall.numberToDecimalString;
  call.requireImport(kLvRuntimeImport);
  return ['final String ${out.expression} = $runtimeCall($value${width == null ? '' : ', $width'});'];
}

List<String>? _stringToNumber(LvPrimCall call, String runtimeCall, {required bool defaultSigned}) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final string = sig.input('string');
  if (string == null) return sig.refuse('has its "string" terminal unwired');
  if (!_isText(string.type)) return sig.typeRefusal('string', string.type, 'a string');
  if (!_inputsAre(sig, {'offset': (_isInt, 'an integer'), 'default': (_isInt, 'an integer')})) return null;
  final number = sig.output('number'), past = sig.output('offset past number');
  if (number == null && past == null) return const [];
  final fallback = sig.input('default');
  final kind = number?.type.numeric ?? fallback?.type.numeric;
  if (number != null && !_isInt(number.type)) return sig.typeRefusal('number', number.type, 'an integer');
  if (past != null && !_isInt(past.type)) return sig.typeRefusal('offset past number', past.type, 'an integer');
  final offset = sig.arg('offset');
  if (offset == null) return null;
  final bits = kind?.bits ?? 32, signed = kind?.signed ?? defaultSigned;
  final arguments = [
    string.expression,
    offset,
    if (fallback != null) 'defaultValue: ${fallback.expression}',
    'bits: $bits',
    'signed: $signed',
  ];
  call.requireImport(kLvRuntimeImport);
  return [
    'final (offsetPastNumber: ${past?.expression ?? '_'}, number: ${number?.expression ?? '_'}) = '
        '$runtimeCall(${arguments.join(', ')});',
  ];
}

List<String>? _fractExpStringToNumber(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final string = sig.input('string');
  if (string == null) return sig.refuse('has its "string" terminal unwired');
  if (!_isText(string.type)) return sig.typeRefusal('string', string.type, 'a string');
  if (!_inputsAre(sig, {'offset': (_isInt, 'an integer'), 'default': (_isFloat, 'a floating-point number')})) {
    return null;
  }
  if (sig.input('use system decimal point') != null) {
    return sig.refuse('has "use system decimal point" wired, and the system decimal point is not modelled');
  }
  final number = sig.output('number'), past = sig.output('offset past number');
  if (number == null && past == null) return const [];
  if (number != null && !_isFloat(number.type)) {
    return sig.typeRefusal('number', number.type, 'a floating-point number');
  }
  final offset = sig.arg('offset');
  if (offset == null) return null;
  final fallback = sig.input('default');
  call.requireImport(kLvRuntimeImport);
  return [
    'final (offsetPastNumber: ${past?.expression ?? '_'}, number: ${number?.expression ?? '_'}) = '
        '${LvRuntimeCall.fractExpStringToNumber}(${string.expression}, $offset'
        '${fallback == null ? '' : ', defaultValue: ${fallback.expression}'});',
  ];
}

List<String>? _numberToFractionalString(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final number = sig.input('number');
  if (number == null) return sig.refuse('has its "number" terminal unwired');
  if (!_isNumber(number.type)) return sig.typeRefusal('number', number.type, 'a scalar number');
  if (!_inputsAre(sig, {'width': (_isInt, 'an integer'), 'precision': (_isInt, 'an integer')})) return null;
  if (sig.input('use system decimal point') != null) {
    return sig.refuse('has "use system decimal point" wired, and the system decimal point is not modelled');
  }
  final out = sig.output('F-format string');
  if (out == null) return const [];
  final precision = sig.arg('precision');
  if (precision == null) return null;
  final width = sig.input('width')?.expression;
  final value = number.type.numeric!.isFloat ? number.expression! : '${number.expression}.toDouble()';
  call.requireImport(kLvRuntimeImport);
  return [
    'final String ${out.expression} = '
        '${LvRuntimeCall.formatFixed}($value, $precision${width == null ? '' : ', width: $width'});',
  ];
}

List<String>? _pickLine(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final lines = sig.input('multi-line string'), index = sig.input('line index');
  if (lines == null || index == null) return sig.refuse('has its multi-line string or line index unwired');
  if (!_inputsAre(sig, {
    'string': (_isText, 'a string'),
    'multi-line string': (_isText, 'a string'),
    'line index': (_isInt, 'an integer'),
  })) {
    return null;
  }
  final out = sig.output('output string');
  if (out == null) return const [];
  final string = sig.arg('string');
  if (string == null) return null;
  call.requireImport(kLvRuntimeImport);
  return [
    'final String ${out.expression} = ${LvRuntimeCall.pickLine}($string, ${lines.expression}, ${index.expression});',
  ];
}

/// The node option bit Search/Split String carries in the corpus, whose meaning (Regular
/// Expression or Match Single Character) is not decoded.
const int kLvSearchSplitOptionBit = 0x1000000;

List<String>? _searchSplitString(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  if ((call.nodeFlags ?? 0) & kLvSearchSplitOptionBit != 0) {
    return sig.refuse(
      'carries node option bit 0x${kLvSearchSplitOptionBit.toRadixString(16)}, and which of its two options '
      '(Regular Expression, Match Single Character) the bit selects is not decoded',
    );
  }
  final string = sig.input('string');
  if (string == null) return sig.refuse('has its "string" terminal unwired');
  if (!_inputsAre(sig, {
    'string': (_isText, 'a string'),
    'search string/char': (_isText, 'a string'),
    'offset': (_isInt, 'an integer'),
  })) {
    return null;
  }
  if (!_outputsAre(sig, {
    'substring before match': (_isText, 'a string'),
    'match + rest of string': (_isText, 'a string'),
    'offset of match': (_isInt, 'an integer'),
  })) {
    return null;
  }
  final search = sig.arg('search string/char'), offset = sig.arg('offset');
  if (search == null || offset == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(
    sig,
    '${LvRuntimeCall.searchSplitString}(${string.expression}, $search, $offset)',
    [
      ('before', 'substring before match'),
      ('matchAndRest', 'match + rest of string'),
      ('offsetOfMatch', 'offset of match'),
    ],
    sideEffect: false,
  );
}

/// Search and Replace String's Regular Expression option: set, the search string is a regular
/// expression and the `multiline?` terminal is shown.
const int kLvSearchReplaceRegularExpressionBit = 0x2000000;

List<String>? _searchAndReplaceString(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final input = sig.input('input string'), search = sig.input('search string');
  if (input == null || search == null) return sig.refuse('has its input string or search string unwired');
  if (!_inputsAre(sig, {
    'input string': (_isText, 'a string'),
    'search string': (_isText, 'a string'),
    'replace string': (_isText, 'a string'),
    'offset': (_isInt, 'an integer'),
    'replace all?': (_isBool, 'a boolean'),
    'ignore case?': (_isBool, 'a boolean'),
    'multiline?': (_isBool, 'a boolean'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  if (!_outputsAre(sig, {
    'result string': (_isText, 'a string'),
    'number of replacements': (_isInt, 'an integer'),
    'offset past replacement': (_isInt, 'an integer'),
    'error out': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  final replace = sig.arg('replace string'), offset = sig.arg('offset');
  final replaceAll = sig.arg('replace all?'), ignoreCase = sig.arg('ignore case?'), multiline = sig.arg('multiline?');
  final errorIn = sig.arg('error in');
  if (replace == null || offset == null || replaceAll == null || ignoreCase == null || multiline == null) return null;
  if (errorIn == null) return null;
  final regex = (call.nodeFlags ?? 0) & kLvSearchReplaceRegularExpressionBit != 0;
  final lines = <String>[];
  if (sig.consumed('error out')) {
    lines.add('final ${LvRuntimeType.error} ${sig.target('error out')} = $errorIn;');
  }
  final arguments = [
    input.expression,
    search.expression,
    replace,
    'offset: $offset',
    'replaceAll: $replaceAll',
    'ignoreCase: $ignoreCase',
    'multiline: $multiline',
    if (regex) 'regularExpression: true',
  ];
  call.requireImport(kLvRuntimeImport);
  lines.addAll(
    _bindFields(
      sig,
      '${LvRuntimeCall.searchAndReplaceString}(${arguments.join(', ')})',
      [
        ('result', 'result string'),
        ('replacements', 'number of replacements'),
        ('offsetPastReplacement', 'offset past replacement'),
      ],
      sideEffect: false,
    ),
  );
  return lines;
}

/// The one specifier of a spreadsheet function's format string, a diagram constant; null (with
/// the call refused) when the string is unwired, not a constant, or not a single specifier this
/// lowering spells. An unwired format string's default is not stated by the reference.
LvFormatSpecifier? _spreadsheetSpecifier(LvSignedCall sig) {
  final format = sig.input('format string');
  if (format == null) {
    return sig.refuse('has its format string unwired, and the default the function takes then is not decoded');
  }
  final text = format.constantText;
  if (text == null) {
    return sig.refuse('has a format string that is not a diagram constant, so its conversion is not decided here');
  }
  final pieces = lvFormatPieces(text);
  final specifiers = pieces?.whereType<LvFormatSpecifier>().toList();
  if (pieces == null || specifiers!.length != 1 || pieces.length != 1) {
    return sig.refuse('has the format string "$text", which is not one specifier this lowering spells');
  }
  return specifiers.single;
}

List<String>? _spreadsheetStringToArray(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final string = sig.input('spreadsheet string');
  if (string == null) return sig.refuse('has its "spreadsheet string" terminal unwired');
  if (!_inputsAre(sig, {
    'spreadsheet string': (_isText, 'a string'),
    'format string': (_isText, 'a string'),
  })) {
    return null;
  }
  final out = sig.output('array');
  if (out == null) return const [];
  final element = out.type.element;
  final specifier = _spreadsheetSpecifier(sig);
  if (specifier == null) return null;
  final format = switch ((specifier.conversion, element.carrier)) {
    (LvFormatConversion.text, LvCarrier.text) => 'LvSpreadsheetFormat.text',
    (LvFormatConversion.decimal, LvCarrier.integer) => 'LvSpreadsheetFormat.integer',
    (LvFormatConversion.fixed, LvCarrier.float) => 'LvSpreadsheetFormat.float',
    _ => null,
  };
  if (format == null) {
    return sig.refuse(
      'converts with ${specifier.conversion.name} into an array of ${element.dartType}, a pairing not decided here',
    );
  }
  final delimiter = sig.input('delimiter');
  final String delimiters;
  if (delimiter == null) {
    delimiters = '';
  } else if (_isText(delimiter.type)) {
    delimiters = ', delimiters: [${delimiter.expression}]';
  } else if (_is1d(delimiter.type) && delimiter.type.element.carrier == LvCarrier.text) {
    delimiters = ', delimiters: ${delimiter.expression}';
  } else {
    return sig.typeRefusal('delimiter', delimiter.type, 'a string or a 1-D array of strings');
  }
  call.requireImport(kLvRuntimeImport);
  final rows = call.names.role(LvNameRole.value);
  final lines = [
    'final $rows = ${LvRuntimeCall.spreadsheetStringToRows}(${string.expression}, $format$delimiters);',
  ];
  final elementType = element.dartType!;
  switch (out.type.dims) {
    case 1:
      if (element.numeric != null) call.requireImport('dart:typed_data');
      final row = '$rows.rows.isEmpty ? const <$elementType>[] : $rows.rows.first.cast<$elementType>()';
      lines.add('final ${out.type.dartType} ${out.expression} = ${lvArrayFreeze(element, '($row)')};');
    case 2:
      call.requireImport('dart:typed_data');
      final zero = switch (element.carrier) {
        LvCarrier.text => "''",
        LvCarrier.integer => '0',
        _ => '0.0',
      };
      final flat = call.names.role(LvNameRole.builder);
      lines
        ..add('final $flat = <$elementType>[')
        ..add('  for (final row in $rows.rows)')
        ..add('    for (var column = 0; column < $rows.columns; column++)')
        ..add('      column < row.length ? row[column] as $elementType : $zero,')
        ..add('];')
        ..add(
          'final ${out.type.dartType} ${out.expression} = ${LvRuntimeType.arrayNd}(${lvArrayFreeze(element, flat)}, '
          'Uint32List.fromList([$rows.rows.length, $rows.columns]));',
        );
    case _:
      return sig.typeRefusal('array', out.type, 'a 1-D or 2-D array');
  }
  return lines;
}

List<String>? _arrayToSpreadsheetString(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final array = sig.input('array');
  if (array == null) return sig.refuse('has its "array" terminal unwired');
  if (!_inputsAre(sig, {'delimiter': (_isText, 'a string'), 'format string': (_isText, 'a string')})) return null;
  final out = sig.output('spreadsheet string');
  if (out == null) return const [];
  final specifier = _spreadsheetSpecifier(sig);
  if (specifier == null) return null;
  final spell = _elementSpell(sig, specifier, array.type);
  if (spell == null) return null;
  final delimiter = sig.arg('delimiter');
  if (delimiter == null) return null;
  final String rows;
  switch (array.type.dims) {
    case 1:
      rows = '[${array.expression}]';
    case 2:
      final grid = array.expression!;
      rows = '[for (var row = 0; row < $grid.outerLength; row++) $grid.rowAt(row)]';
    case _:
      return sig.typeRefusal('array', array.type, 'a 1-D or 2-D array');
  }
  call.requireImport(kLvRuntimeImport);
  return [
    'final String ${out.expression} = '
        '${LvRuntimeCall.arrayToSpreadsheetString}($rows, $spell, delimiter: $delimiter);',
  ];
}

/// How one element of [array] is spelled by a spreadsheet format's [spec], as Format Into String
/// spells it: `%s` a string, `%d` an integer, `%x`/`%X` an integer at its own width, `%f` a
/// float or integer, each with the specifier's width and flags.
String? _elementSpell(LvSignedCall sig, LvFormatSpecifier spec, LvWireType array) {
  final element = array.element;
  final kind = element.numeric;
  final padding = [
    if (spec.width case final width?) 'width: $width',
    if (spec.zeroPad) 'zeroPad: true',
    if (spec.leftJustify) 'leftJustify: true',
  ];
  final signing = [if (spec.plusSign) 'plusSign: true'];
  String call(String function, String value, List<String> named) =>
      '(value) => $function(${[value, ...named].join(', ')})';
  switch (spec.conversion) {
    case LvFormatConversion.text when element.carrier == LvCarrier.text && !spec.plusSign && !spec.zeroPad:
      return call(LvRuntimeCall.formatText, 'value as String', [
        ...padding,
        if (spec.precision case final precision?) 'maxLength: $precision',
      ]);
    case LvFormatConversion.decimal when kind != null && !kind.isFloat && spec.precision == null:
      if (kind.hazards.isNotEmpty) return sig.refuse('spells U64 elements, which Dart reads as signed');
      return call(LvRuntimeCall.formatInt, 'value as int', [...padding, ...signing]);
    case LvFormatConversion.hexadecimal || LvFormatConversion.hexadecimalUpper
        when kind != null && !kind.isFloat && spec.precision == null && !spec.plusSign:
      return call(LvRuntimeCall.formatRadix, 'value as int', [
        '16',
        '${kind.bits}',
        ...padding,
        if (spec.conversion == LvFormatConversion.hexadecimalUpper) 'upper: true',
      ]);
    case LvFormatConversion.fixed when kind != null:
      final value = kind.isFloat ? 'value as double' : '(value as int).toDouble()';
      return call(LvRuntimeCall.formatFixed, value, [
        '${spec.precision ?? kLvFormatDefaultPrecision}',
        ...padding,
        ...signing,
      ]);
    case _:
      return sig.refuse('spells ${element.dartType} elements with ${spec.conversion.name}, which is not decided here');
  }
}

List<String>? _flattenToString(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final anything = sig.input('anything');
  if (anything == null) return sig.refuse('has its "anything" terminal unwired');
  if (sig.consumed('type string (7.x only)')) {
    return sig.refuse('has its type string read, and the 7.x type descriptor of a Dart value is not produced here');
  }
  if (!_inputsAre(sig, {
    'byte order': (_isInt, 'an integer'),
    'prepend array or string size?': (_isBool, 'a boolean'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  if (sig.input('byte order') != null) {
    return sig.refuse('has its byte order wired, and only the big-endian default is spelled here');
  }
  final flat = _flatBytesOf(sig, anything, prepend: sig.arg('prepend array or string size?'));
  if (flat == null) return null;
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  final lines = <String>[];
  if (sig.consumed('error out')) lines.add('final ${LvRuntimeType.error} ${sig.target('error out')} = $errorIn;');
  final data = sig.output('data string');
  if (data != null) {
    call.requireImport(kLvRuntimeImport);
    lines.add('final String ${data.expression} = ${LvRuntimeCall.stringOfFlat}($flat);');
  }
  return lines;
}

/// The flat bytes of [operand] as Flatten To String writes them: a scalar number or boolean
/// unframed, a string or a 1-D numeric array with its size prefixed when [prepend]; other
/// types refuse.
String? _flatBytesOf(LvSignedCall sig, LvPrimTerminal operand, {required String? prepend}) {
  final type = operand.type;
  final kind = type.numeric;
  sig.call.requireImport(kLvRuntimeImport);
  if (type.dims == 0) {
    if (type.carrier == LvCarrier.boolean) return '${LvRuntimeCall.flatOfInt}(${operand.expression} ? 1 : 0, 8)';
    if (type.carrier == LvCarrier.text) {
      return '${LvRuntimeCall.flatOfString}(${operand.expression}, prependSize: $prepend)';
    }
    if (kind != null) {
      final flat = kind.isFloat ? LvRuntimeCall.flatOfFloat : LvRuntimeCall.flatOfInt;
      return '$flat(${operand.expression}, ${kind.bits})';
    }
    return sig.typeRefusal('anything', type, 'a number, boolean, string or 1-D numeric array');
  }
  if (type.dims == 1 && kind != null && !kind.isFloat) {
    return '${LvRuntimeCall.flatOfIntList}(${operand.expression}, ${kind.bits}, prependSize: $prepend)';
  }
  return sig.typeRefusal('anything', type, 'a number, boolean, string or 1-D numeric array');
}

List<String>? _flattenToJson(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final anything = sig.input('anything');
  if (anything == null) return sig.refuse('has its "anything" terminal unwired');
  if (!_inputsAre(sig, {'error in': (_isError, 'an error cluster')})) return null;
  final json = _jsonValueOf(sig, anything.type, anything.expression!);
  if (json == null) return null;
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  final lines = <String>[];
  if (sig.consumed('error out')) lines.add('final ${LvRuntimeType.error} ${sig.target('error out')} = $errorIn;');
  final out = sig.output('JSON string');
  if (out != null) {
    call.requireImport('dart:convert');
    lines.add('final String ${out.expression} = jsonEncode($json);');
  }
  return lines;
}

/// A JSON-encodable Dart expression for [type] as Flatten To JSON spells it: numbers, booleans
/// and strings as themselves, arrays as lists, clusters as maps of their member labels.
String? _jsonValueOf(LvSignedCall sig, LvWireType type, String expression) {
  if (type.dims > 1) return sig.typeRefusal('anything', type, 'scalars, 1-D arrays and clusters of them');
  if (type.dims == 1) {
    final element = LvWireType.scalarOf(type.element);
    final inner = _jsonValueOf(sig, element, 'element');
    if (inner == null) return null;
    return inner == 'element' ? expression : '[for (final element in $expression) $inner]';
  }
  switch (type.carrier) {
    case LvCarrier.boolean || LvCarrier.integer || LvCarrier.float || LvCarrier.text:
      return expression;
    case LvCarrier.nominal:
      final declaration = type.declarations.singleOrNull;
      if (declaration == null || declaration.isEnum) {
        return declaration == null ? sig.typeRefusal('anything', type, 'a JSON-encodable value') : '$expression.name';
      }
      final names = _memberNames(declaration.fields.map((field) => field.label).toList(), declaration: true);
      final entries = <String>[];
      for (var i = 0; i < declaration.fields.length; i++) {
        final member = _jsonValueOf(sig, LvWireType.scalarOf(declaration.fields[i].type), '$expression.${names[i]}');
        if (member == null) return null;
        entries.add("'${_jsonKey(declaration.fields[i].label ?? names[i])}': $member");
      }
      return '<String, Object?>{${entries.join(', ')}}';
    case LvCarrier.compound:
      if (type.value.fields.isEmpty) return sig.typeRefusal('anything', type, 'a JSON-encodable value');
      final names = _memberNames(type.value.fields.map((field) => field.label).toList(), declaration: false);
      if (names.any((name) => name.isEmpty)) {
        return sig.typeRefusal('anything', type, 'a cluster whose members are named');
      }
      final entries = <String>[];
      for (var i = 0; i < type.value.fields.length; i++) {
        final member = _jsonValueOf(sig, LvWireType.scalarOf(type.value.fields[i].type), '$expression.${names[i]}');
        if (member == null) return null;
        entries.add("'${_jsonKey(type.value.fields[i].label ?? names[i])}': $member");
      }
      return '<String, Object?>{${entries.join(', ')}}';
    case _:
      return sig.typeRefusal('anything', type, 'a JSON-encodable value');
  }
}

String _jsonKey(String label) => label.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$');

List<String> _memberNames(List<String?> labels, {required bool declaration}) =>
    declaration ? LvNaming.declarationFields(labels) : [for (final label in labels) lvFieldName(label ?? '')];

// Paths.

List<String>? _pathToString(LvPrimCall call) => _unaryRuntime(
  call,
  'path',
  'string',
  _isPath,
  'a path',
  _isText,
  'a string',
  (operand, source, out) => '${LvRuntimeCall.pathToString}($operand)',
);

List<String>? _stringToPath(LvPrimCall call) => _unaryRuntime(
  call,
  'string',
  'path',
  _isText,
  'a string',
  _isPath,
  'a path',
  (operand, source, out) => '${LvRuntimeCall.pathOfString}($operand)',
);

List<String>? _stripPath(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final path = sig.input('path');
  if (path == null) return sig.refuse('has its "path" terminal unwired');
  if (!_isPath(path.type)) return sig.typeRefusal('path', path.type, 'a path');
  if (!_outputsAre(sig, {'stripped path': (_isPath, 'a path'), 'name': (_isText, 'a string')})) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(sig, '${LvRuntimeCall.stripPath}(${path.expression})', [
    ('strippedPath', 'stripped path'),
    ('name', 'name'),
  ], sideEffect: false);
}

List<String>? _isPathAndNotEmpty(LvPrimCall call) => _unaryRuntime(
  call,
  'path',
  'type',
  _isPath,
  'a path',
  _isInt,
  'an integer',
  (operand, source, out) => '${LvRuntimeCall.pathType}($operand)',
);

List<String>? _pathToArrayOfStrings(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final path = sig.input('path');
  if (path == null) return sig.refuse('has its "path" terminal unwired');
  if (!_isPath(path.type)) return sig.typeRefusal('path', path.type, 'a path');
  if (!_outputsAre(sig, {'relative': (_isBool, 'a boolean')})) return null;
  final strings = sig.output('array of strings');
  if (strings != null && (!_is1d(strings.type) || strings.type.element.carrier != LvCarrier.text)) {
    return sig.typeRefusal('array of strings', strings.type, 'a 1-D array of strings');
  }
  call.requireImport(kLvRuntimeImport);
  return _bindFields(sig, '${LvRuntimeCall.pathToArrayOfStrings}(${path.expression})', [
    ('relative', 'relative'),
    ('components', 'array of strings'),
  ], sideEffect: false);
}

List<String>? _arrayOfStringsToPath(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final strings = sig.input('array of strings');
  if (strings == null) return sig.refuse('has its "array of strings" terminal unwired');
  if (!_is1d(strings.type) || strings.type.element.carrier != LvCarrier.text) {
    return sig.typeRefusal('array of strings', strings.type, 'a 1-D array of strings');
  }
  if (!_inputsAre(sig, {'relative': (_isBool, 'a boolean')})) return null;
  final relative = sig.arg('relative');
  if (relative == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindSingle(
    sig,
    'path',
    '${LvRuntimeCall.arrayOfStringsToPath}(${strings.expression}, relative: $relative)',
    sideEffect: false,
  );
}

// Arrays.

bool _sortable(LvTypeMapping element) =>
    element.carrier == LvCarrier.integer ||
    element.carrier == LvCarrier.float ||
    element.carrier == LvCarrier.text ||
    element.carrier == LvCarrier.boolean ||
    element.carrier == LvCarrier.path ||
    element.carrier == LvCarrier.timestamp;

List<String>? _sort1dArray(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final array = sig.input('array');
  if (array == null) return sig.refuse('has its "array" terminal unwired');
  if (!_is1d(array.type) || !_sortable(array.type.element)) {
    return sig.typeRefusal('array', array.type, 'a 1-D array of numbers, strings, booleans, paths or timestamps');
  }
  if (array.type.numeric == LvNumericKind.u64) return sig.refuse('sorts U64 elements, which Dart reads as signed');
  final out = sig.output('sorted array');
  if (out == null) return const [];
  call.requireImport(kLvRuntimeImport);
  if (out.type.numeric != null) call.requireImport('dart:typed_data');
  return [
    'final ${out.type.dartType} ${out.expression} = '
        '${lvArrayFreeze(out.type.element, '${LvRuntimeCall.sort1dArray}(${array.expression})')};',
  ];
}

List<String>? _transpose2dArray(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final array = sig.input('2D array');
  if (array == null) return sig.refuse('has its "2D array" terminal unwired');
  if (array.type.dims != 2) return sig.typeRefusal('2D array', array.type, 'a 2-D array');
  final out = sig.output('transposed array');
  if (out == null) return const [];
  final element = out.type.element;
  final storage = lvArrayDartType(element, 1);
  final allocate = element.numeric != null
      ? '$storage.new'
      : '(length) => List<${element.dartType}>.filled(length, ${_elementZero(sig, element)})';
  if (call.refusal != null) return null;
  call.requireImport(kLvRuntimeImport);
  call.requireImport('dart:typed_data');
  return [
    'final ${out.type.dartType} ${out.expression} = '
        '${LvRuntimeCall.transpose2dArray}(${array.expression}, $allocate);',
  ];
}

String _elementZero(LvSignedCall sig, LvTypeMapping element) => switch (element.carrier) {
  LvCarrier.boolean => 'false',
  LvCarrier.text => "''",
  LvCarrier.integer => '0',
  LvCarrier.float => '0.0',
  _ => sig.typeRefusal('2D array', LvWireType.scalarOf(element), 'numbers, booleans or strings') ?? '',
};

List<String>? _arrayMaxAndMin(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final array = sig.input('array');
  if (array == null) return sig.refuse('has its "array" terminal unwired');
  if (!_is1d(array.type) || !_sortable(array.type.element)) {
    return sig.typeRefusal('array', array.type, 'a 1-D array of numbers, strings, booleans, paths or timestamps');
  }
  if (!_outputsAre(sig, {'max index(es)': (_isInt, 'an integer'), 'min index(es)': (_isInt, 'an integer')})) {
    return null;
  }
  if (!sig.anyConsumed) return const [];
  final empty = _elementZeroOrDefault(sig, array.type.element);
  if (empty == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(sig, '${LvRuntimeCall.arrayMaxAndMin}(${array.expression}, $empty)', [
    ('maxValue', 'max value'),
    ('maxIndex', 'max index(es)'),
    ('minValue', 'min value'),
    ('minIndex', 'min index(es)'),
  ], sideEffect: false);
}

String? _elementZeroOrDefault(LvSignedCall sig, LvTypeMapping element) {
  switch (element.carrier) {
    case LvCarrier.boolean:
      return 'false';
    case LvCarrier.text:
      return "''";
    case LvCarrier.integer:
      return '0';
    case LvCarrier.float:
      return '0.0';
    case LvCarrier.path:
      sig.call.requireImport(kLvRuntimeImport);
      return 'const ${LvRuntimeType.path}(components: [], absolute: false)';
    case LvCarrier.timestamp:
      sig.call.requireImport(kLvRuntimeImport);
      return LvRuntimeType.timestampEpoch;
    case _:
      return sig.typeRefusal('array', LvWireType.scalarOf(element), 'elements with a spelled default');
  }
}

List<String>? _booleanArrayReduction(LvPrimCall call, String runtimeCall, String output) => _unaryRuntime(
  call,
  'Boolean array',
  output,
  (type) => _is1d(type) && type.element.carrier == LvCarrier.boolean,
  'a 1-D boolean array',
  _isBool,
  'a boolean',
  (operand, source, out) => '$runtimeCall($operand)',
);

List<String>? _multiplyArrayElements(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final array = sig.input('numeric array');
  if (array == null) return sig.refuse('has its "numeric array" terminal unwired');
  final out = sig.output('product');
  if (out == null) return const [];
  final kind = out.type.numeric;
  if (!_is1d(array.type) ||
      kind == null ||
      kind.hazards.isNotEmpty ||
      array.type.element.dartType != out.type.dartType) {
    return sig.typeRefusal('numeric array', array.type, 'a 1-D array of ${out.type.dartType ?? 'numbers'}');
  }
  final total = call.names.role(LvNameRole.value), element = call.names.role(LvNameRole.element);
  return [
    'final ${out.type.dartType} ${out.expression} = ${array.expression}.fold<${out.type.dartType}>('
        '${kind.isFloat ? '1.0' : '1'}, ($total, $element) => ${lvWrapExpression(kind, '$total * $element')});',
  ];
}

List<String>? _split1dArray(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final array = sig.input('array'), index = sig.input('index');
  if (array == null || index == null) return sig.refuse('has its array or index unwired');
  if (!_is1d(array.type)) return sig.typeRefusal('array', array.type, 'a 1-D array');
  if (!_isInt(index.type)) return sig.typeRefusal('index', index.type, 'an integer');
  final first = sig.output('first subarray'), second = sig.output('second subarray');
  if (first == null && second == null) return const [];
  call.requireImport(kLvRuntimeImport);
  if (array.type.numeric != null) call.requireImport('dart:typed_data');
  final pair = call.names.role(LvNameRole.value);
  final element = array.type.element;
  return [
    'final $pair = ${LvRuntimeCall.split1dArray}(${array.expression}, ${index.expression});',
    if (first != null) 'final ${first.type.dartType} ${first.expression} = ${lvArrayFreeze(element, '$pair.\$1')};',
    if (second != null) 'final ${second.type.dartType} ${second.expression} = ${lvArrayFreeze(element, '$pair.\$2')};',
  ];
}

List<String>? _threshold1dArray(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final array = sig.input('array of numbers or points'), threshold = sig.input('threshold y');
  if (array == null || threshold == null) return sig.refuse('has its array or threshold unwired');
  if (!_is1d(array.type) || array.type.numeric == null) {
    return sig.typeRefusal('array of numbers or points', array.type, 'a 1-D numeric array');
  }
  if (!_isNumber(threshold.type)) return sig.typeRefusal('threshold y', threshold.type, 'a scalar number');
  if (!_inputsAre(sig, {'start index': (_isInt, 'an integer')})) return null;
  final start = sig.arg('start index');
  if (start == null) return null;
  final out = sig.output('fractional index or x');
  if (out == null) return const [];
  if (!_isFloat(out.type)) return sig.typeRefusal('fractional index or x', out.type, 'a floating-point number');
  call.requireImport(kLvRuntimeImport);
  return [
    'final double ${out.expression} = '
        '${LvRuntimeCall.threshold1dArray}(${array.expression}, ${threshold.expression}, $start);',
  ];
}

List<String>? _matrixSize(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final matrix = sig.input('matrix');
  if (matrix == null) return sig.refuse('has its "matrix" terminal unwired');
  if (matrix.type.dims != 2) return sig.typeRefusal('matrix', matrix.type, 'a 2-D array');
  if (!_outputsAre(sig, {'number of rows': (_isInt, 'an integer'), 'number of columns': (_isInt, 'an integer')})) {
    return null;
  }
  final rows = sig.output('number of rows'), columns = sig.output('number of columns');
  return [
    if (rows != null) 'final int ${rows.expression} = ${matrix.expression}.dims[0];',
    if (columns != null) 'final int ${columns.expression} = ${matrix.expression}.dims[1];',
  ];
}

/// The member names and Dart types of a cluster wire, as a class or a record spells them.
({List<String> names, List<LvTypeMapping> types, bool isRecord, String? className})? _clusterMembers(
  LvSignedCall sig,
  String terminal,
  LvWireType type,
) {
  if (type.dims != 0) return sig.typeRefusal(terminal, type, 'a cluster');
  if (type.carrier == LvCarrier.nominal) {
    final declaration = type.declarations.singleOrNull;
    if (declaration == null || declaration.isEnum) return sig.typeRefusal(terminal, type, 'a cluster');
    return (
      names: LvNaming.declarationFields([for (final field in declaration.fields) field.label]),
      types: [for (final field in declaration.fields) field.type],
      isRecord: false,
      className: declaration.name,
    );
  }
  if (type.carrier == LvCarrier.compound &&
      type.value.fields.isNotEmpty &&
      (type.dartType?.startsWith('({') ?? false)) {
    return (
      names: [for (final field in type.value.fields) lvFieldName(field.label ?? '')],
      types: [for (final field in type.value.fields) field.type],
      isRecord: true,
      className: null,
    );
  }
  return sig.typeRefusal(terminal, type, 'a cluster whose members are named');
}

List<String>? _clusterToArray(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final cluster = sig.input('cluster');
  if (cluster == null) return sig.refuse('has its "cluster" terminal unwired');
  final members = _clusterMembers(sig, 'cluster', cluster.type);
  if (members == null) return null;
  final out = sig.output('array');
  if (out == null) return const [];
  if (!_is1d(out.type)) return sig.typeRefusal('array', out.type, 'a 1-D array');
  if (members.types.any((type) => type.dartType != out.type.element.dartType)) {
    return sig.refuse('converts a cluster whose members are not all ${out.type.element.dartType}');
  }
  if (out.type.numeric != null) call.requireImport('dart:typed_data');
  final elements = [for (final name in members.names) '${cluster.expression}.$name'];
  return [
    'final ${out.type.dartType} ${out.expression} = '
        '${lvArrayFreeze(out.type.element, '<${out.type.element.dartType}>[${elements.join(', ')}]')};',
  ];
}

List<String>? _arrayToCluster(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final array = sig.input('array');
  if (array == null) return sig.refuse('has its "array" terminal unwired');
  if (!_is1d(array.type)) return sig.typeRefusal('array', array.type, 'a 1-D array');
  final out = sig.output('cluster');
  if (out == null) return const [];
  final members = _clusterMembers(sig, 'cluster', out.type);
  if (members == null) return null;
  if (members.types.any((type) => type.dartType != array.type.element.dartType)) {
    return sig.refuse('fills a cluster whose members are not all ${array.type.element.dartType}');
  }
  final source = lvIsAtomic(array.expression!) ? array.expression! : call.names.wire(array.type);
  final lines = <String>[];
  if (source != array.expression) lines.add('final ${array.type.dartType} $source = ${array.expression};');
  final zero = _elementZeroOrDefault(sig, array.type.element);
  if (zero == null) return null;
  final arguments = [
    for (var i = 0; i < members.names.length; i++) '${members.names[i]}: $i < $source.length ? $source[$i] : $zero',
  ];
  final value = members.isRecord ? '(${arguments.join(', ')})' : '${members.className}(${arguments.join(', ')})';
  lines.add('final ${out.type.dartType} ${out.expression} = $value;');
  return lines;
}

// Variants.

/// [expression] as a variant, recording its numeric representation when it is a number or a
/// 1-D numeric array.
String _variantOf(String expression, LvWireType type) {
  final kind = type.numeric;
  final numeric = kind != null && type.dims <= 1 ? ', numeric: LvNumericType.${kind.name}' : '';
  return '${LvRuntimeCall.toVariant}($expression$numeric)';
}

List<String>? _toVariant(LvPrimCall call) => _unaryRuntime(
  call,
  'anything',
  'variant',
  (type) => type.isMapped,
  'a mapped value',
  _isVariant,
  'a variant',
  (operand, source, out) => _variantOf(operand, source.type),
);

List<String>? _variantToData(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final variant = sig.input('variant');
  if (variant == null) return sig.refuse('has its "variant" terminal unwired');
  if (!_isVariant(variant.type)) return sig.typeRefusal('variant', variant.type, 'a variant');
  if (!_inputsAre(sig, {'error in': (_isError, 'an error cluster')})) return null;
  final data = sig.output('data');
  final type = data?.type ?? sig.input('type')?.type;
  if (type == null) {
    final errorIn = sig.arg('error in');
    if (errorIn == null) return null;
    return sig.consumed('error out')
        ? ['final ${LvRuntimeType.error} ${sig.target('error out')} = $errorIn;']
        : const [];
  }
  if (!type.isMapped) return sig.typeRefusal('type', type, 'a mapped type');
  final fallback = _defaultOf(sig, type);
  if (fallback == null) return null;
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(
    sig,
    '${LvRuntimeCall.variantToData}<${type.dartType}>(${variant.expression}, defaultValue: $fallback, errorIn: $errorIn)',
    [('data', 'data'), ('errorOut', 'error out')],
  );
}

/// The default value of [type] as *use default if unwired* spells it, or null (refusing) for a
/// type with no spelled default.
String? _defaultOf(LvSignedCall sig, LvWireType type) {
  final mapping = type.value;
  if (!mapping.isMapped || mapping.dartType == null) return sig.typeRefusal('type', type, 'a mapped type');
  switch (mapping.carrier) {
    case LvCarrier.boolean:
      return 'false';
    case LvCarrier.integer:
      return '0';
    case LvCarrier.float:
      return '0.0';
    case LvCarrier.text:
      return "''";
    case LvCarrier.error:
      sig.call.requireImport(kLvRuntimeImport);
      return LvRuntimeType.clearedError;
    case LvCarrier.path:
      sig.call.requireImport(kLvRuntimeImport);
      return 'const ${LvRuntimeType.path}(components: [], absolute: false)';
    case LvCarrier.refnum:
      sig.call.requireImport(kLvRuntimeImport);
      return LvRuntimeType.notARefnum;
    case LvCarrier.timestamp:
      sig.call.requireImport(kLvRuntimeImport);
      return LvRuntimeType.timestampEpoch;
    case LvCarrier.variant:
      sig.call.requireImport(kLvRuntimeImport);
      return '${LvRuntimeType.variant}.empty';
    case LvCarrier.nominal:
      final declaration = mapping.declarations.singleOrNull;
      if (declaration == null) return sig.typeRefusal('type', type, 'a type with a spelled default');
      if (declaration.isEnum) {
        return declaration.items.isEmpty
            ? sig.typeRefusal('type', type, 'an enum with items')
            : '${declaration.name}.values.first';
      }
      final names = LvNaming.declarationFields([for (final field in declaration.fields) field.label]);
      final values = <String>[];
      for (var i = 0; i < declaration.fields.length; i++) {
        final value = _defaultOf(sig, LvWireType.scalarOf(declaration.fields[i].type));
        if (value == null) return null;
        values.add('${names[i]}: $value');
      }
      return '${declaration.name}(${values.join(', ')})';
    case LvCarrier.compound:
      if (mapping.fields.isNotEmpty) {
        final names = [for (final field in mapping.fields) lvFieldName(field.label ?? '')];
        if (names.any((name) => name.isEmpty) || names.toSet().length != names.length) {
          return sig.typeRefusal('type', type, 'a cluster whose members are named');
        }
        final values = <String>[];
        for (var i = 0; i < mapping.fields.length; i++) {
          final value = _defaultOf(sig, LvWireType.scalarOf(mapping.fields[i].type));
          if (value == null) return null;
          values.add('${names[i]}: $value');
        }
        return '(${values.join(', ')})';
      }
      final dartType = mapping.dartType!;
      if (dartType.endsWith('List') && !dartType.contains('<')) {
        sig.call.requireImport('dart:typed_data');
        return '$dartType(0)';
      }
      if (dartType.startsWith('List<')) return 'const <${dartType.substring(5, dartType.length - 1)}>[]';
      return sig.typeRefusal('type', type, 'a type with a spelled default');
    case LvCarrier.voidValue:
    case null:
      return sig.typeRefusal('type', type, 'a type with a spelled default');
  }
}

List<String>? _setVariantAttribute(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final variant = sig.input('variant'), name = sig.input('name'), value = sig.input('value');
  if (variant == null || name == null || value == null) return sig.refuse('has its variant, name or value unwired');
  if (!_isVariant(variant.type)) return sig.typeRefusal('variant', variant.type, 'a variant');
  if (!_isText(name.type)) return sig.typeRefusal('name', name.type, 'a string');
  if (!_inputsAre(sig, {'error in': (_isError, 'an error cluster')})) return null;
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(
    sig,
    '${LvRuntimeCall.setVariantAttribute}(${variant.expression}, ${name.expression}, ${_variantOf(value.expression!, value.type)}, errorIn: $errorIn)',
    [('variant', 'variant out'), ('replaced', 'replaced'), ('errorOut', 'error out')],
  );
}

List<String>? _getVariantAttribute(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final variant = sig.input('variant');
  if (variant == null) return sig.refuse('has its "variant" terminal unwired');
  if (!_isVariant(variant.type)) return sig.typeRefusal('variant', variant.type, 'a variant');
  if (!_inputsAre(sig, {'name': (_isText, 'a string'), 'error in': (_isError, 'an error cluster')})) return null;
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  final name = sig.input('name');
  call.requireImport(kLvRuntimeImport);
  if (name == null) {
    if (sig.input('default value') != null) return sig.refuse('wires a default value without a name');
    final names = sig.output('names'), values = sig.output('values');
    if (names != null && (!_is1d(names.type) || names.type.element.carrier != LvCarrier.text)) {
      return sig.typeRefusal('names', names.type, 'a 1-D array of strings');
    }
    if (values != null && (!_is1d(values.type) || values.type.element.carrier != LvCarrier.variant)) {
      return sig.typeRefusal('values', values.type, 'a 1-D array of variants');
    }
    return _bindFields(sig, '${LvRuntimeCall.getVariantAttributes}(${variant.expression}, errorIn: $errorIn)', [
      ('variant', 'duplicate variant'),
      ('names', 'names'),
      ('values', 'values'),
      ('errorOut', 'error out'),
    ]);
  }
  final found = sig.output('names');
  if (found != null && !_isBool(found.type)) return sig.typeRefusal('names', found.type, 'a boolean (found)');
  final value = sig.output('values');
  final fallback = sig.input('default value');
  final type = value?.type ?? fallback?.type;
  final String defaultValue;
  if (fallback != null) {
    defaultValue = fallback.expression!;
  } else if (type != null) {
    final spelled = _defaultOf(sig, type);
    if (spelled == null) return null;
    defaultValue = spelled;
  } else {
    defaultValue = '${LvRuntimeType.variant}.empty';
  }
  final typeArgument = type?.dartType ?? LvRuntimeType.variant;
  return _bindFields(
    sig,
    '${LvRuntimeCall.getVariantAttribute}<$typeArgument>(${variant.expression}, ${name.expression}, '
    'defaultValue: $defaultValue, errorIn: $errorIn)',
    [('variant', 'duplicate variant'), ('found', 'names'), ('value', 'values'), ('errorOut', 'error out')],
  );
}

List<String>? _variantToFlattenedString(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final variant = sig.input('variant');
  if (variant == null) return sig.refuse('has its "variant" terminal unwired');
  if (!_isVariant(variant.type)) return sig.typeRefusal('variant', variant.type, 'a variant');
  if (sig.consumed('type string')) {
    return sig.refuse('has its type string read, and a type descriptor is not produced from a Dart value here');
  }
  if (!_outputsAre(sig, {'data string': (_isText, 'a string')})) return null;
  final data = sig.output('data string');
  if (data == null) return const [];
  call.requireImport(kLvRuntimeImport);
  return ['final String ${data.expression} = ${LvRuntimeCall.flattenVariantData}(${variant.expression});'];
}

// Timing.

List<String>? _tickCount(LvPrimCall call) =>
    _nullary(call, 'millisecond timer value', LvRuntimeCall.tickCount, _isInt, 'an integer');

List<String>? _getDateTimeInSeconds(LvPrimCall call) =>
    _nullary(call, 'current time', LvRuntimeCall.getDateTimeInSeconds, _isTimestamp, 'a timestamp');

List<String>? _nullary(
  LvPrimCall call,
  String output,
  String runtimeCall,
  bool Function(LvWireType) accepts,
  String wanted,
) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final out = sig.output(output);
  if (out == null) return const [];
  if (!accepts(out.type)) return sig.typeRefusal(output, out.type, wanted);
  call.requireImport(kLvRuntimeImport);
  return ['final ${out.type.dartType} ${out.expression} = $runtimeCall();'];
}

List<String>? _waitUntilNextMsMultiple(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final multiple = sig.input('millisecond multiple');
  if (multiple == null) return sig.refuse('has its "millisecond multiple" terminal unwired');
  if (!_isInt(multiple.type)) return sig.typeRefusal('millisecond multiple', multiple.type, 'an integer');
  if (!_outputsAre(sig, {'millisecond timer value': (_isInt, 'an integer')})) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindSingle(
    sig,
    'millisecond timer value',
    '${LvRuntimeCall.waitUntilNextMsMultiple}(${multiple.expression})',
  );
}

List<String>? _formatDateTimeString(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  if (!_inputsAre(sig, {
    'time format string': (_isText, 'a string'),
    'UTC format': (_isBool, 'a boolean'),
    'time stamp': ((type) => _isTimestamp(type) || _isNumber(type), 'a timestamp or a number of seconds'),
  })) {
    return null;
  }
  final out = sig.output('date/time string');
  if (out == null) return const [];
  if (!_isText(out.type)) return sig.typeRefusal('date/time string', out.type, 'a string');
  final format = sig.arg('time format string'), utc = sig.arg('UTC format');
  if (format == null || utc == null) return null;
  final stamp = sig.input('time stamp');
  call.requireImport(kLvRuntimeImport);
  final String time;
  if (stamp == null) {
    time = '${LvRuntimeCall.getDateTimeInSeconds}()';
  } else if (_isTimestamp(stamp.type)) {
    time = stamp.expression!;
  } else {
    final seconds = stamp.type.numeric!.isFloat ? stamp.expression! : '${stamp.expression}.toDouble()';
    time = '${LvRuntimeCall.toTimeStamp}($seconds)';
  }
  return ['final String ${out.expression} = ${LvRuntimeCall.formatDateTimeString}($format, $time, utc: $utc);'];
}

List<String>? _toTimeStamp(LvPrimCall call) => _unaryRuntime(
  call,
  'number',
  'time stamp',
  _isNumber,
  'a scalar number',
  _isTimestamp,
  'a timestamp',
  (operand, source, out) =>
      '${LvRuntimeCall.toTimeStamp}(${source.type.numeric!.isFloat ? operand : '$operand.toDouble()'})',
);

// Files.

/// A file terminal: an open file refnum or a path.
bool _isFileOrPath(LvWireType type) => _isRefnum(type) || _isPath(type);

List<String>? _openCreateReplaceFile(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final path = sig.input('file path');
  if (path == null) return sig.refuse('has its "file path" unwired, and the dialog it opens then runs only in LabVIEW');
  if (!_inputsAre(sig, {
    'file path': (_isPath, 'a path'),
    'operation': (_isInt, 'an integer'),
    'access': (_isInt, 'an integer'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  if (sig.input('prompt') != null || sig.input('disable buffering') != null) {
    return sig.refuse('wires a prompt or disable buffering, which only the dialog or LabVIEW\'s buffering honours');
  }
  final operation = sig.arg('operation'), access = sig.arg('access'), errorIn = sig.arg('error in');
  if (operation == null || access == null || errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(
    sig,
    '${LvRuntimeCall.openCreateReplaceFile}(${path.expression}, operation: $operation, access: $access, errorIn: $errorIn)',
    [('refnum', 'refnum out'), ('cancelled', 'cancelled'), ('errorOut', 'error out')],
  );
}

List<String>? _closeFile(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final refnum = sig.input('refnum');
  if (refnum == null) return sig.refuse('has its "refnum" terminal unwired');
  if (!_isRefnum(refnum.type)) return sig.typeRefusal('refnum', refnum.type, 'a file refnum');
  if (!_inputsAre(sig, {'error in': (_isError, 'an error cluster')})) return null;
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(sig, '${LvRuntimeCall.closeFile}(${refnum.expression}, errorIn: $errorIn)', [
    ('path', 'path'),
    ('errorOut', 'error out'),
  ]);
}

/// Read from Text File's Convert EOL option, the function's option that is on by default; the
/// bit is set on the corpus nodes that keep that default.
const int kLvReadTextConvertEolBit = 0x2000000;

List<String>? _readFromTextFile(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final file = sig.input('file');
  if (file == null) return sig.refuse('has its "file" unwired, and the dialog it opens then runs only in LabVIEW');
  if (!_inputsAre(sig, {
    'file': (_isFileOrPath, 'a file refnum or path'),
    'count': (_isInt, 'an integer'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  if (sig.input('prompt') != null) return sig.refuse('wires a prompt, which only the dialog honours');
  final count = sig.arg('count'), errorIn = sig.arg('error in');
  if (count == null || errorIn == null) return null;
  final flags = call.nodeFlags ?? 0;
  final lines = flags & ViObjFlag.readLines.mask != 0;
  final convertEol = flags & kLvReadTextConvertEolBit != 0;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(
    sig,
    '${LvRuntimeCall.readFromTextFile}(${file.expression}, count: $count'
    '${lines ? ', lines: true' : ''}${convertEol ? ', convertEol: true' : ''}, errorIn: $errorIn)',
    [('refnumOut', 'refnum out'), ('text', 'text'), ('cancelled', 'cancelled'), ('errorOut', 'error out')],
  );
}

List<String>? _writeToTextFile(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final file = sig.input('file'), text = sig.input('text');
  if (file == null) return sig.refuse('has its "file" unwired, and the dialog it opens then runs only in LabVIEW');
  if (text == null) return sig.refuse('has its "text" terminal unwired');
  if (!_inputsAre(sig, {
    'file': (_isFileOrPath, 'a file refnum or path'),
    'text': (_isText, 'a string'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  if (sig.input('prompt') != null) return sig.refuse('wires a prompt, which only the dialog honours');
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(
    sig,
    '${LvRuntimeCall.writeToTextFile}(${file.expression}, ${text.expression}, errorIn: $errorIn)',
    [('refnumOut', 'refnum out'), ('cancelled', 'cancelled'), ('errorOut', 'error out')],
  );
}

List<String>? _readFromBinaryFile(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final file = sig.input('file');
  if (file == null) return sig.refuse('has its "file" unwired, and the dialog it opens then runs only in LabVIEW');
  if (!_inputsAre(sig, {
    'file': (_isFileOrPath, 'a file refnum or path'),
    'count': (_isInt, 'an integer'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  if (sig.input('prompt') != null) return sig.refuse('wires a prompt, which only the dialog honours');
  if (sig.input('byte order') != null) {
    return sig.refuse('wires a byte order, and only the big-endian default is spelled here');
  }
  final data = sig.output('data');
  final type = data?.type ?? sig.input('data type')?.type;
  if (type != null && !(_isText(type) || (_is1d(type) && type.numeric == LvNumericKind.u8))) {
    return sig.typeRefusal('data type', type, 'a string or a 1-D U8 array, the shapes read without a type descriptor');
  }
  final count = sig.arg('count'), errorIn = sig.arg('error in');
  if (count == null || errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  final invocation = '${LvRuntimeCall.readBytesFromBinaryFile}(${file.expression}, count: $count, errorIn: $errorIn)';
  if (!sig.anyConsumed) return ['$invocation;'];
  final read = call.names.role(LvNameRole.value);
  final lines = [
    'final $read = $invocation;',
    if (sig.consumed('refnum out')) 'final ${LvRuntimeType.refnum} ${sig.target('refnum out')} = $read.refnumOut;',
    if (sig.consumed('cancelled')) 'final bool ${sig.target('cancelled')} = $read.cancelled;',
    if (sig.consumed('error out')) 'final ${LvRuntimeType.error} ${sig.target('error out')} = $read.errorOut;',
  ];
  if (data != null) {
    if (_isText(data.type)) {
      lines.add('final String ${data.expression} = $read.data;');
    } else {
      call.requireImport('dart:convert');
      call.requireImport('dart:typed_data');
      lines.add('final Uint8List ${data.expression} = latin1.encode($read.data);');
    }
  }
  return lines;
}

List<String>? _writeToBinaryFile(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final file = sig.input('file'), data = sig.input('data');
  if (file == null) return sig.refuse('has its "file" unwired, and the dialog it opens then runs only in LabVIEW');
  if (data == null) return sig.refuse('has its "data" terminal unwired');
  if (!_inputsAre(sig, {
    'file': (_isFileOrPath, 'a file refnum or path'),
    'prepend array or string size?': (_isBool, 'a boolean'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  if (sig.input('prompt') != null) return sig.refuse('wires a prompt, which only the dialog honours');
  if (sig.input('byte order') != null) {
    return sig.refuse('wires a byte order, and only the big-endian default is spelled here');
  }
  final flat = _flatBytesOf(sig, data, prepend: sig.arg('prepend array or string size?'));
  if (flat == null) return null;
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(sig, '${LvRuntimeCall.writeBytesToBinaryFile}(${file.expression}, $flat, errorIn: $errorIn)', [
    ('refnumOut', 'refnum out'),
    ('cancelled', 'cancelled'),
    ('errorOut', 'error out'),
  ]);
}

List<String>? _pathOperation(
  LvPrimCall call,
  String pathTerminal,
  String runtimeCall,
  List<(String field, String terminal)> fields, {
  Map<String, String> flags = const {},
}) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final path = sig.input(pathTerminal);
  if (path == null) {
    return sig.refuse('has its "$pathTerminal" unwired, and the dialog it opens then runs only in LabVIEW');
  }
  if (!_inputsAre(sig, {
    pathTerminal: (_isPath, 'a path'),
    'error in': (_isError, 'an error cluster'),
    for (final terminal in flags.keys) terminal: (_isBool, 'a boolean'),
  })) {
    return null;
  }
  if (sig.input('prompt') != null) return sig.refuse('wires a prompt, which only the dialog honours');
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  final named = <String>[];
  for (final MapEntry(key: terminal, value: parameter) in flags.entries) {
    final value = sig.arg(terminal);
    if (value == null) return null;
    named.add('$parameter: $value');
  }
  call.requireImport(kLvRuntimeImport);
  return _bindFields(sig, '$runtimeCall(${path.expression}, ${[...named, 'errorIn: $errorIn'].join(', ')})', fields);
}

List<String>? _createFolder(LvPrimCall call) => _pathOperation(call, 'path', LvRuntimeCall.createFolder, [
  ('createdPath', 'created path'),
  ('cancelled', 'cancelled'),
  ('errorOut', 'error out'),
]);

List<String>? _delete(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  if (sig.input('confirm') != null) return sig.refuse('wires "confirm", whose dialog runs only in LabVIEW');
  return _pathOperation(
    call,
    'path',
    LvRuntimeCall.delete,
    [('deletedPath', 'deleted path'), ('cancelled', 'cancelled'), ('errorOut', 'error out')],
    flags: {'entire hierarchy': 'entireHierarchy'},
  );
}

List<String>? _copyOrMove(LvPrimCall call, String runtimeCall) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final source = sig.input('source path'), target = sig.input('target path');
  if (source == null || target == null) {
    return sig.refuse('has a path unwired, and the dialog it opens then runs only in LabVIEW');
  }
  if (!_inputsAre(sig, {
    'source path': (_isPath, 'a path'),
    'target path': (_isPath, 'a path'),
    'overwrite': (_isBool, 'a boolean'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  if (sig.input('prompt') != null) return sig.refuse('wires a prompt, which only the dialog honours');
  final overwrite = sig.arg('overwrite'), errorIn = sig.arg('error in');
  if (overwrite == null || errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(
    sig,
    '$runtimeCall(${source.expression}, ${target.expression}, overwrite: $overwrite, errorIn: $errorIn)',
    [('newPath', 'new path'), ('cancelled', 'cancelled'), ('errorOut', 'error out')],
  );
}

List<String>? _getFileSize(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final file = sig.input('file');
  if (file == null) return sig.refuse('has its "file" terminal unwired');
  if (!_inputsAre(sig, {
    'file': (_isFileOrPath, 'a file refnum or path'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(sig, '${LvRuntimeCall.getFileSize}(${file.expression}, errorIn: $errorIn)', [
    ('refnumOut', 'refnum out'),
    ('size', 'size (in bytes)'),
    ('errorOut', 'error out'),
  ]);
}

List<String>? _setFileSize(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final file = sig.input('file'), size = sig.input('size (in bytes)');
  if (file == null || size == null) return sig.refuse('has its file or size unwired');
  if (!_inputsAre(sig, {
    'file': (_isRefnum, 'a file refnum'),
    'size (in bytes)': (_isInt, 'an integer'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(sig, '${LvRuntimeCall.setFileSize}(${file.expression}, ${size.expression}, errorIn: $errorIn)', [
    ('refnumOut', 'refnum out'),
    ('errorOut', 'error out'),
  ]);
}

List<String>? _setFilePosition(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final refnum = sig.input('refnum');
  if (refnum == null) return sig.refuse('has its "refnum" terminal unwired');
  if (!_inputsAre(sig, {
    'refnum': (_isRefnum, 'a file refnum'),
    'offset (in bytes)': (_isInt, 'an integer'),
    'from': (_isInt, 'an integer'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  final offset = sig.arg('offset (in bytes)'), from = sig.arg('from'), errorIn = sig.arg('error in');
  if (offset == null || from == null || errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(
    sig,
    '${LvRuntimeCall.setFilePosition}(${refnum.expression}, offset: $offset, from: $from, errorIn: $errorIn)',
    [('refnumOut', 'refnum out'), ('errorOut', 'error out')],
  );
}

List<String>? _fileDirectoryInfo(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final path = sig.input('path');
  if (path == null) return sig.refuse('has its "path" terminal unwired');
  if (!_inputsAre(sig, {'path': (_isPath, 'a path'), 'error in': (_isError, 'an error cluster')})) return null;
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(sig, '${LvRuntimeCall.fileDirectoryInfo}(${path.expression}, errorIn: $errorIn)', [
    ('pathOut', 'path out'),
    ('directory', 'directory'),
    ('size', 'size'),
    ('lastMod', 'last mod'),
    ('resolvedPath', 'resolved path'),
    ('shortcut', 'shortcut'),
    ('errorOut', 'error out'),
  ]);
}

List<String>? _listFolder(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final path = sig.input('path');
  if (path == null) return sig.refuse('has its "path" terminal unwired');
  if (!_inputsAre(sig, {
    'path': (_isPath, 'a path'),
    'pattern': (_isText, 'a string'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  if (sig.input('datalog type') != null) return sig.refuse('wires a datalog type, which this runtime does not list');
  final pattern = sig.arg('pattern'), errorIn = sig.arg('error in');
  if (pattern == null || errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(
    sig,
    '${LvRuntimeCall.listFolder}(${path.expression}, pattern: $pattern, errorIn: $errorIn)',
    [('pathOut', 'path out'), ('fileNames', 'filenames'), ('folderNames', 'folder names'), ('errorOut', 'error out')],
  );
}

// Queues, notifiers, data value references, user events.

/// The element type of a queue or notifier reference's payload: the type of the terminal that
/// carries an element, else of the one that names the element data type.
LvWireType? _payloadType(LvSignedCall sig, List<String> terminals) {
  for (final name in terminals) {
    final terminal = sig.input(name) ?? sig.output(name);
    if (terminal != null) return terminal.type;
  }
  return null;
}

List<String>? _obtainQueue(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final type = _payloadType(sig, ['element data type']);
  if (type == null) return sig.refuse('has its "element data type" unwired, so the element type is not decided');
  if (!_inputsAre(sig, {
    'name': (_isText, 'a string'),
    'max queue size': (_isInt, 'an integer'),
    'create if not found?': (_isBool, 'a boolean'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  final name = sig.arg('name'), size = sig.arg('max queue size'), create = sig.arg('create if not found?');
  final errorIn = sig.arg('error in');
  if (name == null || size == null || create == null || errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(
    sig,
    '${LvRuntimeType.queue}.obtain<${type.dartType}>(name: $name, maxSize: $size, createIfNotFound: $create, errorIn: $errorIn)',
    [('queue', 'queue out'), ('createdNew', 'created new?'), ('errorOut', 'error out')],
  );
}

List<String>? _releaseQueue(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final queue = sig.input('queue');
  if (queue == null) return sig.refuse('has its "queue" terminal unwired');
  if (!_inputsAre(sig, {
    'queue': (_isRefnum, 'a queue refnum'),
    'force destroy?': (_isBool, 'a boolean'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  final remaining = sig.output('remaining elements');
  final element = remaining == null ? 'Object?' : (remaining.type.dims == 1 ? remaining.type.element.dartType : null);
  if (element == null) return sig.typeRefusal('remaining elements', remaining!.type, 'a 1-D array');
  final force = sig.arg('force destroy?'), errorIn = sig.arg('error in');
  if (force == null || errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  final invocation =
      '${LvRuntimeType.queue}.release<$element>(${queue.expression}, forceDestroy: $force, errorIn: $errorIn)';
  if (!sig.anyConsumed) return ['$invocation;'];
  final released = call.names.role(LvNameRole.value);
  final lines = [
    'final $released = $invocation;',
    if (sig.consumed('queue name')) 'final String ${sig.target('queue name')} = $released.name;',
    if (sig.consumed('error out')) 'final ${LvRuntimeType.error} ${sig.target('error out')} = $released.errorOut;',
  ];
  if (remaining != null) {
    if (remaining.type.numeric != null) call.requireImport('dart:typed_data');
    lines.add(
      'final ${remaining.type.dartType} ${remaining.expression} = '
      '${lvArrayFreeze(remaining.type.element, '$released.remaining')};',
    );
  }
  return lines;
}

List<String>? _enqueueElement(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final queue = sig.input('queue'), element = sig.input('element');
  if (queue == null || element == null) return sig.refuse('has its queue or element unwired');
  if (!_inputsAre(sig, {
    'queue': (_isRefnum, 'a queue refnum'),
    'timeout in ms': (_isInt, 'an integer'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  final timeout = sig.arg('timeout in ms'), errorIn = sig.arg('error in');
  if (timeout == null || errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  final lines = <String>[];
  if (sig.consumed('queue out')) {
    lines.add('final ${LvRuntimeType.refnum} ${sig.target('queue out')} = ${queue.expression};');
  }
  lines.addAll(
    _bindFields(
      sig,
      '${LvRuntimeType.queue}.enqueue<${element.type.dartType}>(${queue.expression}, ${element.expression}, '
      'timeoutMs: $timeout, errorIn: $errorIn)',
      [('errorOut', 'error out'), ('timedOut', 'timed out?')],
    ),
  );
  return lines;
}

List<String>? _getQueueStatus(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final queue = sig.input('queue');
  if (queue == null) return sig.refuse('has its "queue" terminal unwired');
  if (!_inputsAre(sig, {
    'queue': (_isRefnum, 'a queue refnum'),
    'return elements?': (_isBool, 'a boolean'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  final elements = sig.output('elements');
  final element = elements == null ? 'Object?' : (elements.type.dims == 1 ? elements.type.element.dartType : null);
  if (element == null) return sig.typeRefusal('elements', elements!.type, 'a 1-D array');
  final returnElements = sig.arg('return elements?'), errorIn = sig.arg('error in');
  if (returnElements == null || errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  final invocation =
      '${LvRuntimeType.queue}.status<$element>(${queue.expression}, returnElements: $returnElements, errorIn: $errorIn)';
  if (!sig.anyConsumed) return ['$invocation;'];
  final status = call.names.role(LvNameRole.value);
  final lines = [
    'final $status = $invocation;',
    if (sig.consumed('max queue size')) 'final int ${sig.target('max queue size')} = $status.maxSize;',
    if (sig.consumed('queue name')) 'final String ${sig.target('queue name')} = $status.name;',
    if (sig.consumed('queue out')) 'final ${LvRuntimeType.refnum} ${sig.target('queue out')} = ${queue.expression};',
    if (sig.consumed('# pending remove')) 'final int ${sig.target('# pending remove')} = $status.pendingRemove;',
    if (sig.consumed('# pending insert')) 'final int ${sig.target('# pending insert')} = $status.pendingInsert;',
    if (sig.consumed('# elements in queue')) 'final int ${sig.target('# elements in queue')} = $status.elementCount;',
    if (sig.consumed('error out')) 'final ${LvRuntimeType.error} ${sig.target('error out')} = $status.errorOut;',
  ];
  if (elements != null) {
    if (elements.type.numeric != null) call.requireImport('dart:typed_data');
    lines.add(
      'final ${elements.type.dartType} ${elements.expression} = ${lvArrayFreeze(elements.type.element, '$status.elements')};',
    );
  }
  return lines;
}

List<String>? _sendNotification(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final notifier = sig.input('notifier'), notification = sig.input('notification');
  if (notifier == null || notification == null) return sig.refuse('has its notifier or notification unwired');
  if (!_inputsAre(sig, {'notifier': (_isRefnum, 'a notifier refnum'), 'error in': (_isError, 'an error cluster')})) {
    return null;
  }
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  final lines = <String>[];
  if (sig.consumed('notifier out')) {
    lines.add('final ${LvRuntimeType.refnum} ${sig.target('notifier out')} = ${notifier.expression};');
  }
  final send =
      '${LvRuntimeType.notifier}.send<${notification.type.dartType}>(${notifier.expression}, ${notification.expression}, '
      'errorIn: $errorIn)';
  lines.add(sig.consumed('error out') ? 'final ${LvRuntimeType.error} ${sig.target('error out')} = $send;' : '$send;');
  return lines;
}

List<String>? _waitOnNotification(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final notifier = sig.input('notifier');
  if (notifier == null) return sig.refuse('has its "notifier" terminal unwired');
  if (!_inputsAre(sig, {
    'notifier': (_isRefnum, 'a notifier refnum'),
    'ignore previous': (_isBool, 'a boolean'),
    'timeout in ms': (_isInt, 'an integer'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  final notification = sig.output('notification');
  if (notification == null) {
    return sig.refuse('does not read its notification, so the notifier\'s element type is not decided');
  }
  final fallback = _defaultOf(sig, notification.type);
  if (fallback == null) return null;
  final ignore = sig.arg('ignore previous'), timeout = sig.arg('timeout in ms'), errorIn = sig.arg('error in');
  if (ignore == null || timeout == null || errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  final lines = <String>[];
  if (sig.consumed('notifier out')) {
    lines.add('final ${LvRuntimeType.refnum} ${sig.target('notifier out')} = ${notifier.expression};');
  }
  lines.addAll(
    _bindFields(
      sig,
      '${LvRuntimeType.notifier}.wait<${notification.type.dartType}>(${notifier.expression}, defaultValue: $fallback, '
      'ignorePrevious: $ignore, timeoutMs: $timeout, errorIn: $errorIn)',
      [('notification', 'notification'), ('timedOut', 'timed out?'), ('errorOut', 'error out')],
    ),
  );
  return lines;
}

List<String>? _newDataValueReference(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final value = sig.input('data value');
  if (value == null) return sig.refuse('has its "data value" terminal unwired');
  if (!_inputsAre(sig, {'error in': (_isError, 'an error cluster')})) return null;
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(
    sig,
    '${LvRuntimeType.dataValueReference}.create<${value.type.dartType}>(${value.expression}, errorIn: $errorIn)',
    [('reference', 'data value reference'), ('errorOut', 'error out')],
  );
}

List<String>? _deleteDataValueReference(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final reference = sig.input('data value reference');
  if (reference == null) return sig.refuse('has its "data value reference" terminal unwired');
  if (!_inputsAre(sig, {
    'data value reference': (_isRefnum, 'a data value reference'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  final value = sig.output('data value');
  call.requireImport(kLvRuntimeImport);
  if (value == null) {
    final deleted =
        '${LvRuntimeType.dataValueReference}.delete<Object?>(${reference.expression}, defaultValue: null, errorIn: $errorIn)';
    return sig.consumed('error out')
        ? ['final ${LvRuntimeType.error} ${sig.target('error out')} = $deleted.errorOut;']
        : ['$deleted;'];
  }
  final fallback = _defaultOf(sig, value.type);
  if (fallback == null) return null;
  return _bindFields(
    sig,
    '${LvRuntimeType.dataValueReference}.delete<${value.type.dartType}>(${reference.expression}, defaultValue: $fallback, '
    'errorIn: $errorIn)',
    [('value', 'data value'), ('errorOut', 'error out')],
  );
}

List<String>? _createUserEvent(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final type = sig.input('user event data type');
  if (type == null) return sig.refuse('has its "user event data type" terminal unwired');
  if (!_inputsAre(sig, {'error in': (_isError, 'an error cluster')})) return null;
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  final name = call.portMemberName[type.port] ?? '';
  call.requireImport(kLvRuntimeImport);
  return _bindFields(
    sig,
    "${LvRuntimeType.userEvent}.create<${type.type.dartType}>('${_jsonKey(name)}', errorIn: $errorIn)",
    [('userEvent', 'user event out'), ('errorOut', 'error out')],
  );
}

List<String>? _generateUserEvent(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final event = sig.input('user event'), data = sig.input('event data');
  if (event == null || data == null) return sig.refuse('has its user event or event data unwired');
  if (!_inputsAre(sig, {
    'user event': (_isRefnum, 'a user event refnum'),
    'priority': (_isInt, 'an integer'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  final priority = sig.input('priority'), errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  final lines = <String>[];
  if (sig.consumed('user event out')) {
    lines.add('final ${LvRuntimeType.refnum} ${sig.target('user event out')} = ${event.expression};');
  }
  final generate =
      '${LvRuntimeType.userEvent}.generate<${data.type.dartType}>(${event.expression}, ${data.expression}'
      '${priority == null ? '' : ', priority: ${priority.expression} == 0 ? LvEventPriority.normal : LvEventPriority.high'}, '
      'errorIn: $errorIn)';
  lines.add(
    sig.consumed('error out') ? 'final ${LvRuntimeType.error} ${sig.target('error out')} = $generate;' : '$generate;',
  );
  return lines;
}

List<String>? _referenceErrorOnly(LvPrimCall call, String terminal, String runtimeCall) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final reference = sig.input(terminal);
  if (reference == null) return sig.refuse('has its "$terminal" terminal unwired');
  if (!_inputsAre(sig, {terminal: (_isRefnum, 'a refnum'), 'error in': (_isError, 'an error cluster')})) return null;
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  final body = '$runtimeCall(${reference.expression}, errorIn: $errorIn)';
  return sig.consumed('error out') ? ['final ${LvRuntimeType.error} ${sig.target('error out')} = $body;'] : ['$body;'];
}

// The environment seam: VI Server, application control, dialogs.

List<String>? _closeReference(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final reference = sig.input('reference');
  if (reference == null) return sig.refuse('has its "reference" terminal unwired');
  if (!_inputsAre(sig, {'error in': (_isError, 'an error cluster')})) return null;
  if (!_isRefnum(reference.type) && !(_is1d(reference.type) && reference.type.element.carrier == LvCarrier.refnum)) {
    return sig.typeRefusal('reference', reference.type, 'a refnum or a 1-D array of refnums');
  }
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  final body = _isRefnum(reference.type)
      ? '${LvRuntimeCall.closeAnyReference}(${reference.expression}, $errorIn)'
      : '${LvRuntimeCall.closeReferences}(${reference.expression}, $errorIn)';
  return sig.consumed('error out') ? ['final ${LvRuntimeType.error} ${sig.target('error out')} = $body;'] : ['$body;'];
}

List<String>? _openViReference(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final path = sig.input('vi path');
  if (path == null) return sig.refuse('has its "vi path" terminal unwired');
  if (!_inputsAre(sig, {
    'vi path': ((type) => _isPath(type) || _isText(type), 'a path or a string'),
    'application reference': (_isRefnum, 'a refnum'),
    'type specifier VI Refnum (for type only)': (_isRefnum, 'a refnum'),
    'options': (_isInt, 'an integer'),
    'password': (_isText, 'a string'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  final application = sig.arg('application reference'), options = sig.arg('options'), password = sig.arg('password');
  final specifier = sig.arg('type specifier VI Refnum (for type only)'), errorIn = sig.arg('error in');
  if (application == null || options == null || password == null || specifier == null || errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(
    sig,
    '${LvRuntimeCall.environment}.openViReference(applicationReference: $application, viPath: ${path.expression}, '
    'options: $options, password: $password, typeSpecifier: $specifier, errorIn: $errorIn)',
    [('viReference', 'vi reference'), ('errorOut', 'error out')],
  );
}

List<String>? _castReference(
  LvPrimCall call,
  String method,
  String referenceTerminal,
  String targetTerminal,
  String output,
) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final reference = sig.input(referenceTerminal), target = sig.input(targetTerminal);
  if (reference == null || target == null) return sig.refuse('has its reference or target class unwired');
  if (!_inputsAre(sig, {
    referenceTerminal: (_isRefnum, 'a refnum'),
    targetTerminal: (_isRefnum, 'a refnum'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(
    sig,
    '${LvRuntimeCall.environment}.$method(${reference.expression}, ${target.expression}, $errorIn)',
    [(method == 'preserveRunTimeClass' ? 'object' : 'reference', output), ('errorOut', 'error out')],
  );
}

List<String>? _toMoreGenericClass(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final reference = sig.input('reference'), target = sig.input('target class');
  if (reference == null || target == null) return sig.refuse('has its reference or target class unwired');
  if (!_isRefnum(reference.type) || !_isRefnum(target.type)) {
    return sig.typeRefusal('reference', reference.type, 'a refnum');
  }
  call.requireImport(kLvRuntimeImport);
  return _bindSingle(
    sig,
    'generic class reference',
    '${LvRuntimeCall.environment}.toMoreGenericClass(${reference.expression}, ${target.expression})',
    sideEffect: false,
  );
}

List<String>? _newViObject(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final owner = sig.input('owner refnum'), objectClass = sig.input('vi object class'), location = sig.input('location');
  if (owner == null || objectClass == null || location == null) {
    return sig.refuse('has its owner, class or location unwired');
  }
  if (!_inputsAre(sig, {
    'owner refnum': (_isRefnum, 'a refnum'),
    'vi object class': (_isRefnum, 'a refnum'),
    'style': (_isInt, 'an integer'),
    'auto wire?': (_isBool, 'a boolean'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  final style = sig.arg('style'), autoWire = sig.arg('auto wire?'), path = sig.arg('path'), bounds = sig.arg('bounds');
  final errorIn = sig.arg('error in');
  if (style == null || autoWire == null || path == null || bounds == null || errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindFields(
    sig,
    '${LvRuntimeCall.environment}.newViObject(owner: ${owner.expression}, viObjectClass: ${objectClass.expression}, '
    'style: $style, location: ${location.expression}, autoWire: $autoWire, path: $path, bounds: $bounds, errorIn: $errorIn)',
    [('object', 'object refnum'), ('errorOut', 'error out')],
  );
}

List<String>? _environmentNullary(
  LvPrimCall call,
  String output,
  String method,
  bool Function(LvWireType) accepts,
  String wanted,
) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final out = sig.output(output);
  if (out == null) return const [];
  if (!accepts(out.type)) return sig.typeRefusal(output, out.type, wanted);
  call.requireImport(kLvRuntimeImport);
  return ['final ${out.type.dartType} ${out.expression} = ${LvRuntimeCall.environment}.$method();'];
}

List<String>? _callChain(LvPrimCall call) => _environmentNullary(
  call,
  'call chain',
  'callChain',
  (type) => _is1d(type) && type.element.carrier == LvCarrier.text,
  'a 1-D array of strings',
);

List<String>? _firstCall(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final out = sig.output('First Call?');
  if (out == null) return const [];
  if (!_isBool(out.type)) return sig.typeRefusal('First Call?', out.type, 'a boolean');
  call.requireImport(kLvRuntimeImport);
  return ['final bool ${out.expression} = ${LvRuntimeCall.environment}.firstCall(${call.ports.first});'];
}

List<String>? _oneButtonDialog(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final message = sig.input('message');
  if (message == null) return sig.refuse('has its "message" terminal unwired');
  if (!_inputsAre(sig, {'message': (_isText, 'a string'), 'button name': (_isText, 'a string')})) return null;
  final button = sig.arg('button name');
  if (button == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindSingle(sig, 'true', '${LvRuntimeCall.environment}.oneButtonDialog(${message.expression}, $button)');
}

List<String>? _twoButtonDialog(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final message = sig.input('message');
  if (message == null) return sig.refuse('has its "message" terminal unwired');
  if (!_inputsAre(sig, {
    'message': (_isText, 'a string'),
    'T button name': (_isText, 'a string'),
    'F button name': (_isText, 'a string'),
  })) {
    return null;
  }
  final tName = sig.arg('T button name'), fName = sig.arg('F button name');
  if (tName == null || fName == null) return null;
  call.requireImport(kLvRuntimeImport);
  return _bindSingle(
    sig,
    'T button?',
    '${LvRuntimeCall.environment}.twoButtonDialog(${message.expression}, $tName, $fName)',
  );
}

List<String>? _fileDialog(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  if (!_inputsAre(sig, {
    'start path': (_isPath, 'a path'),
    'prompt': (_isText, 'a string'),
    'pattern': (_isText, 'a string'),
    'default name': (_isText, 'a string'),
    'button label': (_isText, 'a string'),
    'pattern label': (_isText, 'a string'),
    'error in': (_isError, 'an error cluster'),
  })) {
    return null;
  }
  final arguments = <String>[];
  for (final (terminal, parameter) in [
    ('start path', 'startPath'),
    ('prompt', 'prompt'),
    ('pattern', 'pattern'),
    ('default name', 'defaultName'),
    ('button label', 'buttonLabel'),
    ('pattern label', 'patternLabel'),
    ('error in', 'errorIn'),
  ]) {
    final value = sig.arg(terminal);
    if (value == null) return null;
    arguments.add('$parameter: $value');
  }
  call.requireImport(kLvRuntimeImport);
  return _bindFields(sig, '${LvRuntimeCall.environment}.fileDialog(${arguments.join(', ')})', [
    ('path', 'selected path'),
    ('exists', 'exists'),
    ('cancelled', 'cancelled'),
    ('errorOut', 'error out'),
  ]);
}

List<String>? _stopOrQuit(LvPrimCall call, String terminal, String method) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  if (!_inputsAre(sig, {terminal: (_isBool, 'a boolean')})) return null;
  final flag = sig.arg(terminal);
  if (flag == null) return null;
  call.requireImport(kLvRuntimeImport);
  return ['${LvRuntimeCall.environment}.$method($flag);'];
}

List<String>? _permissions(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final path = sig.input('path');
  if (path == null) return sig.refuse('has its "path" terminal unwired');
  if (!_inputsAre(sig, {'path': (_isPath, 'a path'), 'error in': (_isError, 'an error cluster')})) return null;
  final errorIn = sig.arg('error in');
  if (errorIn == null) return null;
  call.requireImport(kLvRuntimeImport);
  if (call.op == PrimOp.getPermissions) {
    final lines = <String>[];
    if (sig.consumed('path out')) {
      lines.add('final ${LvRuntimeType.path} ${sig.target('path out')} = ${path.expression};');
    }
    lines.addAll(
      _bindFields(sig, '${LvRuntimeCall.environment}.getPermissions(${path.expression}, $errorIn)', [
        ('permissions', 'permissions'),
        ('owner', 'owner'),
        ('group', 'group'),
        ('errorOut', 'error out'),
      ]),
    );
    return lines;
  }
  final permissions = sig.input('permissions');
  if (permissions == null) return sig.refuse('has its "permissions" terminal unwired');
  if (!_inputsAre(sig, {
    'permissions': (_isInt, 'an integer'),
    'new owner': (_isText, 'a string'),
    'new group': (_isText, 'a string'),
  })) {
    return null;
  }
  final owner = sig.arg('new owner'), group = sig.arg('new group');
  if (owner == null || group == null) return null;
  final lines = <String>[];
  if (sig.consumed('path out')) {
    lines.add('final ${LvRuntimeType.path} ${sig.target('path out')} = ${path.expression};');
  }
  final set =
      '${LvRuntimeCall.environment}.setPermissions(${path.expression}, ${permissions.expression}, $owner, $group, $errorIn)';
  lines.add(sig.consumed('error out') ? 'final ${LvRuntimeType.error} ${sig.target('error out')} = $set;' : '$set;');
  return lines;
}

/// A session primitive: every input in signature order to `lvEnvironment.session`, every
/// output read back from its result in signature order.
List<String>? _session(LvPrimCall call) {
  final sig = LvSignedCall.of(call);
  if (sig == null) return null;
  final arguments = <String>[];
  for (final index in sig.signature.inputIndices) {
    final value = sig.arg(sig.signature.terminals[index].name);
    if (value == null) return null;
    arguments.add(value);
  }
  call.requireImport(kLvRuntimeImport);
  final invocation =
      "${LvRuntimeCall.environment}.session('${_jsonKey(call.op!.opName)}', <Object?>[${arguments.join(', ')}])";
  if (!sig.anyConsumed) return ['$invocation;'];
  final result = call.names.role(LvNameRole.value);
  final lines = ['final $result = $invocation;'];
  var slot = 0;
  for (final index in sig.signature.outputIndices) {
    final out = sig.output(sig.signature.terminals[index].name);
    if (out != null) {
      lines.add('final ${out.type.dartType} ${out.expression} = $result[$slot] as ${out.type.dartType};');
    }
    slot++;
  }
  return lines;
}

/// Catalogued primitives that lower through their signature, by family.
final Map<PrimOp, LvLowering> kLvFamilyLowerings = {
  PrimOp.subtract: (call) => _orderedBySignature(call, '-'),
  PrimOp.divide: _divideBySignature,
  PrimOp.quotientRemainder: _quotientRemainderBySignature,
  PrimOp.greater: (call) => _orderedBySignature(call, '>', predicate: true),
  PrimOp.less: (call) => _orderedBySignature(call, '<', predicate: true),
  PrimOp.greaterOrEqual: (call) => _orderedBySignature(call, '>=', predicate: true),
  PrimOp.lessOrEqual: (call) => _orderedBySignature(call, '<=', predicate: true),
  PrimOp.maxAndMin: _maxAndMin,
  PrimOp.squareRoot: (call) => _floatFunction(call, LvRuntimeCall.squareRoot),
  PrimOp.sine: (call) => _floatFunction(call, LvRuntimeCall.sine),
  PrimOp.cosine: (call) => _floatFunction(call, LvRuntimeCall.cosine),
  PrimOp.logarithmBase10: (call) => _floatFunction(call, LvRuntimeCall.logarithmBase10),
  PrimOp.powerOf10: (call) => _floatFunction(call, LvRuntimeCall.powerOf10),
  PrimOp.powerOfX: _powerOfX,
  PrimOp.square: _square,
  PrimOp.booleanToZeroOne: _booleanToZeroOne,
  PrimOp.numberToBooleanArray: _numberToBooleanArray,
  PrimOp.toUpperCase: _toUpperCase,
  PrimOp.reverseString: _reverseString,
  PrimOp.numberToDecimalString: _numberToDecimalString,
  PrimOp.decimalStringToNumber: (call) =>
      _stringToNumber(call, LvRuntimeCall.decimalStringToNumber, defaultSigned: true),
  PrimOp.hexadecimalStringToNumber: (call) =>
      _stringToNumber(call, LvRuntimeCall.hexadecimalStringToNumber, defaultSigned: false),
  PrimOp.fractExpStringToNumber: _fractExpStringToNumber,
  PrimOp.numberToFractionalString: _numberToFractionalString,
  PrimOp.pickLine: _pickLine,
  PrimOp.searchSplitString: _searchSplitString,
  PrimOp.searchAndReplaceString: _searchAndReplaceString,
  PrimOp.spreadsheetStringToArray: _spreadsheetStringToArray,
  PrimOp.arrayToSpreadsheetString: _arrayToSpreadsheetString,
  PrimOp.flattenToString: _flattenToString,
  PrimOp.flattenToJson: _flattenToJson,
  PrimOp.pathToString: _pathToString,
  PrimOp.stringToPath: _stringToPath,
  PrimOp.stripPath: _stripPath,
  PrimOp.isPathAndNotEmpty: _isPathAndNotEmpty,
  PrimOp.pathToArrayOfStrings: _pathToArrayOfStrings,
  PrimOp.arrayOfStringsToPath: _arrayOfStringsToPath,
  PrimOp.sort1dArray: _sort1dArray,
  PrimOp.transpose2dArray: _transpose2dArray,
  PrimOp.arrayMaxAndMin: _arrayMaxAndMin,
  PrimOp.orArrayElements: (call) => _booleanArrayReduction(call, LvRuntimeCall.orArrayElements, 'logical OR'),
  PrimOp.andArrayElements: (call) => _booleanArrayReduction(call, LvRuntimeCall.andArrayElements, 'logical AND'),
  PrimOp.multiplyArrayElements: _multiplyArrayElements,
  PrimOp.split1dArray: _split1dArray,
  PrimOp.threshold1dArray: _threshold1dArray,
  PrimOp.matrixSize: _matrixSize,
  PrimOp.clusterToArray: _clusterToArray,
  PrimOp.arrayToCluster: _arrayToCluster,
  PrimOp.toVariant: _toVariant,
  PrimOp.variantToData: _variantToData,
  PrimOp.setVariantAttribute: _setVariantAttribute,
  PrimOp.getVariantAttribute: _getVariantAttribute,
  PrimOp.variantToFlattenedString: _variantToFlattenedString,
  PrimOp.tickCount: _tickCount,
  PrimOp.getDateTimeInSeconds: _getDateTimeInSeconds,
  PrimOp.waitUntilNextMsMultiple: _waitUntilNextMsMultiple,
  PrimOp.formatDateTimeString: _formatDateTimeString,
  PrimOp.toTimeStamp: _toTimeStamp,
  PrimOp.openCreateReplaceFile: _openCreateReplaceFile,
  PrimOp.closeFile: _closeFile,
  PrimOp.readFromTextFile: _readFromTextFile,
  PrimOp.writeToTextFile: _writeToTextFile,
  PrimOp.readFromBinaryFile: _readFromBinaryFile,
  PrimOp.writeToBinaryFile: _writeToBinaryFile,
  PrimOp.createFolder: _createFolder,
  PrimOp.delete: _delete,
  PrimOp.copy: (call) => _copyOrMove(call, LvRuntimeCall.copy),
  PrimOp.move: (call) => _copyOrMove(call, LvRuntimeCall.move),
  PrimOp.getFileSize: _getFileSize,
  PrimOp.setFileSize: _setFileSize,
  PrimOp.setFilePosition: _setFilePosition,
  PrimOp.fileDirectoryInfo: _fileDirectoryInfo,
  PrimOp.listFolder: _listFolder,
  PrimOp.getPermissions: _permissions,
  PrimOp.setPermissions: _permissions,
  PrimOp.fileDialog: _fileDialog,
  PrimOp.obtainQueue: _obtainQueue,
  PrimOp.releaseQueue: _releaseQueue,
  PrimOp.enqueueElement: _enqueueElement,
  PrimOp.getQueueStatus: _getQueueStatus,
  PrimOp.sendNotification: _sendNotification,
  PrimOp.waitOnNotification: _waitOnNotification,
  PrimOp.newDataValueReference: _newDataValueReference,
  PrimOp.deleteDataValueReference: _deleteDataValueReference,
  PrimOp.createUserEvent: _createUserEvent,
  PrimOp.generateUserEvent: _generateUserEvent,
  PrimOp.destroyUserEvent: (call) => _referenceErrorOnly(call, 'user event', '${LvRuntimeType.userEvent}.destroy'),
  PrimOp.unregisterForEvents: (call) =>
      _referenceErrorOnly(call, 'event registration refnum', '${LvRuntimeType.eventRegistration}.unregister'),
  PrimOp.closeReference: _closeReference,
  PrimOp.openViReference: _openViReference,
  PrimOp.toMoreSpecificClass: (call) =>
      _castReference(call, 'toMoreSpecificClass', 'reference', 'target class', 'specific class reference'),
  PrimOp.preserveRunTimeClass: (call) =>
      _castReference(call, 'preserveRunTimeClass', 'object in', 'target object', 'object out'),
  PrimOp.toMoreGenericClass: _toMoreGenericClass,
  PrimOp.newViObject: _newViObject,
  PrimOp.callChain: _callChain,
  PrimOp.currentVisPath: (call) => _environmentNullary(call, 'path', 'currentVisPath', _isPath, 'a path'),
  PrimOp.viLibrary: (call) => _environmentNullary(call, 'path', 'viLibrary', _isPath, 'a path'),
  PrimOp.currentVisMenubar: (call) =>
      _environmentNullary(call, 'menu reference', 'currentVisMenubar', _isRefnum, 'a refnum'),
  PrimOp.firstCall: _firstCall,
  PrimOp.oneButtonDialog: _oneButtonDialog,
  PrimOp.twoButtonDialog: _twoButtonDialog,
  PrimOp.stop: (call) => _stopOrQuit(call, 'stop?', 'stop'),
  PrimOp.quitLabview: (call) => _stopOrQuit(call, 'quit?', 'quitLabview'),
  PrimOp.ipToString: _session,
  PrimOp.stringToIp: _session,
  PrimOp.tcpOpenConnection: _session,
  PrimOp.tcpRead: _session,
  PrimOp.tcpWrite: _session,
  PrimOp.tcpCloseConnection: _session,
  PrimOp.visaClose: _session,
  PrimOp.visaLock: _session,
  PrimOp.tdmsOpen: _session,
  PrimOp.tdmsWrite: _session,
  PrimOp.tdmsClose: _session,
  PrimOp.tdmsSetProperties: _session,
  PrimOp.openPythonSession: _session,
  PrimOp.closePythonSession: _session,
};
