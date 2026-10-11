/// `CCST` - Conditional-Compilation Symbols: [ViConditionalSymbols]
///
/// The conditional-compilation symbols a VI was saved against, each name paired with its value:
/// LabVIEW's own `TARGET_TYPE`, `TARGET_BITNESS`, `RUN_TIME_ENGINE` and `OS`, or ones a project
/// defines. All the names come first, then the values in the same order; the table is usually
/// empty.
///
/// ```text
/// offset  size   field    type              meaning
/// 0       4      count    u32               Number of symbols.
/// 4       …      names    CcstString[count] The symbol names.
///   +0    4      length   u32
///   +4    length text     u8[length]
/// …       …      values   CcstString[count] The values, after every name, in name order.
///   +0    4      length   u32
///   +4    length text     u8[length]
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViConditionalSymbols extends ByteRecord {
  ViConditionalSymbols(Uint8List bytes) : super(bytes, layout) {
    final count = _count.read(view);
    assert(
      count <= (view.lengthInBytes - _names.offset) ~/ (2 * CcstString.layout.minSize),
      'the count fits the payload',
    );
    final strings = <String>[];
    var at = _names.offset;
    for (var i = 0; i < 2 * count; i++) {
      assert(at + CcstString.layout.minSize <= view.lengthInBytes, 'string $i has a length word');
      final end = at + CcstString.layout.minSize + view.getUint32(at + CcstString.length.offset);
      assert(end <= view.lengthInBytes, 'string $i fits the payload');
      strings.add(utf8.decode(Uint8List.sublistView(view, at + CcstString.text.offset, end), allowMalformed: true));
      at = end;
    }
    assert(at == view.lengthInBytes, 'the names and values tile the payload');
    names = strings.sublist(0, count);
    values = strings.sublist(count);
  }

  /// The symbol names, in table order.
  late final List<String> names;

  /// The symbols' values, in [names] order.
  late final List<String> values;

  Map<String, String> get symbols => {for (var i = 0; i < names.length; i++) names[i]: values[i]};

  static const _count = U32(0); // Number of symbols.
  static const _names = Entries(4, CcstString.layout, count: _count); // The symbol names.
  static const _values = Entries(8, CcstString.layout, count: _count); // The values, after every name, in name order.

  static const layout = ByteLayout([_count, _names, _values]);
}

/// One length-prefixed string.
abstract final class CcstString {
  static const length = U32(0);
  static const text = Bytes(4, count: length);

  static const layout = ByteLayout([length, text]);
}
