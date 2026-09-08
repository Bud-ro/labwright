import 'dart:convert';
import 'dart:typed_data';

import 'format.dart';
import 'model.dart';

class TdmsWriter {
  final BytesBuilder _output = BytesBuilder();

  void writeSegment(
    Iterable<TdmsChannel> channels, {
    Map<String, Object> fileProperties = const {},
    Map<String, Map<String, Object>> groupProperties = const {},
  }) {
    final channelList = channels.toList();
    final groupNames = {for (final channel in channelList) channel.group}.toList();

    final metadata = BytesBuilder();
    _writeU32(metadata, 1 + groupNames.length + channelList.length);

    _writeString(metadata, '/');
    _writeU32(metadata, noRawDataIndex);
    _writeProperties(metadata, fileProperties);

    for (final groupName in groupNames) {
      _writeString(metadata, _groupObjectPath(groupName));
      _writeU32(metadata, noRawDataIndex);
      _writeProperties(metadata, groupProperties[groupName] ?? const {});
    }

    for (final channel in channelList) {
      if (channel.type == TdsType.string || channel.type == TdsType.boolean || channel.type == TdsType.timestamp) {
        throw ArgumentError('TdmsWriter cannot write channel type ${channel.type}');
      }
      _writeString(metadata, _channelObjectPath(channel.group, channel.name));
      _writeU32(metadata, plainRawDataIndexByteLength);
      _writeU32(metadata, channel.type.code);
      _writeU32(metadata, channelArrayDimension);
      _writeU64(metadata, channel.data.length);
      _writeProperties(metadata, channel.properties);
    }

    final rawData = BytesBuilder();
    for (final channel in channelList) {
      for (final value in channel.data) {
        _writeSample(rawData, channel.type, value);
      }
    }

    final metadataBytes = metadata.toBytes();
    final rawDataBytes = rawData.toBytes();

    _writeU32(_output, leadInTagTdsm);
    _writeU32(_output, TocFlag.metaData.mask | TocFlag.newObjList.mask | TocFlag.rawData.mask);
    _writeU32(_output, tdmsFormatVersion);
    _writeU64(_output, metadataBytes.length + rawDataBytes.length);
    _writeU64(_output, metadataBytes.length);
    _output.add(metadataBytes);
    _output.add(rawDataBytes);
  }

  Uint8List toBytes() => _output.toBytes();
}

void _writeU32(BytesBuilder out, int value) {
  final encoded = ByteData(4)..setUint32(0, value, Endian.little);
  out.add(encoded.buffer.asUint8List());
}

void _writeU64(BytesBuilder out, int value) {
  final encoded = ByteData(8)..setUint64(0, value, Endian.little);
  out.add(encoded.buffer.asUint8List());
}

void _writeI64(BytesBuilder out, int value) {
  final encoded = ByteData(8)..setInt64(0, value, Endian.little);
  out.add(encoded.buffer.asUint8List());
}

void _writeF64(BytesBuilder out, double value) {
  final encoded = ByteData(8)..setFloat64(0, value, Endian.little);
  out.add(encoded.buffer.asUint8List());
}

void _writeString(BytesBuilder out, String text) {
  final utf8Bytes = utf8.encode(text);
  _writeU32(out, utf8Bytes.length);
  out.add(utf8Bytes);
}

void _writeSample(BytesBuilder out, TdsType type, double value) {
  final encoded = ByteData(8);
  switch (type) {
    case TdsType.i8:
      encoded.setInt8(0, value.toInt());
      out.add(encoded.buffer.asUint8List(0, 1));
    case TdsType.u8:
      encoded.setUint8(0, value.toInt());
      out.add(encoded.buffer.asUint8List(0, 1));
    case TdsType.i16:
      encoded.setInt16(0, value.toInt(), Endian.little);
      out.add(encoded.buffer.asUint8List(0, 2));
    case TdsType.u16:
      encoded.setUint16(0, value.toInt(), Endian.little);
      out.add(encoded.buffer.asUint8List(0, 2));
    case TdsType.i32:
      encoded.setInt32(0, value.toInt(), Endian.little);
      out.add(encoded.buffer.asUint8List(0, 4));
    case TdsType.u32:
      encoded.setUint32(0, value.toInt(), Endian.little);
      out.add(encoded.buffer.asUint8List(0, 4));
    case TdsType.i64:
      encoded.setInt64(0, value.toInt(), Endian.little);
      out.add(encoded.buffer.asUint8List(0, 8));
    case TdsType.u64:
      encoded.setUint64(0, value.toInt(), Endian.little);
      out.add(encoded.buffer.asUint8List(0, 8));
    case TdsType.singleFloat:
      encoded.setFloat32(0, value, Endian.little);
      out.add(encoded.buffer.asUint8List(0, 4));
    case TdsType.doubleFloat:
      encoded.setFloat64(0, value, Endian.little);
      out.add(encoded.buffer.asUint8List(0, 8));
    case TdsType.string:
    case TdsType.boolean:
    case TdsType.timestamp:
      throw ArgumentError('TdmsWriter cannot write channel type $type');
  }
}

void _writeProperties(BytesBuilder out, Map<String, Object> properties) {
  _writeU32(out, properties.length);
  properties.forEach((name, value) => _writeProperty(out, name, value));
}

void _writeProperty(BytesBuilder out, String name, Object value) {
  _writeString(out, name);
  switch (value) {
    case final String text:
      _writeU32(out, TdsType.string.code);
      _writeString(out, text);
    case final bool flag:
      _writeU32(out, TdsType.boolean.code);
      out.addByte(flag ? 1 : 0);
    case final int number:
      _writeU32(out, TdsType.i64.code);
      _writeI64(out, number);
    case final double number:
      _writeU32(out, TdsType.doubleFloat.code);
      _writeF64(out, number);
    default:
      throw ArgumentError('Unsupported TDMS property type: ${value.runtimeType}');
  }
}

String _escapeQuotes(String name) => name.replaceAll("'", "''");
String _groupObjectPath(String group) => "/'${_escapeQuotes(group)}'";
String _channelObjectPath(String group, String channel) => "/'${_escapeQuotes(group)}'/'${_escapeQuotes(channel)}'";
