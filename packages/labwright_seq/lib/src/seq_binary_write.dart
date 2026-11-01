/// Serialises a decoded `TOF1` body back to bytes.
///
/// The record region is re-emitted field by field from the record tree, so a decoded body writes back
/// byte-exactly; the pool is written from the model's string list, so renaming a string touches only its
/// pool entry while every record keeps referring to it by index.
library;

import 'dart:io';
import 'dart:typed_data';

import 'seq_binary.dart';
import 'seq_binary_grammar.dart';
import 'seq_property.dart';

/// A stored double of the record tree: its body offset, its value, and how to change it.
typedef BinaryF64Slot = ({int offset, double value, void Function(double) write});

final class BinarySeqWriteModel {
  BinarySeqWriteModel(this.body) : pool = List.of(body.pool), poolBytes = List.of(body.poolEntries);

  /// A write model for a `TOF1` file; throws [FormatException] as [decodeTof1] does.
  factory BinarySeqWriteModel.parse(Uint8List bytes) => BinarySeqWriteModel(decodeTof1(bytes));
  final Tof1Body body;

  /// Mutable copy of the pool; records reference entries by index.
  final List<String> pool;

  /// Each pool entry's original bytes; null once the entry has been replaced.
  final List<Uint8List?> poolBytes;
  int get recordRegionLength => body.recordRegionLength;

  /// Body byte range `(start, end)` of pool entry [index] in the written body, without its NUL.
  (int, int) poolEntryRange(int index) {
    var at = recordRegionLength + 4;
    for (var i = 0; i < index; i++) {
      at += _entryBytes(i).length + 1;
    }
    return (at, at + _entryBytes(index).length);
  }

  int replacePoolEntry(String from, String to) {
    var replaced = 0;
    for (var i = 0; i < pool.length; i++) {
      if (pool[i] != from) continue;
      pool[i] = to;
      poolBytes[i] = null;
      replaced++;
    }
    return replaced;
  }

  /// Every stored double in body order: `Num` values, `Nums` elements and `Enum` values.
  List<BinaryF64Slot> get f64Slots => [
    for (final record in body.records) ...[
      if (record.value case final double value)
        (offset: record.valueOffset, value: value, write: (v) => record.value = v),
      if (record.kind == SeqValueClass.numbers)
        for (final (i, element) in record.elements!.indexed)
          (offset: record.valueOffset + 8 * i, value: element! as double, write: (v) => record.elements![i] = v),
      if (record.enumValue case final value?)
        (offset: record.enumValueOffset, value: value, write: (v) => record.enumValue = v),
    ],
  ]..sort((a, b) => a.offset.compareTo(b.offset));

  /// Body offsets of every stored double equal to [value].
  List<int> f64Sites(double value) => [
    for (final slot in f64Slots)
      if (slot.value == value) slot.offset,
  ];

  /// Replaces every stored double equal to [from] with [to]; returns how many were replaced.
  int replaceF64(double from, double to) {
    final slots = [
      for (final slot in f64Slots)
        if (slot.value == from) slot,
    ];
    for (final slot in slots) {
      slot.write(to);
    }
    return slots.length;
  }

  /// The body: the record region from the record tree, then the pool, keeping an unterminated last string
  /// unterminated and any bytes after the pool.
  Uint8List writeBody() {
    final writer = _Tof1BodyWriter(body.generation)..body(body);
    final out = writer.out;
    for (var i = 0; i < pool.length; i++) {
      out.add(_entryBytes(i));
      if (i < pool.length - 1 || body.lastStringTerminated) out.addByte(0);
    }
    out.add(body.poolTail);
    return out.takeBytes();
  }

  Uint8List writeFile() {
    final written = writeBody();
    final deflated = zlib.encode(written);
    final out = Uint8List(Tof1Header.size + deflated.length)
      ..setAll(0, body.header.serialize())
      ..setAll(Tof1Header.size, deflated);
    Tof1Header.parse(out)!
      ..inflatedLength = written.length
      ..recordRegionLength = recordRegionLength;
    return out;
  }

  /// The Windows-1252 bytes of pool entry [index]; throws [ArgumentError] for a character the code page lacks.
  Uint8List _entryBytes(int index) =>
      poolBytes[index] ??
      encodeWindows1252(pool[index]) ??
      (throw ArgumentError('pool entry $index is not Windows-1252: ${pool[index]}'));
}

final class _Tof1BodyWriter {
  _Tof1BodyWriter(this.generation);
  final Tof1Generation generation;
  final out = BytesBuilder();
  final _word = Uint8List(8);
  late final _view = ByteData.sublistView(_word);
  void u8(int value) => out.addByte(value);
  void flag(bool value) => out.addByte(value ? 1 : 0);

  void u32(int value) {
    _view.setUint32(0, value, Endian.little);
    out.add(Uint8List.sublistView(_word, 0, 4));
  }

  void f64(double value) {
    _view.setFloat64(0, value, Endian.little);
    out.add(_word);
  }

  void i64(int value) {
    _view.setInt64(0, value, Endian.little);
    out.add(_word);
  }

  void body(Tof1Body body) {
    u32(body.types.length);
    body.types.forEach(typeEntry);
    record(body.data);
    u32(body.tailWord);
    u32(binaryNullIndex);
    u32(body.pool.length);
  }

  void typeEntry(BinaryTypeEntry type) {
    final root = type.root;
    u32(root.flags);
    u32(type.entryWord);
    u32(root.classIndex);
    u32(root.nameIndex);
    valuePart(root);
    if (root.has(BinaryPropertyFlag.comment)) u32(root.commentIndex);
    u32(type.category);
    u32(type.timestamp);
    if (generation.hasWideTimestamp) u32(0);
    u32(type.versionIndex);
    u32(type.lastModVersionIndex);
    u32(type.minProductVersionIndex);
    if (type.typeFlags case final flags?) u32(flags);
    attributeWords(root);
    if (generation.hasProtectionBlock) {
      u32(type.isProtected ? 1 : 0);
      u32(type.protectionDigestIndex);
      u32(type.hasSecondaryDigest ? 1 : 0);
      if (type.hasSecondaryDigest) u32(type.secondaryDigestIndex);
    }
    blocks(root);
    children(root);
    u32(type.additionalTypeFlags);
    flag(type.alwaysSaveType);
    u32(type.orderNumber);
  }

  void record(BinaryRecord r) {
    u32(r.flags);
    u32(0);
    u32(r.classIndex);
    if (r.typeRef case final typeRef?) u32(typeRef);
    u32(r.nameIndex);
    valuePart(r);
    if (r.has(BinaryPropertyFlag.comment)) u32(r.commentIndex);
    attributeWords(r);
    blocks(r);
    children(r);
  }

  void valuePart(BinaryRecord r) {
    if (r.isArray) {
      u32(r.lboundIndex);
      u32(r.uboundIndex);
      if (r.kind == SeqValueClass.objects || r.kind == SeqValueClass.containers) {
        flag(r.hasElemProto);
        if (r.elemProto case final proto?) record(proto);
      }
      if (r.kind == SeqValueClass.strings) return r.elementIndices!.forEach(u32);
      for (final element in r.elements!) {
        switch (element) {
          case final BinaryRecord element:
            record(element);
          case final double element:
            f64(element);
          case final bool element:
            flag(element);
        }
      }
      return;
    }
    switch (r.kind) {
      case SeqValueClass.enumeration:
        if (r.has(BinaryPropertyFlag.enumItems)) {
          u32(r.enumItemsWord!);
          record(r.enumItems!);
        }
        if (r.has(BinaryPropertyFlag.enumValue)) {
          u32(r.enumValueIndex);
          f64(r.enumValue!);
        }
      case SeqValueClass.number:
        if (r.representation case final representation?) u32(representation);
        switch (r.value) {
          case final double value:
            f64(value);
          case final int value:
            i64(value);
        }
      case SeqValueClass.string || SeqValueClass.expression || SeqValueClass.path:
        if (r.has(BinaryPropertyFlag.value)) u32(r.valueIndex);
      case SeqValueClass.boolean:
        if (r.value case final bool value) flag(value);
      default:
        break;
    }
  }

  void attributeWords(BinaryRecord r) {
    if (r.has(BinaryPropertyFlag.numericFormat)) u32(r.formatIndex);
    if (r.flagsForInstances case final word?) u32(word);
    if (r.instanceOverrideFlags case final word?) u32(word);
    if (r.valueFlagsWord case final word?) u32(word);
  }

  void blocks(BinaryRecord r) {
    if (r.has(BinaryPropertyFlag.extData)) {
      u32(r.extData.length);
      for (final entry in r.extData) {
        u32(entry.controllerIndex);
        flag(entry.allowPassing);
        if (entry.controller == ExtDataController.struct) u32(entry.packingOption!);
        flag(entry.exclude);
        if (entry.controller != ExtDataController.struct) {
          u32(entry.memberIndex);
          continue;
        }
        for (final word in [entry.type, entry.arrayStorage, entry.strBufferSize, entry.strStorage]) {
          u32(word!);
        }
      }
    }
    if (r.attributes case final block?) record(block);
    if (r.typeAttributes case final block?) record(block);
  }

  void children(BinaryRecord r) {
    u32(r.children.length);
    r.children.forEach(record);
  }
}
