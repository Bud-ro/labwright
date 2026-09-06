import 'dart:typed_data';

import 'version_word.dart';

class ViLinkInfo {
  const ViLinkInfo({
    required this.version,
    required this.rootKind,
    required this.entryCount,
    required this.linkedNames,
    required this.pathCount,
  });

  final int version;

  final String rootKind;

  final int entryCount;

  final List<String> linkedNames;

  final int pathCount;

  bool get isEmpty => entryCount == 0 && linkedNames.isEmpty;
}

ViLinkInfo? decodeLinkInfo(Uint8List bytes) {
  if (bytes.length < 12) return null;
  final view = ByteData.sublistView(bytes);
  final version = view.getUint16(0);
  final rootKind = String.fromCharCodes(bytes.sublist(2, 6));
  final entryCount = view.getUint32(6);

  final linkedNames = <String>[];
  var pathCount = 0;
  for (var pos = 10; pos < bytes.length - 4; pos++) {
    if (bytes[pos] == 0x50 && bytes[pos + 1] == 0x54 && bytes[pos + 2] == 0x48 && bytes[pos + 3] == 0x30) {
      pathCount++;
      pos += 3;
      continue;
    }
    final len = bytes[pos];
    if (len < 4 || len > 120 || pos + 1 + len > bytes.length) continue;
    var printable = true;
    for (var i = pos + 1; i <= pos + len; i++) {
      final byte = bytes[i];
      if (byte < 0x20 || byte >= 0x7f) {
        printable = false;
        break;
      }
    }
    if (!printable) continue;
    final text = String.fromCharCodes(bytes.sublist(pos + 1, pos + 1 + len));
    if (RegExp(r'\.(vi|vim|vit|ctl|ctt|lvclass|lvlib|llb)$', caseSensitive: false).hasMatch(text)) {
      if (!linkedNames.contains(text)) linkedNames.add(text);
      pos += len;
    }
  }
  return ViLinkInfo(
    version: version,
    rootKind: rootKind,
    entryCount: entryCount,
    linkedNames: linkedNames,
    pathCount: pathCount,
  );
}

class ViLinkInfoRaw {
  const ViLinkInfoRaw({
    required this.version,
    required this.rootKind,
    required this.entryCount,
    required this.entryRegion,
    required this.terminator,
    required this.tiled,
  });

  final int version;

  final String rootKind;

  final int entryCount;

  final Uint8List entryRegion;

  final int terminator;

  final bool tiled;

  Uint8List serialize() {
    final out = Uint8List(12 + entryRegion.length);
    final view = ByteData.sublistView(out);
    view.setUint16(0, version);
    out.setRange(2, 6, rootKind.codeUnits);
    view.setUint32(6, entryCount);
    out.setRange(10, 10 + entryRegion.length, entryRegion);
    view.setUint16(10 + entryRegion.length, terminator);
    return out;
  }
}

ViLinkInfoRaw? decodeLinkInfoRaw(Uint8List bytes, {ViVersionWord? version}) {
  if (bytes.length < 12) return null;
  final view = ByteData.sublistView(bytes);
  final entryCount = view.getUint32(6);
  final terminator = view.getUint16(bytes.length - 2);
  return ViLinkInfoRaw(
    version: view.getUint16(0),
    rootKind: String.fromCharCodes(bytes.sublist(2, 6)),
    entryCount: entryCount,
    entryRegion: Uint8List.sublistView(bytes, 10, bytes.length - 2),
    terminator: terminator,
    tiled: terminator == 3 && _tilesLinkInfo(bytes, version),
  );
}

bool _tilesLinkInfo(Uint8List bytes, ViVersionWord? version) {
  final termOff = bytes.length - 2;
  final view = ByteData.sublistView(bytes);
  final u32at6 = view.getUint32(6);

  if (version != null) {
    var pos = 6;
    var ok = true;
    if (version.major < 14) {
      final nameLen = bytes[6];
      pos = 7 + nameLen;
      if ((nameLen + 1).isOdd) pos += 1;
      if (pos + 2 > bytes.length) {
        ok = false;
      } else {
        pos += 2 + 2 * view.getUint16(pos);
      }
    }
    if (ok && pos + 4 <= bytes.length) {
      final countV = view.getUint32(pos);
      if (countV <= 0x10000 && _tilesFrom(bytes, version, countV, pos + 4, termOff)) {
        return true;
      }
    }
  }
  if (u32at6 <= 0x10000 && _tilesFrom(bytes, version, u32at6, 10, termOff)) {
    return true;
  }
  if (bytes[6] != 0) {
    var pos = 7 + bytes[6];
    if (pos % 4 != 0) pos += 4 - (pos % 4);
    pos += 2;
    if (pos + 4 <= bytes.length) {
      final countB = view.getUint32(pos);
      if (countB <= 0x10000 && _tilesFrom(bytes, version, countB, pos + 4, termOff)) {
        return true;
      }
    }
  }
  return false;
}

bool _tilesFrom(Uint8List bytes, ViVersionWord? version, int count, int start, int termOff) {
  if (count <= 1) return start <= termOff;
  if (version == null) return false;
  final c = _LiCursor(bytes, version.major, version.minor, version.patch)..p = start;
  for (var i = 0; i < count; i++) {
    if (c.p + 6 > termOff || c.u16() != 2) return false;
    final kind = c.tag4();
    c.skip(4);
    _liEntry(c, kind);
    if (!c.ok) return false;
  }
  return c.ok && c.p == termOff;
}

class _LiCursor {
  _LiCursor(this.b, this.major, this.minor, this.patch);
  final Uint8List b;
  final int major, minor, patch;
  int p = 0;
  bool ok = true;

  int lastPathLen = -1;

  bool heapPathEmpty = false;

  bool ge(int a, int c, int d) {
    if (major != a) return major > a;
    if (minor != c) return minor > c;
    return patch >= d;
  }

  int u8() {
    if (p + 1 > b.length) {
      ok = false;
      return 0;
    }
    return b[p++];
  }

  int u16() {
    if (p + 2 > b.length) {
      ok = false;
      return 0;
    }
    final v = (b[p] << 8) | b[p + 1];
    p += 2;
    return v;
  }

  int u32() {
    if (p + 4 > b.length) {
      ok = false;
      return 0;
    }
    final v = (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
    p += 4;
    return v;
  }

  void skip(int n) {
    if (n < 0 || p + n > b.length) {
      ok = false;
      return;
    }
    p += n;
  }

  void pad(int align) {
    final m = p % align;
    if (m > 0) skip(align - m);
  }

  String tag4() {
    if (p + 4 > b.length) {
      ok = false;
      return '';
    }
    return String.fromCharCodes(b, p, p + 4);
  }
}

void _liQualName(_LiCursor c) {
  final count = c.u32();
  if (!c.ok || count > 4096) {
    c.ok = false;
    return;
  }
  for (var i = 0; i < count; i++) {
    c.skip(c.u8());
    if (!c.ok) return;
  }
}

void _liPathRef(_LiCursor c) {
  final id = c.tag4();
  if (!c.ok) return;
  if (id != 'PTH0' && id != 'PTH1' && id != 'PTH2') {
    c.ok = false;
    return;
  }
  c.skip(4);
  final len = c.u32();
  c.lastPathLen = len;
  c.skip(len);
}

void _liPStr(_LiCursor c) {
  final n = c.u8();
  c.skip(n);
  if ((n + 1).isOdd) c.skip(1);
}

void _liLStr(_LiCursor c) {
  final n = c.u32();
  if (!c.ok || n > 0x20000000) {
    c.ok = false;
    return;
  }
  c.skip(n);
}

void _liU2p2(_LiCursor c) {
  if ((c.u16() & 0x8000) != 0) c.u16();
}

void _liBasic(_LiCursor c) {
  c.pad(4);
  _liQualName(c);
  if (!c.ok) return;
  c.pad(2);
  _liPathRef(c);
  if (!c.ok) return;
  if (c.ge(8, 6, 0)) {
    c.skip(4);
  } else if (c.ge(8, 5, 0)) {
    c.skip(1);
  }
}

void _liViLinkRef(_LiCursor c) {
  var flagBt = 0xff;
  if (c.ge(14, 0, 0)) flagBt = c.u8();
  if (!c.ok || flagBt != 0xff) return;
  if (c.ge(8, 0, 0)) c.skip(12);
  if (c.ge(6, 0, 0)) c.skip(12);
}

void _liTyped(_LiCursor c) {
  if (!c.ge(8, 0, 0)) {
    c.ok = false;
    return;
  }
  _liBasic(c);
  if (!c.ok) return;
  _liU2p2(c);
  if (!c.ok) return;
  _liViLinkRef(c);
  if (!c.ok) return;
  if (c.ge(12, 0, 0)) c.skip(4);
}

void _liOffList(_LiCursor c) {
  final n = c.u32();
  if (!c.ok || n > 1 << 20) {
    c.ok = false;
    return;
  }
  c.skip(4 * n);
}

void _liOffsetSave(_LiCursor c) {
  _liTyped(c);
  if (!c.ok) return;
  if (c.ge(8, 2, 0)) _liOffList(c);
}

void _liHeapToVi(_LiCursor c) {
  c.heapPathEmpty = false;
  _liOffsetSave(c);
  if (!c.ok) return;
  if (!c.ge(8, 6, 0)) _liOffList(c);
  if (!c.ok) return;
  if (c.ge(8, 2, 0)) {
    _liPathRef(c);
    c.heapPathEmpty = c.lastPathLen == 0;
  }
}

void _liUdApiCache(_LiCursor c) {
  c.pad(4);
  c.skip(c.ge(8, 0, 0) ? 8 : 4);
  if (!c.ge(8, 0, 4)) c.skip(4);
  c.skip(1);
  if (c.ge(8, 1, 0)) c.skip(1);
  if (c.ge(9, 0, 0)) c.skip(1);
  _liLStr(c);
  if (c.major >= 16) {
    final count = c.u32();
    if (!c.ok || count > 4096) {
      c.ok = false;
      return;
    }
    for (var i = 0; i < count; i++) {
      _liQualName(c);
      if (!c.ok) return;
      _liPathRef(c);
      if (!c.ok) return;
      c.skip(1);
    }
    c.skip(1);
  }
  if (c.major >= 20) c.skip(4);
}

void _liUdHeapApi(_LiCursor c) {
  _liBasic(c);
  if (!c.ok) return;
  if (c.ge(8, 0, 3)) _liUdApiCache(c);
  if (!c.ok) return;
  c.pad(4);
  _liOffList(c);
}

void _liUdViApi(_LiCursor c) {
  _liBasic(c);
  if (!c.ok) return;
  _liUdApiCache(c);
}

void _liTrailer(_LiCursor c) {
  if (c.ge(8, 6, 0)) _liOffList(c);
}

void _liBool(_LiCursor c) => c.skip(c.ge(4, 5, 0) ? 1 : 2);

void _liCcSymbol(_LiCursor c) {
  _liLStr(c);
  if (!c.ok) return;
  _liLStr(c);
  if (!c.ok) return;
  _liLStr(c);
  if (!c.ok) return;
  _liBool(c);
}

void _liExtFunc(_LiCursor c) {
  if (c.ge(8, 0, 3)) {
    _liBasic(c);
    if (!c.ok) return;
    _liOffList(c);
    if (!c.ok) return;
    _liPStr(c);
    if (!c.ok) return;
    c.skip(2);
    if (c.ge(11, 0, 3)) _liBool(c);
  } else {
    _liOffsetSave(c);
  }
}

void _liGiSave(_LiCursor c) {
  c.ge(8, 0, 0) ? _liBasic(c) : _liOffsetSave(c);
  if (!c.ok) return;
  c.skip(12);
}

void _liEntry(_LiCursor c, String kind) {
  switch (kind) {
    case 'VILB':
      _liBasic(c);
    case 'IUVI':
      final heapForm = c.ge(8, 2, 0);
      heapForm ? _liHeapToVi(c) : _liOffsetSave(c);
      if (!c.ok) return;
      if (c.ge(8, 0, 0)) _liPStr(c);
      if (!c.ok) return;
      if (heapForm && c.heapPathEmpty) _liOffList(c);
    case 'VIVI':
      _liTyped(c);
      if (!c.ok) return;
      if (c.ge(10, 0, 0) && c.u8() != 0) c.skip(36);
    case 'VICC':
    case 'VIPV':
    case 'VIPR':
    case 'VIAV':
      _liTyped(c);
    case 'BSVR':
      _liTyped(c);
      if (!c.ok) return;
      c.skip(4);
    case 'TDCC':
      _liHeapToVi(c);
      if (!c.ok) return;
      if (c.heapPathEmpty) _liOffList(c);
    case 'PUPV':
    case 'SVVI':
      _liHeapToVi(c);
      if (!c.ok) return;
      if (c.heapPathEmpty) _liOffList(c);
    case 'V2CC':
      _liBasic(c);
      if (!c.ok) return;
      _liCcSymbol(c);
    case 'H2CC':
      _liOffsetSave(c);
      if (!c.ok) return;
      _liOffList(c);
      if (!c.ok) return;
      _liLStr(c);
      if (!c.ok) return;
      _liLStr(c);
      if (!c.ok) return;
      _liBool(c);
    case 'DSDS':
      _liOffsetSave(c);
      if (!c.ok) return;
      if (c.ge(8, 6, 0)) _liOffList(c);
      if (!c.ok) return;
      _liTrailer(c);
    case 'DSSV':
      _liOffsetSave(c);
      if (!c.ok) return;
      if (c.ge(8, 6, 0)) _liOffList(c);
    case 'DSEF':
    case 'NEXF':
      _liExtFunc(c);
    case 'XNXI':
      _liOffsetSave(c);
      if (!c.ok) return;
      if (c.ge(8, 6, 0)) c.skip(12);
    case 'VIXN':
      _liGiSave(c);
    case 'FPPI':
    case 'DDPI':
    case 'VRPI':
    case 'TCPI':
    case 'DyOM':
    case 'PNOM':
    case 'DRPI':
    case 'DOPI':
      _liUdHeapApi(c);
    case 'VIPI':
      _liUdViApi(c);
    default:
      c.ok = false;
  }
}
