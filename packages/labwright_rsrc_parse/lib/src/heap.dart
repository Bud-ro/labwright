import 'dart:typed_data';

import 'decode.dart';

const int kHeapRecordPrefix = 0xc4;

const Set<String> kHeapSectionTags = {'BDHb', 'BDHP', 'FPHb', 'FPHP', 'DTHP'};

const Set<int> kHeapObjectHeaderLeads = {0x10, 0x11, 0x12};

const Set<int> kHeapGroupOpenLeads = {0x10, 0x11, 0x12, 0x13};

const Set<int> kHeapGroupCloseLeads = {0x08, 0x09, 0x0a, 0x0b};

bool isHeapTypeTag(int tagByte) => tagByte == 0xfb || tagByte == 0xfe || tagByte == 0xfd;

enum HeapOpcode {
  bounds(0x2d, HeapShape.rectangle, isDecoded: true),

  size(0x1f, HeapShape.rectangle, isDecoded: true),

  stringTable(0x2e, HeapShape.stringTable, isDecoded: true),

  caption(0x22, HeapShape.string, isDecoded: true),

  plotName(0x27, HeapShape.string, isDecoded: true),

  formatString(0x74, HeapShape.string, isDecoded: true),

  itemLabel(0x20, HeapShape.string, isDecoded: true),

  symbolName(0xc4, HeapShape.string, isDecoded: true),

  methodName(0xb6, HeapShape.string, isDecoded: true),

  description(0x19, HeapShape.helpText, isDecoded: true),

  path(0xa4, HeapShape.path, isDecoded: true),

  typeBounds(0x4a, HeapShape.rectangle, isDecoded: true),

  container44(0x44, HeapShape.container),

  container64(0x64, HeapShape.container),

  container24(0x24, HeapShape.container),

  docBounds(0x5f, HeapShape.rectangle, isDecoded: true),

  dBounds(0x4c, HeapShape.rectangle, isDecoded: true),

  pBounds(0xd6, HeapShape.rectangle, isDecoded: true),

  dynBounds(0x62, HeapShape.rectangle, isDecoded: true),

  rect26(0x26, HeapShape.rectangle),

  rect23(0x23, HeapShape.rectangle),

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

enum HeapShape {
  rectangle,

  string,

  stringTable,

  helpText,

  path,

  container,

  none,
}

enum HeapAttrKind {
  color,

  coordinate,

  size,

  enumValue,

  flag,

  ordinal,

  numeric,

  controlParam,

  text,

  stringBlob,

  rectangle,

  point,

  container,

  unknown,
}

enum HeapAttrWidth {
  u8,

  u16,

  u24,

  rgb,

  flag,

  f64,

  blob,

  rect,

  container,
}

enum AttrConfidence {
  confirmed,

  inferred,

  kindOnly,
}

enum HeapAttribute {
  relativeOffset(0x01f, HeapAttrKind.coordinate, 'relativeOffset', AttrConfidence.inferred),

  coordX(0x000, HeapAttrKind.coordinate, 'coordX', AttrConfidence.inferred),
  coordY(0x001, HeapAttrKind.coordinate, 'coordY', AttrConfidence.inferred),

  arrayElemValue(0x019, HeapAttrKind.numeric, 'arrayElementValue', AttrConfidence.confirmed),

  partRole(0x0df, HeapAttrKind.enumValue, 'partRole', AttrConfidence.inferred),

  masterPart(0x0af, HeapAttrKind.enumValue, 'masterPart', AttrConfidence.inferred),

  typeDescIndex(0x13a, HeapAttrKind.ordinal, 'typeDescIndex', AttrConfidence.inferred),

  clumpNum(0x03a, HeapAttrKind.ordinal, 'clumpNum', AttrConfidence.inferred),

  howGrow(0x089, HeapAttrKind.numeric, 'howGrow', AttrConfidence.inferred),

  sizeExtent(0x0f8, HeapAttrKind.size, 'sizeExtent', AttrConfidence.inferred),

  termBounds(0x129, HeapAttrKind.rectangle, 'termBounds', AttrConfidence.inferred),

  color29(0x029, HeapAttrKind.numeric, 'value29', AttrConfidence.kindOnly),

  paramIdx(0x0dc, HeapAttrKind.ordinal, 'paramIdx', AttrConfidence.confirmed),

  propItemName(0x231, HeapAttrKind.stringBlob, 'propItemName', AttrConfidence.confirmed),

  constValue(0x26c, HeapAttrKind.stringBlob, 'constValue', AttrConfidence.inferred),

  totalBounds(0x163, HeapAttrKind.rectangle, 'totalBounds', AttrConfidence.inferred),
  srcRect(0x164, HeapAttrKind.rectangle, 'srcRect', AttrConfidence.inferred),

  compressedWireTable(0x1e7, HeapAttrKind.numeric, 'compressedWireTable', AttrConfidence.inferred),

  lastSignalKind(0x09f, HeapAttrKind.numeric, 'lastSignalKind', AttrConfidence.inferred),

  signalState(0x115, HeapAttrKind.numeric, 'signalState', AttrConfidence.inferred),

  dsw(0x061, HeapAttrKind.numeric, 'dsw', AttrConfidence.inferred),

  shortCount(0x106, HeapAttrKind.numeric, 'shortCount', AttrConfidence.inferred),

  mouseWheelSupport(0x286, HeapAttrKind.enumValue, 'mouseWheelSupport', AttrConfidence.inferred),

  firstNodeIdx(0x072, HeapAttrKind.ordinal, 'firstNodeIdx', AttrConfidence.inferred),

  annexDDOFlag(0x17b, HeapAttrKind.numeric, 'annexDDOFlag', AttrConfidence.inferred),

  elementI(0x08a, HeapAttrKind.ordinal, 'i', AttrConfidence.inferred),

  connectorTM(0x048, HeapAttrKind.numeric, 'connectorTM', AttrConfidence.inferred),

  field23(0x023, HeapAttrKind.numeric, 'field23', AttrConfidence.kindOnly),

  primResID(0x0ea, HeapAttrKind.numeric, 'primResID', AttrConfidence.inferred),

  primIndex(0x0e9, HeapAttrKind.numeric, 'primIndex', AttrConfidence.inferred),

  parmIndex(0x0de, HeapAttrKind.ordinal, 'parmIndex', AttrConfidence.inferred),

  objFlags(0x0cb, HeapAttrKind.numeric, 'objFlags', AttrConfidence.inferred),

  packedPair(0x05e, HeapAttrKind.numeric, 'packedPairOrId', AttrConfidence.inferred),

  paneFlags(0x0da, HeapAttrKind.numeric, 'paneFlags', AttrConfidence.inferred),

  backgroundColor(0x028, HeapAttrKind.color, 'backgroundColor', AttrConfidence.confirmed),

  contentColor(0x024, HeapAttrKind.color, 'contentColor', AttrConfidence.confirmed),

  fgColor(0x06f, HeapAttrKind.color, 'fgColor', AttrConfidence.confirmed),

  cosmFgColor(0x020, HeapAttrKind.color, 'cosmFgColor', AttrConfidence.inferred),

  cosmColorB(0x021, HeapAttrKind.color, 'cosmColorB', AttrConfidence.inferred),

  plotColor(0x02a, HeapAttrKind.color, 'plotColor', AttrConfidence.inferred),

  borderColor(0x02b, HeapAttrKind.color, 'borderColor', AttrConfidence.inferred),

  origin(0x0d0, HeapAttrKind.point, 'origin', AttrConfidence.inferred),

  minPaneSize(0x0b7, HeapAttrKind.point, 'minPaneSize', AttrConfidence.inferred),

  shortText(0x022, HeapAttrKind.text, 'shortText', AttrConfidence.inferred),

  formatStyle(0x074, HeapAttrKind.text, 'formatStyle', AttrConfidence.inferred),

  termListLength(0x158, HeapAttrKind.ordinal, 'termListLength', AttrConfidence.confirmed),

  conNum(0x044, HeapAttrKind.ordinal, 'conNum', AttrConfidence.inferred),

  reservedFlag(0x059, HeapAttrKind.flag, 'reservedFlag', AttrConfidence.inferred),

  flag5A(0x05a, HeapAttrKind.flag, 'flag5A', AttrConfidence.inferred),

  defaultData(0x25a, HeapAttrKind.numeric, 'defaultData', AttrConfidence.inferred),

  scaleDMin(0x1f5, HeapAttrKind.controlParam, 'scaleDMin', AttrConfidence.inferred),
  scaleDMax(0x1f6, HeapAttrKind.controlParam, 'scaleDMax', AttrConfidence.inferred),
  scaleDStart(0x1f7, HeapAttrKind.controlParam, 'scaleDStart', AttrConfidence.inferred),
  scaleDIncr(0x1f8, HeapAttrKind.controlParam, 'scaleDIncr', AttrConfidence.inferred),
  scaleDMinInc(0x1f9, HeapAttrKind.controlParam, 'scaleDMinInc', AttrConfidence.confirmed),
  scaleDMultiplier(0x1fa, HeapAttrKind.controlParam, 'scaleDMultiplier', AttrConfidence.confirmed),

  stdNumMin(0x220, HeapAttrKind.controlParam, 'stdNumMin', AttrConfidence.inferred),
  stdNumMax(0x221, HeapAttrKind.controlParam, 'stdNumMax', AttrConfidence.inferred),
  stdNumInc(0x222, HeapAttrKind.controlParam, 'stdNumInc', AttrConfidence.inferred),

  tableFlags(0x120, HeapAttrKind.numeric, 'tableFlags', AttrConfidence.inferred),

  stamp(0x114, HeapAttrKind.numeric, 'stamp', AttrConfidence.confirmed),

  nodeName(0x0c4, HeapAttrKind.text, 'nodeName', AttrConfidence.inferred),

  oMId(0x0c9, HeapAttrKind.numeric, 'oMId', AttrConfidence.inferred),

  omidTypeDesc(0x0ce, HeapAttrKind.ordinal, 'omidTypeDesc', AttrConfidence.inferred),

  dataTypeDesc(0x15b, HeapAttrKind.ordinal, 'dataTypeDesc', AttrConfidence.inferred),

  propItemCode(0x232, HeapAttrKind.numeric, 'propItemCode', AttrConfidence.inferred),

  conId(0x043, HeapAttrKind.numeric, 'conId', AttrConfidence.inferred),

  dIdx(0x04d, HeapAttrKind.ordinal, 'dIdx', AttrConfidence.inferred),

  dcoFiller(0x051, HeapAttrKind.numeric, 'dcoFiller', AttrConfidence.kindOnly),

  index90(0x090, HeapAttrKind.ordinal, 'index', AttrConfidence.inferred),

  inplace(0x097, HeapAttrKind.numeric, 'inplace', AttrConfidence.inferred),

  instrStyle(0x09a, HeapAttrKind.numeric, 'instrStyle', AttrConfidence.inferred),

  nVisItems(0x0c0, HeapAttrKind.numeric, 'nVisItems', AttrConfidence.inferred),

  nRC(0x0bf, HeapAttrKind.point, 'nRC', AttrConfidence.inferred),
  oRC(0x0ca, HeapAttrKind.point, 'oRC', AttrConfidence.inferred),

  termBMPs(0x128, HeapAttrKind.enumValue, 'termBMPs', AttrConfidence.inferred),

  tdOffset(0x127, HeapAttrKind.numeric, 'tdOffset', AttrConfidence.kindOnly),

  textRecField(0x12d, HeapAttrKind.numeric, 'textRecField', AttrConfidence.inferred),

  maxWordLength(0x1c0, HeapAttrKind.numeric, 'maxWordLength', AttrConfidence.inferred),
  fxpOverride(0x1c1, HeapAttrKind.numeric, 'override', AttrConfidence.inferred),
  fxpOverflow(0x1c2, HeapAttrKind.numeric, 'overflow', AttrConfidence.inferred),
  fxpQuantize(0x1c3, HeapAttrKind.numeric, 'quantize', AttrConfidence.inferred),

  paramTableOffset(0x0dd, HeapAttrKind.numeric, 'paramTableOffset', AttrConfidence.inferred),

  selectDefaultCase(0x254, HeapAttrKind.enumValue, 'selectDefaultCase', AttrConfidence.inferred),
  selectNRightType(0x255, HeapAttrKind.enumValue, 'selectNRightType', AttrConfidence.inferred),
  selectSelLabFlags(0x266, HeapAttrKind.numeric, 'selectSelLabFlags', AttrConfidence.inferred),

  parForIndexDistribution(0x25c, HeapAttrKind.numeric, 'parForIndexDistribution', AttrConfidence.inferred),
  debuggingEnabled(0x271, HeapAttrKind.flag, 'debuggingEnabled', AttrConfidence.inferred),
  outputInstanceNumberFromP(0x277, HeapAttrKind.flag, 'outputInstanceNumberFromP', AttrConfidence.inferred),

  defaultTunnelType(0x27f, HeapAttrKind.enumValue, 'defaultTunnelType', AttrConfidence.inferred),

  fpgaImplementation(0x280, HeapAttrKind.flag, 'fpgaImplementation', AttrConfidence.inferred),
  fpgaEnableBoundsMux(0x291, HeapAttrKind.flag, 'fpgaEnableBoundsMux', AttrConfidence.inferred),

  defaultValueMatchesCtlVI(0x28f, HeapAttrKind.flag, 'defaultValueMatchesCtlVI', AttrConfidence.inferred),

  cellPosCol(0x1b3, HeapAttrKind.ordinal, 'cellPosCol', AttrConfidence.inferred),

  savedSize(0x275, HeapAttrKind.rectangle, 'savedSize', AttrConfidence.inferred),

  refListLength(0x159, HeapAttrKind.ordinal, 'refListLength', AttrConfidence.inferred),
  hGrowNodeListLength(0x15a, HeapAttrKind.ordinal, 'hGrowNodeListLength', AttrConfidence.inferred),

  minButSize(0x25e, HeapAttrKind.point, 'minButSize', AttrConfidence.inferred),

  termHotPoint(0x12a, HeapAttrKind.point, 'termHotPoint', AttrConfidence.inferred),

  tunnelType(0x27e, HeapAttrKind.enumValue, 'tunnelType', AttrConfidence.inferred),

  parForNumStaticWorkers(0x263, HeapAttrKind.numeric, 'parForNumStaticWorkers', AttrConfidence.inferred),

  winFlags(0x144, HeapAttrKind.numeric, 'winFlags', AttrConfidence.inferred),

  structColor(0x119, HeapAttrKind.color, 'structColor', AttrConfidence.inferred),

  partOrder(0x0e0, HeapAttrKind.ordinal, 'partOrder', AttrConfidence.inferred),

  preferredInstIndex(0x0e8, HeapAttrKind.ordinal, 'preferredInstIndex', AttrConfidence.inferred),

  cellPosRow(0x1b2, HeapAttrKind.ordinal, 'cellPosRow', AttrConfidence.inferred),

  itemFlags(0x1b8, HeapAttrKind.numeric, 'flags', AttrConfidence.inferred),

  stateData(0x25d, HeapAttrKind.numeric, 'stateData', AttrConfidence.inferred),

  bufValue(0x02e, HeapAttrKind.numeric, 'bufValue', AttrConfidence.kindOnly),

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

  final int id;

  final int rawTag;

  final HeapAttrWidth width;

  final Object value;

  final int length;

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

List<HeapRecord> heapC4Records(Uint8List viBytes) => heapC4RecordsFromDecoded(decodeSections(viBytes));

List<HeapRecord> heapC4RecordsFromDecoded(Iterable<DecodedSection> decoded) => [
  for (final decodedSection in decoded) ...scanC4Records(decodedSection.bytes, decodedSection.tag),
];

class HeapSpan {
  const HeapSpan({required this.offset, required this.length, required this.lead});

  final int offset;

  final int length;

  final int lead;

  bool get isC4Record => lead == kHeapRecordPrefix;
}

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

  final int? stoppedAtOffset;

  final int? stoppedLead;

  double get coverage => bodyBytes <= 0 ? 1.0 : coveredBytes / bodyBytes;

  bool get complete => stoppedAtOffset == null;
}

enum PropTokenForm {
  taggedList,

  selector,
}

enum HeapPropertyToken {
  smallValueProperty(0x10, 0x19, PropTokenForm.taggedList, 'smallValueProperty', AttrConfidence.kindOnly),

  textAppearanceFlag(0x10, 0x8d, PropTokenForm.taggedList, 'textAppearanceFlag', AttrConfidence.inferred),

  terminalClusterRole(0x10, 0x22, PropTokenForm.taggedList, 'terminalClusterRole', AttrConfidence.inferred),

  textElementPresent(0x11, 0x2d, PropTokenForm.taggedList, 'textElementPresent', AttrConfidence.inferred),

  subPartShapeCount(0x11, 0x1f, PropTokenForm.taggedList, 'subPartShapeCount', AttrConfidence.inferred),

  controlStyleCount(0x10, 0xe1, PropTokenForm.taggedList, 'controlStyleCount', AttrConfidence.inferred),

  tipStripEnabled(0x11, 0x18, PropTokenForm.taggedList, 'tipStripEnabled', AttrConfidence.inferred),

  textStyleRuns(0x10, 0x25, PropTokenForm.taggedList, 'textStyleRuns', AttrConfidence.confirmed),

  structureChildReflist(0x10, 0x55, PropTokenForm.taggedList, 'structureChildReflist', AttrConfidence.confirmed),

  diagramFrameStyle(0x11, 0x4e, PropTokenForm.taggedList, 'diagramFrameStyle', AttrConfidence.kindOnly),

  enumRingProperty(0x11, 0xeb, PropTokenForm.taggedList, 'enumRingProperty', AttrConfidence.inferred),

  enumRingCount(0x11, 0xea, PropTokenForm.taggedList, 'enumRingCount', AttrConfidence.inferred),

  diagramProperty(0x10, 0x49, PropTokenForm.taggedList, 'diagramProperty', AttrConfidence.kindOnly),

  caseSeqParamA(0x12, 0x15, PropTokenForm.taggedList, 'caseSeqParamA', AttrConfidence.inferred),

  caseSeqParamB(0x12, 0x16, PropTokenForm.taggedList, 'caseSeqParamB', AttrConfidence.inferred),

  caseSeqParamC(0x12, 0x17, PropTokenForm.taggedList, 'caseSeqParamC', AttrConfidence.inferred),

  decorationProperty(0x12, 0x05, PropTokenForm.taggedList, 'decorationProperty', AttrConfidence.kindOnly),

  viewportSlot1(0x11, 0x10, PropTokenForm.selector, 'viewportSlot1', AttrConfidence.confirmed),

  viewportSlot2(0x11, 0x14, PropTokenForm.selector, 'viewportSlot2', AttrConfidence.inferred),

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

enum HeapGroupTag {
  fontRunList(0x25),

  fontRun(0x19),

  arrayIndex(0x15),

  selectorRangeList(0x56),

  selectorRangeListAlt(0x57),

  selectorRange(0x19),

  selectorStringPool(0x58)
  ;

  const HeapGroupTag(this.tag);

  final int tag;
}

/// TODO: raw tag `0x029` inside a font run is not decoded.
enum FontRunAttr {
  start(0x027),

  fontId(0x028)
  ;

  const FontRunAttr(this.raw);

  final int raw;
}

enum SelectorRangeAttr {
  low(0x01f),

  high(0x020),

  lowBound(0x021),

  highBound(0x022),

  frame(0x023)
  ;

  const SelectorRangeAttr(this.raw);

  final int raw;
}

bool isTypeDescriptorToken(int op) => op == 0x04;

bool _isObjectHeader(Uint8List body, int offset) =>
    offset + 9 <= body.length &&
    kHeapObjectHeaderLeads.contains(body[offset]) &&
    body[offset + 2] == 0x02 &&
    body[offset + 3] == 0xfe &&
    body[offset + 6] == 0xfd;

({int kind, int oid, int length})? heapObjectHeaderAt(Uint8List body, int offset) {
  if (!_isObjectHeader(body, offset)) return null;
  final view = ByteData.sublistView(body);
  final kind = view.getUint16(offset + 4);
  if ((body[offset + 7] & 0x80) != 0 && offset + 13 <= body.length) {
    return (kind: kind, oid: view.getUint32(offset + 9), length: 13);
  }
  return (kind: kind, oid: view.getUint16(offset + 7), length: 9);
}

class HeapPropertyValue {
  const HeapPropertyValue({required this.token, required this.value, required this.length});

  final HeapPropertyToken token;

  final int? value;

  final int length;
}

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

enum HeapRefKind {
  childRef(0x019, 'childRef', AttrConfidence.confirmed),

  dcoRef(0x04f, 'dcoRef', AttrConfidence.inferred),

  ownerRef(0x01f, 'ownerRef', AttrConfidence.confirmed),

  dcoAggRef(0x050, 'dcoAggRef', AttrConfidence.inferred),

  ddoRef(0x053, 'ddoRef', AttrConfidence.inferred),

  srcDCORef(0x113, 'srcDCORef', AttrConfidence.inferred),

  loopLimitDCORef(0x1bd, 'loopLimitDCORef', AttrConfidence.inferred),

  dataValRefDCORef(0x1d0, 'dataValRefDCORef', AttrConfidence.inferred),

  tunnelLinkRef(0x1e2, 'tunnelLinkRef', AttrConfidence.inferred),

  poserRef(0x1cf, 'poserRef', AttrConfidence.inferred),

  attachmentRef(0x28a, 'attachmentRef', AttrConfidence.inferred),

  attachedObjectRef(0x289, 'attachedObjectRef', AttrConfidence.inferred),

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

class HeapRef {
  const HeapRef({required this.kind, required this.targetOid, required this.length});

  final HeapRefKind kind;

  final int targetOid;

  final int length;
}

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

enum HeapDecodeTier {
  semantic,

  valueKindKnown,

  framed,
}

class HeapTierGrade {
  const HeapTierGrade(this.tier, {this.valueKindPayloadBytes = 0});

  final HeapDecodeTier tier;

  final int valueKindPayloadBytes;
}

const Set<int> kCosmClassKinds = {0x09, 0x0b, 0x0c};

HeapTierGrade heapDecodeTier(Uint8List body, int offset, int lead, String sectionTag, {int enclosingKind = -1}) {
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

class HeapTierTotals {
  const HeapTierTotals({required this.walk, required this.semanticBytes, required this.valueKindBytes});

  final HeapWalk walk;

  final int semanticBytes;

  final int valueKindBytes;
}

HeapTierTotals measureHeapTiers(Uint8List body, String sectionTag) {
  final walk = walkHeapBody(body);
  final length = body.length;
  var semantic = 0, valueKind = 0;
  final enclosingBeforeOpen = <int>[];
  var innermost = -1;

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

void walkHeapObjects<T extends Object>(
  Uint8List body, {
  required T Function(HeapSpan span, int kind, int oid, T? parent) onObjectOpen,
  void Function(HeapSpan span, T? enclosing)? onRecord,
  void Function(int groupTag, T? enclosing)? onGroupOpen,
  void Function(int groupTag, T? enclosing)? onGroupClose,
}) {
  final stack = <T?>[];
  final groupTags = <int>[];
  T? innermost() => stack.lastWhere((scope) => scope != null, orElse: () => null);
  final length = body.length;
  for (final span in walkHeapBody(body).spans) {
    final offset = span.offset;
    final lead = span.lead;
    final header = heapObjectHeaderAt(body, offset);
    if (header != null) {
      stack.add(onObjectOpen(span, header.kind, header.oid, innermost()));
      groupTags.add(-1);
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
        final closedTag = groupTags.removeLast();
        if (closedTag >= 0) onGroupClose?.call(closedTag, innermost());
      }
      continue;
    }
    onRecord?.call(span, innermost());
  }
}

Map<int, int> heapOpcodeHistogram(Uint8List viBytes) {
  final hist = <int, int>{};
  for (final record in heapC4Records(viBytes)) {
    hist[record.opcode] = (hist[record.opcode] ?? 0) + 1;
  }
  return hist;
}
