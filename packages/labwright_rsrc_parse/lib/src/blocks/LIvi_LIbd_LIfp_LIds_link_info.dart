/// `LIvi` / `LIbd` / `LIfp` / `LIds` — link info for the VI, its block diagram, front panel
/// and data space: the resources it links to, each as an entry whose grammar depends on
/// its four-character kind and on the saving LabVIEW version.
///
/// A VI saved inside a library before LabVIEW 14 puts its own qualified name between the
/// root kind and the entry count. Entries follow with no length of their own, so an entry
/// whose kind the grammar does not know ends the walk: the rest of the region up to the
/// terminator is retained as one [ViLinkEntryUnwalked].
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       2     version                    u16      link-info format version, 1
/// 2       4     rootKind                   4cc      the linking resource: LVIN, BDHP, FPHP or VIDS
/// optional, when saved inside a library before LabVIEW 14:
/// 6       rest  qualifiedName              pstr     the VI's library-qualified name, padded to an
///                                                   even length, then a u16 whose role is TODO
/// …       4     entryCount                 u32      number of entries
/// …       rest  entries                    entry[entryCount] entryCount entries
///   +0    2     version                    u16      entry format version, 2
///   +2    4     kind                       4cc      link kind such as IUVI (sub-VI) or VILB
///                                                   (library)
///   +6    rest  body                       bytes    grammar per kind and saving version
/// …       2     terminator                 u16      always 3, the last two bytes of the payload
/// ```
///
/// [ViLinkInfo] is a view over the payload; [decodeLinkInfo] walks the entries with the
/// grammar of [ViVersionWord] when given one and requires the header and terminator.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import 'vers_version.dart';

const _version = BlockField(0, 2, 'version', 'u16', 'link-info format version, 1');
const _rootKind = BlockField(2, 4, 'rootKind', '4cc', 'the linking resource: LVIN, BDHP, FPHP or VIDS');
const _qualifiedName = BlockField(
  6,
  null,
  'qualifiedName',
  'pstr',
  'the VI\'s library-qualified name, padded to an even length, then a u16 whose role is TODO',
  optional: 'saved inside a library before LabVIEW 14',
);
const _entryCount = BlockField(6, 4, 'entryCount', 'u32', 'number of entries');
const _entryVersion = BlockField(0, 2, 'version', 'u16', 'entry format version, 2');
const _entryKind = BlockField(2, 4, 'kind', '4cc', 'link kind such as IUVI (sub-VI) or VILB (library)');
const _entryBody = BlockField(6, null, 'body', 'bytes', 'grammar per kind and saving version');
const _entries = BlockField(
  10,
  null,
  'entries',
  'entry[entryCount]',
  'entryCount entries',
  entry: [_entryVersion, _entryKind, _entryBody],
);
const _terminator = BlockField(0, 2, 'terminator', 'u16', 'always 3, the last two bytes of the payload');

const BlockLayout linkInfoLayout = [_version, _rootKind, _qualifiedName, _entryCount, _entries, _terminator];

/// One entry of a [ViLinkInfo].
sealed class ViLinkEntry {
  const ViLinkEntry(this.offset, this.end);

  final int offset;

  final int end;
}

/// An entry the grammar walked: [kind] at `offset + 2`, body to [end].
final class ViLinkEntryFramed extends ViLinkEntry {
  const ViLinkEntryFramed(super.offset, super.end, this.kind);

  final String kind;
}

/// The entry region from an entry the grammar cannot walk up to the terminator.
final class ViLinkEntryUnwalked extends ViLinkEntry {
  const ViLinkEntryUnwalked(super.offset, super.end);
}

/// A view over an `LIvi`, `LIbd`, `LIfp` or `LIds` payload.
class ViLinkInfo {
  ViLinkInfo._(this.bytes, this.entriesOffset, this.entries) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  /// Where the entries start: after the count word, itself after the optional qualified name.
  final int entriesOffset;

  final List<ViLinkEntry> entries;

  int get version => _view.getUint16(_version.offset);

  String get rootKind => String.fromCharCodes(bytes, _rootKind.offset, _rootKind.end);

  int get entryCount => _view.getUint32(entriesOffset - 4);

  int get terminator => _view.getUint16(bytes.length - 2);

  bool get isWalked => entries.every((e) => e is ViLinkEntryFramed);

  /// Names ending in a LabVIEW file extension that appear as Pascal strings anywhere in
  /// the entry region, in order of first appearance.
  List<String> get linkedNames {
    final out = <String>[];
    for (var pos = entriesOffset; pos < bytes.length - 4; pos++) {
      final len = bytes[pos];
      if (len < 4 || len > 120 || pos + 1 + len > bytes.length) continue;
      if (!_printable(pos + 1, pos + 1 + len)) continue;
      final text = String.fromCharCodes(bytes, pos + 1, pos + 1 + len);
      if (_linkedFile.hasMatch(text)) {
        if (!out.contains(text)) out.add(text);
        pos += len;
      }
    }
    return out;
  }

  /// `PTH0` path records anywhere in the entry region.
  int get pathCount {
    var n = 0;
    for (var pos = entriesOffset; pos + 4 <= bytes.length; pos++) {
      if (bytes[pos] == 0x50 && bytes[pos + 1] == 0x54 && bytes[pos + 2] == 0x48 && bytes[pos + 3] == 0x30) {
        n++;
        pos += 3;
      }
    }
    return n;
  }

  bool _printable(int start, int end) {
    for (var i = start; i < end; i++) {
      if (bytes[i] < 0x20 || bytes[i] >= 0x7f) return false;
    }
    return true;
  }

  Uint8List serialize() => bytes;
}

final _linkedFile = RegExp(r'\.(vi|vim|vit|ctl|ctt|lvclass|lvlib|llb)$', caseSensitive: false);

ViLinkInfo decodeLinkInfo(Uint8List bytes, {ViVersionWord? version}) {
  assert(bytes.length >= _entries.offset + 2, 'link info holds a header, a count and a terminator');
  final view = ByteData.sublistView(bytes);
  final termOff = bytes.length - 2;
  for (final start in _entriesStarts(bytes, view, version)) {
    final count = view.getUint32(start - 4);
    final entries = _walk(bytes, version, count, start, termOff);
    if (entries != null) return ViLinkInfo._(bytes, start, entries);
  }
  final start = _entries.offset;
  return ViLinkInfo._(bytes, start, [ViLinkEntryUnwalked(start, termOff)]);
}

/// Candidate offsets of the first entry, each preceded by its count word.
Iterable<int> _entriesStarts(Uint8List bytes, ByteData view, ViVersionWord? version) sync* {
  if (version != null && version.major < 14) {
    final nameLen = bytes[_qualifiedName.offset];
    var pos = _qualifiedName.offset + 1 + nameLen;
    if ((nameLen + 1).isOdd) pos += 1;
    if (pos + 6 <= bytes.length) yield pos + 2 + 2 * view.getUint16(pos) + 4;
  }
  yield _entries.offset;
  if (bytes[_qualifiedName.offset] != 0) {
    var pos = _qualifiedName.offset + 1 + bytes[_qualifiedName.offset];
    if (pos % 4 != 0) pos += 4 - pos % 4;
    pos += 2;
    if (pos + 4 <= bytes.length) yield pos + 4;
  }
}

List<ViLinkEntry>? _walk(Uint8List bytes, ViVersionWord? version, int count, int start, int termOff) {
  if (start > termOff || count > 0x10000) return null;
  if (count == 0) return start == termOff ? const [] : null;
  final entries = <ViLinkEntry>[];
  if (version == null) return [ViLinkEntryUnwalked(start, termOff)];
  final c = _LiCursor(bytes, version.major, version.minor, version.patch)..p = start;
  for (var i = 0; i < count; i++) {
    final at = c.p;
    final kind = at + 6 <= termOff && c.u16() == 2 ? c.tag4() : '';
    if (kind.isNotEmpty) {
      c.skip(4);
      _liEntry(c, kind);
    }
    if (kind.isEmpty || !c.ok || c.p > termOff) {
      return entries.isEmpty ? null : (entries..add(ViLinkEntryUnwalked(at, termOff)));
    }
    entries.add(ViLinkEntryFramed(at, c.p, kind));
  }
  if (c.p != termOff) {
    final last = entries.removeLast();
    entries.add(ViLinkEntryUnwalked(last.offset, termOff));
  }
  return entries;
}

class _LiCursor {
  _LiCursor(this.b, this.major, this.minor, this.patch) : view = ByteData.sublistView(b);
  final Uint8List b;
  final ByteData view;
  final int major, minor, patch;
  int p = 0;
  bool ok = true;

  int? lastPathLen;

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
    final v = view.getUint16(p);
    p += 2;
    return v;
  }

  int u32() {
    if (p + 4 > b.length) {
      ok = false;
      return 0;
    }
    final v = view.getUint32(p);
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
  if (c.major >= 20) _liClassChain(c);
}

void _liClassChain(_LiCursor c) {
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
    final ancestors = c.u32();
    if (!c.ok || ancestors > 4096) {
      c.ok = false;
      return;
    }
    for (var j = 0; j < ancestors; j++) {
      _liQualName(c);
      if (!c.ok) return;
      _liPathRef(c);
      if (!c.ok) return;
    }
  }
}

void _liTypeDescriptors(_LiCursor c) {
  final count = c.u32();
  if (!c.ok || count > 4096) {
    c.ok = false;
    return;
  }
  for (var i = 0; i < count; i++) {
    final length = c.u16();
    if (!c.ok || length < 4) {
      c.ok = false;
      return;
    }
    c.skip(length - 2);
    if (!c.ok) return;
  }
  final hasTopType = c.u16();
  if ((hasTopType & 0x8000) != 0) c.u16();
  if (hasTopType != 0) _liU2p2(c);
}

void _liHeapToFile(_LiCursor c) {
  _liBasic(c);
  if (!c.ok) return;
  _liLStr(c);
  if (!c.ok) return;
  c.pad(4);
  c.skip(4);
  _liOffList(c);
}

void _liHeapToRcFile(_LiCursor c) {
  _liHeapToFile(c);
  if (!c.ok) return;
  final count = c.u32();
  if (!c.ok || count > 4096) {
    c.ok = false;
    return;
  }
  for (var i = 0; i < count; i++) {
    _liTypeDescriptors(c);
    if (!c.ok) return;
    c.skip(4);
  }
}

void _liActiveXTypeLib(_LiCursor c) {
  _liBasic(c);
  if (!c.ok) return;
  c.skip(4);
  _liU2p2(c);
  if (!c.ok) return;
  _liViLinkRef(c);
  if (!c.ok) return;
  if (c.ge(12, 0, 0)) c.skip(4);
  _liOffList(c);
  if (!c.ok) return;
  c.skip(40);
}

void _liHeapToAssembly(_LiCursor c) {
  _liOffsetSave(c);
  if (!c.ok) return;
  c.skip(8);
  for (var i = 0; i < 4; i++) {
    c.skip(c.u8());
    if (!c.ok) return;
  }
  c.skip(4);
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
    case 'RVPI':
      _liUdViApi(c);
    case 'RCFL':
      _liHeapToRcFile(c);
    case 'AXVT':
    case 'AXDT':
      _liActiveXTypeLib(c);
    case 'DNDA':
      _liHeapToAssembly(c);
    default:
      c.ok = false;
  }
}
