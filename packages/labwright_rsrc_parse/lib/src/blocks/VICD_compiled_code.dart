/// `VICD` — compiled machine code for one target architecture: a header, the fixups and
/// code, and a `CODE` chunk that may carry a symbol table.
///
/// Bit `0x100` of the header word at 12 selects the header layout: set (`0x103`, `0x303`),
/// the code-end pointer is at 36; clear (`0`, `0x3`), at 28. A 64-bit architecture (`wx64`,
/// `mx64`) puts it 4 bytes later in both layouts. The `CODE` chunk is bare (20 bytes for
/// 32-bit code, 40 for 64-bit) or carries `count` length-prefixed names padded to 4 bytes.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     codeStart                  u32le    offset of the machine code within the payload
/// 4       4     architecture               4cc      i386, m386, wx64 or mx64, see CodeArchitecture
/// 8       4     codeSize                   u32le    bytes of machine code
/// 12      4     layoutWord                 u32le    bit 0x100 puts the code-end pointer at 36
///                                                   (32-bit) or 40 (64-bit); clear, it is at 28 or
///                                                   32
/// 16      4     flags                      u32le    bits TODO
/// 20      4     codeTag                    4cc      "code"
/// 28      4     codeEnd                    u32le    offset of the CODE chunk; at 28, 32, 36 or 40
///                                                   as layoutWord and the architecture select
/// 24      rest  TODO                       bytes    retained; not decoded
/// …       20    codeChunk                  chunk    at codeEnd; the 32-bit bare form
///   +0    4     chunkTag                   4cc      "CODE"
///   +4    12    zeros                      u32le[3] zero
///   +16   4     selfOffset                 u32le    equals codeEnd
/// …       40    codeChunk                  chunk    at codeEnd; the 64-bit bare form
///   +0    4     chunkTag                   4cc      "CODE"
///   +4    28    zeros                      u32le[7] zero
///   +32   4     selfOffset                 u32le    equals codeEnd
///   +36   4     zero                       u32le    zero
/// …       rest  codeChunk                  chunk    at codeEnd; the 32-bit symbol-table form
///   +0    4     chunkTag                   4cc      "CODE"
///   +4    12    zeros                      u32le[3] zero
///   +16   4     selfOffset                 u32le    equals codeEnd
///   +20   4     count                      u32le    symbol names that follow
/// …       rest  codeChunk                  chunk    at codeEnd; the 64-bit symbol-table form
///   +0    4     chunkTag                   4cc      "CODE"
///   +4    4     codeImageSize              u32le    role TODO
///   +8    16    zeros                      u32le[4] zero
///   +24   4     selfOffset                 u32le    equals codeEnd
///   +28   4     zero                       u32le    zero
///   +32   4     count                      u32le    symbol names that follow
/// …       rest  names                      entry[count] after the chunk head
///   +0    4     nameLength                 u32le    bytes of name
///   +4    rest  name                       u8[nameLength] symbol name, padded to a multiple of 4
///                                                         bytes
/// ```
///
/// The section usually stores the payload in the zlib envelope that [inflateHeapPayload]
/// opens, and sometimes plain; the layout is the inflated body.
///
/// [ViCompiledCode] is a view over the payload that records where each symbol name starts;
/// [CodeArchitecture] names the 4CC at 4; [decodeCompiledCode] requires the tags, the
/// code-end pointer and the symbol table to tile the payload.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';
import '../decode.dart' show inflateHeapPayload;

const _codeStart = BlockField(0, 4, 'codeStart', 'u32le', 'offset of the machine code within the payload');
const _architecture = BlockField(4, 4, 'architecture', '4cc', 'i386, m386, wx64 or mx64, see CodeArchitecture');
const _codeSize = BlockField(8, 4, 'codeSize', 'u32le', 'bytes of machine code');
const _layoutWord = BlockField(
  12,
  4,
  'layoutWord',
  'u32le',
  'bit 0x100 puts the code-end pointer at 36 (32-bit) or 40 (64-bit); clear, it is at 28 or 32',
);
const _flags = BlockField(16, 4, 'flags', 'u32le', 'bits TODO');
const _codeTag = BlockField(20, 4, 'codeTag', '4cc', '"code"');
const _fixupsAndCode = BlockField.undecoded(24, null, type: 'bytes');
const _codeEnd = BlockField(
  28,
  4,
  'codeEnd',
  'u32le',
  'offset of the CODE chunk; at 28, 32, 36 or 40 as layoutWord and the architecture select',
);
const _chunkTag = BlockField(0, 4, 'chunkTag', '4cc', '"CODE"');
const _bareZeros = BlockField(4, 12, 'zeros', 'u32le[3]', 'zero');
const _bareSelfOffset = BlockField(16, 4, 'selfOffset', 'u32le', 'equals codeEnd');
const _codeChunk = BlockField(
  0,
  20,
  'codeChunk',
  'chunk',
  'at codeEnd; the 32-bit bare form',
  entry: [_chunkTag, _bareZeros, _bareSelfOffset],
);
const _bare64Zeros = BlockField(4, 28, 'zeros', 'u32le[7]', 'zero');
const _bare64SelfOffset = BlockField(32, 4, 'selfOffset', 'u32le', 'equals codeEnd');
const _bare64Zero = BlockField(36, 4, 'zero', 'u32le', 'zero');
const _codeChunk64 = BlockField(
  0,
  40,
  'codeChunk',
  'chunk',
  'at codeEnd; the 64-bit bare form',
  entry: [_chunkTag, _bare64Zeros, _bare64SelfOffset, _bare64Zero],
);
const _i386Count = BlockField(20, 4, 'count', 'u32le', 'symbol names that follow');
const _i386Chunk = BlockField(
  0,
  null,
  'codeChunk',
  'chunk',
  'at codeEnd; the 32-bit symbol-table form',
  entry: [_chunkTag, _bareZeros, _bareSelfOffset, _i386Count],
);
const _wx64ImageSize = BlockField(4, 4, 'codeImageSize', 'u32le', 'role TODO');
const _wx64Zeros = BlockField(8, 16, 'zeros', 'u32le[4]', 'zero');
const _wx64SelfOffset = BlockField(24, 4, 'selfOffset', 'u32le', 'equals codeEnd');
const _wx64Zero = BlockField(28, 4, 'zero', 'u32le', 'zero');
const _wx64Count = BlockField(32, 4, 'count', 'u32le', 'symbol names that follow');
const _wx64Chunk = BlockField(
  0,
  null,
  'codeChunk',
  'chunk',
  'at codeEnd; the 64-bit symbol-table form',
  entry: [_chunkTag, _wx64ImageSize, _wx64Zeros, _wx64SelfOffset, _wx64Zero, _wx64Count],
);
const _nameLength = BlockField(0, 4, 'nameLength', 'u32le', 'bytes of name');
const _name = BlockField(4, null, 'name', 'u8[nameLength]', 'symbol name, padded to a multiple of 4 bytes');
const _names = BlockField(0, null, 'names', 'entry[count]', 'after the chunk head', entry: [_nameLength, _name]);

const BlockLayout vicdLayout = [
  _codeStart,
  _architecture,
  _codeSize,
  _layoutWord,
  _flags,
  _codeTag,
  _codeEnd,
  _fixupsAndCode,
  _codeChunk,
  _codeChunk64,
  _i386Chunk,
  _wx64Chunk,
  _names,
];

/// The [_layoutWord] bit that puts the code-end pointer after a longer header.
const _modernHeaderBit = 0x100;
const _legacyCodeEndOffset = 28;
const _modernCodeEndOffset = 36;

/// The target architecture named by the 4CC at offset 4.
enum CodeArchitecture {
  i386('i386', is64Bit: false),
  m386('m386', is64Bit: false),
  wx64('wx64', is64Bit: true),
  mx64('mx64', is64Bit: true)
  ;

  const CodeArchitecture(this.fourCc, {required this.is64Bit});

  final String fourCc;

  /// Whether pointers are 8 bytes wide, which moves the code-end pointer 4 bytes later and
  /// selects the 64-bit `CODE` chunk forms.
  final bool is64Bit;

  /// Offset of the code-end pointer for [layoutWord].
  int codeEndOffset(int layoutWord) =>
      (layoutWord & _modernHeaderBit != 0 ? _modernCodeEndOffset : _legacyCodeEndOffset) + (is64Bit ? 4 : 0);

  int get bareChunkSize => is64Bit ? _codeChunk64.size! : _codeChunk.size!;

  int get bareSelfOffset => is64Bit ? _bare64SelfOffset.offset : _bareSelfOffset.offset;

  int get tableSelfOffset => is64Bit ? _wx64SelfOffset.offset : _bareSelfOffset.offset;

  int get countOffset => is64Bit ? _wx64Count.offset : _i386Count.offset;

  /// Offset of the first symbol name within a symbol-table `CODE` chunk.
  int get namesOffset => is64Bit ? _wx64Count.end : _i386Count.end;

  static CodeArchitecture? of(String fourCc) {
    for (final a in values) {
      if (a.fourCc == fourCc) return a;
    }
    return null;
  }
}

/// A view over a `VICD` payload.
class ViCompiledCode implements BlockRecord {
  ViCompiledCode._(this.bytes, this.architecture, this._nameOffsets) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  final CodeArchitecture architecture;

  final List<int> _nameOffsets;

  int get codeStart => _view.getUint32(_codeStart.offset, Endian.little);

  int get codeSize => _view.getUint32(_codeSize.offset, Endian.little);

  int get layoutWord => _view.getUint32(_layoutWord.offset, Endian.little);

  int get flags => _view.getUint32(_flags.offset, Endian.little);

  int get codeEnd => _view.getUint32(_codeEndOffset(this), Endian.little);

  Uint8List get fixupsAndCode => Uint8List.sublistView(bytes, _fixupsAndCode.offset, codeEnd);

  int get symbolCount => _nameOffsets.length;

  Uint8List symbolNameAt(int index) {
    final at = _nameOffsets[index];
    return Uint8List.sublistView(bytes, at + _name.offset, at + _name.offset + _view.getUint32(at, Endian.little));
  }

  @override
  Uint8List serialize() => bytes;
}

int _codeEndOffset(ViCompiledCode code) => code.architecture.codeEndOffset(code.layoutWord);

bool _has4cc(Uint8List bytes, int at, String tag) {
  if (at < 0 || at + 4 > bytes.length) return false;
  for (var i = 0; i < 4; i++) {
    if (bytes[at + i] != tag.codeUnitAt(i)) return false;
  }
  return true;
}

ViCompiledCode decodeCompiledCode(Uint8List bytes) {
  assert(bytes.length >= _codeEnd.end + _codeChunk.size!, 'VICD holds a header and a CODE chunk');
  assert(_has4cc(bytes, _codeTag.offset, 'code'), 'the code tag follows the header');
  final architecture = CodeArchitecture.of(String.fromCharCodes(bytes, _architecture.offset, _architecture.end));
  assert(architecture != null, 'the architecture is i386, m386, wx64 or mx64');
  final view = ByteData.sublistView(bytes);
  final codeEndOffset = architecture!.codeEndOffset(view.getUint32(_layoutWord.offset, Endian.little));
  final codeEnd = view.getUint32(codeEndOffset, Endian.little);
  assert(
    codeEnd >= codeEndOffset + 4 && codeEnd + _codeChunk.size! <= bytes.length,
    'the CODE chunk lies inside the payload',
  );
  assert(_has4cc(bytes, codeEnd, 'CODE'), 'the CODE chunk starts with its tag');
  final tail = bytes.length - codeEnd;
  if (tail == architecture.bareChunkSize) {
    assert(
      view.getUint32(codeEnd + architecture.bareSelfOffset, Endian.little) == codeEnd,
      'the bare chunk points at itself',
    );
    return ViCompiledCode._(bytes, architecture, const []);
  }
  assert(codeEnd + architecture.namesOffset <= bytes.length, 'a symbol table has its head');
  assert(
    view.getUint32(codeEnd + architecture.tableSelfOffset, Endian.little) == codeEnd,
    'the symbol-table chunk points at itself',
  );
  final count = view.getUint32(codeEnd + architecture.countOffset, Endian.little);
  var at = codeEnd + architecture.namesOffset;
  assert(count <= (bytes.length - at) ~/ 4, 'the count fits the payload');
  final offsets = List<int>.filled(count, 0);
  for (var i = 0; i < count; i++) {
    assert(at + 4 <= bytes.length, 'name $i has a length word');
    offsets[i] = at;
    at += 4 + ((view.getUint32(at, Endian.little) + 3) & ~3);
  }
  assert(at == bytes.length, 'the names tile the payload');
  return ViCompiledCode._(bytes, architecture, offsets);
}
