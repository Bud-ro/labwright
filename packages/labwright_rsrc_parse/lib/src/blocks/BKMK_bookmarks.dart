/// `BKMK` - Bookmarks: [ViBookmarkList]
///
/// Two counted tables of text entries, the first with an extra word per entry; their roles
/// are not decoded.
///
/// ```text
/// offset  size       field      type                     meaning
/// 0       4          countA     u32                      Entries in table A.
/// 4       …          tableA     ViBookmarkEntryA[countA]
///   +0    4          wordA      u32                      Role TODO.
///   +4    4          wordB      u32                      Role TODO.
///   +8    4          textLength u32
///   +12   textLength text       u8[textLength]
/// …       4          countB     u32                      Entries in table B, after table A.
/// …       …          tableB     ViBookmarkEntryB[countB]
///   +0    4          wordB      u32                      Role TODO.
///   +4    4          textLength u32
///   +8    textLength text       u8[textLength]
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViBookmarkList extends ByteRecord {
  ViBookmarkList(Uint8List bytes) : super(bytes, layout) {
    var at = _tableA.offset;
    final a = <ViBookmarkEntryA>[];
    for (var i = _countA.read(view); i > 0; i--) {
      final entry = ViBookmarkEntryA.at(view, at);
      a.add(entry);
      at += ViBookmarkEntryA.layout.minSize + entry.text.length;
    }
    tableA = a;
    assert(at + _countB.size <= view.lengthInBytes, 'table B has a count');
    final countB = view.getUint32(at);
    at += _countB.size;
    final b = <ViBookmarkEntryB>[];
    for (var i = countB; i > 0; i--) {
      final entry = ViBookmarkEntryB.at(view, at);
      b.add(entry);
      at += ViBookmarkEntryB.layout.minSize + entry.text.length;
    }
    tableB = b;
    assert(at == view.lengthInBytes, 'the two tables tile the payload');
  }

  late final List<ViBookmarkEntryA> tableA;

  late final List<ViBookmarkEntryB> tableB;

  bool get isEmpty => tableA.isEmpty && tableB.isEmpty;

  /// The two tables of the given entries.
  static Uint8List encode({
    required List<({int wordA, int wordB, List<int> text})> tableA,
    required List<({int wordB, List<int> text})> tableB,
  }) {
    var length = _tableA.offset + _countB.size;
    for (final entry in tableA) {
      length += ViBookmarkEntryA.layout.minSize + entry.text.length;
    }
    for (final entry in tableB) {
      length += ViBookmarkEntryB.layout.minSize + entry.text.length;
    }
    final out = Uint8List(length);
    _countA.write(ByteData.sublistView(out), tableA.length);
    var at = _tableA.offset;
    for (final (:wordA, :wordB, :text) in tableA) {
      final entry = ByteData.sublistView(out, at);
      ViBookmarkEntryA._wordA.write(entry, wordA);
      ViBookmarkEntryA._wordB.write(entry, wordB);
      ViBookmarkEntryA._textLength.write(entry, text.length);
      ViBookmarkEntryA._text.write(entry, text);
      at += ViBookmarkEntryA.layout.minSize + text.length;
    }
    _countB.write(ByteData.sublistView(out, at - _countB.offset), tableB.length);
    at += _countB.size;
    for (final (:wordB, :text) in tableB) {
      final entry = ByteData.sublistView(out, at);
      ViBookmarkEntryB._wordB.write(entry, wordB);
      ViBookmarkEntryB._textLength.write(entry, text.length);
      ViBookmarkEntryB._text.write(entry, text);
      at += ViBookmarkEntryB.layout.minSize + text.length;
    }
    return out;
  }

  static const _countA = U32(0); // Entries in table A.
  static const _tableA = Entries(4, ViBookmarkEntryA.layout, count: _countA);
  static const _countB = U32(4); // Entries in table B, after table A.
  static const _tableB = Entries(8, ViBookmarkEntryB.layout, count: _countB);

  static const layout = ByteLayout([_countA, _tableA, _countB, _tableB]);
}

/// One entry of table A.
final class ViBookmarkEntryA {
  const ViBookmarkEntryA(this.wordA, this.wordB, this.text);

  /// The entry starting at [at] in [view].
  factory ViBookmarkEntryA.at(ByteData view, int at) {
    assert(at + layout.minSize <= view.lengthInBytes, 'the entry has its words and length');
    final entry = ByteData.sublistView(view, at);
    assert(_text.endIn(entry) <= entry.lengthInBytes, 'the text fits the payload');
    return ViBookmarkEntryA(_wordA.read(entry), _wordB.read(entry), _text.read(entry));
  }

  final int wordA;

  final int wordB;

  final Uint8List text;

  static const _wordA = U32(0); // Role TODO.
  static const _wordB = U32(4); // Role TODO.
  static const _textLength = U32(8);
  static const _text = Bytes(12, count: _textLength);

  static const layout = ByteLayout([_wordA, _wordB, _textLength, _text]);
}

/// One entry of table B.
final class ViBookmarkEntryB {
  const ViBookmarkEntryB(this.wordB, this.text);

  /// The entry starting at [at] in [view].
  factory ViBookmarkEntryB.at(ByteData view, int at) {
    assert(at + layout.minSize <= view.lengthInBytes, 'the entry has its word and length');
    final entry = ByteData.sublistView(view, at);
    assert(_text.endIn(entry) <= entry.lengthInBytes, 'the text fits the payload');
    return ViBookmarkEntryB(_wordB.read(entry), _text.read(entry));
  }

  final int wordB;

  final Uint8List text;

  static const _wordB = U32(0); // Role TODO.
  static const _textLength = U32(4);
  static const _text = Bytes(8, count: _textLength);

  static const layout = ByteLayout([_wordB, _textLength, _text]);
}
