/// `VICD` - VI Compiled Code: [ViCompiledCode]
///
/// Compiled machine code for one target architecture: a header, the fixups and code, and a
/// `CODE` chunk that may carry a symbol table. Bit `0x100` of the header word at 12 selects
/// the header layout: set (`0x103`, `0x303`), the code-end pointer is at 36; clear (`0`,
/// `0x3`), at 28. A 64-bit architecture (`wx64`, `mx64`, `AM64`) puts it 4 bytes later in both
/// layouts. The `CODE` chunk is bare (20 bytes for 32-bit code, 40 for 64-bit) or carries
/// `count` length-prefixed names padded to 4 bytes. The section usually stores the payload
/// in the zlib envelope that [inflateHeapPayload] opens, and sometimes plain; the layout is
/// the inflated body.
///
/// ```text
/// offset  size       field         type           meaning
/// 0       4          codeStart     u32le          Offset of the machine code within the payload.
/// 4       4          architecture  4cc            i386, m386, wx64, mx64 or AM64, see CodeArchitecture.
/// 8       4          codeSize      u32le          Bytes of machine code.
/// 12      4          layoutWord    u32le          Bit 0x100 puts the code-end pointer at 36 (32-bit) or 40
///                                                 (64-bit); clear, it is at 28 or 32.
/// 16      4          flags         u32le          Bits TODO.
/// 20      4          codeTag       4cc            "code".
/// 24      rest       fixupsAndCode                The fixups and the machine code, up to codeEnd.
/// …       4          codeEnd       u32le          Offset of the CODE chunk; at 28, 32, 36 or 40 as
///                                                 layoutWord and the architecture select, inside
///                                                 fixupsAndCode.
/// …       20         bareChunk32   VicdChunk32    At codeEnd; the 32-bit bare form.
///   +0    4          chunkTag      4cc            "CODE".
///   +4    12         zeros         u32le[3]       Zero.
///   +16   4          selfOffset    u32le          Equals codeEnd.
/// …       40         bareChunk64   VicdChunk64    At codeEnd; the 64-bit bare form.
///   +0    4          chunkTag      4cc            "CODE".
///   +4    28         zeros         u32le[7]       Zero.
///   +32   4          selfOffset    u32le          Equals codeEnd.
///   +36   4          zero          u32le          Zero.
/// …       24         tableChunk32  VicdChunkI386  At codeEnd; the 32-bit symbol-table form.
///   +0    4          chunkTag      4cc            "CODE".
///   +4    12         zeros         u32le[3]       Zero.
///   +16   4          selfOffset    u32le          Equals codeEnd.
///   +20   4          count         u32le          Symbol names that follow.
/// …       36         tableChunk64  VicdChunkWx64  At codeEnd; the 64-bit symbol-table form.
///   +0    4          chunkTag      4cc            "CODE".
///   +4    4          codeImageSize u32le          Role TODO.
///   +8    16         zeros         u32le[4]       Zero.
///   +24   4          selfOffset    u32le          Equals codeEnd.
///   +28   4          zero          u32le          Zero.
///   +32   4          count         u32le          Symbol names that follow.
/// …       rest       names         VicdName[]     After a symbol-table chunk head, as many as its count
///                                                 says.
///   +0    4          nameLength    u32le          Bytes of name.
///   +4    nameLength name          u8[nameLength] Symbol name, padded to a multiple of 4 bytes.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';
import '../decode.dart' show inflateHeapPayload;

/// The bare `CODE` chunk of 32-bit code.
abstract final class VicdChunk32 {
  static const chunkTag = FourCc(0); // "CODE".
  static const zeros = U32List(4, endian: Endian.little, length: 3); // Zero.
  static const selfOffset = U32(16, endian: Endian.little); // Equals codeEnd.

  static const layout = ByteLayout([chunkTag, zeros, selfOffset]);
}

/// The bare `CODE` chunk of 64-bit code.
abstract final class VicdChunk64 {
  static const chunkTag = FourCc(0); // "CODE".
  static const zeros = U32List(4, endian: Endian.little, length: 7); // Zero.
  static const selfOffset = U32(32, endian: Endian.little); // Equals codeEnd.
  static const zero = U32(36, endian: Endian.little); // Zero.

  static const layout = ByteLayout([chunkTag, zeros, selfOffset, zero]);
}

/// The symbol-table `CODE` chunk head of 32-bit code.
abstract final class VicdChunkI386 {
  static const chunkTag = FourCc(0); // "CODE".
  static const zeros = U32List(4, endian: Endian.little, length: 3); // Zero.
  static const selfOffset = U32(16, endian: Endian.little); // Equals codeEnd.
  static const count = U32(20, endian: Endian.little); // Symbol names that follow.

  static const layout = ByteLayout([chunkTag, zeros, selfOffset, count]);
}

/// The symbol-table `CODE` chunk head of 64-bit code.
abstract final class VicdChunkWx64 {
  static const chunkTag = FourCc(0); // "CODE".
  static const codeImageSize = U32(4, endian: Endian.little); // Role TODO.
  static const zeros = U32List(8, endian: Endian.little, length: 4); // Zero.
  static const selfOffset = U32(24, endian: Endian.little); // Equals codeEnd.
  static const zero = U32(28, endian: Endian.little); // Zero.
  static const count = U32(32, endian: Endian.little); // Symbol names that follow.

  static const layout = ByteLayout([chunkTag, codeImageSize, zeros, selfOffset, zero, count]);
}

/// One symbol name of a symbol-table chunk.
abstract final class VicdName {
  static const nameLength = U32(0, endian: Endian.little); // Bytes of name.
  static const name = Bytes(4, count: nameLength); // Symbol name, padded to a multiple of 4 bytes.

  static const layout = ByteLayout([nameLength, name]);
}

/// The [ViCompiledCode.layoutWord] bit that puts the code-end pointer after a longer header.
const _modernHeaderBit = 0x100;
const _legacyCodeEndOffset = 28;
const _modernCodeEndOffset = 36;

/// The target architecture named by the 4CC at offset 4.
enum CodeArchitecture {
  i386('i386', is64Bit: false),
  m386('m386', is64Bit: false),
  wx64('wx64', is64Bit: true),
  mx64('mx64', is64Bit: true),
  am64('AM64', is64Bit: true);

  const CodeArchitecture(this.fourCc, {required this.is64Bit});

  final String fourCc;

  /// Whether pointers are 8 bytes wide, which moves the code-end pointer 4 bytes later and
  /// selects the 64-bit `CODE` chunk forms.
  final bool is64Bit;

  /// Offset of the code-end pointer for [layoutWord].
  int codeEndOffset(int layoutWord) =>
      (layoutWord & _modernHeaderBit != 0 ? _modernCodeEndOffset : _legacyCodeEndOffset) + (is64Bit ? 4 : 0);

  int get bareChunkSize => is64Bit ? VicdChunk64.layout.size! : VicdChunk32.layout.size!;

  int get bareSelfOffset => is64Bit ? VicdChunk64.selfOffset.offset : VicdChunk32.selfOffset.offset;

  int get tableSelfOffset => is64Bit ? VicdChunkWx64.selfOffset.offset : VicdChunkI386.selfOffset.offset;

  int get countOffset => is64Bit ? VicdChunkWx64.count.offset : VicdChunkI386.count.offset;

  /// Offset of the first symbol name within a symbol-table `CODE` chunk.
  int get namesOffset => is64Bit ? VicdChunkWx64.count.end : VicdChunkI386.count.end;

  static CodeArchitecture? of(String fourCc) {
    for (final a in values) {
      if (a.fourCc == fourCc) return a;
    }
    return null;
  }
}

final class ViCompiledCode extends ByteRecord {
  ViCompiledCode(Uint8List bytes) : super(bytes, layout) {
    assert(view.lengthInBytes >= _codeEnd.end + VicdChunk32.layout.size!, 'VICD holds a header and a CODE chunk');
    assert(_codeTag.read(view) == 'code', 'the code tag follows the header');
    final architecture = CodeArchitecture.of(_architecture.read(view));
    assert(architecture != null, 'the architecture is i386, m386, wx64, mx64 or AM64');
    this.architecture = architecture!;
    final codeEndOffset = architecture.codeEndOffset(layoutWord);
    final codeEnd = view.getUint32(codeEndOffset, Endian.little);
    assert(
      codeEnd >= codeEndOffset + 4 && codeEnd + VicdChunk32.layout.size! <= view.lengthInBytes,
      'the CODE chunk lies inside the payload',
    );
    assert(_has4cc(codeEnd, 'CODE'), 'the CODE chunk starts with its tag');
    final tail = view.lengthInBytes - codeEnd;
    if (tail == architecture.bareChunkSize) {
      assert(
        view.getUint32(codeEnd + architecture.bareSelfOffset, Endian.little) == codeEnd,
        'the bare chunk points at itself',
      );
      _nameOffsets = const [];
      return;
    }
    assert(codeEnd + architecture.namesOffset <= view.lengthInBytes, 'a symbol table has its head');
    assert(
      view.getUint32(codeEnd + architecture.tableSelfOffset, Endian.little) == codeEnd,
      'the symbol-table chunk points at itself',
    );
    final count = view.getUint32(codeEnd + architecture.countOffset, Endian.little);
    var at = codeEnd + architecture.namesOffset;
    assert(count <= (view.lengthInBytes - at) ~/ 4, 'the count fits the payload');
    final offsets = List<int>.filled(count, 0);
    for (var i = 0; i < count; i++) {
      assert(at + 4 <= view.lengthInBytes, 'name $i has a length word');
      offsets[i] = at;
      at += 4 + ((view.getUint32(at, Endian.little) + 3) & ~3);
    }
    assert(at == view.lengthInBytes, 'the names tile the payload');
    _nameOffsets = offsets;
  }

  /// i386, m386, wx64, mx64 or AM64, see [CodeArchitecture].
  late final CodeArchitecture architecture;

  /// Offset of the machine code within the payload.
  int get codeStart => _codeStart.read(view);

  /// Bytes of machine code.
  int get codeSize => _codeSize.read(view);

  /// Bit 0x100 puts the code-end pointer at 36 (32-bit) or 40 (64-bit); clear, it is at 28
  /// or 32.
  int get layoutWord => _layoutWord.read(view);

  /// Bits TODO.
  int get flags => _flags.read(view);

  /// Offset of the CODE chunk; at 28, 32, 36 or 40 as layoutWord and the architecture
  /// select, inside fixupsAndCode.
  int get codeEnd => view.getUint32(architecture.codeEndOffset(layoutWord), Endian.little);

  /// The fixups and the machine code, up to codeEnd.
  Uint8List get fixupsAndCode => Uint8List.sublistView(view, _fixupsAndCode.offset, codeEnd);

  int get symbolCount => _nameOffsets.length;

  Uint8List symbolNameAt(int index) {
    final at = _nameOffsets[index];
    final start = at + VicdName.name.offset;
    return Uint8List.sublistView(view, start, start + view.getUint32(at + VicdName.nameLength.offset, Endian.little));
  }

  late final List<int> _nameOffsets;

  bool _has4cc(int at, String tag) {
    if (at < 0 || at + 4 > view.lengthInBytes) return false;
    for (var i = 0; i < 4; i++) {
      if (view.getUint8(at + i) != tag.codeUnitAt(i)) return false;
    }
    return true;
  }

  // dart format off
  static const _codeStart = U32(0, endian: Endian.little);
  static const _architecture = FourCc(4);
  static const _codeSize = U32(8, endian: Endian.little);
  static const _layoutWord = U32(12, endian: Endian.little);
  static const _flags = U32(16, endian: Endian.little);
  static const _codeTag = FourCc(20); // "code".
  static const _fixupsAndCode = Unknown(24);
  static const _codeEnd = U32(28, endian: Endian.little);
  static const _bareChunk32 = Struct(0, VicdChunk32.layout); // At codeEnd; the 32-bit bare form.
  static const _bareChunk64 = Struct(0, VicdChunk64.layout); // At codeEnd; the 64-bit bare form.
  static const _tableChunk32 = Struct(0, VicdChunkI386.layout); // At codeEnd; the 32-bit symbol-table form.
  static const _tableChunk64 = Struct(0, VicdChunkWx64.layout); // At codeEnd; the 64-bit symbol-table form.
  static const _names = Entries(0, VicdName.layout); // After a symbol-table chunk head, as many as its count says.

  static const layout = ByteLayout([_codeStart, _architecture, _codeSize, _layoutWord, _flags, _codeTag, _fixupsAndCode, _codeEnd, _bareChunk32, _bareChunk64, _tableChunk32, _tableChunk64, _names]);
  // dart format on
}
