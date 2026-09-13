/// One row of a block's byte layout: the [size] bytes at [offset] hold [name].
///
/// Block files declare their rows as `const` values, read field offsets from
/// them, and list them in a [BlockLayout] that `tool/gen_block_docs.dart`
/// renders into the file's doc comment.
final class BlockField {
  const BlockField(this.offset, this.size, this.name, this.type, this.meaning, {this.optional, this.entry = const []});

  /// Bytes whose role is not decoded; retained verbatim. [type] may state the evident shape.
  const BlockField.undecoded(this.offset, this.size, {this.type = '', this.optional})
    : name = 'TODO',
      meaning = '',
      entry = const [];

  final int offset;

  /// Null when the field runs to the end of the payload.
  final int? size;

  final String name;

  /// `u8`, `u16`, `u32`, `i32`, `u16le`, `u32le`, `4cc`, `pstr`, `u8[16]`, `u32[]` and the like;
  /// big-endian unless suffixed `le`.
  final String type;

  final String meaning;

  /// The condition under which the field is present, e.g. `the record is 160 bytes`.
  final String? optional;

  /// For a repeated field, the rows of one entry with offsets relative to the entry start.
  final List<BlockField> entry;

  bool get isUndecoded => meaning.isEmpty;

  int get end => offset + size!;
}

typedef BlockLayout = List<BlockField>;
