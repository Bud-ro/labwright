/// The primitives a `primResID` names, with the basis of each name.
library;

import '../heap/heap_object.dart';

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
  complexToPolar(1045, 'Complex To Polar', PrimNameBasis.review),
  add(1050, 'Add', PrimNameBasis.adjacency),

  reImToComplex(1046, 'Re/Im To Complex', PrimNameBasis.review),

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

  greaterOrEqual(1103, 'Greater Or Equal?', PrimNameBasis.review),

  lessOrEqual(1104, 'Less Or Equal?', PrimNameBasis.review),

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

  mantissaAndExponent(1150, 'Mantissa & Exponent', PrimNameBasis.review),

  toQuadInteger(1155, 'To Quad Integer', PrimNameBasis.review),

  toUnsignedQuadInteger(1156, 'To Unsigned Quad Integer', PrimNameBasis.review),

  swapBytes(1162, 'Swap Bytes', PrimNameBasis.review),

  swapWords(1163, 'Swap Words', PrimNameBasis.review),

  flattenToString(1164, 'Flatten To String', PrimNameBasis.corpusLabel),

  unflattenFromString(1165, 'Unflatten From String', PrimNameBasis.review),

  typeCast(1166, 'Type Cast', PrimNameBasis.corpusLabel),

  booleanToZeroOne(1167, 'Boolean To (0,1)', PrimNameBasis.corpusLabel),

  arrayToCluster(1168, 'Array To Cluster', PrimNameBasis.review),

  clusterToArray(1169, 'Cluster To Array', PrimNameBasis.corpusLabel),

  numberToDecimalString(1180, 'Number To Decimal String', PrimNameBasis.corpusLabel),

  numberToHexadecimalString(1181, 'Number To Hexadecimal String', PrimNameBasis.review),

  decimalStringToNumber(1184, 'Decimal String To Number', PrimNameBasis.corpusLabel),

  hexadecimalStringToNumber(1185, 'Hexadecimal String To Number', PrimNameBasis.review),

  fractExpStringToNumber(1187, 'Fract/Exp String To Number', PrimNameBasis.review),

  toUpperCase(1188, 'To Upper Case', PrimNameBasis.review),

  toLowerCase(1189, 'To Lower Case', PrimNameBasis.corpusLabel),

  sine(1200, 'Sine', PrimNameBasis.review),

  cosine(1201, 'Cosine', PrimNameBasis.review),

  logarithmBase10(1210, 'Logarithm Base 10', PrimNameBasis.review),

  powerOf10(1212, 'Power Of 10', PrimNameBasis.review),

  powerOfX(1213, 'Power Of X', PrimNameBasis.review),

  tickCount(1300, 'Tick Count (ms)', PrimNameBasis.corpusLabel),

  waitMs(1302, 'Wait (ms)', PrimNameBasis.corpusLabel),

  getDateTimeInSeconds(1303, 'Get Date/Time In Seconds', PrimNameBasis.corpusLabel),

  dateTimeToSeconds(1308, 'Date/Time To Seconds', PrimNameBasis.review),

  secondsToDateTime(1309, 'Seconds To Date/Time', PrimNameBasis.review),

  waitUntilNextMsMultiple(1327, 'Wait Until Next ms Multiple', PrimNameBasis.corpusLabel),

  oneButtonDialog(1340, 'One Button Dialog', PrimNameBasis.corpusLabel),

  twoButtonDialog(1341, 'Two Button Dialog', PrimNameBasis.corpusLabel),

  stop(1350, 'Stop', PrimNameBasis.review),

  quitLabview(1352, 'Quit LabVIEW', PrimNameBasis.review),

  buildPath(1419, 'Build Path', PrimNameBasis.corpusLabel),

  stripPath(1420, 'Strip Path', PrimNameBasis.corpusLabel),

  isPathAndNotEmpty(1421, 'Is Path And Not Empty?', PrimNameBasis.review),

  arrayOfStringsToPath(1422, 'Array Of Strings To Path', PrimNameBasis.review),

  pathToArrayOfStrings(1423, 'Path To Array Of Strings', PrimNameBasis.review),

  viLibrary(1425, 'VI Library', PrimNameBasis.corpusLabel),

  currentVisPath(1426, "Current VI's Path", PrimNameBasis.corpusLabel),

  stringLength(1502, 'String Length', PrimNameBasis.corpusLabel),

  stringSubset(1503, 'String Subset', PrimNameBasis.corpusLabel),

  numberToFractionalString(1506, 'Number To Fractional String', PrimNameBasis.review),

  pickLine(1510, 'Pick Line', PrimNameBasis.corpusLabel),

  select(1516, 'Select', PrimNameBasis.corpusLabel),

  scanValue(1534, 'Scan Value', PrimNameBasis.review),

  matchPattern(1535, 'Match Pattern', PrimNameBasis.corpusLabel),

  reverseString(1537, 'Reverse String', PrimNameBasis.review),

  searchSplitString(1538, 'Search/Split String', PrimNameBasis.corpusLabel),

  spreadsheetStringToArray(1539, 'Spreadsheet String To Array', PrimNameBasis.corpusLabel),

  arrayToSpreadsheetString(1540, 'Array To Spreadsheet String', PrimNameBasis.corpusLabel),

  rotateLeftWithCarry(1606, 'Rotate Left With Carry', PrimNameBasis.adjacency),

  rotateRightWithCarry(1607, 'Rotate Right With Carry', PrimNameBasis.corpusLabel),

  stringToByteArray(1608, 'String To Byte Array', PrimNameBasis.corpusLabel, output: ViTypeKind.numericInt),

  byteArrayToString(1609, 'Byte Array To String', PrimNameBasis.corpusLabel),

  ipToString(1710, 'IP To String', PrimNameBasis.review),

  stringToIp(1711, 'String To IP', PrimNameBasis.review),

  tcpCloseConnection(1713, 'TCP Close Connection', PrimNameBasis.review),

  tcpWrite(1714, 'TCP Write', PrimNameBasis.review),

  tcpOpenConnection(1715, 'TCP Open Connection', PrimNameBasis.review),

  tcpRead(1716, 'TCP Read', PrimNameBasis.review),

  udpOpen(1723, 'UDP Open', PrimNameBasis.review),

  udpRead(1724, 'UDP Read', PrimNameBasis.review),

  udpWrite(1725, 'UDP Write', PrimNameBasis.review),

  udpClose(1726, 'UDP Close', PrimNameBasis.review),

  arraySize(1809, 'Array Size', PrimNameBasis.corpusLabel),

  numberToBooleanArray(1814, 'Number To Boolean Array', PrimNameBasis.adjacency),

  booleanArrayToNumber(1815, 'Boolean Array To Number', PrimNameBasis.corpusLabel),

  reverse1dArray(1900, 'Reverse 1D Array', PrimNameBasis.corpusLabel),

  search1dArray(1901, 'Search 1D Array', PrimNameBasis.corpusLabel),

  transpose2dArray(1902, 'Transpose 2D Array', PrimNameBasis.corpusLabel),

  addArrayElements(1903, 'Add Array Elements', PrimNameBasis.corpusLabel),

  multiplyArrayElements(1904, 'Multiply Array Elements', PrimNameBasis.review),

  arrayMaxAndMin(1907, 'Array Max & Min', PrimNameBasis.corpusLabel),

  split1dArray(1908, 'Split 1D Array', PrimNameBasis.review),

  threshold1dArray(1909, 'Threshold 1D Array', PrimNameBasis.review),

  orArrayElements(1910, 'Or Array Elements', PrimNameBasis.corpusLabel),

  andArrayElements(1911, 'And Array Elements', PrimNameBasis.corpusLabel),

  visaClose(1922, 'VISA Close', PrimNameBasis.review),

  visaClear(1927, 'VISA Clear', PrimNameBasis.review),

  visaLock(1993, 'VISA Lock', PrimNameBasis.corpusLabel),

  callChain(1999, 'Call Chain', PrimNameBasis.corpusLabel),

  tdmsWrite(2010, 'TDMS Write', PrimNameBasis.review),

  tdmsRead(2011, 'TDMS Read', PrimNameBasis.review),

  tdmsOpen(2012, 'TDMS Open', PrimNameBasis.review),

  tdmsClose(2013, 'TDMS Close', PrimNameBasis.review),

  tdmsSetProperties(2014, 'TDMS Set Properties', PrimNameBasis.review),

  tdmsListContents(2016, 'TDMS List Contents', PrimNameBasis.review),

  createUserEvent(2073, 'Create User Event', PrimNameBasis.corpusLabel),

  generateUserEvent(2074, 'Generate User Event', PrimNameBasis.corpusLabel),

  destroyUserEvent(2075, 'Destroy User Event', PrimNameBasis.corpusLabel),

  unregisterForEvents(2076, 'Unregister For Events', PrimNameBasis.corpusLabel),

  newDataValueReference(2408, 'New Data Value Reference', PrimNameBasis.corpusLabel),

  deleteDataValueReference(2409, 'Delete Data Value Reference', PrimNameBasis.corpusLabel),

  searchAndReplaceString(3914, 'Search and Replace String', PrimNameBasis.corpusLabel),

  toTimeStamp(5560, 'To Time Stamp', PrimNameBasis.review),

  fixedPointToIntegerCast(5566, 'Fixed-Point To Integer Cast', PrimNameBasis.review),

  integerToFixedPointCast(5567, 'Integer To Fixed-Point Cast', PrimNameBasis.review),

  variantToData(8003, 'Variant To Data', PrimNameBasis.corpusLabel),

  openViReference(8010, 'Open VI Reference', PrimNameBasis.corpusLabel),

  closeReference(8011, 'Close Reference', PrimNameBasis.corpusLabel),

  newViObject(8015, 'New VI Object', PrimNameBasis.corpusLabel),

  toMoreSpecificClass(8016, 'To More Specific Class', PrimNameBasis.corpusLabel),

  toMoreGenericClass(8017, 'To More Generic Class', PrimNameBasis.review),

  preserveRunTimeClass(8018, 'Preserve Run-Time Class', PrimNameBasis.review),

  openCreateReplaceFile(8050, 'Open/Create/Replace File', PrimNameBasis.corpusLabel),

  readFromBinaryFile(8051, 'Read From Binary File', PrimNameBasis.review),

  closeFile(8052, 'Close File', PrimNameBasis.corpusLabel),

  copy(8053, 'Copy', PrimNameBasis.review),

  createFolder(8055, 'Create Folder', PrimNameBasis.corpusLabel),

  delete(8056, 'Delete', PrimNameBasis.corpusLabel),

  fileDialog(8058, 'File Dialog', PrimNameBasis.corpusLabel),

  getFilePosition(8062, 'Get File Position', PrimNameBasis.review),

  getFileSize(8063, 'Get File Size', PrimNameBasis.corpusLabel),

  getPermissions(8065, 'Get Permissions', PrimNameBasis.review),

  move(8068, 'Move', PrimNameBasis.review),

  readFromTextFile(8070, 'Read from Text File', PrimNameBasis.corpusLabel),

  setFilePosition(8073, 'Set File Position', PrimNameBasis.corpusLabel),

  setFileSize(8074, 'Set File Size', PrimNameBasis.review),

  setPermissions(8076, 'Set Permissions', PrimNameBasis.review),

  writeToBinaryFile(8078, 'Write To Binary File', PrimNameBasis.review),

  writeToTextFile(8080, 'Write to Text File', PrimNameBasis.corpusLabel),

  fileDirectoryInfo(8082, 'File/Directory Info', PrimNameBasis.corpusLabel),

  listFolder(8083, 'List Folder', PrimNameBasis.review),

  formatDateTimeString(8100, 'Format Date/Time String', PrimNameBasis.corpusLabel),

  toVariant(8201, 'To Variant', PrimNameBasis.corpusLabel),

  flattenedStringToVariant(8202, 'Flattened String To Variant', PrimNameBasis.review),

  variantToFlattenedString(8203, 'Variant To Flattened String', PrimNameBasis.corpusLabel),

  setVariantAttribute(8204, 'Set Variant Attribute', PrimNameBasis.corpusLabel),

  getVariantAttribute(8205, 'Get Variant Attribute', PrimNameBasis.corpusLabel),

  matrixSize(8507, 'Matrix Size', PrimNameBasis.review),

  currentVisMenubar(9000, "Current VI's Menubar", PrimNameBasis.corpusLabel),

  sendNotification(9104, 'Send Notification', PrimNameBasis.corpusLabel),

  waitOnNotification(9105, 'Wait on Notification', PrimNameBasis.corpusLabel),

  obtainQueue(9108, 'Obtain Queue', PrimNameBasis.corpusLabel),

  releaseQueue(9109, 'Release Queue', PrimNameBasis.corpusLabel),

  getQueueStatus(9110, 'Get Queue Status', PrimNameBasis.corpusLabel),

  enqueueElement(9111, 'Enqueue Element', PrimNameBasis.corpusLabel),

  square(23059, 'Square', PrimNameBasis.review),

  emptyArray(23063, 'Empty Array?', PrimNameBasis.corpusLabel),

  flattenToJson(24201, 'Flatten To JSON', PrimNameBasis.corpusLabel),

  unflattenFromJson(24202, 'Unflatten From JSON', PrimNameBasis.review),

  openPythonSession(24206, 'Open Python Session', PrimNameBasis.review),

  closePythonSession(24207, 'Close Python Session', PrimNameBasis.review);

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
}
