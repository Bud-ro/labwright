/// Built-in primitive operation names, keyed by the `0x0EA` **primResID**
/// heap attribute ([HeapAttribute.primResID]) carried by primitive nodes
/// (class `0x2F`; see [HeapAttribute.primResID] for the corpus census —
/// the stats live there once, not here).
///
/// Naming evidence, per entry:
///
/// - [PrimNameBasis.corpusLabel] — corpus VIs label the node with LabVIEW's
///   default node name (users rarely rename primitives; renamed ones read as
///   free-text comments and were excluded). Each doc comment carries the
///   distinct-VI label count; the top label was unanimous or near-unanimous
///   for every entry taken.
/// - [PrimNameBasis.adjacency] — no corpus label, but the id sits inside a
///   contiguous run whose neighbours are corpus-pinned and whose palette
///   order the run reproduces (e.g. the To-Integer conversion run
///   1140..1147), or it is the documented pair of a corpus-pinned entry.
///   The doc comment states the specific basis, plus corroborating
///   measurements where the run alone underdetermines the name (terminal
///   arity via positional child count, corpus node frequency, or exhaustion
///   over a snippet's complete id set).
///
/// Ids observed in the corpus without either kind of evidence (126 of 242)
/// are deliberately absent — callers get null from [PrimOp.fromId] and must
/// render/report the numeric id, never a guessed name. That includes ids
/// with merely *suggestive* evidence: 1170/1171 read as Split/Join Numbers
/// from CRC-snippet wiring, but 1170 pairs the pinned [clusterToArray] just
/// as naturally as Array To Cluster, so neither is named.
///
/// @docImport '../heap.dart';
library;

import '../graph.dart' show ViTypeKind;

/// The kind of evidence behind a [PrimOp]'s name (see the library doc).
enum PrimNameBasis {
  /// LabVIEW's default node name read off corpus node labels.
  corpusLabel,

  /// Interpolated from corpus-pinned neighbours in a contiguous palette run,
  /// or the documented pair of a corpus-pinned entry.
  adjacency,
}

/// A named built-in primitive operation (see the library doc for evidence
/// rules). [id] is the raw primResID value; [opName] is LabVIEW's default
/// node name.
enum PrimOp {
  /// Heads the arithmetic run whose tail is corpus-pinned ([subtract],
  /// [multiply], [divide]). Measured binary (3 positional children on
  /// 1,267/1,298 corpus nodes, matching [subtract]'s 1,617/1,646), and the
  /// preceding id 1049 is measured *unary* (2 children, n=3), so the run
  /// cannot start there.
  add(1050, 'Add', PrimNameBasis.adjacency),

  /// ×24 corpus labels.
  subtract(1051, 'Subtract', PrimNameBasis.corpusLabel),

  /// ×6 corpus labels.
  multiply(1052, 'Multiply', PrimNameBasis.corpusLabel),

  /// ×18 corpus labels.
  divide(1053, 'Divide', PrimNameBasis.corpusLabel),

  /// ×12 corpus labels.
  increment(1057, 'Increment', PrimNameBasis.corpusLabel),

  /// ×15 corpus labels.
  decrement(1058, 'Decrement', PrimNameBasis.corpusLabel),

  /// ×2 corpus labels.
  squareRoot(1060, 'Square Root', PrimNameBasis.corpusLabel),

  /// Opens the boolean run And/Or/Exclusive Or/Not around the corpus-pinned
  /// [exclusiveOr].
  and(1061, 'And', PrimNameBasis.adjacency),

  /// Second of the boolean run around the corpus-pinned [exclusiveOr].
  or(1062, 'Or', PrimNameBasis.adjacency),

  /// ×6 corpus labels.
  exclusiveOr(1063, 'Exclusive Or', PrimNameBasis.corpusLabel),

  /// Closes the boolean run And/Or/Exclusive Or/Not around the corpus-pinned
  /// [exclusiveOr]. Measured unary (2 positional children on 759/788 corpus
  /// nodes) — the only unary op in the run; 1061/1062/1063 all measure
  /// binary (3 children).
  not(1064, 'Not', PrimNameBasis.adjacency),

  /// ×3 corpus labels.
  randomNumber(1070, 'Random Number (0-1)', PrimNameBasis.corpusLabel),

  /// ×7 corpus labels.
  pathToString(1077, 'Path To String', PrimNameBasis.corpusLabel),

  /// ×9 corpus labels.
  stringToPath(1078, 'String To Path', PrimNameBasis.corpusLabel),

  /// ×6 corpus labels.
  logicalShift(1081, 'Logical Shift', PrimNameBasis.corpusLabel),

  /// ×6 corpus labels.
  firstCall(1083, 'First Call?', PrimNameBasis.corpusLabel),

  /// ×33 corpus labels.
  equal(1102, 'Equal?', PrimNameBasis.corpusLabel),

  /// ×5 corpus labels.
  notEqual(1105, 'Not Equal?', PrimNameBasis.corpusLabel),

  /// ×4 corpus labels.
  maxAndMin(1108, 'Max & Min', PrimNameBasis.corpusLabel),

  /// ×5 corpus labels.
  greater(1110, 'Greater?', PrimNameBasis.corpusLabel),

  /// ×6 corpus labels.
  less(1111, 'Less?', PrimNameBasis.corpusLabel),

  /// ×18 corpus labels.
  emptyStringPath(1112, 'Empty String/Path?', PrimNameBasis.corpusLabel),

  /// ×5 corpus labels.
  equalToZero(1113, 'Equal To 0?', PrimNameBasis.corpusLabel),

  /// ×21 corpus labels.
  greaterOrEqualToZero(1114, 'Greater Or Equal To 0?', PrimNameBasis.corpusLabel),

  /// ×1 corpus label.
  lessOrEqualToZero(1115, 'Less Or Equal To 0?', PrimNameBasis.corpusLabel),

  /// ×4 corpus labels.
  notEqualToZero(1116, 'Not Equal To 0?', PrimNameBasis.corpusLabel),

  /// ×6 corpus labels.
  greaterThanZero(1117, 'Greater Than 0?', PrimNameBasis.corpusLabel),

  /// ×3 corpus labels.
  lessThanZero(1118, 'Less Than 0?', PrimNameBasis.corpusLabel),

  /// ×21 corpus labels.
  sort1dArray(1120, 'Sort 1D Array', PrimNameBasis.corpusLabel),

  /// ×4 corpus labels.
  inRangeAndCoerce(1127, 'In Range and Coerce', PrimNameBasis.corpusLabel),

  /// ×13 corpus labels.
  notANumberPathRefnum(1128, 'Not A Number/Path/Refnum?', PrimNameBasis.corpusLabel),

  /// ×3 corpus labels.
  toByteInteger(1140, 'To Byte Integer', PrimNameBasis.corpusLabel),

  /// Fills the 1140..1147 conversion run between the corpus-pinned
  /// [toByteInteger] and [toLongInteger].
  toWordInteger(1141, 'To Word Integer', PrimNameBasis.adjacency),

  /// ×7 corpus labels.
  toLongInteger(1142, 'To Long Integer', PrimNameBasis.corpusLabel),

  /// Fills the 1140..1147 conversion run between the corpus-pinned
  /// [toLongInteger] and [toUnsignedWordInteger].
  toUnsignedByteInteger(1143, 'To Unsigned Byte Integer', PrimNameBasis.adjacency),

  /// ×1 corpus label.
  toUnsignedWordInteger(1144, 'To Unsigned Word Integer', PrimNameBasis.corpusLabel),

  /// ×14 corpus labels.
  toUnsignedLongInteger(1145, 'To Unsigned Long Integer', PrimNameBasis.corpusLabel),

  /// Fills the 1140..1147 conversion run between the corpus-pinned
  /// [toUnsignedLongInteger] and [toDoublePrecisionFloat].
  toSinglePrecisionFloat(1146, 'To Single Precision Float', PrimNameBasis.adjacency),

  /// ×1 corpus label.
  toDoublePrecisionFloat(1147, 'To Double Precision Float', PrimNameBasis.corpusLabel),

  /// ×1 corpus label.
  flattenToString(1164, 'Flatten To String', PrimNameBasis.corpusLabel),

  /// ×11 corpus labels.
  typeCast(1166, 'Type Cast', PrimNameBasis.corpusLabel),

  /// ×1 corpus label.
  booleanToZeroOne(1167, 'Boolean To (0,1)', PrimNameBasis.corpusLabel),

  /// ×4 corpus labels.
  clusterToArray(1169, 'Cluster To Array', PrimNameBasis.corpusLabel),

  /// ×2 corpus labels.
  numberToDecimalString(1180, 'Number To Decimal String', PrimNameBasis.corpusLabel),

  /// ×2 corpus labels.
  decimalStringToNumber(1184, 'Decimal String To Number', PrimNameBasis.corpusLabel),

  /// ×10 corpus labels.
  toLowerCase(1189, 'To Lower Case', PrimNameBasis.corpusLabel),

  /// ×1 corpus label.
  tickCount(1300, 'Tick Count (ms)', PrimNameBasis.corpusLabel),

  /// ×5 corpus labels.
  waitMs(1302, 'Wait (ms)', PrimNameBasis.corpusLabel),

  /// ×7 corpus labels.
  getDateTimeInSeconds(1303, 'Get Date/Time In Seconds', PrimNameBasis.corpusLabel),

  /// ×1 corpus label.
  waitUntilNextMsMultiple(1327, 'Wait Until Next ms Multiple', PrimNameBasis.corpusLabel),

  /// ×13 corpus labels.
  oneButtonDialog(1340, 'One Button Dialog', PrimNameBasis.corpusLabel),

  /// ×4 corpus labels.
  twoButtonDialog(1341, 'Two Button Dialog', PrimNameBasis.corpusLabel),

  /// ×23 corpus labels.
  buildPath(1419, 'Build Path', PrimNameBasis.corpusLabel),

  /// ×12 corpus labels.
  stripPath(1420, 'Strip Path', PrimNameBasis.corpusLabel),

  /// ×5 corpus labels.
  viLibrary(1425, 'VI Library', PrimNameBasis.corpusLabel),

  /// ×4 corpus labels.
  currentVisPath(1426, "Current VI's Path", PrimNameBasis.corpusLabel),

  /// ×29 corpus labels.
  stringLength(1502, 'String Length', PrimNameBasis.corpusLabel),

  /// ×44 corpus labels.
  stringSubset(1503, 'String Subset', PrimNameBasis.corpusLabel),

  /// ×2 corpus labels.
  pickLine(1510, 'Pick Line', PrimNameBasis.corpusLabel),

  /// ×50 corpus labels.
  select(1516, 'Select', PrimNameBasis.corpusLabel),

  /// ×21 corpus labels.
  matchPattern(1535, 'Match Pattern', PrimNameBasis.corpusLabel),

  /// ×11 corpus labels.
  searchSplitString(1538, 'Search/Split String', PrimNameBasis.corpusLabel),

  /// ×3 corpus labels.
  spreadsheetStringToArray(1539, 'Spreadsheet String To Array', PrimNameBasis.corpusLabel),

  /// ×2 corpus labels.
  arrayToSpreadsheetString(1540, 'Array To Spreadsheet String', PrimNameBasis.corpusLabel),

  /// Pairs the corpus-pinned [rotateRightWithCarry] with the same measured
  /// with-carry arity (4 positional children — value+carry in and out — on
  /// all snippet instances, matching 1607; the plain rotates are 3-terminal).
  rotateLeftWithCarry(1606, 'Rotate Left With Carry', PrimNameBasis.adjacency),

  /// ×1 corpus label.
  rotateRightWithCarry(1607, 'Rotate Right With Carry', PrimNameBasis.corpusLabel),

  /// ×3 corpus labels. Output: a `[u8]` byte array by definition (the op is
  /// named by its output), so its wire draws in the integer-numeric colour.
  stringToByteArray(1608, 'String To Byte Array', PrimNameBasis.corpusLabel, output: ViTypeKind.numericInt),

  /// ×1 corpus label.
  byteArrayToString(1609, 'Byte Array To String', PrimNameBasis.corpusLabel),

  /// ×19 corpus labels.
  arraySize(1809, 'Array Size', PrimNameBasis.corpusLabel),

  /// Pairs the corpus-pinned [booleanArrayToNumber], by exhaustion over the
  /// bit-reversal snippet's complete prim set {1142, 1143, 1166, 1814, 1815,
  /// 1900}: reversing bits needs Number→Boolean Array upstream of the
  /// pinned Reverse 1D Array and Boolean Array To Number, and every other
  /// id in the set is corpus-pinned to a different op.
  numberToBooleanArray(1814, 'Number To Boolean Array', PrimNameBasis.adjacency),

  /// ×3 corpus labels.
  booleanArrayToNumber(1815, 'Boolean Array To Number', PrimNameBasis.corpusLabel),

  /// ×2 corpus labels.
  reverse1dArray(1900, 'Reverse 1D Array', PrimNameBasis.corpusLabel),

  /// ×21 corpus labels.
  search1dArray(1901, 'Search 1D Array', PrimNameBasis.corpusLabel),

  /// ×6 corpus labels.
  transpose2dArray(1902, 'Transpose 2D Array', PrimNameBasis.corpusLabel),

  /// ×4 corpus labels.
  addArrayElements(1903, 'Add Array Elements', PrimNameBasis.corpusLabel),

  /// ×6 corpus labels.
  arrayMaxAndMin(1907, 'Array Max & Min', PrimNameBasis.corpusLabel),

  /// ×1 corpus label.
  orArrayElements(1910, 'Or Array Elements', PrimNameBasis.corpusLabel),

  /// ×5 corpus labels.
  andArrayElements(1911, 'And Array Elements', PrimNameBasis.corpusLabel),

  /// ×1 corpus label.
  visaLock(1993, 'VISA Lock', PrimNameBasis.corpusLabel),

  /// ×1 corpus label.
  callChain(1999, 'Call Chain', PrimNameBasis.corpusLabel),

  /// ×4 corpus labels.
  createUserEvent(2073, 'Create User Event', PrimNameBasis.corpusLabel),

  /// ×1 corpus label.
  generateUserEvent(2074, 'Generate User Event', PrimNameBasis.corpusLabel),

  /// ×3 corpus labels.
  destroyUserEvent(2075, 'Destroy User Event', PrimNameBasis.corpusLabel),

  /// ×1 corpus label.
  unregisterForEvents(2076, 'Unregister For Events', PrimNameBasis.corpusLabel),

  /// ×5 corpus labels.
  newDataValueReference(2408, 'New Data Value Reference', PrimNameBasis.corpusLabel),

  /// ×13 corpus labels.
  deleteDataValueReference(2409, 'Delete Data Value Reference', PrimNameBasis.corpusLabel),

  /// ×15 corpus labels.
  searchAndReplaceString(3914, 'Search and Replace String', PrimNameBasis.corpusLabel),

  /// ×2 corpus labels.
  variantToData(8003, 'Variant To Data', PrimNameBasis.corpusLabel),

  /// ×11 corpus labels.
  openViReference(8010, 'Open VI Reference', PrimNameBasis.corpusLabel),

  /// ×13 corpus labels.
  closeReference(8011, 'Close Reference', PrimNameBasis.corpusLabel),

  /// ×3 corpus labels.
  newViObject(8015, 'New VI Object', PrimNameBasis.corpusLabel),

  /// ×22 corpus labels.
  toMoreSpecificClass(8016, 'To More Specific Class', PrimNameBasis.corpusLabel),

  /// ×2 corpus labels.
  openCreateReplaceFile(8050, 'Open/Create/Replace File', PrimNameBasis.corpusLabel),

  /// ×5 corpus labels.
  closeFile(8052, 'Close File', PrimNameBasis.corpusLabel),

  /// ×1 corpus label.
  createFolder(8055, 'Create Folder', PrimNameBasis.corpusLabel),

  /// ×6 corpus labels.
  delete(8056, 'Delete', PrimNameBasis.corpusLabel),

  /// ×3 corpus labels.
  fileDialog(8058, 'File Dialog', PrimNameBasis.corpusLabel),

  /// ×1 corpus label.
  getFileSize(8063, 'Get File Size', PrimNameBasis.corpusLabel),

  /// ×6 corpus labels.
  readFromTextFile(8070, 'Read from Text File', PrimNameBasis.corpusLabel),

  /// ×2 corpus labels.
  setFilePosition(8073, 'Set File Position', PrimNameBasis.corpusLabel),

  /// ×7 corpus labels.
  writeToTextFile(8080, 'Write to Text File', PrimNameBasis.corpusLabel),

  /// ×5 corpus labels.
  fileDirectoryInfo(8082, 'File/Directory Info', PrimNameBasis.corpusLabel),

  /// ×1 corpus label.
  formatDateTimeString(8100, 'Format Date/Time String', PrimNameBasis.corpusLabel),

  /// ×2 corpus labels.
  toVariant(8201, 'To Variant', PrimNameBasis.corpusLabel),

  /// ×8 corpus labels.
  variantToFlattenedString(8203, 'Variant To Flattened String', PrimNameBasis.corpusLabel),

  /// ×8 corpus labels.
  setVariantAttribute(8204, 'Set Variant Attribute', PrimNameBasis.corpusLabel),

  /// ×7 corpus labels.
  getVariantAttribute(8205, 'Get Variant Attribute', PrimNameBasis.corpusLabel),

  /// ×2 corpus labels.
  currentVisMenubar(9000, "Current VI's Menubar", PrimNameBasis.corpusLabel),

  /// ×2 corpus labels.
  sendNotification(9104, 'Send Notification', PrimNameBasis.corpusLabel),

  /// ×1 corpus label.
  waitOnNotification(9105, 'Wait on Notification', PrimNameBasis.corpusLabel),

  /// ×10 corpus labels.
  obtainQueue(9108, 'Obtain Queue', PrimNameBasis.corpusLabel),

  /// ×4 corpus labels.
  releaseQueue(9109, 'Release Queue', PrimNameBasis.corpusLabel),

  /// ×2 corpus labels.
  getQueueStatus(9110, 'Get Queue Status', PrimNameBasis.corpusLabel),

  /// ×4 corpus labels.
  enqueueElement(9111, 'Enqueue Element', PrimNameBasis.corpusLabel),

  /// ×4 corpus labels.
  emptyArray(23063, 'Empty Array?', PrimNameBasis.corpusLabel),

  /// ×4 corpus labels.
  flattenToJson(24201, 'Flatten To JSON', PrimNameBasis.corpusLabel)
  ;

  const PrimOp(this.id, this.opName, this.basis, {this.output});

  /// The raw primResID value (the `0x0EA` attribute payload).
  final int id;

  /// LabVIEW's default node name for the primitive.
  final String opName;

  /// The evidence behind [opName] (see the library doc).
  final PrimNameBasis basis;

  /// The wire-colour family of the op's output, set ONLY where the op's
  /// documented semantics fix it (e.g. a conversion named by its output
  /// type). An array output carries its element family — LabVIEW draws the
  /// wire in the element colour. Null means not asserted, never guessed.
  final ViTypeKind? output;

  /// [opName] as a filename-safe slug (`add`, `to-long-integer`,
  /// `greater-or-equal-to-0`) — the naming half of the icon-asset contract
  /// `prim<id>_<slug>.png`.
  String get slug => opName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

  static final Map<int, PrimOp> _byId = {for (final op in values) op.id: op};

  /// The catalogued primitive for a raw primResID [id], or null when the
  /// corpus gives no name (callers must show the numeric id, never guess).
  static PrimOp? fromId(int id) => _byId[id];
}
