import 'dart:typed_data';

/// A field of a block payload: [size] bytes at [offset]; multi-byte words are big-endian unless
/// the field says `endian: Endian.little`.
///
/// A block model declares its fields as `static const` members, named by their identifiers
/// (a leading underscore dropped) and described by their doc comments, and lists them in
/// offset order in a `static const layout`. `tool/gen_block_docs.dart` renders those into the
/// file's byte diagram and into `lib/src/generated/block_docs.dart`.
sealed class Field {
  const Field(this.offset, {this.optional = false});

  final int offset;

  /// Whether the payload may end before the field.
  final bool optional;

  /// Null when the data decides the extent: a Pascal string, a counted run, the rest of the
  /// payload.
  int? get size;

  int get end => offset + size!;

  /// The extent within [view], for a field the data sizes.
  int endIn(ByteData view) => size == null ? view.lengthInBytes : end;

  /// Whether [view] reaches the field; false only for an [optional] one the payload ends before.
  bool isIn(ByteData view) => size == null ? offset <= view.lengthInBytes : end <= view.lengthInBytes;

  /// The type as the byte diagrams spell it.
  String get typeName;
}

/// A field read as one integer.
sealed class Scalar extends Field {
  const Scalar(super.offset, {super.optional});

  int read(ByteData view);
}

final class U8 extends Scalar {
  const U8(super.offset, {super.optional});

  @override
  int get size => 1;

  @override
  int read(ByteData view) => view.getUint8(offset);

  @override
  String get typeName => 'u8';
}

final class U16 extends Scalar {
  const U16(super.offset, {this.endian = Endian.big, super.optional});

  final Endian endian;

  @override
  int get size => 2;

  @override
  int read(ByteData view) => view.getUint16(offset, endian);

  @override
  String get typeName => endian == Endian.big ? 'u16' : 'u16le';
}

final class U32 extends Scalar {
  const U32(super.offset, {this.endian = Endian.big, super.optional});

  final Endian endian;

  @override
  int get size => 4;

  @override
  int read(ByteData view) => view.getUint32(offset, endian);

  @override
  String get typeName => endian == Endian.big ? 'u32' : 'u32le';
}

final class I16 extends Scalar {
  const I16(super.offset, {this.endian = Endian.big, super.optional});

  final Endian endian;

  @override
  int get size => 2;

  @override
  int read(ByteData view) => view.getInt16(offset, endian);

  @override
  String get typeName => endian == Endian.big ? 'i16' : 'i16le';
}

final class I32 extends Scalar {
  const I32(super.offset, {this.endian = Endian.big, super.optional});

  final Endian endian;

  @override
  int get size => 4;

  @override
  int read(ByteData view) => view.getInt32(offset, endian);

  @override
  String get typeName => endian == Endian.big ? 'i32' : 'i32le';
}

/// A field read as one IEEE 754 single.
final class F32 extends Field {
  const F32(super.offset, {this.endian = Endian.big, super.optional});

  final Endian endian;

  @override
  int get size => 4;

  double read(ByteData view) => view.getFloat32(offset, endian);

  @override
  String get typeName => endian == Endian.big ? 'f32' : 'f32le';
}

/// A word of two bytes, or of four with the high bit set and the value in the low 31 bits.
final class PackedWord extends Scalar {
  const PackedWord(super.offset, {super.optional});

  @override
  int? get size => null;

  static int sizeAt(ByteData view, int offset) => view.getUint16(offset) & 0x8000 == 0 ? 2 : 4;

  static int readAt(ByteData view, int offset) {
    final high = view.getUint16(offset);
    return high & 0x8000 == 0 ? high : view.getUint32(offset) & 0x7fffffff;
  }

  @override
  int read(ByteData view) => readAt(view, offset);

  @override
  int endIn(ByteData view) => offset + sizeAt(view, offset);

  @override
  String get typeName => 'packed';
}

/// Four ASCII characters.
final class FourCc extends Field {
  const FourCc(super.offset, {super.optional});

  @override
  int get size => 4;

  String read(ByteData view) => String.fromCharCodes(Uint8List.sublistView(view, offset, end));

  @override
  String get typeName => '4cc';
}

/// A Pascal string: a length byte and that many bytes.
final class PStr extends Field {
  const PStr(super.offset, {super.optional});

  @override
  int? get size => null;

  static int endAt(ByteData view, int offset) => offset + 1 + view.getUint8(offset);

  @override
  int endIn(ByteData view) => endAt(view, offset);

  static String readAt(ByteData view, int offset) =>
      String.fromCharCodes(Uint8List.sublistView(view, offset + 1, endAt(view, offset)));

  String read(ByteData view) => readAt(view, offset);

  @override
  String get typeName => 'pstr';
}

/// A run of bytes: [size] of them, or as many as [count] holds, or to the end of the payload.
final class Bytes extends Field {
  const Bytes(super.offset, {this.size, this.count, super.optional});

  @override
  final int? size;

  final Scalar? count;

  @override
  int endIn(ByteData view) => size != null ? end : offset + (count?.read(view) ?? view.lengthInBytes - offset);

  Uint8List read(ByteData view) => Uint8List.sublistView(view, offset, endIn(view));

  @override
  String get typeName => size == null ? 'u8[]' : 'u8[$size]';
}

/// Bytes whose role is not decoded, retained verbatim; to the end of the payload when [size]
/// is null.
final class Unknown extends Field {
  const Unknown(super.offset, {this.size, super.optional});

  @override
  final int? size;

  Uint8List read(ByteData view) => Uint8List.sublistView(view, offset, endIn(view));

  @override
  String get typeName => '';
}

/// A run of same-sized words: [length] of them, or as many as [count] holds, or to the end
/// of the payload.
sealed class WordList extends Field {
  const WordList(super.offset, {this.length, this.count, super.optional});

  final int? length;

  final Scalar? count;

  int get wordSize;

  @override
  int? get size => length == null ? null : length! * wordSize;

  int lengthIn(ByteData view) => length ?? count?.read(view) ?? (view.lengthInBytes - offset) ~/ wordSize;

  @override
  int endIn(ByteData view) => offset + lengthIn(view) * wordSize;

  int at(ByteData view, int index);

  List<int> read(ByteData view) => [for (var i = 0; i < lengthIn(view); i++) at(view, i)];

  String get _wordName;

  @override
  String get typeName => '$_wordName[${length ?? ''}]';
}

final class U16List extends WordList {
  const U16List(super.offset, {this.endian = Endian.big, super.length, super.count, super.optional});

  final Endian endian;

  @override
  int get wordSize => 2;

  @override
  int at(ByteData view, int index) => view.getUint16(offset + 2 * index, endian);

  @override
  String get _wordName => endian == Endian.big ? 'u16' : 'u16le';
}

final class U32List extends WordList {
  const U32List(super.offset, {this.endian = Endian.big, super.length, super.count, super.optional});

  final Endian endian;

  @override
  int get wordSize => 4;

  @override
  int at(ByteData view, int index) => view.getUint32(offset + 4 * index, endian);

  @override
  String get _wordName => endian == Endian.big ? 'u32' : 'u32le';
}

/// A run of [PackedWord]s: [length] of them, or as many as [count] holds, or to the end of the
/// payload.
final class PackedWordList extends Field {
  const PackedWordList(super.offset, {this.length, this.count, super.optional});

  final int? length;

  final Scalar? count;

  @override
  int? get size => null;

  @override
  String get typeName => 'packed[${length ?? ''}]';
}

/// Packed Pascal strings: [length] of them, or as many as [count] holds, or to the end of the
/// payload.
final class PStrList extends Field {
  const PStrList(super.offset, {this.length, this.count, super.optional});

  final int? length;

  final Scalar? count;

  @override
  int? get size => null;

  List<String> read(ByteData view) {
    final out = <String>[];
    final limit = length ?? count?.read(view);
    var at = offset;
    while (limit == null ? at < view.lengthInBytes : out.length < limit) {
      out.add(PStr.readAt(view, at));
      at = PStr.endAt(view, at);
    }
    return out;
  }

  @override
  String get typeName => 'pstr[${length ?? ''}]';
}

/// Repeated records in the [entry] layout, offsets relative to each entry: [length] of them,
/// or as many as [count] holds, or to the end of the payload.
final class Entries extends Field {
  const Entries(super.offset, this.entry, {this.length, this.count, super.optional});

  final ByteLayout entry;

  final int? length;

  final Scalar? count;

  @override
  int? get size => length == null
      ? null
      : switch (entry.size) {
          final int entrySize => length! * entrySize,
          null => null,
        };

  @override
  String get typeName => 'entry[${length ?? ''}]';
}

/// One record in the [entry] layout, offsets relative to the record.
final class Struct extends Field {
  const Struct(super.offset, this.entry, {super.optional});

  final ByteLayout entry;

  @override
  int? get size => entry.size;

  @override
  String get typeName => 'struct';
}

/// The fields of one record shape in offset order.
///
/// The fields before the first one the data sizes tile the record from offset 0; the offsets
/// of any fields after it are nominal.
final class ByteLayout {
  const ByteLayout(this.fields);

  final List<Field> fields;

  /// Whether the fields before the first data-sized one start at 0 and abut with no gap or
  /// overlap.
  bool get isContiguous {
    var at = 0;
    for (final field in fields) {
      if (field.offset != at) return false;
      if (field.size == null) return true;
      at = field.end;
    }
    return true;
  }

  /// The bytes every payload holds: the end of the last field that is neither optional nor
  /// after a data-sized one.
  int get minSize {
    var end = 0;
    for (final field in fields) {
      if (field.size == null) break;
      if (!field.optional) end = field.end;
    }
    return end;
  }

  /// The exact payload size when every field is fixed and required, else null.
  int? get size {
    var end = 0;
    for (final field in fields) {
      if (field.size == null || field.optional) return null;
      end = field.end;
    }
    return end;
  }

  /// Whether [length] bytes hold the layout: exactly [size] when it is fixed, else at least
  /// [minSize].
  bool fits(int length) => switch (size) {
    final int size => length == size,
    null => length >= minSize,
  };

  /// Whether the optional fields form the tail: once one field is optional, every later one
  /// is too, so a payload's length alone says which fields it holds.
  bool get optionalsTrail {
    var trailing = false;
    for (final field in fields) {
      if (field.optional) {
        trailing = true;
      } else if (trailing) {
        return false;
      }
    }
    return true;
  }

  /// Asserts that the layout [isContiguous], its [optionalsTrail], and [view] [fits] it.
  void check(ByteData view) {
    assert(isContiguous, 'the layout tiles its fixed prefix');
    assert(optionalsTrail, 'optional fields end the layout');
    assert(fits(view.lengthInBytes), 'a ${view.lengthInBytes}-byte payload holds the layout');
  }

  /// The bytes of [length] that [Unknown] fields cover.
  int unknownBytes(int length) {
    var total = 0;
    for (final field in fields) {
      if (field is! Unknown || field.offset >= length) continue;
      final end = field.size == null ? length : field.end;
      total += (end > length ? length : end) - field.offset;
    }
    return total;
  }
}

/// The identifier, spelled type and doc comment of a [Field], as `tool/gen_block_docs.dart`
/// reads them from the block file; [entry] documents the fields of an [Entries] or [Struct]
/// entry.
final class FieldDoc {
  const FieldDoc(this.name, this.type, this.doc, [this.entry = const []]);

  final String name;

  final String type;

  final String doc;

  final List<FieldDoc> entry;
}
