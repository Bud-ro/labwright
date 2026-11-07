/// `LIvi` / `LIbd` / `LIfp` / `LIds` - Link Info: [ViLinkInfo]
///
/// The resources the VI, its block diagram, front panel and data space link to, each an entry
/// whose grammar depends on its four-character kind and on the saving LabVIEW version. A VI
/// saved inside a library before LabVIEW 14 puts its own qualified name between the root kind
/// and the entry count, the [ViLinkInfo.libraryLayout] form. Entries carry no length of their
/// own, so an entry whose kind the grammar does not know ends the walk and the rest of the
/// region up to the terminator is retained as one [ViLinkEntryUnwalked].
///
/// ```text
/// LIvi / LIfp / LIbd / LIds:
/// offset  size  field      type                      meaning
/// 0       2     version    u16                       Link-info format version, 1.
/// 2       4     rootKind   4cc                       The linking resource: LVIN, BDHP, FPHP or VIDS.
/// 6       4     entryCount u32                       Number of entries.
/// 10      …     entries    LinkInfoEntry[entryCount]
///   +0    2     version    u16                       Entry format version, 2.
///   +2    4     kind       4cc                       Link kind such as IUVI (sub-VI) or VILB (library).
///   +6    rest  body       u8[]                      Grammar per kind and saving version.
/// …       2     terminator u16                       Always 3, the last two bytes of the payload.
/// ViLinkInfo.libraryLayout:
/// offset  size        field         type                      meaning
/// 0       2           version       u16                       Link-info format version, 1.
/// 2       4           rootKind      4cc                       The linking resource: LVIN, BDHP, FPHP or
///                                                             VIDS.
/// 6       …           qualifiedName pstr                      The VI's library-qualified name, padded to an
///                                                             even length.
/// …       2           wordCount     u16                       After the padded name; role TODO.
/// …       2·wordCount words         u16[wordCount]            Words whose role is TODO; the entry count
///                                                             follows them.
/// …       4           entryCount    u32                       Number of entries.
/// …       …           entries       LinkInfoEntry[entryCount]
///   +0    2           version       u16                       Entry format version, 2.
///   +2    4           kind          4cc                       Link kind such as IUVI (sub-VI) or VILB
///                                                             (library).
///   +6    rest        body          u8[]                      Grammar per kind and saving version.
/// …       2           terminator    u16                       Always 3, the last two bytes of the payload.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';
import '../pth0.dart';
import 'vers_version.dart';

/// One link entry.
abstract final class LinkInfoEntry {
  static const version = U16(0); // Entry format version, 2.
  static const kind = FourCc(2); // Link kind such as IUVI (sub-VI) or VILB (library).
  static const body = Bytes(6); // Grammar per kind and saving version.

  static const layout = ByteLayout([version, kind, body]);
}

/// One entry of a [ViLinkInfo].
sealed class ViLinkEntry {
  const ViLinkEntry(this.offset, this.end);

  final int offset;

  final int end;
}

/// An entry the grammar walked: [kind] at `offset + 2`, body to [end].
final class ViLinkEntryFramed extends ViLinkEntry {
  const ViLinkEntryFramed(super.offset, super.end, this.kind, {this.qualifiedName = const [], this.path});

  final String kind;

  /// The linked resource's library-qualified name, outermost first, such as
  /// `MB Master.lvlib`, `MB_Master.lvclass`, `Close Session.vi`; empty for an entry kind that
  /// names none.
  final List<String> qualifiedName;

  /// The linked resource's path record, relative to the VI's own directory when
  /// [ViPath.pathType] says so; null for an entry kind that carries none.
  final ViPath? path;
}

/// The entry region from an entry the grammar cannot walk up to the terminator.
final class ViLinkEntryUnwalked extends ViLinkEntry {
  const ViLinkEntryUnwalked(super.offset, super.end);
}

final class ViLinkInfo extends ByteRecord {
  ViLinkInfo(Uint8List bytes, {ViVersionWord? version}) : super(bytes, layout) {
    assert(bytes.length >= _entries.offset + _terminator.size, 'link info holds a header, a count and a terminator');
    final termOff = bytes.length - _terminator.size;
    for (final start in _entriesStarts(bytes, view, version)) {
      final count = view.getUint32(start - _entryCount.size);
      final walked = _walk(bytes, version, count, start, termOff);
      if (walked != null) {
        entriesOffset = start;
        entries = walked;
        return;
      }
    }
    entriesOffset = _entries.offset;
    entries = [ViLinkEntryUnwalked(_entries.offset, termOff)];
  }

  /// Where the entries start: after the count word, itself after the qualified name in the
  /// library form.
  late final int entriesOffset;

  late final List<ViLinkEntry> entries;

  /// Link-info format version, 1.
  int get version => _version.read(view);

  /// The linking resource: LVIN, BDHP, FPHP or VIDS.
  String get rootKind => _rootKind.read(view);

  /// Number of entries.
  int get entryCount => view.getUint32(entriesOffset - _entryCount.size);

  /// Always 3, the last two bytes of the payload.
  int get terminator => view.getUint16(view.lengthInBytes - _terminator.size);

  bool get isWalked => entries.every((e) => e is ViLinkEntryFramed);

  /// Names ending in a LabVIEW file extension that appear as Pascal strings anywhere in
  /// the entry region, in order of first appearance.
  List<String> get linkedNames {
    final bytes = Uint8List.sublistView(view);
    final out = <String>[];
    for (var pos = entriesOffset; pos < bytes.length - 4; pos++) {
      final len = bytes[pos];
      if (len < 4 || len > 120 || pos + 1 + len > bytes.length) continue;
      if (!_printable(bytes, pos + 1, pos + 1 + len)) continue;
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
    final bytes = Uint8List.sublistView(view);
    var n = 0;
    for (var pos = entriesOffset; pos + 4 <= bytes.length; pos++) {
      if (bytes[pos] == 0x50 && bytes[pos + 1] == 0x54 && bytes[pos + 2] == 0x48 && bytes[pos + 3] == 0x30) {
        n++;
        pos += 3;
      }
    }
    return n;
  }

  static bool _printable(Uint8List bytes, int start, int end) {
    for (var i = start; i < end; i++) {
      if (bytes[i] < 0x20 || bytes[i] >= 0x7f) return false;
    }
    return true;
  }

  // dart format off
  static const _version = U16(0);
  static const _rootKind = FourCc(2);
  static const _entryCount = U32(6);
  static const _entries = Entries(10, LinkInfoEntry.layout, count: _entryCount);
  static const _terminator = U16(0);
  static const _qualifiedName = PStr(6); // The VI's library-qualified name, padded to an even length.
  static const _wordCount = U16(7); // After the padded name; role TODO.
  static const _words = U16List(9, count: _wordCount); // Words whose role is TODO; the entry count follows them.

  static const layout = ByteLayout([_version, _rootKind, _entryCount, _entries, _terminator]);
  static const libraryLayout = ByteLayout([_version, _rootKind, _qualifiedName, _wordCount, _words, _entryCount, _entries, _terminator]);
  // dart format on
}

final _linkedFile = RegExp(r'\.(vi|vim|vit|ctl|ctt|lvclass|lvlib|llb)$', caseSensitive: false);

/// Candidate offsets of the first entry, each preceded by its count word.
Iterable<int> _entriesStarts(Uint8List bytes, ByteData view, ViVersionWord? version) sync* {
  if (version != null && version.major < 14) {
    final nameLen = bytes[ViLinkInfo._qualifiedName.offset];
    var pos = ViLinkInfo._qualifiedName.offset + 1 + nameLen;
    if ((nameLen + 1).isOdd) pos += 1;
    if (pos + 6 <= bytes.length) yield pos + 2 + 2 * view.getUint16(pos) + 4;
  }
  yield ViLinkInfo._entries.offset;
  if (bytes[ViLinkInfo._qualifiedName.offset] != 0) {
    var pos = ViLinkInfo._qualifiedName.offset + 1 + bytes[ViLinkInfo._qualifiedName.offset];
    if (pos % 4 != 0) pos += 4 - pos % 4;
    pos += 2;
    if (pos + 4 <= bytes.length) yield pos + 4;
  }
}

/// Whether a `PTH0` record with components starts at [at]; a link may also carry an empty
/// record or a `PTH1`/`PTH2`, which [ViPath] does not model.
bool _framesPath(Uint8List bytes, ByteData view, int at) {
  if (at + 8 > bytes.length) return false;
  final length = view.getUint32(at + 4);
  if (length < 4 || at + 8 + length > bytes.length) return false;
  return isPth0(Uint8List.sublistView(bytes, at, at + 8 + length));
}

/// A link's qualified name: a `u32` count, then that many Pascal strings. A component of the API
/// link kinds (a class method's `DyOM`, `VIPI`, `FPPI` and their kin) may itself be a qualified
/// name, a `u8` count then that many Pascal strings filling the component exactly, and its
/// components then stand in its place.
// TODO: components of the API kinds that start with a control byte and do not read as a nested
// qualified name (most of DDPI, FPPI, TCPI and PNOM, some of VIPI) are not decoded.
List<String> _qualifiedNameAt(Uint8List bytes, int at) {
  final count = ByteData.sublistView(bytes).getUint32(at);
  final names = <String>[];
  var pos = at + 4;
  for (var i = 0; i < count; i++) {
    final length = bytes[pos];
    names.addAll(
      _nestedQualifiedName(bytes, pos + 1, pos + 1 + length) ??
          [String.fromCharCodes(bytes, pos + 1, pos + 1 + length)],
    );
    pos += 1 + length;
  }
  return names;
}

/// The bytes [start]..[end] as a `u8` count then that many Pascal strings that end exactly at
/// [end]; null when they do not read so.
List<String>? _nestedQualifiedName(Uint8List bytes, int start, int end) {
  if (start >= end) return null;
  final count = bytes[start];
  if (count == 0 || count >= 0x20) return null;
  final names = <String>[];
  var pos = start + 1;
  for (var i = 0; i < count; i++) {
    if (pos >= end) return null;
    final length = bytes[pos];
    if (length == 0 || pos + 1 + length > end) return null;
    names.add(String.fromCharCodes(bytes, pos + 1, pos + 1 + length));
    pos += 1 + length;
  }
  return pos == end ? names : null;
}

List<ViLinkEntry>? _walk(Uint8List bytes, ViVersionWord? version, int count, int start, int termOff) {
  if (start > termOff || count > 0x10000) return null;
  if (count == 0) return start == termOff ? const [] : null;
  final entries = <ViLinkEntry>[];
  if (version == null) return [ViLinkEntryUnwalked(start, termOff)];
  final c = _LiCursor(bytes, version.major, version.minor, version.patch)..p = start;
  for (var i = 0; i < count; i++) {
    final at = c.p;
    c.qualifiedNameAt = null;
    c.pathAt = null;
    final kind = at + 6 <= termOff && c.u16() == 2 ? c.tag4() : '';
    if (kind.isNotEmpty) {
      c.skip(4);
      _liEntry(c, kind);
    }
    if (kind.isEmpty || !c.ok || c.p > termOff) {
      return entries.isEmpty ? null : (entries..add(ViLinkEntryUnwalked(at, termOff)));
    }
    entries.add(
      ViLinkEntryFramed(
        at,
        c.p,
        kind,
        qualifiedName: switch (c.qualifiedNameAt) {
          final at? => _qualifiedNameAt(bytes, at),
          null => const [],
        },
        path: switch (c.pathAt) {
          final at? when _framesPath(bytes, c.view, at) => ViPath(
            Uint8List.sublistView(bytes, at, at + 8 + c.view.getUint32(at + 4)),
          ),
          _ => null,
        },
      ),
    );
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

  /// Where the entry's first qualified name and path record start: the linked resource's.
  int? qualifiedNameAt, pathAt;

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
  c.skip(len);
  if (len == 0) c.skip(4);
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
  c.qualifiedNameAt ??= c.p;
  _liQualName(c);
  if (!c.ok) return;
  c.pad(2);
  c.pathAt ??= c.p;
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
  _liOffsetSave(c);
  if (!c.ok) return;
  if (!c.ge(8, 6, 0)) _liOffList(c);
  if (!c.ok) return;
  if (c.ge(8, 2, 0)) _liPathRef(c);
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
  _liOffsetSave(c);
  if (!c.ok) return;
  c.skip(40);
}

void _liHeapToAssembly(_LiCursor c) {
  _liOffsetSave(c);
  if (!c.ok) return;
  if (c.ge(8, 5, 0)) {
    _liAssemblyPath(c);
    return;
  }
  c.skip(4);
  for (var i = 0; i < 4; i++) {
    c.skip(c.u8());
    if (!c.ok) return;
  }
  c.skip(4);
}

void _liViToAssembly(_LiCursor c) {
  _liBasic(c);
  if (!c.ok) return;
  _liAssemblyPath(c);
}

void _liAssemblyPath(_LiCursor c) {
  if (!c.ge(10, 0, 0)) return;
  c.pad(2);
  _liPathRef(c);
}

void _liEio(_LiCursor c, {required bool heap}) {
  _liBasic(c);
  if (!c.ok) return;
  _liLStr(c);
  if (!c.ok) return;
  c.skip(4);
  _liLStr(c);
  if (!c.ok) return;
  if (heap) _liOffList(c);
  if (!c.ok) return;
  _liLStr(c);
  if (!c.ok) return;
  _liBool(c);
}

void _liVariable(_LiCursor c, {required bool heap}) {
  _liBasic(c);
  if (!c.ok) return;
  for (var i = 0; i < 3; i++) {
    _liLStr(c);
    if (!c.ok) return;
  }
  if (heap) _liOffList(c);
  if (!c.ok) return;
  _liLStr(c);
  if (!c.ok) return;
  c.skip(4);
  _liLStr(c);
  if (!c.ok) return;
  c.skip(16);
  _liLStr(c);
  if (!c.ok) return;
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

void _liBool(_LiCursor c) => c.skip(c.ge(4, 5, 0) ? 1 : 2);

void _liCcSymbol(_LiCursor c) {
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
      c.ge(8, 2, 0) ? _liHeapToVi(c) : _liOffsetSave(c);
      if (!c.ok) return;
      if (c.ge(8, 0, 0)) _liPStr(c);
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
    case 'PUPV':
    case 'SVVI':
      _liHeapToVi(c);
    case 'XNVI':
      _liHeapToVi(c);
      if (!c.ok) return;
      _liLStr(c);
    case 'VIIV':
      _liTyped(c);
      if (!c.ok) return;
      _liQualName(c);
      if (!c.ok) return;
      _liPathRef(c);
      if (!c.ok) return;
      _liBool(c);
    case 'IUIV':
      _liHeapToVi(c);
      if (!c.ok) return;
      c.skip(2);
    case 'V2CC':
      _liBasic(c);
      if (!c.ok) return;
      _liCcSymbol(c);
    case 'H2CC':
      _liOffsetSave(c);
      if (!c.ok) return;
      _liCcSymbol(c);
    case 'DSSV':
      _liOffsetSave(c);
    case 'DSDS':
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
    case 'VIXC':
      _liGiSave(c);
    case 'XCXI':
      _liOffsetSave(c);
      if (!c.ok) return;
      if (c.ge(8, 6, 0)) c.skip(12);
    case 'VIGV':
      _liTyped(c);
      if (!c.ok) return;
      c.skip(36);
    case 'GUGV':
      _liHeapToVi(c);
      if (!c.ok) return;
      c.skip(38);
    case 'EiVr':
      _liEio(c, heap: false);
    case 'HpEr':
      _liEio(c, heap: true);
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
    case 'DNVA':
      _liViToAssembly(c);
    case 'DSVr':
    case 'DSSC':
    case 'NSCR':
      _liOffsetSave(c);
    case 'VIVr':
      _liVariable(c, heap: false);
    case 'HpVr':
      _liVariable(c, heap: true);
    default:
      c.ok = false;
  }
}
