import 'dart:convert';
import 'dart:typed_data';

import 'format.dart';
import 'model.dart';

const double _twoPow64 = 18446744073709551616.0;
double _u64AsDouble(int value) => value >= 0 ? value.toDouble() : value + _twoPow64;

abstract final class TdmsReader {
  static TdmsFile read(Uint8List bytes) {
    final cursor = _ByteCursor(bytes);
    final objectsByPath = <String, _ObjectState>{};
    final pathOrder = <String>[];
    final activeObjects = <_ObjectState>[];

    while (cursor.remaining >= leadInByteLength) {
      cursor.endian = Endian.little;
      if (cursor.u32() != leadInTagTdsm) break;
      final tocMask = cursor.u32();
      cursor.endian = TocFlag.bigEndian.isSetIn(tocMask) ? Endian.big : Endian.little;
      cursor.u32(); // format version
      final nextSegmentOffset = cursor.u64();
      final rawDataOffset = cursor.u64();
      if (nextSegmentOffset < 0 || rawDataOffset < 0 || rawDataOffset > nextSegmentOffset) {
        throw TdmsFormatException('invalid segment offsets (next=$nextSegmentOffset raw=$rawDataOffset)');
      }
      final segmentBodyStart = cursor.position;

      if (TocFlag.metaData.isSetIn(tocMask)) {
        if (TocFlag.newObjList.isSetIn(tocMask)) activeObjects.clear();
        final objectCount = cursor.u32();
        for (var i = 0; i < objectCount; i++) {
          final path = cursor.string();
          final object = objectsByPath.putIfAbsent(path, () {
            pathOrder.add(path);
            return _ObjectState();
          });
          final rawDataIndex = cursor.u32();
          var carriesRawData = true;
          if (rawDataIndex == noRawDataIndex) {
            carriesRawData = false;
          } else if (rawDataIndex == sameLayoutAsPreviousIndex) {
          } else if (rawDataIndex == daqmxFormatChangingIndex || rawDataIndex == daqmxDigitalLineIndex) {
            _readDaqmxRawDataIndex(cursor, object);
          } else {
            final dataTypeCode = cursor.u32();
            cursor.u32(); // array dimension
            final valueCount = cursor.u64();
            if (dataTypeCode == TdsType.string.code) {
              cursor.u64(); // total byte size of the string data
            }
            object
              ..dataTypeCode = dataTypeCode
              ..valueCount = valueCount
              ..isDaqmx = false;
          }
          final propertyCount = cursor.u32();
          for (var i = 0; i < propertyCount; i++) {
            final propertyName = cursor.string();
            final propertyTypeCode = cursor.u32();
            final propertyValue = _readPropertyValue(cursor, propertyTypeCode);
            if (propertyValue != null) object.properties[propertyName] = propertyValue;
          }
          if (carriesRawData && !activeObjects.contains(object)) activeObjects.add(object);
        }
      }

      if (TocFlag.rawData.isSetIn(tocMask)) {
        final rawDataStart = segmentBodyStart + rawDataOffset;
        final rawDataLength = nextSegmentOffset - rawDataOffset;
        if (activeObjects.any((object) => object.isDaqmx)) {
          _readDaqmxSamples(
            cursor,
            [
              for (final object in activeObjects)
                if (object.isDaqmx) object,
            ],
            rawDataStart,
            rawDataLength,
          );
        } else if (TocFlag.interleaved.isSetIn(tocMask)) {
          _readInterleavedSamples(cursor, activeObjects);
        } else {
          for (final object in activeObjects) {
            _readContiguousSamples(cursor, object);
          }
        }
      }

      cursor.position = segmentBodyStart + nextSegmentOffset;
    }

    return _assembleFile(objectsByPath, pathOrder);
  }

  static TdmsFile _assembleFile(Map<String, _ObjectState> objectsByPath, List<String> pathOrder) {
    final rootProperties = objectsByPath['/']?.properties ?? <String, Object>{};
    final groupOrder = <String>[];
    final groupProperties = <String, Map<String, Object>>{};
    final channelsByGroup = <String, List<TdmsChannelData>>{};

    void ensureGroup(String groupName) {
      if (!channelsByGroup.containsKey(groupName)) {
        channelsByGroup[groupName] = [];
        groupOrder.add(groupName);
      }
    }

    for (final path in pathOrder) {
      if (path == '/') continue;
      final names = _parseObjectPath(path);
      if (names.length == 1) {
        ensureGroup(names[0]);
        groupProperties[names[0]] = objectsByPath[path]!.properties;
      } else if (names.length == 2) {
        final groupName = names[0];
        ensureGroup(groupName);
        final object = objectsByPath[path]!;
        channelsByGroup[groupName]!.add(TdmsChannelData(groupName, names[1], object.properties, object.samples));
      }
    }

    return TdmsFile(rootProperties, [
      for (final groupName in groupOrder)
        TdmsGroup(
          groupName,
          groupProperties[groupName] ?? <String, Object>{},
          channelsByGroup[groupName]!,
        ),
    ]);
  }
}

class _ObjectState {
  int dataTypeCode = 0;
  int valueCount = 0;

  final Map<String, Object> properties = {};
  final List<double> samples = [];
  bool isDaqmx = false;
  int daqmxBufferIndex = 0;
  int daqmxByteOffset = 0;
  int daqmxStrideBytes = 0;
}

class _ByteCursor {
  _ByteCursor(this._bytes) : _byteData = ByteData.sublistView(_bytes);
  final Uint8List _bytes;
  final ByteData _byteData;
  int position = 0;
  Endian endian = Endian.little;

  int get remaining => _bytes.length - position;
  int get length => _bytes.length;
  int intAt(int at, int width) {
    if (at < 0 || at + width > _bytes.length) {
      throw TdmsFormatException('read past end of data at $at');
    }
    switch (width) {
      case 1:
        return _byteData.getInt8(at);
      case 2:
        return _byteData.getInt16(at, endian);
      case 4:
        return _byteData.getInt32(at, endian);
      case 8:
        return _byteData.getInt64(at, endian);
      default:
        throw TdmsFormatException('unsupported DAQmx element width $width');
    }
  }

  void _need(int count) {
    if (count < 0 || position + count > _bytes.length) {
      throw TdmsFormatException('unexpected end of data: need $count byte(s) at offset $position of ${_bytes.length}');
    }
  }

  void skip(int count) {
    _need(count);
    position += count;
  }

  int i8() {
    _need(1);
    final value = _byteData.getInt8(position);
    position += 1;
    return value;
  }

  int u8() {
    _need(1);
    final value = _byteData.getUint8(position);
    position += 1;
    return value;
  }

  int i16() {
    _need(2);
    final value = _byteData.getInt16(position, endian);
    position += 2;
    return value;
  }

  int u16() {
    _need(2);
    final value = _byteData.getUint16(position, endian);
    position += 2;
    return value;
  }

  int i32() {
    _need(4);
    final value = _byteData.getInt32(position, endian);
    position += 4;
    return value;
  }

  int u32() {
    _need(4);
    final value = _byteData.getUint32(position, endian);
    position += 4;
    return value;
  }

  int i64() {
    _need(8);
    final value = _byteData.getInt64(position, endian);
    position += 8;
    return value;
  }

  int u64() {
    _need(8);
    final value = _byteData.getUint64(position, endian);
    position += 8;
    return value;
  }

  double f32() {
    _need(4);
    final value = _byteData.getFloat32(position, endian);
    position += 4;
    return value;
  }

  double f64() {
    _need(8);
    final value = _byteData.getFloat64(position, endian);
    position += 8;
    return value;
  }

  double timestamp1904Seconds() {
    final fractions = u64();
    final seconds = i64();
    return seconds + _u64AsDouble(fractions) / _twoPow64;
  }

  String string() {
    final byteLength = u32();
    _need(byteLength);
    final text = utf8.decode(_bytes.sublist(position, position + byteLength), allowMalformed: true);
    position += byteLength;
    return text;
  }
}

double _readSample(_ByteCursor cursor, int dataTypeCode) {
  switch (TdsType.fromCode(dataTypeCode)) {
    case TdsType.i8:
      return cursor.i8().toDouble();
    case TdsType.u8:
      return cursor.u8().toDouble();
    case TdsType.i16:
      return cursor.i16().toDouble();
    case TdsType.u16:
      return cursor.u16().toDouble();
    case TdsType.i32:
      return cursor.i32().toDouble();
    case TdsType.u32:
      return cursor.u32().toDouble();
    case TdsType.i64:
      return cursor.i64().toDouble();
    case TdsType.u64:
      return _u64AsDouble(cursor.u64());
    case TdsType.singleFloat:
      return cursor.f32();
    case TdsType.doubleFloat:
      return cursor.f64();
    case TdsType.boolean:
      return cursor.u8() != 0 ? 1.0 : 0.0;
    case TdsType.timestamp:
      return cursor.timestamp1904Seconds();
    case TdsType.string:
    case null:
      throw TdmsFormatException('unsupported channel data type $dataTypeCode');
  }
}

DateTime _readTimestampUtc(_ByteCursor cursor) {
  final fractions = cursor.u64();
  final seconds = cursor.i64();
  final fractionsUnsigned = _u64AsDouble(fractions);
  final micros = (seconds * 1000000) + ((fractionsUnsigned / _twoPow64) * 1000000).round();
  return DateTime.utc(1904).add(Duration(microseconds: micros));
}

Object? _readPropertyValue(_ByteCursor cursor, int typeCode) {
  if (typeCode == 0) return null;
  switch (TdsType.fromCode(typeCode)) {
    case TdsType.i8:
      return cursor.i8();
    case TdsType.i16:
      return cursor.i16();
    case TdsType.i32:
      return cursor.i32();
    case TdsType.i64:
      return cursor.i64();
    case TdsType.u8:
      return cursor.u8();
    case TdsType.u16:
      return cursor.u16();
    case TdsType.u32:
      return cursor.u32();
    case TdsType.u64:
      return cursor.u64();
    case TdsType.singleFloat:
      return cursor.f32();
    case TdsType.doubleFloat:
      return cursor.f64();
    case TdsType.string:
      return cursor.string();
    case TdsType.boolean:
      return cursor.u8() != 0;
    case TdsType.timestamp:
      return _readTimestampUtc(cursor);
    case null:
      throw TdmsFormatException('unsupported TDMS property type: $typeCode');
  }
}

void _readContiguousSamples(_ByteCursor cursor, _ObjectState object) {
  final dataTypeCode = object.dataTypeCode;
  final valueCount = object.valueCount;
  if (valueCount < 0) throw TdmsFormatException('negative raw-data count $valueCount');

  if (dataTypeCode == TdsType.string.code) {
    if (valueCount > cursor.remaining ~/ 4) {
      throw TdmsFormatException('string offset count $valueCount exceeds remaining ${cursor.remaining} bytes');
    }
    var lastOffset = 0;
    for (var i = 0; i < valueCount; i++) {
      lastOffset = cursor.u32();
    }
    if (lastOffset > cursor.remaining) {
      throw TdmsFormatException('string data size $lastOffset exceeds remaining ${cursor.remaining} bytes');
    }
    cursor.skip(lastOffset);
    return;
  }

  final width = TdsType.fromCode(dataTypeCode)?.width;
  if (width == null || width <= 0) throw TdmsFormatException('unsupported channel data type $dataTypeCode');
  if (valueCount > cursor.remaining ~/ width) {
    throw TdmsFormatException('raw-data count $valueCount exceeds remaining ${cursor.remaining} bytes');
  }
  for (var i = 0; i < valueCount; i++) {
    object.samples.add(_readSample(cursor, dataTypeCode));
  }
}

void _readInterleavedSamples(_ByteCursor cursor, List<_ObjectState> objects) {
  if (objects.isEmpty) return;
  var bytesPerSample = 0;
  for (final object in objects) {
    if (object.dataTypeCode == TdsType.string.code) {
      throw TdmsFormatException('interleaved string data is not supported');
    }
    final width = TdsType.fromCode(object.dataTypeCode)?.width;
    if (width == null || width <= 0) {
      throw TdmsFormatException('unsupported channel data type ${object.dataTypeCode}');
    }
    bytesPerSample += width;
  }
  final sampleCount = objects.first.valueCount;
  if (sampleCount < 0) throw TdmsFormatException('negative raw-data count $sampleCount');
  if (sampleCount > cursor.remaining ~/ bytesPerSample) {
    throw TdmsFormatException(
      'interleaved raw-data ($sampleCount x $bytesPerSample B) exceeds remaining ${cursor.remaining} bytes',
    );
  }
  for (var sample = 0; sample < sampleCount; sample++) {
    for (final object in objects) {
      object.samples.add(_readSample(cursor, object.dataTypeCode));
    }
  }
}

void _readDaqmxRawDataIndex(_ByteCursor cursor, _ObjectState object) {
  cursor.u32(); // data type
  cursor.u32(); // array dimension
  final valueCount = cursor.u64();
  final scalerCount = cursor.u32();
  if (scalerCount > cursor.remaining ~/ 20) {
    throw TdmsFormatException('DAQmx scaler count $scalerCount exceeds remaining');
  }
  var bufferIndex = 0;
  var byteOffset = 0;
  for (var scaler = 0; scaler < scalerCount; scaler++) {
    cursor.u32(); // scaler data type
    final scalerBufferIndex = cursor.u32();
    final scalerByteOffset = cursor.u32();
    cursor.u32(); // sample-format bitmap
    cursor.u32(); // scale id
    if (scaler == 0) {
      bufferIndex = scalerBufferIndex;
      byteOffset = scalerByteOffset;
    }
  }
  final widthCount = cursor.u32();
  if (widthCount > cursor.remaining ~/ 4) {
    throw TdmsFormatException('DAQmx width count $widthCount exceeds remaining');
  }
  var strideBytes = 0;
  for (var i = 0; i < widthCount; i++) {
    final width = cursor.u32();
    if (i == bufferIndex) strideBytes = width;
  }
  object
    ..isDaqmx = true
    ..dataTypeCode = -1
    ..valueCount = valueCount
    ..daqmxBufferIndex = bufferIndex
    ..daqmxByteOffset = byteOffset
    ..daqmxStrideBytes = strideBytes;
}

void _readDaqmxSamples(_ByteCursor cursor, List<_ObjectState> objects, int rawDataStart, int rawDataLength) {
  final strideBytes = objects.first.daqmxStrideBytes;
  if (strideBytes <= 0) throw TdmsFormatException('invalid DAQmx stride $strideBytes');
  for (final object in objects) {
    if (object.daqmxStrideBytes != strideBytes || object.daqmxBufferIndex != objects.first.daqmxBufferIndex) {
      throw TdmsFormatException('multi-buffer DAQmx raw data is not supported');
    }
  }
  if (rawDataStart < 0 || rawDataStart + rawDataLength > cursor.length) {
    throw TdmsFormatException('DAQmx raw data exceeds the buffer');
  }
  final sampleCount = rawDataLength ~/ strideBytes;
  final byteOffsets = {for (final object in objects) object.daqmxByteOffset}.toList()..sort();
  int elementWidthAt(int byteOffset) {
    final index = byteOffsets.indexOf(byteOffset);
    final nextOffset = index + 1 < byteOffsets.length ? byteOffsets[index + 1] : strideBytes;
    return nextOffset - byteOffset;
  }

  for (final object in objects) {
    final width = elementWidthAt(object.daqmxByteOffset);
    final scale = _daqmxLinearScale(object);
    for (var sample = 0; sample < sampleCount; sample++) {
      final rawValue = cursor.intAt(rawDataStart + sample * strideBytes + object.daqmxByteOffset, width);
      object.samples.add(scale == null ? rawValue.toDouble() : rawValue * scale.slope + scale.intercept);
    }
  }
}

({double slope, double intercept})? _daqmxLinearScale(_ObjectState object) {
  final slopeKeyPattern = RegExp(r'^NI_Scale\[(\d+)\]_Linear_Slope$');
  double? slope;
  var intercept = 0.0;
  var highestIndex = -1;
  for (final property in object.properties.entries) {
    final match = slopeKeyPattern.firstMatch(property.key);
    final value = property.value;
    if (match == null || value is! num) continue;
    final scaleIndex = int.parse(match.group(1)!);
    if (scaleIndex <= highestIndex) continue;
    highestIndex = scaleIndex;
    slope = value.toDouble();
    final interceptValue = object.properties['NI_Scale[$scaleIndex]_Linear_Y_Intercept'];
    intercept = interceptValue is num ? interceptValue.toDouble() : 0.0;
  }
  if (slope == null || object.properties['NI_Scaling_Status'] != 'unscaled') return null;
  return (slope: slope, intercept: intercept);
}

final RegExp _quotedSegmentPattern = RegExp("'((?:[^']|'')*)'");
List<String> _parseObjectPath(String path) => [
  for (final match in _quotedSegmentPattern.allMatches(path)) match.group(1)!.replaceAll("''", "'"),
];
