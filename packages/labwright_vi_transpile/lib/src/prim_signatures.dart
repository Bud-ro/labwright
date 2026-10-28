import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// One terminal of a primitive in the order its node's terminal holders are stored.
class LvPrimTerminalSpec {
  const LvPrimTerminalSpec.input(this.name, {this.defaultText, this.labels = const {}, this.isError = false})
    : isInput = true;

  const LvPrimTerminalSpec.output(this.name, {this.labels = const {}, this.isError = false})
    : isInput = false,
      defaultText = null;

  /// The reference's name for the terminal.
  final String name;

  final bool isInput;

  /// The Dart expression an unwired input takes, or null when the input must be wired.
  final String? defaultText;

  /// The labels the terminal's own type descriptor carries across the corpus when its type is
  /// fixed; empty for a terminal whose type, and so whose label, follows the wire.
  final Set<String> labels;

  /// Whether the terminal is an error cluster.
  final bool isError;
}

/// A primitive's terminals in heap child order, for nodes drawn with exactly this many.
class LvPrimSignature {
  const LvPrimSignature(this.op, this.terminals);

  final PrimOp op;

  final List<LvPrimTerminalSpec> terminals;

  int get length => terminals.length;

  /// The child index of the terminal named [name].
  int indexOf(String name) {
    for (var i = 0; i < terminals.length; i++) {
      if (terminals[i].name == name) return i;
    }
    throw ArgumentError.value(name, 'name', 'not a terminal of ${op.opName}');
  }

  Iterable<int> get inputIndices => [
    for (var i = 0; i < terminals.length; i++)
      if (terminals[i].isInput) i,
  ];

  Iterable<int> get outputIndices => [
    for (var i = 0; i < terminals.length; i++)
      if (!terminals[i].isInput) i,
  ];

  /// The signature of [op] for a node with [holderCount] terminal holders, or null when the
  /// corpus draws no such node and so its order is not decoded.
  static LvPrimSignature? of(PrimOp op, int holderCount) {
    for (final signature in kLvPrimSignatures[op] ?? const <LvPrimSignature>[]) {
      if (signature.length == holderCount) return signature;
    }
    return null;
  }
}

const String kLvErrorInLabel = 'error in (no error)';

const String kLvErrorInShortLabel = 'error in';

const String kLvErrorOutLabel = 'error out';

const LvPrimTerminalSpec _errorIn = LvPrimTerminalSpec.input(
  'error in',
  labels: {kLvErrorInLabel, kLvErrorInShortLabel},
  isError: true,
  defaultText: 'LvError.none',
);

const LvPrimTerminalSpec _errorOut = LvPrimTerminalSpec.output(
  'error out',
  labels: {kLvErrorOutLabel},
  isError: true,
);

LvPrimTerminalSpec _in(String name, {String? defaultText, String? label, Set<String> labels = const {}}) =>
    LvPrimTerminalSpec.input(name, defaultText: defaultText, labels: label == null ? labels : {label});

LvPrimTerminalSpec _out(String name, {String? label, Set<String> labels = const {}}) =>
    LvPrimTerminalSpec.output(name, labels: label == null ? labels : {label});

/// `[result, y, x]`: the output first, then the operands bottom-up.
List<LvPrimTerminalSpec> _binary(String result) => [_out(result), _in('y'), _in('x')];

List<LvPrimTerminalSpec> _unary(String result, String operand) => [_out(result), _in(operand)];

/// Every primitive's terminals in heap child order, keyed by [PrimOp], one signature per
/// holder count the corpus draws. A primitive absent from the corpus has none.
final Map<PrimOp, List<LvPrimSignature>> kLvPrimSignatures = () {
  final byOp = <PrimOp, List<LvPrimSignature>>{};
  for (final signature in _kSignatures) {
    byOp.putIfAbsent(signature.op, () => []).add(signature);
  }
  return byOp;
}();

final List<LvPrimSignature> _kSignatures = [
  LvPrimSignature(PrimOp.complexToPolar, [_in('r * e^(i*theta)'), _out('r'), _out('theta')]),
  LvPrimSignature(PrimOp.reImToComplex, _binary('x + iy')),
  LvPrimSignature(PrimOp.add, _binary('x+y')),
  LvPrimSignature(PrimOp.subtract, _binary('x-y')),
  LvPrimSignature(PrimOp.multiply, _binary('x*y')),
  LvPrimSignature(PrimOp.divide, _binary('x/y')),
  LvPrimSignature(PrimOp.quotientRemainder, [_out('floor(x/y)'), _out('x-y*floor(x/y)'), _in('y'), _in('x')]),
  LvPrimSignature(PrimOp.increment, _unary('x+1', 'x')),
  LvPrimSignature(PrimOp.decrement, _unary('x-1', 'x')),
  LvPrimSignature(PrimOp.squareRoot, _unary('sqrt(x)', 'x')),
  LvPrimSignature(PrimOp.and, _binary('x .and. y?')),
  LvPrimSignature(PrimOp.or, _binary('x .or. y?')),
  LvPrimSignature(PrimOp.exclusiveOr, _binary('x .xor. y?')),
  LvPrimSignature(PrimOp.not, _unary('.not. x?', 'x')),
  LvPrimSignature(PrimOp.randomNumber, [_out('number (0 to 1)', label: 'number: 0 to 1')]),
  LvPrimSignature(PrimOp.pathToString, _unary('string', 'path')),
  LvPrimSignature(PrimOp.stringToPath, _unary('path', 'string')),
  LvPrimSignature(PrimOp.logicalShift, [_out('x << y'), _in('x'), _in('y')]),
  LvPrimSignature(PrimOp.firstCall, [_out('First Call?', label: 'First Call?: T/F')]),
  LvPrimSignature(PrimOp.equal, _binary('x = y?')),
  LvPrimSignature(PrimOp.greaterOrEqual, _binary('x >= y?')),
  LvPrimSignature(PrimOp.lessOrEqual, _binary('x <= y?')),
  LvPrimSignature(PrimOp.notEqual, _binary('x != y?')),
  LvPrimSignature(PrimOp.maxAndMin, [_out('min(x, y)'), _out('max(x, y)'), _in('y'), _in('x')]),
  LvPrimSignature(PrimOp.greater, _binary('x > y?')),
  LvPrimSignature(PrimOp.less, _binary('x < y?')),
  LvPrimSignature(PrimOp.emptyStringPath, _unary('empty?', 'string/path')),
  LvPrimSignature(PrimOp.equalToZero, _unary('x = 0?', 'x')),
  LvPrimSignature(PrimOp.greaterOrEqualToZero, _unary('x >= 0?', 'x')),
  LvPrimSignature(PrimOp.lessOrEqualToZero, _unary('x <= 0?', 'x')),
  LvPrimSignature(PrimOp.notEqualToZero, _unary('x != 0?', 'x')),
  LvPrimSignature(PrimOp.greaterThanZero, _unary('x > 0?', 'x')),
  LvPrimSignature(PrimOp.lessThanZero, _unary('x < 0?', 'x')),
  LvPrimSignature(PrimOp.sort1dArray, _unary('sorted array', 'array')),
  LvPrimSignature(PrimOp.inRangeAndCoerce, [
    _out('In Range?'),
    _out('coerced(x)'),
    _in('lower limit'),
    _in('x'),
    _in('upper limit'),
  ]),
  LvPrimSignature(PrimOp.notANumberPathRefnum, _unary('NaN/Path/Refnum?', 'number/path/refnum')),
  LvPrimSignature(PrimOp.toByteInteger, _unary('8bit integer', 'number')),
  LvPrimSignature(PrimOp.toWordInteger, _unary('16bit integer', 'number')),
  LvPrimSignature(PrimOp.toLongInteger, _unary('32bit integer', 'number')),
  LvPrimSignature(PrimOp.toUnsignedByteInteger, _unary('unsigned 8bit integer', 'number')),
  LvPrimSignature(PrimOp.toUnsignedWordInteger, _unary('unsigned 16bit integer', 'number')),
  LvPrimSignature(PrimOp.toUnsignedLongInteger, _unary('unsigned 32bit integer', 'number')),
  LvPrimSignature(PrimOp.toSinglePrecisionFloat, _unary('single precision float', 'number')),
  LvPrimSignature(PrimOp.toDoublePrecisionFloat, _unary('double precision float', 'number')),
  LvPrimSignature(PrimOp.toQuadInteger, _unary('64bit integer', 'number')),
  LvPrimSignature(PrimOp.toUnsignedQuadInteger, _unary('unsigned 64bit integer', 'number')),
  LvPrimSignature(PrimOp.swapBytes, _unary('byte swapped', 'data')),
  LvPrimSignature(PrimOp.swapWords, _unary('word swapped', 'data')),
  LvPrimSignature(PrimOp.flattenToString, [
    _errorOut,
    _out('type string (7.x only)'),
    _out('data string'),
    _errorIn,
    _in('byte order', defaultText: '0'),
    _in('prepend array or string size?', defaultText: 'true', label: 'prepend array or string size? (T)'),
    _in('anything'),
  ]),
  LvPrimSignature(PrimOp.unflattenFromString, [
    _errorOut,
    _out('value'),
    _out('rest of the binary string'),
    _in('type'),
    _errorIn,
    _in('byte order', defaultText: '0'),
    _in(
      'data includes array or string size?',
      defaultText: 'true',
      label: 'data includes array or string size? (T)',
    ),
    _in('binary string'),
  ]),
  LvPrimSignature(PrimOp.typeCast, [_in('x'), _in('type'), _out('*(type *) &x')]),
  LvPrimSignature(PrimOp.booleanToZeroOne, _unary('0, 1', 'Boolean')),
  LvPrimSignature(PrimOp.arrayToCluster, _unary('cluster', 'array')),
  LvPrimSignature(PrimOp.clusterToArray, _unary('array', 'cluster')),
  LvPrimSignature(PrimOp.numberToDecimalString, [
    _out('decimal integer string'),
    _in('width'),
    _in('number'),
  ]),
  LvPrimSignature(PrimOp.numberToHexadecimalString, [
    _out('hex integer string'),
    _in('width'),
    _in('number'),
  ]),
  LvPrimSignature(PrimOp.decimalStringToNumber, [
    _out('number'),
    _out('offset past number', label: 'offset past number'),
    _in('default'),
    _in('offset', defaultText: '0'),
    _in('string'),
  ]),
  LvPrimSignature(PrimOp.hexadecimalStringToNumber, [
    _out('number'),
    _out('offset past number', label: 'offset past number'),
    _in('default'),
    _in('offset', defaultText: '0'),
    _in('string'),
  ]),
  LvPrimSignature(PrimOp.fractExpStringToNumber, [
    _out('number'),
    _out('offset past number', label: 'offset past number'),
    _in('use system decimal point', defaultText: 'true', label: 'use system decimal point (T)'),
    _in('default', defaultText: '0.0'),
    _in('offset', defaultText: '0'),
    _in('string'),
  ]),
  LvPrimSignature(PrimOp.toUpperCase, _unary('all upper case string', 'string')),
  LvPrimSignature(PrimOp.toLowerCase, _unary('all lower case string', 'string')),
  LvPrimSignature(PrimOp.sine, _unary('sin(x)', 'x')),
  LvPrimSignature(PrimOp.cosine, _unary('cos(x)', 'x')),
  LvPrimSignature(PrimOp.logarithmBase10, _unary('log(x)', 'x')),
  LvPrimSignature(PrimOp.powerOf10, _unary('10^x', 'x')),
  LvPrimSignature(PrimOp.powerOfX, [_out('x^y'), _in('x'), _in('y')]),
  LvPrimSignature(PrimOp.tickCount, [_out('millisecond timer value', label: 'millisecond timer value')]),
  LvPrimSignature(PrimOp.waitMs, [
    _out('millisecond timer value', label: 'millisecond timer value'),
    _in('milliseconds to wait'),
  ]),
  LvPrimSignature(PrimOp.getDateTimeInSeconds, [_out('current time', label: 'seconds since 1Jan1904')]),
  LvPrimSignature(PrimOp.waitUntilNextMsMultiple, [
    _out('millisecond timer value', label: 'millisecond timer value'),
    _in('millisecond multiple'),
  ]),
  LvPrimSignature(PrimOp.oneButtonDialog, [
    _out('true', label: 'true'),
    _in('button name', defaultText: "'OK'"),
    _in('message'),
  ]),
  LvPrimSignature(PrimOp.twoButtonDialog, [
    _out('T button?', label: 'T button?'),
    _in('F button name', defaultText: "'Cancel'"),
    _in('T button name', defaultText: "'OK'"),
    _in('message'),
  ]),
  LvPrimSignature(PrimOp.stop, [_in('stop?', defaultText: 'true', label: 'stop? (T)')]),
  LvPrimSignature(PrimOp.quitLabview, [_in('quit?', defaultText: 'true', label: 'quit? (T)')]),
  LvPrimSignature(PrimOp.buildPath, [
    _out('appended path', label: 'appended path'),
    _in('name or relative path'),
    _in('base path', label: 'base path'),
  ]),
  LvPrimSignature(PrimOp.stripPath, [
    _in('path', label: 'path'),
    _out('stripped path', label: 'stripped path'),
    _out('name'),
  ]),
  LvPrimSignature(PrimOp.isPathAndNotEmpty, [_out('type', label: 'type'), _in('path', label: 'path')]),
  LvPrimSignature(PrimOp.arrayOfStringsToPath, [
    _in('array of strings'),
    _in('relative', defaultText: 'false', label: 'relative'),
    _out('path', label: 'path'),
  ]),
  LvPrimSignature(PrimOp.pathToArrayOfStrings, [
    _in('path', label: 'path'),
    _out('relative', label: 'relative'),
    _out('array of strings'),
  ]),
  LvPrimSignature(PrimOp.viLibrary, [_out('path', label: 'path')]),
  LvPrimSignature(PrimOp.currentVisPath, [_out('path', label: 'path')]),
  LvPrimSignature(PrimOp.stringLength, _unary('length', 'string')),
  LvPrimSignature(PrimOp.stringSubset, [
    _out('substring'),
    _in('length'),
    _in('offset', defaultText: '0'),
    _in('string'),
  ]),
  LvPrimSignature(PrimOp.numberToFractionalString, [
    _out('F-format string'),
    _in('use system decimal point', defaultText: 'true', label: 'use system decimal point (T)'),
    _in('precision', defaultText: '6'),
    _in('width'),
    _in('number'),
  ]),
  LvPrimSignature(PrimOp.pickLine, [
    _out('output string', label: 'output string'),
    _in('line index'),
    _in('multi-line string'),
    _in('string', defaultText: "''"),
  ]),
  LvPrimSignature(PrimOp.select, [_out('s? t:f'), _in('f'), _in('s'), _in('t')]),
  LvPrimSignature(PrimOp.scanValue, [
    _out('value'),
    _out('output string'),
    _in('default'),
    _in('format string'),
    _in('string'),
  ]),
  LvPrimSignature(PrimOp.matchPattern, [
    _in('string'),
    _in('regular expression'),
    _in('offset', defaultText: '0'),
    _out('before substring'),
    _out('match substring'),
    _out('after substring'),
    _out('offset past match', label: 'offset past match'),
  ]),
  LvPrimSignature(PrimOp.reverseString, _unary('reversed', 'string')),
  LvPrimSignature(PrimOp.searchSplitString, [
    _out('offset of match', label: 'offset of match'),
    _out('match + rest of string'),
    _out('substring before match'),
    _in('offset', defaultText: '0'),
    _in('search string/char', defaultText: "''"),
    _in('string'),
  ]),
  LvPrimSignature(PrimOp.spreadsheetStringToArray, [
    _out('array'),
    _in('delimiter', defaultText: r"'\t'"),
    _in('array type'),
    _in('spreadsheet string'),
    _in('format string'),
  ]),
  LvPrimSignature(PrimOp.arrayToSpreadsheetString, [
    _out('spreadsheet string', label: 'spreadsheet string'),
    _in('delimiter', defaultText: r"'\t'"),
    _in('array'),
    _in('format string'),
  ]),
  LvPrimSignature(PrimOp.rotateRightWithCarry, [
    _out('rotated value'),
    _out('lsb carry out', label: 'lsb carry out'),
    _in('value'),
    _in('carry', label: 'carry'),
  ]),
  LvPrimSignature(PrimOp.stringToByteArray, [
    _out('unsigned byte array', label: 'unsigned byte array'),
    _in('string'),
  ]),
  LvPrimSignature(PrimOp.byteArrayToString, [_out('string', label: 'string'), _in('unsigned byte array')]),
  LvPrimSignature(PrimOp.ipToString, [
    _out('name'),
    _in('dot notation?', defaultText: 'false', label: 'dot notation? (F)'),
    _in('net address'),
  ]),
  LvPrimSignature(PrimOp.stringToIp, [_out('net address'), _in('name')]),
  LvPrimSignature(PrimOp.tcpCloseConnection, [
    _errorOut,
    _out('connection ID out'),
    _errorIn,
    _in('abort', defaultText: 'false', label: 'abort (F)'),
    _in('connection ID'),
  ]),
  LvPrimSignature(PrimOp.tcpWrite, [
    _errorOut,
    _out('bytes written'),
    _out('connection ID out'),
    _errorIn,
    _in('timeout ms', defaultText: '25000'),
    _in('data in'),
    _in('connection ID'),
  ]),
  LvPrimSignature(PrimOp.tcpOpenConnection, [
    _errorOut,
    _out('connection ID', label: 'connection ID'),
    _in('local port', defaultText: '0'),
    _errorIn,
    _in('timeout ms', defaultText: '60000'),
    _in('remote port'),
    _in('address'),
  ]),
  LvPrimSignature(PrimOp.tcpRead, [
    _errorOut,
    _out('data out', label: 'data out'),
    _out('connection ID out'),
    _in('mode', defaultText: '0'),
    _errorIn,
    _in('timeout ms', defaultText: '25000'),
    _in('bytes to read'),
    _in('connection ID'),
  ]),
  LvPrimSignature(PrimOp.arraySize, _unary('size(s)', 'array')),
  LvPrimSignature(PrimOp.numberToBooleanArray, [_out('Boolean array', label: 'Boolean array'), _in('number')]),
  LvPrimSignature(PrimOp.booleanArrayToNumber, _unary('number', 'Boolean array')),
  LvPrimSignature(PrimOp.reverse1dArray, _unary('reversed array', 'array')),
  LvPrimSignature(PrimOp.search1dArray, [
    _out('index of element', label: 'index of element'),
    _in('start index', defaultText: '0'),
    _in('element'),
    _in('1D array'),
  ]),
  LvPrimSignature(PrimOp.transpose2dArray, _unary('transposed array', '2D array')),
  LvPrimSignature(PrimOp.addArrayElements, _unary('sum', 'numeric array')),
  LvPrimSignature(PrimOp.multiplyArrayElements, _unary('product', 'numeric array')),
  LvPrimSignature(PrimOp.arrayMaxAndMin, [
    _in('array'),
    _out('max value'),
    _out('max index(es)'),
    _out('min value'),
    _out('min index(es)'),
  ]),
  LvPrimSignature(PrimOp.split1dArray, [_out('second subarray'), _out('first subarray'), _in('index'), _in('array')]),
  LvPrimSignature(PrimOp.threshold1dArray, [
    _out('fractional index or x'),
    _in('start index', defaultText: '0'),
    _in('threshold y'),
    _in('array of numbers or points'),
  ]),
  LvPrimSignature(PrimOp.orArrayElements, _unary('logical OR', 'Boolean array')),
  LvPrimSignature(PrimOp.andArrayElements, _unary('logical AND', 'Boolean array')),
  LvPrimSignature(PrimOp.visaClose, [_errorOut, _errorIn, _in('VISA resource name')]),
  LvPrimSignature(PrimOp.visaLock, [
    _errorOut,
    _out('access key'),
    _out('VISA resource name out'),
    _in('lock type', defaultText: '1'),
    _errorIn,
    _in('requested key', defaultText: "''"),
    _in('timeout', defaultText: '0'),
    _in('VISA resource name'),
  ]),
  LvPrimSignature(PrimOp.callChain, [_out('call chain', label: 'call chain')]),
  LvPrimSignature(PrimOp.tdmsWrite, [
    _in('tdms file', label: 'tdms file'),
    _in('data layout', defaultText: '0'),
    _out('tdms file out', label: 'tdms file out'),
    _in('group name in', defaultText: "'Untitled'"),
    _out('group name out', label: 'group name out'),
    _in('channel name(s) in'),
    _out('channel name(s) out'),
    _in('data'),
    _errorIn,
    _errorOut,
  ]),
  LvPrimSignature(PrimOp.tdmsOpen, [
    _errorOut,
    _out('tdms file out', label: 'tdms file out'),
    _in('create index file?', defaultText: 'true', label: 'create index file? (T)'),
    _in('disable buffering?', defaultText: 'true', label: 'disable buffering (T)'),
    _in('file format version', defaultText: '2'),
    _errorIn,
    _in('byte order', defaultText: '2'),
    _in('operation', defaultText: '0'),
    _in('file path', label: 'file path'),
  ]),
  LvPrimSignature(PrimOp.tdmsClose, [
    _errorOut,
    _out('file path out', label: 'file path out'),
    _errorIn,
    _in('tdms file', label: 'tdms file'),
  ]),
  LvPrimSignature(PrimOp.tdmsSetProperties, [
    _errorOut,
    _out('channel name out', label: 'channel name out'),
    _out('group name out', label: 'group name out'),
    _out('tdms file out', label: 'tdms file out'),
    _in('property values'),
    _in('property names'),
    _errorIn,
    _in('channel name', defaultText: "''"),
    _in('group name', defaultText: "''"),
    _in('tdms file', label: 'tdms file'),
  ]),
  LvPrimSignature(PrimOp.createUserEvent, [
    _in('user event data type'),
    _errorIn,
    _out('user event out'),
    _errorOut,
  ]),
  LvPrimSignature(PrimOp.generateUserEvent, [
    _in('user event'),
    _in('event data'),
    _errorIn,
    _in('priority', defaultText: '0'),
    _out('user event out'),
    _errorOut,
  ]),
  LvPrimSignature(PrimOp.destroyUserEvent, [_in('user event'), _errorIn, _errorOut]),
  LvPrimSignature(PrimOp.unregisterForEvents, [_in('event registration refnum'), _errorIn, _errorOut]),
  LvPrimSignature(PrimOp.newDataValueReference, [
    _errorOut,
    _out('data value reference', label: 'data value reference'),
    _errorIn,
    _in('data value'),
  ]),
  LvPrimSignature(PrimOp.deleteDataValueReference, [
    _errorOut,
    _out('data value'),
    _errorIn,
    _in('data value reference'),
  ]),
  LvPrimSignature(PrimOp.searchAndReplaceString, [
    _in('input string'),
    _in('replace all?', defaultText: 'false', label: 'replace all?'),
    _in('ignore case?', defaultText: 'false', label: 'case sensitive?'),
    _in('multiline?', defaultText: 'false', label: 'multiline?'),
    _out('result string', label: 'result string'),
    _in('search string'),
    _in('replace string', defaultText: "''"),
    _out('number of replacements', label: 'number of replacements'),
    _in('offset', defaultText: '0'),
    _out('offset past replacement', label: 'offset past replacement'),
    _errorIn,
    _errorOut,
  ]),
  LvPrimSignature(PrimOp.toTimeStamp, _unary('time stamp', 'number')),
  LvPrimSignature(PrimOp.integerToFixedPointCast, [
    _in('integer', label: 'integer'),
    _in('fixed-point type', label: 'fixed-point type'),
    _out('fixed-point'),
  ]),
  LvPrimSignature(PrimOp.variantToData, [_errorIn, _errorOut, _in('variant'), _in('type'), _out('data')]),
  LvPrimSignature(PrimOp.openViReference, [
    _errorOut,
    _out('vi reference'),
    _in('password', defaultText: "''", label: 'password ("")'),
    _in('type specifier VI Refnum (for type only)', defaultText: 'LvRefnum.none'),
    _errorIn,
    _in('options', defaultText: '0'),
    _in('vi path'),
    _in('application reference', defaultText: 'LvRefnum.none', label: 'application reference (local)'),
  ]),
  LvPrimSignature(PrimOp.closeReference, [_errorOut, _errorIn, _in('reference')]),
  LvPrimSignature(PrimOp.newViObject, [
    _errorOut,
    _out('object refnum'),
    _in('bounds', defaultText: 'null', label: 'bounds'),
    _in('auto wire?', defaultText: 'false', label: 'auto wire? (F)'),
    _in('path', defaultText: 'null'),
    _in('vi object class'),
    _errorIn,
    _in('location'),
    _in('style', defaultText: '0'),
    _in('owner refnum'),
  ]),
  LvPrimSignature(PrimOp.toMoreSpecificClass, [
    _out('specific class reference'),
    _errorOut,
    _in('reference'),
    _in('target class'),
    _errorIn,
  ]),
  LvPrimSignature(PrimOp.toMoreGenericClass, [_in('reference'), _in('target class'), _out('generic class reference')]),
  LvPrimSignature(PrimOp.preserveRunTimeClass, [
    _out('object out'),
    _errorOut,
    _in('object in'),
    _in('target object'),
    _errorIn,
  ]),
  LvPrimSignature(PrimOp.openCreateReplaceFile, [
    _errorOut,
    _out('cancelled', label: 'cancelled'),
    _out('refnum out', label: 'refnum out'),
    _in('disable buffering', defaultText: 'false', label: 'disable buffering (F)'),
    _in('prompt', defaultText: "''", label: 'prompt'),
    _errorIn,
    _in('access', defaultText: '0'),
    _in('operation', defaultText: '0'),
    _in('file path', label: 'file path (use dialog)'),
  ]),
  LvPrimSignature(PrimOp.readFromBinaryFile, [
    _errorOut,
    _out('cancelled', label: 'cancelled'),
    _out('data'),
    _out('refnum out', label: 'refnum out'),
    _in('data type'),
    _in('prompt', defaultText: "''", label: 'prompt (Open existing file)'),
    _errorIn,
    _in('byte order', defaultText: '0'),
    _in('count', defaultText: '1'),
    _in('file'),
  ]),
  LvPrimSignature(PrimOp.closeFile, [
    _errorOut,
    _out('path', label: 'path'),
    _errorIn,
    _in('refnum', label: 'refnum out'),
  ]),
  LvPrimSignature(PrimOp.copy, [
    _errorOut,
    _out('cancelled', label: 'cancelled'),
    _out('new path', label: 'new path'),
    _in('prompt', defaultText: "''", label: 'prompt (Choose or enter target path for copy)'),
    _errorIn,
    _in('overwrite', defaultText: 'false', label: 'overwrite (F)'),
    _in('target path', label: 'target path (use dialog)'),
    _in('source path', label: 'source path'),
  ]),
  LvPrimSignature(PrimOp.createFolder, [
    _errorOut,
    _out('cancelled', label: 'cancelled'),
    _out('created path', label: 'created path'),
    _in('prompt', defaultText: "''", label: 'prompt (Create Folder)'),
    _errorIn,
    _in('path', label: 'path (use dialog)'),
  ]),
  LvPrimSignature(PrimOp.delete, [
    _errorOut,
    _out('cancelled', label: 'cancelled'),
    _out('deleted path', label: 'deleted path'),
    _in('prompt', defaultText: "''", label: 'prompt (Delete)'),
    _errorIn,
    _in('confirm', defaultText: 'false', label: 'confirm (F)'),
    _in('entire hierarchy', defaultText: 'false', label: 'entire hierarchy (F)'),
    _in('path', label: 'path (use dialog)'),
  ]),
  LvPrimSignature(PrimOp.fileDialog, [
    _errorOut,
    _out('cancelled', label: 'cancelled'),
    _out('exists', label: 'exists'),
    _out('selected path'),
    _in('pattern label', defaultText: "''", label: 'pattern label'),
    _in('button label', defaultText: "''", label: 'button label'),
    _in('pattern', defaultText: "''", label: 'pattern (all files)'),
    _in('prompt', defaultText: "''", label: 'prompt'),
    _errorIn,
    _in('default name', defaultText: "''", label: 'default name'),
    _in('start path', defaultText: 'const LvPath(components: [], absolute: false)', label: 'start path'),
  ]),
  LvPrimSignature(PrimOp.getFileSize, [
    _errorOut,
    _out('size (in bytes)'),
    _out('refnum out', label: 'refnum out'),
    _errorIn,
    _in('file'),
  ]),
  LvPrimSignature(PrimOp.getPermissions, [
    _errorOut,
    _out('group', label: 'group'),
    _out('owner', label: 'owner'),
    _out('path out', labels: {'path out', 'dup path'}),
    _out('permissions'),
    _errorIn,
    _in('path', label: 'path'),
  ]),
  LvPrimSignature(PrimOp.move, [
    _errorOut,
    _out('cancelled', label: 'cancelled'),
    _out('new path', label: 'new path'),
    _in('prompt', defaultText: "''", label: 'prompt (Choose or enter target path for move)'),
    _errorIn,
    _in('overwrite', defaultText: 'false', label: 'overwrite (F)'),
    _in('target path', label: 'target path (use dialog)'),
    _in('source path', label: 'source path'),
  ]),
  LvPrimSignature(PrimOp.readFromTextFile, [
    _errorOut,
    _out('cancelled', label: 'cancelled'),
    _out('text'),
    _out('refnum out', label: 'refnum out'),
    _in('prompt', defaultText: "''", label: 'prompt (Open existing file)'),
    _errorIn,
    _in('count', defaultText: '-1'),
    _in('file'),
  ]),
  LvPrimSignature(PrimOp.setFilePosition, [
    _errorOut,
    _out('refnum out', label: 'refnum'),
    _errorIn,
    _in('from', defaultText: '0'),
    _in('offset (in bytes)', defaultText: '0'),
    _in('refnum', label: 'refnum'),
  ]),
  LvPrimSignature(PrimOp.setFileSize, [
    _errorOut,
    _out('refnum out', label: 'refnum out'),
    _errorIn,
    _in('size (in bytes)'),
    _in('file', label: 'refnum out'),
  ]),
  LvPrimSignature(PrimOp.setPermissions, [
    _errorOut,
    _out('path out', labels: {'path out', 'dup path'}),
    _in('permissions'),
    _errorIn,
    _in('new group', defaultText: "''", label: 'new group'),
    _in('new owner', defaultText: "''", label: 'new owner'),
    _in('path', label: 'path'),
  ]),
  LvPrimSignature(PrimOp.writeToBinaryFile, [
    _errorOut,
    _out('cancelled', label: 'cancelled'),
    _out('refnum out', label: 'refnum out'),
    _in('prepend array or string size?', defaultText: 'true', label: 'prepend array or string size? (T)'),
    _in('prompt', defaultText: "''", label: 'prompt (Choose or enter file path)'),
    _errorIn,
    _in('byte order', defaultText: '0'),
    _in('data'),
    _in('file'),
  ]),
  LvPrimSignature(PrimOp.writeToTextFile, [
    _errorOut,
    _out('cancelled', label: 'cancelled'),
    _out('refnum out', label: 'refnum out'),
    _in('prompt', defaultText: "''", label: 'prompt (Choose or enter file path)'),
    _errorIn,
    _in('text'),
    _in('file'),
  ]),
  LvPrimSignature(PrimOp.fileDirectoryInfo, [
    _errorOut,
    _out('last mod', label: 'last mod'),
    _out('size', label: 'size'),
    _out('path out', labels: {'path out', 'dup path'}),
    _out('resolved path', label: 'resolved path'),
    _out('directory', label: 'directory'),
    _out('shortcut', label: 'shortcut'),
    _errorIn,
    _in('path', label: 'path'),
  ]),
  LvPrimSignature(PrimOp.listFolder, [
    _errorOut,
    _out('folder names', label: 'folder names'),
    _out('filenames', labels: {'file names', 'filenames'}),
    _out('path out', labels: {'path out', 'dup path'}),
    _in('datalog type', defaultText: 'null'),
    _in('pattern', defaultText: "''"),
    _errorIn,
    _in('path', label: 'path'),
  ]),
  LvPrimSignature(PrimOp.formatDateTimeString, [
    _out('date/time string', label: 'date/time string'),
    _in('UTC format', defaultText: 'false', label: 'UTC format'),
    _in('time stamp'),
    _in('time format string', defaultText: "'%c'"),
  ]),
  LvPrimSignature(PrimOp.toVariant, [_out('variant', label: 'Variant'), _in('anything')]),
  LvPrimSignature(PrimOp.flattenedStringToVariant, [
    _errorOut,
    _out('variant', label: 'Variant'),
    _errorIn,
    _in('data string'),
    _in('type string'),
  ]),
  LvPrimSignature(PrimOp.variantToFlattenedString, [
    _in('variant', label: 'Variant'),
    _out('type string'),
    _out('data string'),
  ]),
  LvPrimSignature(PrimOp.setVariantAttribute, [
    _errorOut,
    _out('replaced', label: 'replaced'),
    _out('variant out'),
    _errorIn,
    _in('value'),
    _in('name'),
    _in('variant'),
  ]),
  LvPrimSignature(PrimOp.getVariantAttribute, [
    _errorOut,
    _out('values'),
    _out('names'),
    _out('duplicate variant'),
    _errorIn,
    _in('default value'),
    _in('name'),
    _in('variant'),
  ]),
  LvPrimSignature(PrimOp.matrixSize, [
    _in('matrix'),
    _out('number of columns'),
    _out('number of rows'),
  ]),
  LvPrimSignature(PrimOp.currentVisMenubar, [_out('menu reference', label: 'menubar')]),
  LvPrimSignature(PrimOp.sendNotification, [
    _in('notifier'),
    _in('notification'),
    _errorIn,
    _out('notifier out'),
    _errorOut,
  ]),
  LvPrimSignature(PrimOp.waitOnNotification, [
    _in('notifier'),
    _in('ignore previous', defaultText: 'false', label: 'ignore previous (F)'),
    _in('timeout in ms', defaultText: '-1'),
    _errorIn,
    _out('notifier out'),
    _out('notification'),
    _out('timed out?', label: 'timed out?'),
    _errorOut,
  ]),
  LvPrimSignature(PrimOp.obtainQueue, [
    _in('name', defaultText: "''"),
    _in('element data type'),
    _in('create if not found?', defaultText: 'true', label: 'create if not found? (T)'),
    _errorIn,
    _in('max queue size', defaultText: '-1'),
    _out('queue out', label: 'queue out'),
    _out('created new?', label: 'created new?'),
    _errorOut,
  ]),
  LvPrimSignature(PrimOp.releaseQueue, [
    _in('queue'),
    _in('force destroy?', defaultText: 'false', label: 'force destroy? (F)'),
    _errorIn,
    _out('queue name', label: 'queue name'),
    _out('remaining elements', label: 'remaining elements'),
    _errorOut,
  ]),
  LvPrimSignature(PrimOp.getQueueStatus, [
    _in('queue'),
    _in('return elements?', defaultText: 'false', label: 'return elements? (F)'),
    _errorIn,
    _out('max queue size', label: 'max queue size'),
    _out('elements', label: 'elements'),
    _out('queue name'),
    _out('# elements in queue', label: '# elements in queue'),
    _out('queue out'),
    _out('# pending remove', label: '# pending remove'),
    _out('# pending insert', label: '# pending insert'),
    _errorOut,
  ]),
  LvPrimSignature(PrimOp.enqueueElement, [
    _in('queue'),
    _in('element'),
    _in('timeout in ms', defaultText: '-1'),
    _errorIn,
    _out('queue out'),
    _out('timed out?', label: 'timed out?'),
    _errorOut,
  ]),
  LvPrimSignature(PrimOp.square, _unary('x^2', 'x')),
  LvPrimSignature(PrimOp.emptyArray, [_out('empty?', label: 'empty?'), _in('array')]),
  LvPrimSignature(PrimOp.flattenToJson, [
    _in('anything'),
    _errorIn,
    _in('enable LabVIEW extensions', defaultText: 'true', label: 'enable LabVIEW extensions? (T)'),
    _out('JSON string'),
    _errorOut,
  ]),
  LvPrimSignature(PrimOp.unflattenFromJson, [
    _in('JSON string'),
    _in('type/defaults'),
    _errorIn,
    _in('path', defaultText: 'const <String>[]'),
    _in('default null elements', defaultText: 'false', label: 'default null elements? (F)'),
    _in('enable LabVIEW extensions', defaultText: 'true', label: 'enable LabVIEW extensions? (T)'),
    _in('strict validation', defaultText: 'false', label: 'strict validation? (F)'),
    _out('value'),
    _errorOut,
  ]),
  LvPrimSignature(PrimOp.openPythonSession, [
    _in('Python version'),
    _in('Python path', defaultText: 'const LvPath(components: [], absolute: false)', label: 'python path'),
    _errorIn,
    _out('session out', label: 'session out'),
    _errorOut,
  ]),
  LvPrimSignature(PrimOp.closePythonSession, [_in('session in', label: 'session in'), _errorIn, _errorOut]),
];
