/// The primitives a `primResID` names, with the basis of each name.
library;

import '../blocks/VCTP_type_pool.dart';
import 'objects.dart' show ViTypeKind;

/// Where a [PrimOp]'s name comes from.
enum PrimNameBasis {
  /// A label the corpus attaches to nodes with the id.
  corpusLabel,

  /// The id's position among neighbouring ids whose names are known.
  adjacency,

  /// An icon review.
  review,
}

/// A primitive node, keyed by its `primResID`.
enum PrimOp {
  add(1050, 'Add', PrimNameBasis.adjacency),

  subtract(1051, 'Subtract', PrimNameBasis.corpusLabel),

  multiply(1052, 'Multiply', PrimNameBasis.corpusLabel),

  divide(1053, 'Divide', PrimNameBasis.corpusLabel),

  quotientRemainder(1056, 'Quotient & Remainder', PrimNameBasis.review),

  increment(1057, 'Increment', PrimNameBasis.corpusLabel),

  decrement(1058, 'Decrement', PrimNameBasis.corpusLabel),

  squareRoot(1060, 'Square Root', PrimNameBasis.corpusLabel),

  and(1061, 'And', PrimNameBasis.adjacency),

  or(1062, 'Or', PrimNameBasis.adjacency),

  exclusiveOr(1063, 'Exclusive Or', PrimNameBasis.corpusLabel),

  not(1064, 'Not', PrimNameBasis.adjacency),

  randomNumber(1070, 'Random Number (0-1)', PrimNameBasis.corpusLabel),

  pathToString(1077, 'Path To String', PrimNameBasis.corpusLabel),

  stringToPath(1078, 'String To Path', PrimNameBasis.corpusLabel),

  logicalShift(1081, 'Logical Shift', PrimNameBasis.corpusLabel),

  firstCall(1083, 'First Call?', PrimNameBasis.corpusLabel),

  equal(1102, 'Equal?', PrimNameBasis.corpusLabel),

  notEqual(1105, 'Not Equal?', PrimNameBasis.corpusLabel),

  maxAndMin(1108, 'Max & Min', PrimNameBasis.corpusLabel),

  greater(1110, 'Greater?', PrimNameBasis.corpusLabel),

  less(1111, 'Less?', PrimNameBasis.corpusLabel),

  emptyStringPath(1112, 'Empty String/Path?', PrimNameBasis.corpusLabel),

  equalToZero(1113, 'Equal To 0?', PrimNameBasis.corpusLabel),

  greaterOrEqualToZero(1114, 'Greater Or Equal To 0?', PrimNameBasis.corpusLabel),

  lessOrEqualToZero(1115, 'Less Or Equal To 0?', PrimNameBasis.corpusLabel),

  notEqualToZero(1116, 'Not Equal To 0?', PrimNameBasis.corpusLabel),

  greaterThanZero(1117, 'Greater Than 0?', PrimNameBasis.corpusLabel),

  lessThanZero(1118, 'Less Than 0?', PrimNameBasis.corpusLabel),

  sort1dArray(1120, 'Sort 1D Array', PrimNameBasis.corpusLabel),

  inRangeAndCoerce(1127, 'In Range and Coerce', PrimNameBasis.corpusLabel),

  notANumberPathRefnum(1128, 'Not A Number/Path/Refnum?', PrimNameBasis.corpusLabel),

  toByteInteger(1140, 'To Byte Integer', PrimNameBasis.corpusLabel),

  toWordInteger(1141, 'To Word Integer', PrimNameBasis.adjacency),

  toLongInteger(1142, 'To Long Integer', PrimNameBasis.corpusLabel),

  toUnsignedByteInteger(1143, 'To Unsigned Byte Integer', PrimNameBasis.adjacency),

  toUnsignedWordInteger(1144, 'To Unsigned Word Integer', PrimNameBasis.corpusLabel),

  toUnsignedLongInteger(1145, 'To Unsigned Long Integer', PrimNameBasis.corpusLabel),

  toSinglePrecisionFloat(1146, 'To Single Precision Float', PrimNameBasis.adjacency),

  toDoublePrecisionFloat(1147, 'To Double Precision Float', PrimNameBasis.corpusLabel),

  toQuadInteger(1155, 'To Quad Integer', PrimNameBasis.review),

  toUnsignedQuadInteger(1156, 'To Unsigned Quad Integer', PrimNameBasis.review),

  swapBytes(1162, 'Swap Bytes', PrimNameBasis.review),

  swapWords(1163, 'Swap Words', PrimNameBasis.review),

  flattenToString(1164, 'Flatten To String', PrimNameBasis.corpusLabel),

  typeCast(1166, 'Type Cast', PrimNameBasis.corpusLabel),

  booleanToZeroOne(1167, 'Boolean To (0,1)', PrimNameBasis.corpusLabel),

  clusterToArray(1169, 'Cluster To Array', PrimNameBasis.corpusLabel),

  numberToDecimalString(1180, 'Number To Decimal String', PrimNameBasis.corpusLabel),

  decimalStringToNumber(1184, 'Decimal String To Number', PrimNameBasis.corpusLabel),

  hexadecimalStringToNumber(1185, 'Hexadecimal String To Number', PrimNameBasis.review),

  fractExpStringToNumber(1187, 'Fract/Exp String To Number', PrimNameBasis.review),

  toLowerCase(1189, 'To Lower Case', PrimNameBasis.corpusLabel),

  tickCount(1300, 'Tick Count (ms)', PrimNameBasis.corpusLabel),

  waitMs(1302, 'Wait (ms)', PrimNameBasis.corpusLabel),

  getDateTimeInSeconds(1303, 'Get Date/Time In Seconds', PrimNameBasis.corpusLabel),

  waitUntilNextMsMultiple(1327, 'Wait Until Next ms Multiple', PrimNameBasis.corpusLabel),

  oneButtonDialog(1340, 'One Button Dialog', PrimNameBasis.corpusLabel),

  twoButtonDialog(1341, 'Two Button Dialog', PrimNameBasis.corpusLabel),

  buildPath(1419, 'Build Path', PrimNameBasis.corpusLabel),

  stripPath(1420, 'Strip Path', PrimNameBasis.corpusLabel),

  viLibrary(1425, 'VI Library', PrimNameBasis.corpusLabel),

  currentVisPath(1426, "Current VI's Path", PrimNameBasis.corpusLabel),

  stringLength(1502, 'String Length', PrimNameBasis.corpusLabel),

  stringSubset(1503, 'String Subset', PrimNameBasis.corpusLabel),

  pickLine(1510, 'Pick Line', PrimNameBasis.corpusLabel),

  select(1516, 'Select', PrimNameBasis.corpusLabel),

  matchPattern(1535, 'Match Pattern', PrimNameBasis.corpusLabel),

  searchSplitString(1538, 'Search/Split String', PrimNameBasis.corpusLabel),

  spreadsheetStringToArray(1539, 'Spreadsheet String To Array', PrimNameBasis.corpusLabel),

  arrayToSpreadsheetString(1540, 'Array To Spreadsheet String', PrimNameBasis.corpusLabel),

  rotateLeftWithCarry(1606, 'Rotate Left With Carry', PrimNameBasis.adjacency),

  rotateRightWithCarry(1607, 'Rotate Right With Carry', PrimNameBasis.corpusLabel),

  stringToByteArray(1608, 'String To Byte Array', PrimNameBasis.corpusLabel, output: ViTypeKind.numericInt),

  byteArrayToString(1609, 'Byte Array To String', PrimNameBasis.corpusLabel),

  arraySize(1809, 'Array Size', PrimNameBasis.corpusLabel),

  numberToBooleanArray(1814, 'Number To Boolean Array', PrimNameBasis.adjacency),

  booleanArrayToNumber(1815, 'Boolean Array To Number', PrimNameBasis.corpusLabel),

  reverse1dArray(1900, 'Reverse 1D Array', PrimNameBasis.corpusLabel),

  search1dArray(1901, 'Search 1D Array', PrimNameBasis.corpusLabel),

  transpose2dArray(1902, 'Transpose 2D Array', PrimNameBasis.corpusLabel),

  addArrayElements(1903, 'Add Array Elements', PrimNameBasis.corpusLabel),

  multiplyArrayElements(1904, 'Multiply Array Elements', PrimNameBasis.adjacency),

  arrayMaxAndMin(1907, 'Array Max & Min', PrimNameBasis.corpusLabel),

  orArrayElements(1910, 'Or Array Elements', PrimNameBasis.corpusLabel),

  andArrayElements(1911, 'And Array Elements', PrimNameBasis.corpusLabel),

  visaLock(1993, 'VISA Lock', PrimNameBasis.corpusLabel),

  callChain(1999, 'Call Chain', PrimNameBasis.corpusLabel),

  createUserEvent(2073, 'Create User Event', PrimNameBasis.corpusLabel),

  generateUserEvent(2074, 'Generate User Event', PrimNameBasis.corpusLabel),

  destroyUserEvent(2075, 'Destroy User Event', PrimNameBasis.corpusLabel),

  unregisterForEvents(2076, 'Unregister For Events', PrimNameBasis.corpusLabel),

  newDataValueReference(2408, 'New Data Value Reference', PrimNameBasis.corpusLabel),

  deleteDataValueReference(2409, 'Delete Data Value Reference', PrimNameBasis.corpusLabel),

  searchAndReplaceString(3914, 'Search and Replace String', PrimNameBasis.corpusLabel),

  variantToData(8003, 'Variant To Data', PrimNameBasis.corpusLabel),

  openViReference(8010, 'Open VI Reference', PrimNameBasis.corpusLabel),

  closeReference(8011, 'Close Reference', PrimNameBasis.corpusLabel),

  newViObject(8015, 'New VI Object', PrimNameBasis.corpusLabel),

  toMoreSpecificClass(8016, 'To More Specific Class', PrimNameBasis.corpusLabel),

  openCreateReplaceFile(8050, 'Open/Create/Replace File', PrimNameBasis.corpusLabel),

  closeFile(8052, 'Close File', PrimNameBasis.corpusLabel),

  createFolder(8055, 'Create Folder', PrimNameBasis.corpusLabel),

  delete(8056, 'Delete', PrimNameBasis.corpusLabel),

  fileDialog(8058, 'File Dialog', PrimNameBasis.corpusLabel),

  getFileSize(8063, 'Get File Size', PrimNameBasis.corpusLabel),

  readFromTextFile(8070, 'Read from Text File', PrimNameBasis.corpusLabel),

  setFilePosition(8073, 'Set File Position', PrimNameBasis.corpusLabel),

  writeToTextFile(8080, 'Write to Text File', PrimNameBasis.corpusLabel),

  fileDirectoryInfo(8082, 'File/Directory Info', PrimNameBasis.corpusLabel),

  formatDateTimeString(8100, 'Format Date/Time String', PrimNameBasis.corpusLabel),

  toVariant(8201, 'To Variant', PrimNameBasis.corpusLabel),

  variantToFlattenedString(8203, 'Variant To Flattened String', PrimNameBasis.corpusLabel),

  setVariantAttribute(8204, 'Set Variant Attribute', PrimNameBasis.corpusLabel),

  getVariantAttribute(8205, 'Get Variant Attribute', PrimNameBasis.corpusLabel),

  currentVisMenubar(9000, "Current VI's Menubar", PrimNameBasis.corpusLabel),

  sendNotification(9104, 'Send Notification', PrimNameBasis.corpusLabel),

  waitOnNotification(9105, 'Wait on Notification', PrimNameBasis.corpusLabel),

  obtainQueue(9108, 'Obtain Queue', PrimNameBasis.corpusLabel),

  releaseQueue(9109, 'Release Queue', PrimNameBasis.corpusLabel),

  getQueueStatus(9110, 'Get Queue Status', PrimNameBasis.corpusLabel),

  enqueueElement(9111, 'Enqueue Element', PrimNameBasis.corpusLabel),

  emptyArray(23063, 'Empty Array?', PrimNameBasis.corpusLabel),

  flattenToJson(24201, 'Flatten To JSON', PrimNameBasis.corpusLabel);

  const PrimOp(this.id, this.opName, this.basis, {this.output});

  /// The `primResID` value.
  final int id;

  /// The name shown on the node.
  final String opName;

  final PrimNameBasis basis;

  /// The kind of the primitive's output when it does not depend on the inputs.
  final ViTypeKind? output;

  /// The naming half of the icon-asset contract `prim<id>_<slug>.png`.
  String get slug => opName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

  static final Map<int, PrimOp> _byId = {for (final op in values) op.id: op};

  /// The primitive with [id], or null for an id not listed.
  static PrimOp? fromId(int id) => _byId[id];

  /// The terminals in the order the node's terminal list holds them, outputs first: each one's
  /// name as LabVIEW's own help gives it and its rectangle within a 32 by 32 node, as every
  /// corpus node of the primitive draws it; null for a primitive not measured yet.
  List<PrimTerminal>? get terminals => _terminals[this];

  List<String>? get terminalNames => terminals?.map((t) => t.name).toList();
}

/// One terminal of a primitive: its name, whether it consumes its wire, and where it sits in
/// the node.
class PrimTerminal {
  const PrimTerminal(
    this.name,
    this.top,
    this.left,
    this.bottom,
    this.right, {
    this.input = false,
    this.type,
    this.dims = 0,
  });

  const PrimTerminal.input(this.name, this.top, this.left, this.bottom, this.right, {this.type, this.dims = 0})
    : input = true;

  final String name;

  final bool input;

  /// The element type the terminal always carries, when the primitive fixes it, over [dims]
  /// array dimensions; null when the wire decides.
  final ViDataType? type;

  final int dims;

  final int top;

  final int left;

  final int bottom;

  final int right;
}

const Map<PrimOp, List<PrimTerminal>> _terminals = {
  PrimOp.toDoublePrecisionFloat: [
    PrimTerminal('double precision float', 0, 13, 11, 26, type: ViDataType.dbl),
    PrimTerminal.input('number', 0, 0, 11, 13),
  ],
  PrimOp.waitMs: [
    PrimTerminal('millisecond timer value', 0, 16, 32, 32, type: ViDataType.u32),
    PrimTerminal.input('milliseconds to wait', 0, 0, 32, 16, type: ViDataType.u32),
  ],
  PrimOp.waitUntilNextMsMultiple: [
    PrimTerminal('millisecond timer value', 0, 16, 32, 32, type: ViDataType.u32),
    PrimTerminal.input('millisecond multiple', 0, 0, 32, 16, type: ViDataType.u32),
  ],
  PrimOp.getDateTimeInSeconds: [PrimTerminal('current time', 0, 0, 32, 32, type: ViDataType.measureData)],
  PrimOp.arraySize: [PrimTerminal('size(s)', 0, 16, 21, 32), PrimTerminal.input('array', 0, 0, 21, 16)],
  PrimOp.addArrayElements: [PrimTerminal('sum', 0, 12, 25, 25), PrimTerminal.input('numeric array', 0, 0, 25, 12)],
  PrimOp.multiplyArrayElements: [
    PrimTerminal('product', 0, 12, 25, 25),
    PrimTerminal.input('numeric array', 0, 0, 25, 12),
  ],
  PrimOp.formatDateTimeString: [
    PrimTerminal('date/time string', 0, 16, 32, 32, type: ViDataType.string),
    PrimTerminal.input('UTC format', 21, 0, 32, 16, type: ViDataType.boolean),
    PrimTerminal.input('time stamp', 11, 0, 21, 16, type: ViDataType.measureData),
    PrimTerminal.input('time format string', 0, 0, 11, 16, type: ViDataType.string),
  ],
  PrimOp.add: [
    PrimTerminal('x+y', 0, 10, 21, 21),
    PrimTerminal.input('y', 10, 0, 21, 10),
    PrimTerminal.input('x', 0, 0, 10, 10),
  ],
  PrimOp.subtract: [
    PrimTerminal('x-y', 0, 10, 21, 21),
    PrimTerminal.input('y', 10, 0, 21, 10),
    PrimTerminal.input('x', 0, 0, 10, 10),
  ],
  PrimOp.multiply: [
    PrimTerminal('x*y', 0, 10, 21, 21),
    PrimTerminal.input('y', 10, 0, 21, 10),
    PrimTerminal.input('x', 0, 0, 10, 10),
  ],
  PrimOp.divide: [
    PrimTerminal('x/y', 0, 10, 21, 21),
    PrimTerminal.input('y', 10, 0, 21, 10),
    PrimTerminal.input('x', 0, 0, 10, 10),
  ],
  PrimOp.increment: [PrimTerminal('x+1', 0, 10, 21, 21), PrimTerminal.input('x', 0, 0, 21, 10)],
  PrimOp.decrement: [PrimTerminal('x-1', 0, 10, 21, 21), PrimTerminal.input('x', 0, 0, 21, 10)],
  PrimOp.and: [
    PrimTerminal('x .and. y?', 0, 12, 16, 24),
    PrimTerminal.input('y', 8, 0, 16, 12),
    PrimTerminal.input('x', 0, 0, 8, 12),
  ],
  PrimOp.or: [
    PrimTerminal('x .or. y?', 0, 10, 16, 22),
    PrimTerminal.input('y', 8, 0, 16, 10),
    PrimTerminal.input('x', 0, 0, 8, 10),
  ],
  PrimOp.exclusiveOr: [
    PrimTerminal('x .xor. y?', 0, 12, 16, 24),
    PrimTerminal.input('y', 8, 0, 16, 12),
    PrimTerminal.input('x', 0, 0, 8, 12),
  ],
  PrimOp.toLongInteger: [
    PrimTerminal('32bit integer', 0, 12, 11, 25, type: ViDataType.i32),
    PrimTerminal.input('number', 0, 0, 11, 12),
  ],
  PrimOp.toUnsignedByteInteger: [
    PrimTerminal('unsigned 8bit integer', 0, 12, 11, 25, type: ViDataType.u8),
    PrimTerminal.input('number', 0, 0, 11, 12),
  ],
  PrimOp.rotateLeftWithCarry: [
    PrimTerminal('value', 8, 12, 17, 25),
    PrimTerminal('msb carry out', 0, 12, 8, 25, type: ViDataType.boolean),
    PrimTerminal.input('value', 8, 0, 17, 12),
    PrimTerminal.input('carry', 0, 0, 8, 12, type: ViDataType.boolean),
  ],
  PrimOp.stringToByteArray: [
    PrimTerminal('unsigned byte array', 0, 13, 11, 25, type: ViDataType.u8, dims: 1),
    PrimTerminal.input('string', 0, 0, 11, 13, type: ViDataType.string),
  ],
  PrimOp.numberToBooleanArray: [
    PrimTerminal('Boolean array', 0, 13, 11, 26, type: ViDataType.boolean, dims: 1),
    PrimTerminal.input('number', 0, 0, 11, 13),
  ],
  PrimOp.booleanArrayToNumber: [
    PrimTerminal('number', 0, 13, 11, 26, type: ViDataType.u32),
    PrimTerminal.input('Boolean array', 0, 0, 11, 13, type: ViDataType.boolean, dims: 1),
  ],
  PrimOp.reverse1dArray: [PrimTerminal('reversed array', 0, 16, 23, 32), PrimTerminal.input('array', 0, 0, 23, 16)],
  PrimOp.randomNumber: [PrimTerminal('number (0 to 1)', 0, 0, 21, 19, type: ViDataType.dbl)],
  PrimOp.select: [
    PrimTerminal('s? t:f', 0, 14, 27, 27),
    PrimTerminal.input('f', 19, 0, 27, 14),
    PrimTerminal.input('s', 9, 0, 19, 14, type: ViDataType.boolean),
    PrimTerminal.input('t', 0, 0, 9, 14),
  ],
  PrimOp.typeCast: [
    PrimTerminal.input('x', 0, 0, 32, 11),
    PrimTerminal.input('type', 0, 11, 32, 21),
    PrimTerminal('*(type *) &x', 0, 21, 32, 32),
  ],
  PrimOp.arrayToSpreadsheetString: [
    PrimTerminal('spreadsheet string', 0, 21, 32, 32, type: ViDataType.string),
    PrimTerminal.input('delimiter', 16, 0, 32, 11, type: ViDataType.string),
    PrimTerminal.input('array', 0, 11, 32, 21),
    PrimTerminal.input('format string', 0, 0, 16, 11, type: ViDataType.string),
  ],
  PrimOp.hexadecimalStringToNumber: [
    PrimTerminal('number', 16, 16, 32, 32),
    PrimTerminal('offset past number', 0, 16, 16, 32),
    PrimTerminal.input('default', 21, 0, 32, 16),
    PrimTerminal.input('offset', 11, 0, 21, 16),
    PrimTerminal.input('string', 0, 0, 11, 16, type: ViDataType.string),
  ],
  PrimOp.fractExpStringToNumber: [
    PrimTerminal('number', 16, 21, 32, 32),
    PrimTerminal('offset past number', 0, 21, 16, 32),
    PrimTerminal.input('use system decimal point', 0, 11, 32, 21, type: ViDataType.boolean),
    PrimTerminal.input('default', 21, 0, 32, 11),
    PrimTerminal.input('offset', 11, 0, 21, 11),
    PrimTerminal.input('string', 0, 0, 11, 11, type: ViDataType.string),
  ],
};
