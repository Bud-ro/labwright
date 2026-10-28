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
import 'seq_binary_header.dart';
import 'seq_binary_text.dart';
import 'seq_property.dart';

final class BinarySeqWriteModel {
  BinarySeqWriteModel._({
    required this.header,
    required this.body,
    required this.pool,
    required this.poolBytes,
  });

  /// The file bytes before the zlib stream.
  final Uint8List header;

  final Tof1Body body;

  /// Mutable copy of the pool; records reference entries by index.
  final List<String> pool;

  /// Each pool entry's original bytes; null once the entry has been replaced.
  final List<Uint8List?> poolBytes;

  Tof1Generation get generation => body.generation;

  int get recordRegionLength => body.recordRegionLength;

  /// Body byte range `(start, end)` of pool entry [index] in the written body, without its NUL.
  (int, int) poolEntryRange(int index) {
    var at = body.recordRegionLength + 4;
    for (var i = 0; i < index; i++) {
      at += _entryBytes(i).length + 1;
    }
    return (at, at + _entryBytes(index).length);
  }

  int replacePoolEntry(String from, String to) {
    var replaced = 0;
    for (var i = 0; i < pool.length; i++) {
      if (pool[i] == from) {
        pool[i] = to;
        poolBytes[i] = null;
        replaced++;
      }
    }
    return replaced;
  }

  /// Body offsets of every stored double equal to [value]: `Num` values, `Nums` elements and `Enum` values.
  List<int> f64Sites(double value) => [
    for (final slot in _f64Slots())
      if (slot.value == value) slot.offset,
  ];

  /// Replaces every stored double equal to [from] with [to]; returns how many were replaced.
  int replaceF64(double from, double to) {
    var replaced = 0;
    for (final slot in _f64Slots()) {
      if (slot.value == from) {
        slot.write(to);
        replaced++;
      }
    }
    return replaced;
  }

  /// Every stored double in body order: `Num` values, `Nums` elements and `Enum` values.
  List<double> get f64Values => [for (final slot in _f64Slots()) slot.value];

  List<_F64Slot> _f64Slots() {
    final slots = <_F64Slot>[];
    _walk(body, (record) {
      final value = record.value;
      if (value is double) {
        slots.add(_F64Slot(record.valueOffset, value, (v) => record.value = v));
      }
      if (record.kind == SeqValueClass.numbers) {
        final elements = record.elements!;
        for (var i = 0; i < elements.length; i++) {
          slots.add(_F64Slot(record.valueOffset + 8 * i, elements[i]! as double, (v) => elements[i] = v));
        }
      }
      final enumValue = record.enumValue;
      if (enumValue != null) {
        slots.add(_F64Slot(record.enumValueOffset, enumValue, (v) => record.enumValue = v));
      }
    });
    slots.sort((a, b) => a.offset.compareTo(b.offset));
    return slots;
  }

  /// The body: the record region from the record tree, then the pool, keeping an unterminated last string
  /// unterminated and any bytes after the pool.
  Uint8List writeBody() {
    final out = _ByteSink(body.bytes.length + 64);
    _Tof1BodyWriter(out, generation).body(body);
    for (var i = 0; i < pool.length; i++) {
      out.bytes(_entryBytes(i));
      if (i < pool.length - 1 || body.lastStringTerminated) out.u8(0);
    }
    out.bytes(body.poolTail);
    return out.take();
  }

  Uint8List writeFile() {
    final written = writeBody();
    final deflated = ZLibCodec().encode(written);
    final compressed = deflated is Uint8List ? deflated : Uint8List.fromList(deflated);
    final out = Uint8List(header.length + compressed.length);
    out.setRange(0, header.length, header);
    final view = ByteData.sublistView(out);
    view.setUint32(Tof1HeaderField.inflatedLength.offset, written.length, Endian.little);
    view.setUint32(Tof1HeaderField.recordRegionLength.offset, body.recordRegionLength, Endian.little);
    out.setRange(header.length, out.length, compressed);
    return out;
  }

  /// The Windows-1252 bytes of pool entry [index]; throws [ArgumentError] for a character the code page lacks.
  Uint8List _entryBytes(int index) {
    final original = poolBytes[index];
    if (original != null) return original;
    final encoded = encodeWindows1252(pool[index]);
    if (encoded == null) throw ArgumentError('pool entry $index is not Windows-1252: ${pool[index]}');
    return encoded;
  }

  static void _walk(Tof1Body body, void Function(BinaryRecord) visit) {
    for (final type in body.types) {
      _walkRecord(type.root, visit);
    }
    _walkRecord(body.data, visit);
  }

  static void _walkRecord(BinaryRecord record, void Function(BinaryRecord) visit) {
    visit(record);
    final proto = record.elemProto;
    if (proto != null) _walkRecord(proto, visit);
    for (final element in record.elements ?? const <Object?>[]) {
      if (element is BinaryRecord) _walkRecord(element, visit);
    }
    final items = record.enumItems;
    if (items != null) _walkRecord(items, visit);
    for (final block in [record.attributes, record.typeAttributes]) {
      if (block != null) _walkRecord(block, visit);
    }
    for (final child in record.children) {
      _walkRecord(child, visit);
    }
  }
}

/// A write model for a `TOF1` file; null when the body does not inflate or leaves the grammar.
BinarySeqWriteModel? parseBinarySeqWriteModel(Uint8List seqBytes) {
  final decode = decodeTof1(seqBytes);
  final grammar = decode?.grammar;
  if (decode == null || grammar == null) return null;
  final poolBytes = <Uint8List?>[];
  for (var i = 0; i < grammar.pool.length; i++) {
    final start = grammar.poolOffsets[i];
    var end = start;
    while (end < grammar.bytes.length && grammar.bytes[end] != 0) {
      end++;
    }
    poolBytes.add(Uint8List.sublistView(grammar.bytes, start, end));
  }
  return BinarySeqWriteModel._(
    header: Uint8List.sublistView(seqBytes, 0, Tof1HeaderField.body.offset),
    body: grammar,
    pool: List.of(grammar.pool),
    poolBytes: poolBytes,
  );
}

/// A stored double of the record tree: where it sits in the body and how to change it.
final class _F64Slot {
  _F64Slot(this.offset, this.value, this.write);

  final int offset;

  final double value;

  final void Function(double) write;
}

/// An append-only little-endian byte buffer.
final class _ByteSink {
  _ByteSink(int capacity) : this._(Uint8List(capacity));

  _ByteSink._(Uint8List buffer) : _buffer = buffer, _view = ByteData.sublistView(buffer);

  Uint8List _buffer;

  ByteData _view;

  int length = 0;

  void _reserve(int more) {
    if (length + more <= _buffer.length) return;
    var capacity = _buffer.length * 2;
    while (capacity < length + more) {
      capacity *= 2;
    }
    final grown = Uint8List(capacity)..setRange(0, length, _buffer);
    _buffer = grown;
    _view = ByteData.sublistView(grown);
  }

  void u8(int value) {
    _reserve(1);
    _buffer[length++] = value;
  }

  void u32(int value) {
    _reserve(4);
    _view.setUint32(length, value, Endian.little);
    length += 4;
  }

  void f64(double value) {
    _reserve(8);
    _view.setFloat64(length, value, Endian.little);
    length += 8;
  }

  void i64(int value) {
    _reserve(8);
    _view.setInt64(length, value, Endian.little);
    length += 8;
  }

  void bytes(Uint8List data) {
    _reserve(data.length);
    _buffer.setRange(length, length + data.length, data);
    length += data.length;
  }

  Uint8List take() => Uint8List.sublistView(_buffer, 0, length);
}

final class _Tof1BodyWriter {
  _Tof1BodyWriter(this.out, this.generation);

  final _ByteSink out;

  final Tof1Generation generation;

  void u32(int value) => out.u32(value);

  void u8(int value) => out.u8(value);

  void f64(double value) => out.f64(value);

  void i64(int value) => out.i64(value);

  void body(Tof1Body body) {
    u32(body.types.length);
    for (final type in body.types) {
      typeEntry(type);
    }
    record(body.data);
    u32(body.tailWord);
    u32(binaryNullIndex);
    u32(body.pool.length);
  }

  void typeEntry(BinaryTypeEntry type) {
    final root = type.root;
    u32(type.entryFlags);
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
    if (root.has(BinaryPropertyFlag.extData)) extData(root.extData);
    if (root.attributes case final block?) record(block);
    if (root.typeAttributes case final block?) record(block);
    children(root);
    u32(type.additionalTypeFlags);
    u8(type.alwaysSaveType ? 1 : 0);
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
    if (r.has(BinaryPropertyFlag.extData)) extData(r.extData);
    if (r.attributes case final block?) record(block);
    if (r.typeAttributes case final block?) record(block);
    children(r);
  }

  void valuePart(BinaryRecord r) {
    if (r.isArray) {
      u32(r.lboundIndex);
      u32(r.uboundIndex);
      if (r.kind == SeqValueClass.objects || r.kind == SeqValueClass.containers) {
        u8(r.hasElemProto ? 1 : 0);
        if (r.elemProto case final proto?) record(proto);
      }
      final elements = r.elements ?? const <Object?>[];
      final indices = r.elementIndices;
      for (var i = 0; i < elements.length; i++) {
        switch (elements[i]) {
          case final BinaryRecord element:
            record(element);
          case final double element:
            f64(element);
          case final bool element:
            u8(element ? 1 : 0);
          case final int element:
            u32(element);
          default:
            u32(indices == null ? binaryNullIndex : indices[i]);
        }
      }
      return;
    }
    if (r.isEnum) {
      if (r.has(BinaryPropertyFlag.enumItems)) {
        u32(r.enumItemsWord ?? 1);
        record(r.enumItems!);
      }
      if (r.has(BinaryPropertyFlag.enumValue)) {
        u32(r.enumValueIndex);
        f64(r.enumValue ?? 0);
      }
      return;
    }
    switch (r.kind) {
      case SeqValueClass.number:
        if (r.has(BinaryPropertyFlag.numericRepresentation)) u32(r.representation ?? 0);
        if (r.has(BinaryPropertyFlag.value)) {
          switch (r.value) {
            case final double value:
              f64(value);
            case final int value:
              i64(value);
            default:
              f64(0);
          }
        }
      case SeqValueClass.string || SeqValueClass.expression || SeqValueClass.path:
        if (r.has(BinaryPropertyFlag.value)) u32(r.valueIndex);
      case SeqValueClass.boolean:
        if (r.has(BinaryPropertyFlag.value)) u8(r.value == true ? 1 : 0);
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

  void extData(List<BinaryExtData> entries) {
    u32(entries.length);
    for (final entry in entries) {
      u32(entry.controllerIndex);
      switch (entry.controller) {
        case ExtDataController.struct:
          u8(entry.allowPassing ? 1 : 0);
          u32(entry.packingOption ?? 0);
          u8(entry.exclude ? 1 : 0);
          u32(entry.type ?? 0);
          u32(entry.arrayStorage ?? 0);
          u32(entry.strBufferSize ?? 0);
          u32(entry.strStorage ?? 0);
        case ExtDataController.cluster || ExtDataController.lvCluster || ExtDataController.dotNetStruct:
          u8(entry.allowPassing ? 1 : 0);
          u8(entry.exclude ? 1 : 0);
          u32(entry.memberIndex);
      }
    }
  }

  void children(BinaryRecord r) {
    u32(r.children.length);
    for (final child in r.children) {
      record(child);
    }
  }
}
