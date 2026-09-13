/// `PTH0` — a LabVIEW path: a type word and a counted run of Pascal components.
///
/// Whole blocks (`HLPP`, `DLLP`) hold one path; link-info entries embed paths inline.
///
/// ```text
/// offset  size  field           type   meaning
/// 0       4     magic           4cc    "PTH0"
/// 4       4     length          u32    bytes that follow this word
/// 8       2     pathType        u16    role TODO; 1 with an empty first component is a relative path
/// 10      2     componentCount  u16    number of components
/// 12      rest  components      pstr[componentCount]
/// ```
///
/// [ViPath] is a view over the path bytes that records where each component starts;
/// [decodePth0] requires the magic, the length word and the components to tile the bytes
/// exactly; [isPth0] tells whether bytes at an offset satisfy that.
library;

import 'dart:typed_data';

import 'block_layout.dart';

const _magic = BlockField(0, 4, 'magic', '4cc', '"PTH0"');
const _length = BlockField(4, 4, 'length', 'u32', 'bytes that follow this word');
const _pathType = BlockField(8, 2, 'pathType', 'u16', 'role TODO; 1 with an empty first component is a relative path');
const _componentCount = BlockField(10, 2, 'componentCount', 'u16', 'number of components');
const _components = BlockField(12, null, 'components', 'pstr[componentCount]', 'the path components');

const BlockLayout pth0Layout = [_magic, _length, _pathType, _componentCount, _components];

const _magicBytes = [0x50, 0x54, 0x48, 0x30];

/// A view over one `PTH0` path.
class ViPath {
  ViPath._(this.bytes, this._componentOffsets) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  final List<int> _componentOffsets;

  int get pathType => _view.getUint16(_pathType.offset);

  int get componentCount => _componentOffsets.length;

  String componentAt(int index) {
    final at = _componentOffsets[index];
    return String.fromCharCodes(bytes, at + 1, at + 1 + bytes[at]);
  }

  List<String> get components => [for (var i = 0; i < componentCount; i++) componentAt(i)];

  String get path => components.join('/');

  Uint8List serialize() => bytes;
}

/// The byte extent of a `PTH0` whose magic sits at [at], or null when the bytes there do not
/// hold a complete path.
int? pth0ExtentAt(Uint8List bytes, int at) {
  if (at + _components.offset > bytes.length) return null;
  for (var i = 0; i < 4; i++) {
    if (bytes[at + i] != _magicBytes[i]) return null;
  }
  final view = ByteData.sublistView(bytes);
  final end = at + _length.end + view.getUint32(at + _length.offset);
  if (end > bytes.length) return null;
  var pos = at + _components.offset;
  for (var i = view.getUint16(at + _componentCount.offset); i > 0; i--) {
    if (pos >= end) return null;
    pos += 1 + bytes[pos];
  }
  return pos == end ? end - at : null;
}

bool isPth0(Uint8List bytes) => pth0ExtentAt(bytes, 0) == bytes.length;

ViPath decodePth0(Uint8List bytes) {
  assert(isPth0(bytes), 'a PTH0 path: magic, length word, and components tiling the bytes');
  final count = ByteData.sublistView(bytes).getUint16(_componentCount.offset);
  final offsets = List<int>.filled(count, 0);
  var pos = _components.offset;
  for (var i = 0; i < count; i++) {
    offsets[i] = pos;
    pos += 1 + bytes[pos];
  }
  return ViPath._(bytes, offsets);
}
