/// The C4 record heap: the body of an `FPHb`/`BDHb` section after its length word, read as a
/// stream of records that [recordSkip] sizes by their lead byte.
///
/// ```text
/// offset  size  field    meaning
/// 0       4     length   u32; the walk starts at 4
/// 4       rest  records  one record per lead byte, sized as below
/// ```
///
/// Record forms, as [recordSkip], [heapObjectHeaderAt], [decodeHeapAttr], [decodeHeapRef] and
/// [decodeHeapPropertyToken] read them:
///
/// ```text
/// lead            layout                                              read by
/// 10 11 12        [lead][tag][02][fe][u16 kind][fd][u16 oid]          heapObjectHeaderAt: object open, 9 bytes;
///                 [lead][tag][02][fe][u16 kind][fd][80 00][u32 oid]   13 bytes when byte 7 has bit 0x80 set
/// 10..13          [lead][groupTag][count][typeTag] items              group open when byte 3 is a type tag
///                                                                     (fb: 2-byte items; fe, fd: 3-byte items, 7 when
///                                                                     an item starts fd with bit 0x80 set)
/// 08..0b          [lead][tag]                                         group close, 2 bytes
/// 0x..1x          [lead][tag]                                         2 bytes unless byte 3 is a type tag (typed list)
/// c4              [c4][opcode][len]                  [payload]        C4 record; len ff escapes to [ff][u16 len];
///                                                                     opcode named by HeapOpcode, payload by HeapShape
/// c5 c6           [lead][id][len][payload]                            counted attribute; c6 with len ff escapes to
///                                                                     [ff][u16 len]; HeapAttribute.raw = (lead & 3) << 8 | id;
///                                                                     payload 8 bytes = rect, f64 for the scale ids,
///                                                                     length-prefixed string for the string ids,
///                                                                     otherwise a container whose first byte is the value
/// x4 x5 x6        [lead][id][value]                                   attribute whose high nibble sizes the value:
///                                                                     0 = flag false, 2 = u8, 4 = u16, 6 = u24, 8 = u32
///                                                                     (rgb), e = flag true
/// 14..17          [lead][id][01][fd][u16 oid]                         reference, 6 bytes; [fd][80 00][u32 oid] = 10;
///                                                                     HeapRefKind.raw = (lead & 3) << 8 | id
/// op subop        [op][subop] ([count][typeTag] items)                property token named by HeapPropertyToken;
///                                                                     the selector form is the 2 bytes alone
/// 04              [04][x]                                             type descriptor token, 2 bytes
/// 02 fe           [02][fe] + 5 bytes                                  7 bytes; content not decoded
/// ```
///
/// [walkHeapBody] frames the body into [HeapSpan]s; [walkHeapObjects] replays it as an object
/// tree; [scanC4Records] collects the C4 records; [measureHeapTiers] grades every span by
/// [HeapDecodeTier].
library;

import 'dart:typed_data';

import '../decode.dart';

/// Lead byte of a C4 record.
const int kHeapRecordPrefix = 0xc4;

/// Lead bytes that can open an object.
const Set<int> kHeapObjectHeaderLeads = {0x10, 0x11, 0x12};

/// Lead bytes that can open a group.
const Set<int> kHeapGroupOpenLeads = {0x10, 0x11, 0x12, 0x13};

/// Lead bytes that close a group.
const Set<int> kHeapGroupCloseLeads = {0x08, 0x09, 0x0a, 0x0b};

/// Whether [tagByte] is one of the typed-list tags `fb`, `fe`, `fd`.
bool isHeapTypeTag(int tagByte) => tagByte == 0xfb || tagByte == 0xfe || tagByte == 0xfd;

/// The opcode byte of a C4 record; [shape] says how its payload reads.
enum HeapOpcode {
  /// Bounds rectangle.
  bounds(0x2d, HeapShape.rectangle, isDecoded: true),

  /// Size rectangle.
  size(0x1f, HeapShape.rectangle, isDecoded: true),

  /// Table of Pascal strings.
  stringTable(0x2e, HeapShape.stringTable, isDecoded: true),

  /// Caption text.
  caption(0x22, HeapShape.string, isDecoded: true),

  /// Plot name text.
  plotName(0x27, HeapShape.string, isDecoded: true),

  /// Format string text.
  formatString(0x74, HeapShape.string, isDecoded: true),

  /// Item label text.
  itemLabel(0x20, HeapShape.string, isDecoded: true),

  /// Symbol name text.
  symbolName(0xc4, HeapShape.string, isDecoded: true),

  /// Method name text.
  methodName(0xb6, HeapShape.string, isDecoded: true),

  /// Description or help text.
  description(0x19, HeapShape.helpText, isDecoded: true),

  /// A `PTH0` path.
  path(0xa4, HeapShape.path, isDecoded: true),

  /// Type bounds rectangle.
  typeBounds(0x4a, HeapShape.rectangle, isDecoded: true),

  /// Container of nested C4 records; role not established.
  container44(0x44, HeapShape.container),

  /// Container of nested C4 records; role not established.
  container64(0x64, HeapShape.container),

  /// Container of nested C4 records; role not established.
  container24(0x24, HeapShape.container),

  /// Document bounds rectangle.
  docBounds(0x5f, HeapShape.rectangle, isDecoded: true),

  /// D bounds rectangle.
  dBounds(0x4c, HeapShape.rectangle, isDecoded: true),

  /// P bounds rectangle.
  pBounds(0xd6, HeapShape.rectangle, isDecoded: true),

  /// Dynamic bounds rectangle.
  dynBounds(0x62, HeapShape.rectangle, isDecoded: true),

  /// A rectangle; role not established.
  rect26(0x26, HeapShape.rectangle),

  /// A rectangle; role not established.
  rect23(0x23, HeapShape.rectangle),

  /// Any opcode not listed.
  unknown(-1, HeapShape.none)
  ;

  const HeapOpcode(this.byte, this.shape, {this.isDecoded = false});

  final int byte;

  final HeapShape shape;

  final bool isDecoded;

  static final Map<int, HeapOpcode> _byByte = {
    for (final op in values)
      if (op != unknown) op.byte: op,
  };

  static HeapOpcode fromByte(int opByte) => _byByte[opByte] ?? unknown;
}

/// What a C4 record payload holds.
enum HeapShape {
  /// Four signed 16-bit edges, see [HeapRect].
  rectangle,

  /// Text bytes.
  string,

  /// Table of Pascal strings.
  stringTable,

  /// Text, or Pascal runs of text.
  helpText,

  /// A `PTH0` path.
  path,

  /// Nested C4 records.
  container,

  /// No payload shape is established.
  none,
}

/// What an attribute value means.
enum HeapAttrKind {
  /// An RGB colour.
  color,

  /// A coordinate.
  coordinate,

  /// A size.
  size,

  /// A member of an enumeration whose values are not named here.
  enumValue,

  /// A boolean.
  flag,

  /// An index or count.
  ordinal,

  /// A number.
  numeric,

  /// A control parameter, stored as f64.
  controlParam,

  /// Short text packed into the value bytes.
  text,

  /// A length-prefixed string.
  stringBlob,

  /// A rectangle.
  rectangle,

  /// Two signed 16-bit coordinates packed into one value.
  point,

  /// A counted payload of nested records.
  container,

  /// Not established.
  unknown,
}

/// How an attribute value is stored.
enum HeapAttrWidth {
  /// One value byte.
  u8,

  /// Two value bytes.
  u16,

  /// Three value bytes.
  u24,

  /// Four value bytes.
  rgb,

  /// No value bytes; the high nibble carries true or false.
  flag,

  /// An 8-byte float payload.
  f64,

  /// A length-prefixed payload read as a string.
  blob,

  /// An 8-byte rectangle payload.
  rect,

  /// A counted payload of nested records.
  container,
}

/// How far an attribute, token or reference name is established.
enum AttrConfidence {
  /// Established by a test against the corpus.
  confirmed,

  /// Named from the value's use; not confirmed.
  inferred,

  /// Only the value's shape is known.
  kindOnly,
}

/// The attribute ids, `(lead & 3) << 8 | id`, with the kind and name each carries.
enum HeapAttribute {
  /// Relative offset; inferred.
  relativeOffset(0x01f, HeapAttrKind.coordinate, 'relativeOffset', AttrConfidence.inferred),

  /// X coordinate; inferred.
  coordX(0x000, HeapAttrKind.coordinate, 'coordX', AttrConfidence.inferred),

  /// Y coordinate; inferred.
  coordY(0x001, HeapAttrKind.coordinate, 'coordY', AttrConfidence.inferred),

  /// Array element value.
  arrayElemValue(0x019, HeapAttrKind.numeric, 'arrayElementValue', AttrConfidence.confirmed),

  /// Part role; inferred.
  partRole(0x0df, HeapAttrKind.enumValue, 'partRole', AttrConfidence.inferred),

  /// Master part; inferred.
  masterPart(0x0af, HeapAttrKind.enumValue, 'masterPart', AttrConfidence.inferred),

  /// Type descriptor index; inferred.
  typeDescIndex(0x13a, HeapAttrKind.ordinal, 'typeDescIndex', AttrConfidence.inferred),

  /// Clump number; inferred.
  clumpNum(0x03a, HeapAttrKind.ordinal, 'clumpNum', AttrConfidence.inferred),

  /// How the object grows; inferred.
  howGrow(0x089, HeapAttrKind.numeric, 'howGrow', AttrConfidence.inferred),

  /// Size extent; inferred.
  sizeExtent(0x0f8, HeapAttrKind.size, 'sizeExtent', AttrConfidence.inferred),

  /// Terminal bounds rectangle; inferred.
  termBounds(0x129, HeapAttrKind.rectangle, 'termBounds', AttrConfidence.inferred),

  /// Numeric value; role not established.
  color29(0x029, HeapAttrKind.numeric, 'value29', AttrConfidence.kindOnly),

  /// Parameter index.
  paramIdx(0x0dc, HeapAttrKind.ordinal, 'paramIdx', AttrConfidence.confirmed),

  /// Property item name.
  propItemName(0x231, HeapAttrKind.stringBlob, 'propItemName', AttrConfidence.confirmed),

  /// Constant value; inferred.
  constValue(0x26c, HeapAttrKind.stringBlob, 'constValue', AttrConfidence.inferred),

  /// Total bounds rectangle; inferred.
  totalBounds(0x163, HeapAttrKind.rectangle, 'totalBounds', AttrConfidence.inferred),

  /// Source rectangle; inferred.
  srcRect(0x164, HeapAttrKind.rectangle, 'srcRect', AttrConfidence.inferred),

  /// Compressed wire table; inferred.
  compressedWireTable(0x1e7, HeapAttrKind.numeric, 'compressedWireTable', AttrConfidence.inferred),

  /// Last signal kind; inferred.
  lastSignalKind(0x09f, HeapAttrKind.numeric, 'lastSignalKind', AttrConfidence.inferred),

  /// Signal state; inferred.
  signalState(0x115, HeapAttrKind.numeric, 'signalState', AttrConfidence.inferred),

  /// DSW; inferred.
  dsw(0x061, HeapAttrKind.numeric, 'dsw', AttrConfidence.inferred),

  /// Short count; inferred.
  shortCount(0x106, HeapAttrKind.numeric, 'shortCount', AttrConfidence.inferred),

  /// Mouse-wheel support; inferred.
  mouseWheelSupport(0x286, HeapAttrKind.enumValue, 'mouseWheelSupport', AttrConfidence.inferred),

  /// First node index; inferred.
  firstNodeIdx(0x072, HeapAttrKind.ordinal, 'firstNodeIdx', AttrConfidence.inferred),

  /// Annex DDO flag; inferred.
  annexDDOFlag(0x17b, HeapAttrKind.numeric, 'annexDDOFlag', AttrConfidence.inferred),

  /// Element index; inferred.
  elementI(0x08a, HeapAttrKind.ordinal, 'i', AttrConfidence.inferred),

  /// Connector TM; inferred.
  connectorTM(0x048, HeapAttrKind.numeric, 'connectorTM', AttrConfidence.inferred),

  /// Numeric value; role not established.
  field23(0x023, HeapAttrKind.numeric, 'field23', AttrConfidence.kindOnly),

  /// Primitive resource id; inferred.
  primResID(0x0ea, HeapAttrKind.numeric, 'primResID', AttrConfidence.inferred),

  /// Primitive index; inferred.
  primIndex(0x0e9, HeapAttrKind.numeric, 'primIndex', AttrConfidence.inferred),

  /// Parameter index; inferred.
  parmIndex(0x0de, HeapAttrKind.ordinal, 'parmIndex', AttrConfidence.inferred),

  /// Object flags; inferred.
  objFlags(0x0cb, HeapAttrKind.numeric, 'objFlags', AttrConfidence.inferred),

  /// Packed pair or id; inferred.
  packedPair(0x05e, HeapAttrKind.numeric, 'packedPairOrId', AttrConfidence.inferred),

  /// Pane flags; inferred.
  paneFlags(0x0da, HeapAttrKind.numeric, 'paneFlags', AttrConfidence.inferred),

  /// Background colour.
  backgroundColor(0x028, HeapAttrKind.color, 'backgroundColor', AttrConfidence.confirmed),

  /// Content colour.
  contentColor(0x024, HeapAttrKind.color, 'contentColor', AttrConfidence.confirmed),

  /// Foreground colour.
  fgColor(0x06f, HeapAttrKind.color, 'fgColor', AttrConfidence.confirmed),

  /// Cosmetic foreground colour; inferred.
  cosmFgColor(0x020, HeapAttrKind.color, 'cosmFgColor', AttrConfidence.inferred),

  /// Second cosmetic colour; inferred.
  cosmColorB(0x021, HeapAttrKind.color, 'cosmColorB', AttrConfidence.inferred),

  /// Plot colour; inferred.
  plotColor(0x02a, HeapAttrKind.color, 'plotColor', AttrConfidence.inferred),

  /// Border colour; inferred.
  borderColor(0x02b, HeapAttrKind.color, 'borderColor', AttrConfidence.inferred),

  /// Origin point; inferred.
  origin(0x0d0, HeapAttrKind.point, 'origin', AttrConfidence.inferred),

  /// Minimum pane size; inferred.
  minPaneSize(0x0b7, HeapAttrKind.point, 'minPaneSize', AttrConfidence.inferred),

  /// Short text; inferred.
  shortText(0x022, HeapAttrKind.text, 'shortText', AttrConfidence.inferred),

  /// Format style text; inferred.
  formatStyle(0x074, HeapAttrKind.text, 'formatStyle', AttrConfidence.inferred),

  /// Terminal list length.
  termListLength(0x158, HeapAttrKind.ordinal, 'termListLength', AttrConfidence.confirmed),

  /// Connection number; inferred.
  conNum(0x044, HeapAttrKind.ordinal, 'conNum', AttrConfidence.inferred),

  /// Reserved flag; inferred.
  reservedFlag(0x059, HeapAttrKind.flag, 'reservedFlag', AttrConfidence.inferred),

  /// Flag; inferred.
  flag5A(0x05a, HeapAttrKind.flag, 'flag5A', AttrConfidence.inferred),

  /// Default data; inferred.
  defaultData(0x25a, HeapAttrKind.numeric, 'defaultData', AttrConfidence.inferred),

  /// Scale minimum; inferred.
  scaleDMin(0x1f5, HeapAttrKind.controlParam, 'scaleDMin', AttrConfidence.inferred),

  /// Scale maximum; inferred.
  scaleDMax(0x1f6, HeapAttrKind.controlParam, 'scaleDMax', AttrConfidence.inferred),

  /// Scale start; inferred.
  scaleDStart(0x1f7, HeapAttrKind.controlParam, 'scaleDStart', AttrConfidence.inferred),

  /// Scale increment; inferred.
  scaleDIncr(0x1f8, HeapAttrKind.controlParam, 'scaleDIncr', AttrConfidence.inferred),

  /// Scale minimum increment.
  scaleDMinInc(0x1f9, HeapAttrKind.controlParam, 'scaleDMinInc', AttrConfidence.confirmed),

  /// Scale multiplier.
  scaleDMultiplier(0x1fa, HeapAttrKind.controlParam, 'scaleDMultiplier', AttrConfidence.confirmed),

  /// Standard numeric minimum; inferred.
  stdNumMin(0x220, HeapAttrKind.controlParam, 'stdNumMin', AttrConfidence.inferred),

  /// Standard numeric maximum; inferred.
  stdNumMax(0x221, HeapAttrKind.controlParam, 'stdNumMax', AttrConfidence.inferred),

  /// Standard numeric increment; inferred.
  stdNumInc(0x222, HeapAttrKind.controlParam, 'stdNumInc', AttrConfidence.inferred),

  /// Table flags; inferred.
  tableFlags(0x120, HeapAttrKind.numeric, 'tableFlags', AttrConfidence.inferred),

  /// Stamp.
  stamp(0x114, HeapAttrKind.numeric, 'stamp', AttrConfidence.confirmed),

  /// Node name text; inferred.
  nodeName(0x0c4, HeapAttrKind.text, 'nodeName', AttrConfidence.inferred),

  /// OM id; inferred.
  oMId(0x0c9, HeapAttrKind.numeric, 'oMId', AttrConfidence.inferred),

  /// OM id type descriptor; inferred.
  omidTypeDesc(0x0ce, HeapAttrKind.ordinal, 'omidTypeDesc', AttrConfidence.inferred),

  /// Data type descriptor; inferred.
  dataTypeDesc(0x15b, HeapAttrKind.ordinal, 'dataTypeDesc', AttrConfidence.inferred),

  /// Property item code; inferred.
  propItemCode(0x232, HeapAttrKind.numeric, 'propItemCode', AttrConfidence.inferred),

  /// Connection id; inferred.
  conId(0x043, HeapAttrKind.numeric, 'conId', AttrConfidence.inferred),

  /// D index; inferred.
  dIdx(0x04d, HeapAttrKind.ordinal, 'dIdx', AttrConfidence.inferred),

  /// Numeric value; role not established.
  dcoFiller(0x051, HeapAttrKind.numeric, 'dcoFiller', AttrConfidence.kindOnly),

  /// Index; inferred.
  index90(0x090, HeapAttrKind.ordinal, 'index', AttrConfidence.inferred),

  /// In-place; inferred.
  inplace(0x097, HeapAttrKind.numeric, 'inplace', AttrConfidence.inferred),

  /// Instrument style; inferred.
  instrStyle(0x09a, HeapAttrKind.numeric, 'instrStyle', AttrConfidence.inferred),

  /// Visible item count; inferred.
  nVisItems(0x0c0, HeapAttrKind.numeric, 'nVisItems', AttrConfidence.inferred),

  /// nRC point; inferred.
  nRC(0x0bf, HeapAttrKind.point, 'nRC', AttrConfidence.inferred),

  /// oRC point; inferred.
  oRC(0x0ca, HeapAttrKind.point, 'oRC', AttrConfidence.inferred),

  /// Terminal bitmaps; inferred.
  termBMPs(0x128, HeapAttrKind.enumValue, 'termBMPs', AttrConfidence.inferred),

  /// Numeric value; role not established.
  tdOffset(0x127, HeapAttrKind.numeric, 'tdOffset', AttrConfidence.kindOnly),

  /// Text record field; inferred.
  textRecField(0x12d, HeapAttrKind.numeric, 'textRecField', AttrConfidence.inferred),

  /// Maximum word length; inferred.
  maxWordLength(0x1c0, HeapAttrKind.numeric, 'maxWordLength', AttrConfidence.inferred),

  /// Fixed-point override; inferred.
  fxpOverride(0x1c1, HeapAttrKind.numeric, 'override', AttrConfidence.inferred),

  /// Fixed-point overflow; inferred.
  fxpOverflow(0x1c2, HeapAttrKind.numeric, 'overflow', AttrConfidence.inferred),

  /// Fixed-point quantize; inferred.
  fxpQuantize(0x1c3, HeapAttrKind.numeric, 'quantize', AttrConfidence.inferred),

  /// Parameter table offset; inferred.
  paramTableOffset(0x0dd, HeapAttrKind.numeric, 'paramTableOffset', AttrConfidence.inferred),

  /// Selected default case; inferred.
  selectDefaultCase(0x254, HeapAttrKind.enumValue, 'selectDefaultCase', AttrConfidence.inferred),

  /// Select N right type; inferred.
  selectNRightType(0x255, HeapAttrKind.enumValue, 'selectNRightType', AttrConfidence.inferred),

  /// Selector label flags; inferred.
  selectSelLabFlags(0x266, HeapAttrKind.numeric, 'selectSelLabFlags', AttrConfidence.inferred),

  /// Parallel-for index distribution; inferred.
  parForIndexDistribution(0x25c, HeapAttrKind.numeric, 'parForIndexDistribution', AttrConfidence.inferred),

  /// Debugging enabled; inferred.
  debuggingEnabled(0x271, HeapAttrKind.flag, 'debuggingEnabled', AttrConfidence.inferred),

  /// Output instance number from P; inferred.
  outputInstanceNumberFromP(0x277, HeapAttrKind.flag, 'outputInstanceNumberFromP', AttrConfidence.inferred),

  /// Default tunnel type; inferred.
  defaultTunnelType(0x27f, HeapAttrKind.enumValue, 'defaultTunnelType', AttrConfidence.inferred),

  /// FPGA implementation; inferred.
  fpgaImplementation(0x280, HeapAttrKind.flag, 'fpgaImplementation', AttrConfidence.inferred),

  /// FPGA enable bounds mux; inferred.
  fpgaEnableBoundsMux(0x291, HeapAttrKind.flag, 'fpgaEnableBoundsMux', AttrConfidence.inferred),

  /// Default value matches the control VI; inferred.
  defaultValueMatchesCtlVI(0x28f, HeapAttrKind.flag, 'defaultValueMatchesCtlVI', AttrConfidence.inferred),

  /// Cell column; inferred.
  cellPosCol(0x1b3, HeapAttrKind.ordinal, 'cellPosCol', AttrConfidence.inferred),

  /// Saved size rectangle; inferred.
  savedSize(0x275, HeapAttrKind.rectangle, 'savedSize', AttrConfidence.inferred),

  /// Reference list length; inferred.
  refListLength(0x159, HeapAttrKind.ordinal, 'refListLength', AttrConfidence.inferred),

  /// Horizontal-grow node list length; inferred.
  hGrowNodeListLength(0x15a, HeapAttrKind.ordinal, 'hGrowNodeListLength', AttrConfidence.inferred),

  /// Minimum button size; inferred.
  minButSize(0x25e, HeapAttrKind.point, 'minButSize', AttrConfidence.inferred),

  /// Terminal hot point; inferred.
  termHotPoint(0x12a, HeapAttrKind.point, 'termHotPoint', AttrConfidence.inferred),

  /// Tunnel type; inferred.
  tunnelType(0x27e, HeapAttrKind.enumValue, 'tunnelType', AttrConfidence.inferred),

  /// Parallel-for static worker count; inferred.
  parForNumStaticWorkers(0x263, HeapAttrKind.numeric, 'parForNumStaticWorkers', AttrConfidence.inferred),

  /// Window flags; inferred.
  winFlags(0x144, HeapAttrKind.numeric, 'winFlags', AttrConfidence.inferred),

  /// Structure colour; inferred.
  structColor(0x119, HeapAttrKind.color, 'structColor', AttrConfidence.inferred),

  /// Part order; inferred.
  partOrder(0x0e0, HeapAttrKind.ordinal, 'partOrder', AttrConfidence.inferred),

  /// Preferred instance index; inferred.
  preferredInstIndex(0x0e8, HeapAttrKind.ordinal, 'preferredInstIndex', AttrConfidence.inferred),

  /// Cell row; inferred.
  cellPosRow(0x1b2, HeapAttrKind.ordinal, 'cellPosRow', AttrConfidence.inferred),

  /// Item flags; inferred.
  itemFlags(0x1b8, HeapAttrKind.numeric, 'flags', AttrConfidence.inferred),

  /// State data; inferred.
  stateData(0x25d, HeapAttrKind.numeric, 'stateData', AttrConfidence.inferred),

  /// Numeric value; role not established.
  bufValue(0x02e, HeapAttrKind.numeric, 'bufValue', AttrConfidence.kindOnly),

  /// Any id not listed.
  unknown(-1, HeapAttrKind.unknown, 'unknown', AttrConfidence.kindOnly)
  ;

  const HeapAttribute(this.raw, this.kind, this.attrName, this.confidence);

  final int raw;

  final HeapAttrKind kind;

  final String attrName;

  final AttrConfidence confidence;

  static final Map<int, HeapAttribute> _byRaw = {
    for (final attribute in values)
      if (attribute != unknown) attribute.raw: attribute,
  };

  static HeapAttribute fromRaw(int raw) => _byRaw[raw] ?? unknown;
}

/// One decoded attribute record.
class HeapAttr {
  const HeapAttr({
    required this.attribute,
    required this.id,
    required this.rawTag,
    required this.width,
    required this.value,
    required this.length,
    this.rawValueBytes,
  });

  final HeapAttribute attribute;

  /// The low byte of the attribute id.
  final int id;

  /// The full attribute id, `(lead & 3) << 8 | id`.
  final int rawTag;

  final HeapAttrWidth width;

  final Object value;

  /// Bytes the record occupies, header included.
  final int length;

  /// The payload bytes of a counted attribute; null for the nibble-sized forms.
  final Uint8List? rawValueBytes;

  HeapAttrKind get kind => switch (width) {
    HeapAttrWidth.f64 => HeapAttrKind.controlParam,
    HeapAttrWidth.blob => HeapAttrKind.stringBlob,
    HeapAttrWidth.rect => HeapAttrKind.rectangle,
    HeapAttrWidth.container => HeapAttrKind.container,
    _ => attribute.kind,
  };

  int? get asInt => switch (value) {
    final int number => number,
    _ => null,
  };

  double? get asDouble => switch (value) {
    final double number => number,
    _ => null,
  };

  String? get asString => switch (value) {
    final String text => text,
    _ => null,
  };

  String? get asciiText => switch (value) {
    final int number when _asciiIntRaws.contains(rawTag) => _asciiFromInt(number),
    _ => null,
  };

  HeapRect? get asRect => switch (value) {
    final HeapRect rect => rect,
    _ => null,
  };

  ({int a, int b})? get asPoint => switch (value) {
    final int number when kind == HeapAttrKind.point && width == HeapAttrWidth.rgb => (
      a: (number >> 16).toSigned(16),
      b: (number & 0xffff).toSigned(16),
    ),
    _ => null,
  };

  int? get rgb => switch (value) {
    final int number when kind == HeapAttrKind.color => number & 0xffffff,
    _ => null,
  };

  bool get isTransparent => switch (value) {
    final int number => rgb == 0 && number >>> 24 == 0x01,
    _ => false,
  };
}

const Set<int> _rectPayloadRaws = {0x129, 0x163, 0x164, 0x275};

const Set<int> _f64PayloadRaws = {0x1f5, 0x1f6, 0x1f7, 0x1f8, 0x1f9, 0x1fa, 0x220, 0x221, 0x222};

const Set<int> _inlineStringRaws = {0x231};

const Set<int> _u32StringRaws = {0x26c};

const Set<int> _asciiIntRaws = {0x022, 0x0c4};

bool _isPrintableAscii(int byte) => byte >= 0x20 && byte < 0x7f;

String? _asciiFromInt(int v) {
  if (v <= 0) return null;
  final chars = <int>[];
  for (var x = v; x > 0; x >>= 8) {
    final b = x & 0xff;
    if (!_isPrintableAscii(b)) return null;
    chars.add(b);
  }
  return String.fromCharCodes(chars.reversed);
}

const Map<int, int> _attrNibbleValueBytes = {0x0: 0, 0x2: 1, 0x4: 2, 0x6: 3, 0x8: 4, 0xe: 0};

/// The attribute record at [offset], or null when the bytes there are not one.
HeapAttr? decodeHeapAttr(Uint8List body, int offset) {
  if (offset + 2 > body.length) return null;
  final view = ByteData.sublistView(body);
  final op = body[offset];
  final id = body[offset + 1];
  final raw = ((op & 3) << 8) | id;

  if (op == 0xc6 && offset + 3 <= body.length && _inlineStringRaws.contains(raw) && body[offset + 2] != 0xff) {
    final len = body[offset + 2];
    if (offset + 3 + len <= body.length) {
      final text = String.fromCharCodes(body.sublist(offset + 3, offset + 3 + len).where(_isPrintableAscii));
      return HeapAttr(
        attribute: HeapAttribute.fromRaw(raw),
        id: id,
        rawTag: raw,
        width: HeapAttrWidth.blob,
        value: text,
        length: 3 + len,
        rawValueBytes: Uint8List.sublistView(body, offset + 3, offset + 3 + len),
      );
    }
  }

  if ((op == 0xc5 || op == 0xc6) && offset + 11 <= body.length && body[offset + 2] == 0x08) {
    if (_rectPayloadRaws.contains(raw)) {
      final rect = HeapRect.fromPayload(Uint8List.sublistView(body, offset + 3, offset + 11));
      if (rect != null) {
        return HeapAttr(
          attribute: HeapAttribute.fromRaw(raw),
          id: id,
          rawTag: raw,
          width: HeapAttrWidth.rect,
          value: rect,
          length: 11,
        );
      }
    }
    if (_f64PayloadRaws.contains(raw)) {
      final value = view.getFloat64(offset + 3);
      return HeapAttr(
        attribute: HeapAttribute.fromRaw(raw),
        id: id,
        rawTag: raw,
        width: HeapAttrWidth.f64,
        value: value,
        length: 11,
        rawValueBytes: Uint8List.sublistView(body, offset + 3, offset + 11),
      );
    }
  }

  if (op == 0xc6 && offset + 5 <= body.length && body[offset + 2] == 0xff) {
    final len = view.getUint16(offset + 3);
    final end = offset + 5 + len;
    if (end <= body.length && len >= 4) {
      final strLen = view.getUint32(offset + 5);
      final from = offset + 9, to = (from + strLen) <= end ? from + strLen : end;
      final bytes = body.sublist(from, to);
      final chars = bytes.where(_isPrintableAscii).toList();
      if (bytes.isNotEmpty && chars.length / bytes.length >= 0.9) {
        return HeapAttr(
          attribute: HeapAttribute.fromRaw(raw),
          id: id,
          rawTag: raw,
          width: HeapAttrWidth.blob,
          value: String.fromCharCodes(chars),
          length: 5 + len,
          rawValueBytes: Uint8List.sublistView(body, offset + 5, offset + 5 + len),
        );
      }
    }
  }

  if (op == 0xc6 && offset + 3 <= body.length && _u32StringRaws.contains(raw)) {
    final len = body[offset + 2];
    if (len != 0xff && len != 0x08 && len >= 5 && offset + 3 + len <= body.length) {
      final payloadStart = offset + 3;
      final strLen = view.getUint32(payloadStart);
      final slack = len - (strLen + 4);
      if (strLen >= 1 && slack >= 0 && !(strLen <= 2 && slack >= 8)) {
        final bytes = body.sublist(payloadStart + 4, payloadStart + 4 + strLen);
        if (bytes.every(_isPrintableAscii)) {
          return HeapAttr(
            attribute: HeapAttribute.fromRaw(raw),
            id: id,
            rawTag: raw,
            width: HeapAttrWidth.blob,
            value: String.fromCharCodes(bytes),
            length: 3 + len,
            rawValueBytes: Uint8List.sublistView(body, offset + 3, offset + 3 + len),
          );
        }
      }
    }
  }

  if (op == 0xc5 || op == 0xc6) {
    if (offset + 3 > body.length) return null;
    var headerLen = 3;
    var len = body[offset + 2];
    if (op == 0xc6 && len == 0xff) {
      if (offset + 5 > body.length) return null;
      headerLen = 5;
      len = view.getUint16(offset + 3);
    }
    if (offset + headerLen + len > body.length) return null;
    return HeapAttr(
      attribute: HeapAttribute.fromRaw(raw),
      id: id,
      rawTag: raw,
      width: HeapAttrWidth.container,
      value: len > 0 ? body[offset + headerLen] : 0,
      length: headerLen + len,
      rawValueBytes: Uint8List.sublistView(body, offset + headerLen, offset + headerLen + len),
    );
  }

  final lo = op & 0xf, hi = op >> 4;
  if (lo == 4 || lo == 5 || lo == 6) {
    final valueBytes = _attrNibbleValueBytes[hi];
    if (valueBytes == null) return null;
    if (hi == 0x0 && op != 0x04 && offset + 4 <= body.length && isHeapTypeTag(body[offset + 3])) {
      return null;
    }
    final valEnd = offset + 2 + valueBytes;
    if (valEnd > body.length) return null;
    HeapAttrWidth width;
    Object value;
    switch (hi) {
      case 0x0:
        width = HeapAttrWidth.flag;
        value = 0;
      case 0x2:
        width = HeapAttrWidth.u8;
        value = body[offset + 2];
      case 0x4:
        width = HeapAttrWidth.u16;
        value = view.getUint16(offset + 2);
      case 0x6:
        width = HeapAttrWidth.u24;
        value = (view.getUint16(offset + 2) << 8) | body[offset + 4];
      case 0x8:
        width = HeapAttrWidth.rgb;
        value = view.getUint32(offset + 2);
      default:
        width = HeapAttrWidth.flag;
        value = 1;
    }
    return HeapAttr(
      attribute: HeapAttribute.fromRaw(raw),
      id: id,
      rawTag: raw,
      width: width,
      value: value,
      length: 2 + valueBytes,
    );
  }

  return null;
}

/// One C4 record: its opcode and payload at [offset] within the section.
class HeapRecord {
  const HeapRecord({
    required this.sectionTag,
    required this.offset,
    required this.opcode,
    required this.payload,
    this.headerLength = 3,
  });

  final String sectionTag;

  final int offset;

  /// 3, or 5 when the length byte escaped to `ff` and a u16.
  final int headerLength;

  final int opcode;

  final Uint8List payload;

  HeapOpcode get kind => HeapOpcode.fromByte(opcode);

  int get byteLength => headerLength + payload.length;

  HeapRect? get rect => kind.shape == HeapShape.rectangle ? HeapRect.fromPayload(payload) : null;

  HeapRect? get bounds => kind == HeapOpcode.bounds ? HeapRect.fromPayload(payload) : null;

  HeapRect? get sizeRect => kind == HeapOpcode.size ? HeapRect.fromPayload(payload) : null;

  String? get text {
    if (kind.shape != HeapShape.string || payload.isEmpty) return null;
    if (payload.any((b) => (b < 32 && b != 0x09 && b != 0x0a && b != 0x0d) || b >= 127)) {
      return null;
    }
    return String.fromCharCodes(payload).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  Uint8List? get rawText => kind.shape == HeapShape.string && payload.isNotEmpty ? payload : null;

  String? get descriptionText {
    if (kind != HeapOpcode.description) return null;
    bool isTextByte(int byte) => (byte >= 32 && byte < 127) || byte == 9 || byte == 10 || byte == 13;

    if (payload.isNotEmpty) {
      final printable = payload.where(isTextByte).length;
      if (printable / payload.length >= 0.9) {
        return String.fromCharCodes(payload.where(isTextByte)).trim();
      }
    }

    final runs = <String>[];
    var i = 0;
    while (i < payload.length) {
      final len = payload[i];
      if (len >= 6 && i + 1 + len <= payload.length && payload.sublist(i + 1, i + 1 + len).every(isTextByte)) {
        runs.add(String.fromCharCodes(payload.sublist(i + 1, i + 1 + len)));
        i += 1 + len;
      } else {
        i++;
      }
    }
    return runs.isEmpty ? null : runs.join('\n');
  }

  String? get path {
    if (kind != HeapOpcode.path) return null;
    final bytes = payload;
    if (bytes.length < 12 || bytes[0] != 0x50 || bytes[1] != 0x54 || bytes[2] != 0x48 || bytes[3] != 0x30) {
      return null;
    }
    final nComp = ByteData.sublistView(bytes).getUint16(10);
    final parts = <String>[];
    var i = 12;
    for (var componentIndex = 0; componentIndex < nComp && i < bytes.length; componentIndex++) {
      final len = bytes[i];
      if (i + 1 + len > bytes.length) break;
      final part = bytes.sublist(i + 1, i + 1 + len);
      if (part.any((byte) => byte < 32 || byte >= 127)) break;
      parts.add(String.fromCharCodes(part));
      i += 1 + len;
    }
    return parts.isEmpty ? null : parts.join('/');
  }

  Uint8List? get rawPathBytes => kind == HeapOpcode.path && payload.isNotEmpty ? payload : null;

  List<HeapRecord> get children =>
      kind.shape == HeapShape.container ? scanC4Records(payload, sectionTag) : const <HeapRecord>[];
}

/// Every C4 record in [heapBytes], skipping bytes that do not start one.
List<HeapRecord> scanC4Records(Uint8List heapBytes, String sectionTag) {
  final out = <HeapRecord>[];
  final length = heapBytes.length;
  var i = 0;
  while (i < length) {
    final frame = c4FrameAt(heapBytes, i, sectionTag);
    if (frame != null) {
      out.add(frame);
      i += frame.byteLength;
      continue;
    }
    i++;
  }
  return out;
}

/// The C4 record at [offset], or null when the bytes there are not one.
HeapRecord? c4FrameAt(Uint8List heapBytes, int offset, String sectionTag) {
  final length = heapBytes.length;
  if (offset + 3 > length || heapBytes[offset] != kHeapRecordPrefix) return null;
  final op = heapBytes[offset + 1];
  final lenByte = heapBytes[offset + 2];
  int headerLen;
  int len;
  if (lenByte == 0xff) {
    if (offset + 5 > length) return null;
    headerLen = 5;
    len = ByteData.sublistView(heapBytes).getUint16(offset + 3);
  } else {
    headerLen = 3;
    len = lenByte;
  }
  if (offset + headerLen + len > length) return null;
  return HeapRecord(
    sectionTag: sectionTag,
    offset: offset,
    opcode: op,
    payload: Uint8List.sublistView(heapBytes, offset + headerLen, offset + headerLen + len),
    headerLength: headerLen,
  );
}

/// A rectangle payload: four signed 16-bit edges.
class HeapRect {
  const HeapRect({required this.top, required this.left, required this.bottom, required this.right});

  static HeapRect? fromPayload(Uint8List payload) {
    if (payload.length != 8) return null;
    final view = ByteData.sublistView(payload);
    return HeapRect(top: view.getInt16(0), left: view.getInt16(2), bottom: view.getInt16(4), right: view.getInt16(6));
  }

  final int top;
  final int left;
  final int bottom;
  final int right;

  int get height => bottom - top;

  int get width => right - left;

  bool get isValid => bottom >= top && right >= left;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HeapRect && other.top == top && other.left == left && other.bottom == bottom && other.right == right;

  @override
  int get hashCode => Object.hash(top, left, bottom, right);

  @override
  String toString() => 'HeapRect(t:$top l:$left b:$bottom r:$right ${width}x$height)';
}

/// The C4 records of every section of a VI.
List<HeapRecord> heapC4Records(Uint8List viBytes) => heapC4RecordsFromDecoded(decodeSections(viBytes));

/// The C4 records of the given sections.
List<HeapRecord> heapC4RecordsFromDecoded(Iterable<DecodedSection> decoded) => [
  for (final decodedSection in decoded) ...scanC4Records(decodedSection.bytes, decodedSection.tag),
];

/// One framed record of a heap body.
class HeapSpan {
  const HeapSpan({required this.offset, required this.length, required this.lead});

  final int offset;

  final int length;

  /// The first byte of the span.
  final int lead;

  bool get isC4Record => lead == kHeapRecordPrefix;
}

/// The framing of a heap body; [complete] when every byte after the length word was sized.
class HeapWalk {
  const HeapWalk({
    required this.spans,
    required this.coveredBytes,
    required this.bodyBytes,
    this.stoppedAtOffset,
    this.stoppedLead,
  });

  final List<HeapSpan> spans;

  final int coveredBytes;

  final int bodyBytes;

  /// Where framing stopped; null when the body was walked to its end.
  final int? stoppedAtOffset;

  /// The byte at [stoppedAtOffset].
  final int? stoppedLead;

  double get coverage => bodyBytes <= 0 ? 1.0 : coveredBytes / bodyBytes;

  bool get complete => stoppedAtOffset == null;
}

/// The two shapes of a property token.
enum PropTokenForm {
  /// The pair is followed by `[count][typeTag]` items.
  taggedList,

  /// The pair stands alone.
  selector,
}

/// The `[op][subop]` pairs that open property records.
enum HeapPropertyToken {
  /// Small value property; role not established.
  smallValueProperty(0x10, 0x19, PropTokenForm.taggedList, 'smallValueProperty', AttrConfidence.kindOnly),

  /// Text appearance flag; inferred.
  textAppearanceFlag(0x10, 0x8d, PropTokenForm.taggedList, 'textAppearanceFlag', AttrConfidence.inferred),

  /// Terminal cluster role; inferred.
  terminalClusterRole(0x10, 0x22, PropTokenForm.taggedList, 'terminalClusterRole', AttrConfidence.inferred),

  /// Text element present; inferred.
  textElementPresent(0x11, 0x2d, PropTokenForm.taggedList, 'textElementPresent', AttrConfidence.inferred),

  /// Sub-part shape count; inferred.
  subPartShapeCount(0x11, 0x1f, PropTokenForm.taggedList, 'subPartShapeCount', AttrConfidence.inferred),

  /// Control style count; inferred.
  controlStyleCount(0x10, 0xe1, PropTokenForm.taggedList, 'controlStyleCount', AttrConfidence.inferred),

  /// Tip strip enabled; inferred.
  tipStripEnabled(0x11, 0x18, PropTokenForm.taggedList, 'tipStripEnabled', AttrConfidence.inferred),

  /// Text style runs.
  textStyleRuns(0x10, 0x25, PropTokenForm.taggedList, 'textStyleRuns', AttrConfidence.confirmed),

  /// Structure child reference list.
  structureChildReflist(0x10, 0x55, PropTokenForm.taggedList, 'structureChildReflist', AttrConfidence.confirmed),

  /// Diagram frame style; role not established.
  diagramFrameStyle(0x11, 0x4e, PropTokenForm.taggedList, 'diagramFrameStyle', AttrConfidence.kindOnly),

  /// Enum or ring property; inferred.
  enumRingProperty(0x11, 0xeb, PropTokenForm.taggedList, 'enumRingProperty', AttrConfidence.inferred),

  /// Enum or ring item count; inferred.
  enumRingCount(0x11, 0xea, PropTokenForm.taggedList, 'enumRingCount', AttrConfidence.inferred),

  /// Diagram property; role not established.
  diagramProperty(0x10, 0x49, PropTokenForm.taggedList, 'diagramProperty', AttrConfidence.kindOnly),

  /// Case or sequence parameter A; inferred.
  caseSeqParamA(0x12, 0x15, PropTokenForm.taggedList, 'caseSeqParamA', AttrConfidence.inferred),

  /// Case or sequence parameter B; inferred.
  caseSeqParamB(0x12, 0x16, PropTokenForm.taggedList, 'caseSeqParamB', AttrConfidence.inferred),

  /// Case or sequence parameter C; inferred.
  caseSeqParamC(0x12, 0x17, PropTokenForm.taggedList, 'caseSeqParamC', AttrConfidence.inferred),

  /// Decoration property; role not established.
  decorationProperty(0x12, 0x05, PropTokenForm.taggedList, 'decorationProperty', AttrConfidence.kindOnly),

  /// Viewport slot 1.
  viewportSlot1(0x11, 0x10, PropTokenForm.selector, 'viewportSlot1', AttrConfidence.confirmed),

  /// Viewport slot 2; inferred.
  viewportSlot2(0x11, 0x14, PropTokenForm.selector, 'viewportSlot2', AttrConfidence.inferred),

  /// Wizard id marker; inferred.
  wizIdMarker(0x15, 0x4b, PropTokenForm.selector, 'wizID', AttrConfidence.inferred)
  ;

  const HeapPropertyToken(this.op, this.subop, this.form, this.tokenName, this.confidence);

  final int op;

  final int subop;

  final PropTokenForm form;

  final String tokenName;

  final AttrConfidence confidence;

  static final Map<int, HeapPropertyToken> _byKey = {
    for (final token in values) (token.op << 8) | token.subop: token,
  };

  static HeapPropertyToken? lookup(int op, int subop) => _byKey[(op << 8) | subop];
}

/// The tag byte of a group-open record.
enum HeapGroupTag {
  /// List of font runs.
  fontRunList(0x25),

  /// One font run.
  fontRun(0x19),

  /// Array index.
  arrayIndex(0x15),

  /// List of case-selector ranges.
  selectorRangeList(0x56),

  /// List of case-selector ranges, alternate tag.
  selectorRangeListAlt(0x57),

  /// One case-selector range.
  selectorRange(0x19),

  /// Case-selector string pool.
  selectorStringPool(0x58)
  ;

  const HeapGroupTag(this.tag);

  final int tag;
}

/// TODO: raw tag `0x029` inside a font run is not decoded.
enum FontRunAttr {
  /// Character offset where the run starts.
  start(0x027),

  /// Font id the run uses, resolved through the `FTAB` table.
  fontId(0x028)
  ;

  const FontRunAttr(this.raw);

  final int raw;
}

/// Attribute ids inside a case-selector range group.
enum SelectorRangeAttr {
  /// Low end of the range.
  low(0x01f),

  /// High end of the range.
  high(0x020),

  /// Whether the low end is bounded.
  lowBound(0x021),

  /// Whether the high end is bounded.
  highBound(0x022),

  /// Frame the range selects.
  frame(0x023)
  ;

  const SelectorRangeAttr(this.raw);

  final int raw;
}

/// Whether [op] is the type-descriptor token lead.
bool isTypeDescriptorToken(int op) => op == 0x04;

bool _isObjectHeader(Uint8List body, int offset) =>
    offset + 9 <= body.length &&
    kHeapObjectHeaderLeads.contains(body[offset]) &&
    body[offset + 2] == 0x02 &&
    body[offset + 3] == 0xfe &&
    body[offset + 6] == 0xfd;

/// The object header at [offset], or null when the bytes there are not one.
({int kind, int oid, int length})? heapObjectHeaderAt(Uint8List body, int offset) {
  if (!_isObjectHeader(body, offset)) return null;
  final view = ByteData.sublistView(body);
  final kind = view.getUint16(offset + 4);
  if ((body[offset + 7] & 0x80) != 0 && offset + 13 <= body.length) {
    return (kind: kind, oid: view.getUint32(offset + 9), length: 13);
  }
  return (kind: kind, oid: view.getUint16(offset + 7), length: 9);
}

/// One decoded property token and, for the tagged-list form, its first item.
class HeapPropertyValue {
  const HeapPropertyValue({required this.token, required this.value, required this.length});

  final HeapPropertyToken token;

  /// The first item of a tagged list; null for the selector form or an empty list.
  final int? value;

  final int length;
}

/// The property token at [offset], or null when the bytes there are not one.
HeapPropertyValue? decodeHeapPropertyToken(Uint8List body, int offset) {
  if (offset + 2 > body.length) return null;
  if (_isObjectHeader(body, offset)) return null;
  final op = body[offset], subop = body[offset + 1];
  final token = HeapPropertyToken.lookup(op, subop);
  if (token == null) return null;
  if (token.form == PropTokenForm.selector) {
    return HeapPropertyValue(token: token, value: null, length: 2);
  }
  if (offset + 4 > body.length || !isHeapTypeTag(body[offset + 3])) return null;
  final len = _typedList(body, offset);
  if (len == null) return null;
  final count = body[offset + 2];
  final tag = body[offset + 3];
  final view = ByteData.sublistView(body);
  int? value;
  if (count == 0) {
    value = null;
  } else if (tag == 0xfd && offset + 5 <= body.length && (body[offset + 4] & 0x80) != 0) {
    value = offset + 10 <= body.length ? view.getUint32(offset + 6) : null;
  } else if ((tag == 0xfb || tag == 0xfe || tag == 0xfd) && offset + 6 <= body.length) {
    value = view.getUint16(offset + 4);
  }
  return HeapPropertyValue(token: token, value: value, length: len);
}

/// The reference ids, `(lead & 3) << 8 | id`; [objectRef] stands for any other id.
enum HeapRefKind {
  /// Child reference.
  childRef(0x019, 'childRef', AttrConfidence.confirmed),

  /// DCO reference; inferred.
  dcoRef(0x04f, 'dcoRef', AttrConfidence.inferred),

  /// Owner reference.
  ownerRef(0x01f, 'ownerRef', AttrConfidence.confirmed),

  /// DCO aggregate reference; inferred.
  dcoAggRef(0x050, 'dcoAggRef', AttrConfidence.inferred),

  /// DDO reference; inferred.
  ddoRef(0x053, 'ddoRef', AttrConfidence.inferred),

  /// Source DCO reference; inferred.
  srcDCORef(0x113, 'srcDCORef', AttrConfidence.inferred),

  /// Loop limit DCO reference; inferred.
  loopLimitDCORef(0x1bd, 'loopLimitDCORef', AttrConfidence.inferred),

  /// Data value reference DCO reference; inferred.
  dataValRefDCORef(0x1d0, 'dataValRefDCORef', AttrConfidence.inferred),

  /// Tunnel link reference; inferred.
  tunnelLinkRef(0x1e2, 'tunnelLinkRef', AttrConfidence.inferred),

  /// Poser reference; inferred.
  poserRef(0x1cf, 'poserRef', AttrConfidence.inferred),

  /// Attachment reference; inferred.
  attachmentRef(0x28a, 'attachmentRef', AttrConfidence.inferred),

  /// Attached object reference; inferred.
  attachedObjectRef(0x289, 'attachedObjectRef', AttrConfidence.inferred),

  /// Any other reference id; inferred.
  objectRef(-1, 'objectRef', AttrConfidence.inferred)
  ;

  const HeapRefKind(this.raw, this.refName, this.confidence);

  final int raw;

  final String refName;

  final AttrConfidence confidence;

  static final Map<int, HeapRefKind> _byRaw = {
    for (final refKind in values)
      if (refKind != objectRef) refKind.raw: refKind,
  };

  static HeapRefKind fromRaw(int raw) => _byRaw[raw] ?? objectRef;
}

/// One decoded reference record.
class HeapRef {
  const HeapRef({required this.kind, required this.targetOid, required this.length});

  final HeapRefKind kind;

  final int targetOid;

  /// 6, or 10 for the u32 oid form.
  final int length;
}

/// The reference record at [offset], or null when the bytes there are not one.
HeapRef? decodeHeapRef(Uint8List body, int offset) {
  if (offset + 6 > body.length) return null;
  final lead = body[offset];
  if (lead < 0x14 || lead > 0x17) return null;
  if (body[offset + 2] != 0x01 || body[offset + 3] != 0xfd) return null;
  final raw = ((lead & 3) << 8) | body[offset + 1];
  final view = ByteData.sublistView(body);
  if ((body[offset + 4] & 0x80) != 0) {
    if (offset + 10 > body.length) return null;
    return HeapRef(kind: HeapRefKind.fromRaw(raw), targetOid: view.getUint32(offset + 6), length: 10);
  }
  return HeapRef(kind: HeapRefKind.fromRaw(raw), targetOid: view.getUint16(offset + 4), length: 6);
}

/// How much of a span is understood.
enum HeapDecodeTier {
  /// The record's meaning and value are decoded.
  semantic,

  /// The record's shape is known but not its meaning.
  valueKindKnown,

  /// The record is only sized.
  framed,
}

/// A span's tier; [valueKindPayloadBytes] is the part of a semantic span that is only value-kind known.
class HeapTierGrade {
  const HeapTierGrade(this.tier, {this.valueKindPayloadBytes = 0});

  final HeapDecodeTier tier;

  final int valueKindPayloadBytes;
}

/// Object kinds whose cosmetic colours [heapDecodeTier] counts as decoded.
const Set<int> kCosmClassKinds = {0x09, 0x0b, 0x0c};

/// Grades the span at [offset]; [enclosingKind] is the class code of the innermost open object,
/// null when none is open.
HeapTierGrade heapDecodeTier(Uint8List body, int offset, int lead, String sectionTag, {int? enclosingKind}) {
  const semantic = HeapTierGrade(HeapDecodeTier.semantic);
  const valueKindKnown = HeapTierGrade(HeapDecodeTier.valueKindKnown);
  const framed = HeapTierGrade(HeapDecodeTier.framed);
  if (_isObjectHeader(body, offset)) return semantic;
  if (kHeapGroupCloseLeads.contains(lead)) return semantic;
  if (kHeapGroupOpenLeads.contains(lead) && offset + 4 <= body.length && isHeapTypeTag(body[offset + 3])) {
    return semantic;
  }
  if (lead >= 0x14 && lead <= 0x17) {
    if (decodeHeapRef(body, offset) != null) return semantic;
    if (offset + 4 <= body.length && isHeapTypeTag(body[offset + 3])) return valueKindKnown;
  }
  if (lead == kHeapRecordPrefix) {
    final rec = c4FrameAt(body, offset, sectionTag);
    if (rec == null) return framed;
    if (rec.kind.isDecoded) return semantic;
    return valueKindKnown;
  }
  final attr = decodeHeapAttr(body, offset);
  if (attr != null) {
    if (attr.width == HeapAttrWidth.container) {
      if (attr.attribute.confidence == AttrConfidence.kindOnly) return valueKindKnown;
      final headerLen = body[offset] == 0xc6 && body[offset + 2] == 0xff ? 5 : 3;
      return HeapTierGrade(HeapDecodeTier.semantic, valueKindPayloadBytes: attr.length - headerLen);
    }
    if (attr.attribute == HeapAttribute.unknown) return valueKindKnown;
    if (attr.attribute.confidence == AttrConfidence.kindOnly) return valueKindKnown;
    if (attr.attribute.kind == HeapAttrKind.color) {
      if (attr.width != HeapAttrWidth.rgb && attr.width != HeapAttrWidth.f64) {
        return valueKindKnown;
      }
      if ((attr.rawTag == 0x020 || attr.rawTag == 0x021) && !kCosmClassKinds.contains(enclosingKind)) {
        return valueKindKnown;
      }
    }
    return semantic;
  }
  final pv = decodeHeapPropertyToken(body, offset);
  if (pv != null) {
    return pv.token.confidence == AttrConfidence.kindOnly ? valueKindKnown : semantic;
  }
  if (lead >> 4 == 1 && recordSkip(body, offset) == 2) return valueKindKnown;
  return framed;
}

/// Bytes of a heap body per tier, with the walk that framed them.
class HeapTierTotals {
  const HeapTierTotals({required this.walk, required this.semanticBytes, required this.valueKindBytes});

  final HeapWalk walk;

  final int semanticBytes;

  final int valueKindBytes;
}

/// Walks [body] and totals the bytes per [HeapDecodeTier].
HeapTierTotals measureHeapTiers(Uint8List body, String sectionTag) {
  final walk = walkHeapBody(body);
  final length = body.length;
  var semantic = 0, valueKind = 0;
  final enclosingBeforeOpen = <int?>[];
  int? innermost;

  for (final span in walk.spans) {
    final offset = span.offset;
    final lead = span.lead;
    final header = heapObjectHeaderAt(body, offset);
    if (header != null) {
      enclosingBeforeOpen.add(innermost);
      innermost = header.kind;
      semantic += span.length;
      continue;
    }
    if (kHeapGroupOpenLeads.contains(lead) && offset + 4 <= length && isHeapTypeTag(body[offset + 3])) {
      enclosingBeforeOpen.add(innermost);
      semantic += span.length;
      continue;
    }
    if (kHeapGroupCloseLeads.contains(lead)) {
      if (enclosingBeforeOpen.isNotEmpty) innermost = enclosingBeforeOpen.removeLast();
      semantic += span.length;
      continue;
    }
    final grade = heapDecodeTier(body, offset, lead, sectionTag, enclosingKind: innermost);
    switch (grade.tier) {
      case HeapDecodeTier.semantic:
        semantic += span.length - grade.valueKindPayloadBytes;
        valueKind += grade.valueKindPayloadBytes;
      case HeapDecodeTier.valueKindKnown:
        valueKind += span.length;
      case HeapDecodeTier.framed:
        break;
    }
  }
  return HeapTierTotals(walk: walk, semanticBytes: semantic, valueKindBytes: valueKind);
}

/// Record header: `byte0 = sizeSpec(3b)<<5 | hasAttrList(1b)<<4 | scope(2b)<<2 | tagHi(2b)`, `byte1 = tagLo`.
/// Scope 0 opens, 1 is a leaf, 2 closes; sizeSpec 0 = no value (false), 1–4 = that many value bytes,
/// 6 = `u8` length prefix with the `FF` → `u16` escape, 7 = no value (true).
int? recordSkip(Uint8List heapBytes, int offset) {
  final length = heapBytes.length;
  if (offset >= length) return null;
  final op = heapBytes[offset];
  switch (op) {
    case 0xc4:
      if (offset + 3 > length) return null;
      final lenByte = heapBytes[offset + 2];
      if (lenByte == 0xff) {
        if (offset + 5 > length) return null;
        return 5 + ByteData.sublistView(heapBytes).getUint16(offset + 3);
      }
      return 3 + lenByte;
    case 0x14:
      return (offset + 4 <= length &&
              heapBytes[offset + 2] == 1 &&
              (heapBytes[offset + 3] == 0xfd || heapBytes[offset + 3] == 0xfe))
          ? _typedList(heapBytes, offset)
          : null;
    case 0x08:
    case 0x09:
    case 0x04:
      return 2;
    case 0x02:
      return (offset + 2 <= length && heapBytes[offset + 1] == 0xfe) ? 7 : null;
    case 0xc6:
      if (offset + 3 <= length && heapBytes[offset + 2] == 0xff) {
        return (offset + 5 <= length) ? 5 + ByteData.sublistView(heapBytes).getUint16(offset + 3) : null;
      }
  }
  final lo = op & 0x0f;
  if ((lo == 4 || lo == 5 || lo == 6) && op >> 4 != 0) {
    if (op >> 4 == 0xc) return (offset + 3 <= length) ? 3 + heapBytes[offset + 2] : null;
    final valueBytes = _attrNibbleValueBytes[op >> 4];
    if (valueBytes != null) return 2 + valueBytes;
  }
  final hi = op >> 4;
  if (hi == 0 || hi == 1) {
    return (offset + 4 <= length && isHeapTypeTag(heapBytes[offset + 3])) ? _typedList(heapBytes, offset) : 2;
  }
  return null;
}

int? _typedList(Uint8List heapBytes, int offset) {
  final length = heapBytes.length;
  if (offset + 4 > length) return null;
  final count = heapBytes[offset + 2];
  final tag = heapBytes[offset + 3];
  if (tag == 0xfb) {
    final end = offset + 4 + 2 * count;
    return end <= length ? end - offset : null;
  }
  if (tag == 0xfe || tag == 0xfd) {
    var pos = offset + 3;
    for (var itemIndex = 0; itemIndex < count; itemIndex++) {
      final isEscape = pos + 1 < length && heapBytes[pos] == 0xfd && (heapBytes[pos + 1] & 0x80) != 0;
      final step = isEscape ? 7 : 3;
      if (pos + step > length) return null;
      pos += step;
    }
    return pos - offset;
  }
  return null;
}

/// Frames [body] into spans from offset 4, stopping at the first byte [recordSkip] cannot size.
HeapWalk walkHeapBody(Uint8List body) {
  final spans = <HeapSpan>[];
  final length = body.length;
  if (length < 4) return HeapWalk(spans: spans, coveredBytes: 0, bodyBytes: 0);
  final bodyBytes = length - 4;
  var i = 4;
  var covered = 0;
  while (i < length) {
    final step = recordSkip(body, i);
    if (step == null || i + step > length) {
      return HeapWalk(
        spans: spans,
        coveredBytes: covered,
        bodyBytes: bodyBytes,
        stoppedAtOffset: i,
        stoppedLead: body[i],
      );
    }
    spans.add(HeapSpan(offset: i, length: step, lead: body[i]));
    covered += step;
    i += step;
  }
  return HeapWalk(spans: spans, coveredBytes: covered, bodyBytes: bodyBytes);
}

/// Replays a heap body as an object tree: [onObjectOpen] returns the scope for each object
/// header, groups push a null scope, and [onRecord] sees every other span with the innermost scope.
void walkHeapObjects<T extends Object>(
  Uint8List body, {
  required T Function(HeapSpan span, int kind, int oid, T? parent) onObjectOpen,
  void Function(HeapSpan span, T? enclosing)? onRecord,
  void Function(int groupTag, T? enclosing)? onGroupOpen,
  void Function(int groupTag, T? enclosing)? onGroupClose,
}) {
  final stack = <T?>[];
  final groupTags = <int?>[];
  T? innermost() => stack.lastWhere((scope) => scope != null, orElse: () => null);
  final length = body.length;
  for (final span in walkHeapBody(body).spans) {
    final offset = span.offset;
    final lead = span.lead;
    final header = heapObjectHeaderAt(body, offset);
    if (header != null) {
      stack.add(onObjectOpen(span, header.kind, header.oid, innermost()));
      groupTags.add(null);
      continue;
    }
    if (kHeapGroupOpenLeads.contains(lead) && offset + 4 <= length && isHeapTypeTag(body[offset + 3])) {
      stack.add(null);
      groupTags.add(body[offset + 1]);
      onGroupOpen?.call(body[offset + 1], innermost());
      continue;
    }
    if (kHeapGroupCloseLeads.contains(lead)) {
      if (stack.isNotEmpty) {
        stack.removeLast();
        if (groupTags.removeLast() case final closedTag?) onGroupClose?.call(closedTag, innermost());
      }
      continue;
    }
    onRecord?.call(span, innermost());
  }
}

/// C4 record count per opcode across every section of a VI.
Map<int, int> heapOpcodeHistogram(Uint8List viBytes) {
  final hist = <int, int>{};
  for (final record in heapC4Records(viBytes)) {
    hist[record.opcode] = (hist[record.opcode] ?? 0) + 1;
  }
  return hist;
}
