import 'dart:convert';
import 'dart:typed_data';

/// LabVIEW TDMS data-type codes (`tdsDataType`), with each type's fixed element
/// width in bytes (`-1` = variable-length, i.e. string).
enum TdsType {
  i8(1, 1),
  i16(2, 2),
  i32(3, 4),
  i64(4, 8),
  u8(5, 1),
  u16(6, 2),
  u32(7, 4),
  u64(8, 8),
  singleFloat(9, 4),
  doubleFloat(10, 8),
  string(0x20, -1),
  boolean(0x21, 1),
  timestamp(0x44, 16);

  const TdsType(this.code, this.width);

  /// The on-disk type code.
  final int code;

  /// Fixed element width in bytes, or -1 for variable-length (string).
  final int width;

  /// The type for [code], or null if unknown/unsupported.
  static TdsType? fromCode(int code) {
    for (final t in values) {
      if (t.code == code) return t;
    }
    return null;
  }
}

const double _twoPow64 = 18446744073709551616.0;

const int _tocMetaData = 1 << 1;
const int _tocNewObjList = 1 << 2;
const int _tocRawData = 1 << 3;
const int _tocInterleaved = 1 << 5;
const int _tocBigEndian = 1 << 6;

/// TDMS format version written/expected in each segment lead-in (4713 = v2.0).
const int _tdmsVersion = 4713;

/// Segment lead-in tag, ASCII "TDSm".
const List<int> _tag = [0x54, 0x44, 0x53, 0x6D];

/// Raw-data index sentinel for an object with no raw data in this segment.
const int _noRawDataIndex = 0xFFFFFFFF;

/// Raw-data index sentinel meaning "same layout as this object's previous segment".
const int _sameAsPreviousIndex = 0;

/// Byte length of the raw-data index a writer emits: type code (4) + dimension (4) + value count (8).
const int _rawDataIndexLength = 16;

/// Array dimension written for every channel (TDMS raw data is one-dimensional).
const int _arrayDimension = 1;

/// Thrown when TDMS bytes are malformed — truncated, or with declared
/// lengths/counts that exceed the data. The reader bounds-checks every read, so
/// it raises this (never `RangeError`, an out-of-memory, or a hang) on bad input.
class TdmsFormatException implements Exception {
  TdmsFormatException(this.message);
  final String message;
  @override
  String toString() => 'TdmsFormatException: $message';
}

/// One channel's worth of data to write in a segment. [data] is always supplied
/// as doubles; [type] selects the on-disk numeric encoding (default
/// [TdsType.doubleFloat]). Integer types take `value.toInt()`. String/bool/
/// timestamp channels are not written. Properties may be String/int/double/bool.
class TdmsChannel {
  TdmsChannel({
    required this.group,
    required this.name,
    required this.data,
    this.type = TdsType.doubleFloat,
    this.properties = const {},
  });

  final String group;
  final String name;
  final List<double> data;
  final TdsType type;
  final Map<String, Object> properties;
}

/// Writes TDMS bytes. Each [writeSegment] call appends one segment that
/// re-declares its objects (a valid, simple form of streaming): call it
/// repeatedly to append more samples to the same channels.
class TdmsWriter {
  final BytesBuilder _out = BytesBuilder();

  void writeSegment(
    Iterable<TdmsChannel> channels, {
    Map<String, Object> fileProperties = const {},
    Map<String, Map<String, Object>> groupProperties = const {},
  }) {
    final chList = channels.toList();
    final groups = <String>[];
    for (final c in chList) {
      if (!groups.contains(c.group)) {
        groups.add(c.group);
      }
    }

    final meta = BytesBuilder();
    _u32(meta, 1 + groups.length + chList.length);

    _str(meta, '/');
    _u32(meta, _noRawDataIndex);
    _writeProps(meta, fileProperties);

    for (final g in groups) {
      _str(meta, _groupPath(g));
      _u32(meta, _noRawDataIndex);
      _writeProps(meta, groupProperties[g] ?? const {});
    }

    for (final c in chList) {
      if (c.type == TdsType.string || c.type == TdsType.boolean || c.type == TdsType.timestamp) {
        throw ArgumentError('TdmsWriter cannot write channel type ${c.type}');
      }
      _str(meta, _channelPath(c.group, c.name));
      _u32(meta, _rawDataIndexLength);
      _u32(meta, c.type.code);
      _u32(meta, _arrayDimension);
      _u64(meta, c.data.length);
      _writeProps(meta, c.properties);
    }

    final raw = BytesBuilder();
    for (final c in chList) {
      for (final v in c.data) {
        _writeElem(raw, c.type, v);
      }
    }

    final metaBytes = meta.toBytes();
    final rawBytes = raw.toBytes();

    _out.add(Uint8List.fromList(_tag));
    _u32(_out, _tocMetaData | _tocNewObjList | _tocRawData);
    _u32(_out, _tdmsVersion);
    _u64(_out, metaBytes.length + rawBytes.length);
    _u64(_out, metaBytes.length);
    _out.add(metaBytes);
    _out.add(rawBytes);
  }

  Uint8List toBytes() => _out.toBytes();
}

/// Parsed TDMS file: root [properties] plus ordered [groups].
class TdmsFile {
  /// Wraps the parsed root [properties] and ordered [groups].
  TdmsFile(this.properties, this.groups);

  /// File-level (root object) properties.
  final Map<String, Object> properties;

  /// The groups, in the order they first appeared in the file.
  final List<TdmsGroup> groups;

  /// The group named [name], or null if absent.
  TdmsGroup? group(String name) {
    for (final g in groups) {
      if (g.name == name) return g;
    }
    return null;
  }
}

/// One TDMS group (a named collection of channels).
class TdmsGroup {
  /// Wraps a group's [name], [properties], and [channels].
  TdmsGroup(this.name, this.properties, this.channels);

  /// The group name.
  final String name;

  /// Group-level properties.
  final Map<String, Object> properties;

  /// The channels in this group, in file order.
  final List<TdmsChannelData> channels;

  /// The channel named [name] in this group, or null if absent.
  TdmsChannelData? channel(String name) {
    for (final c in channels) {
      if (c.name == name) return c;
    }
    return null;
  }
}

/// One channel's decoded data and metadata. Numeric samples are surfaced as
/// doubles; non-numeric channels carry their value(s) in [properties] with empty
/// [data].
class TdmsChannelData {
  /// Wraps a channel's [group] name, [name], [properties], and [data].
  TdmsChannelData(this.group, this.name, this.properties, this.data);

  /// The owning group's name.
  final String group;

  /// The channel name.
  final String name;

  /// Channel-level properties (units, scaling, etc.).
  final Map<String, Object> properties;

  /// Decoded numeric samples (empty for non-numeric channels).
  final List<double> data;
}

/// Parses TDMS bytes (as written by [TdmsWriter]) back into a [TdmsFile].
/// Accumulates raw data per channel across segments (streaming).
abstract final class TdmsReader {
  static TdmsFile read(Uint8List bytes) {
    final r = _Cursor(bytes);
    final objects = <String, _Obj>{};
    final order = <String>[];
    final active = <_Obj>[];

    while (r.remaining >= 28) {
      r.endian = Endian.little;
      final tag = r.bytes(4);
      if (!_eq(tag, _tag)) break;
      final toc = r.u32();
      r.endian = (toc & _tocBigEndian) != 0 ? Endian.big : Endian.little;
      r.u32();
      final nextOff = r.u64();
      final rawOff = r.u64();
      if (nextOff < 0 || rawOff < 0 || rawOff > nextOff) {
        throw TdmsFormatException('invalid segment offsets (next=$nextOff raw=$rawOff)');
      }
      final afterLeadIn = r.pos;

      if (toc & _tocMetaData != 0) {
        if (toc & _tocNewObjList != 0) active.clear();
        final n = r.u32();
        for (var i = 0; i < n; i++) {
          final path = r.str();
          final obj = objects.putIfAbsent(path, () {
            order.add(path);
            return _Obj(path);
          });
          final rawIdx = r.u32();
          var hasData = false;
          if (rawIdx == _noRawDataIndex) {
            hasData = false;
          } else if (rawIdx == _sameAsPreviousIndex) {
            hasData = true;
          } else if (rawIdx == 0x1269 || rawIdx == 0x1369) {
            _readDaqmxIndex(r, obj);
            hasData = true;
          } else {
            final dtype = r.u32();
            r.u32();
            final count = r.u64();
            if (dtype == TdsType.string.code) {
              r.u64();
            }
            obj
              ..dataType = dtype
              ..numValues = count
              ..daqmx = false;
            hasData = true;
          }
          final np = r.u32();
          for (var p = 0; p < np; p++) {
            final pname = r.str();
            final ptype = r.u32();
            final pv = _readProp(r, ptype);
            if (pv != null) obj.properties[pname] = pv;
          }
          if (hasData && !active.contains(obj)) active.add(obj);
        }
      }

      if (toc & _tocRawData != 0) {
        final rawStart = afterLeadIn + rawOff;
        final rawLen = nextOff - rawOff;
        if (active.any((o) => o.daqmx)) {
          _readDaqmx(r, [for (final o in active) if (o.daqmx) o], rawStart, rawLen);
        } else if (toc & _tocInterleaved != 0) {
          _readInterleaved(r, active);
        } else {
          for (final obj in active) {
            _readChannelRaw(r, obj);
          }
        }
      }

      r.pos = afterLeadIn + nextOff;
    }

    return _assemble(objects, order);
  }

  static TdmsFile _assemble(Map<String, _Obj> objects, List<String> order) {
    final rootProps = objects['/']?.properties ?? <String, Object>{};
    final groupOrder = <String>[];
    final groupProps = <String, Map<String, Object>>{};
    final channelsByGroup = <String, List<TdmsChannelData>>{};

    void ensureGroup(String g) {
      if (!channelsByGroup.containsKey(g)) {
        channelsByGroup[g] = [];
        groupOrder.add(g);
      }
    }

    for (final path in order) {
      if (path == '/') continue;
      final parts = _parsePath(path);
      if (parts.length == 1) {
        ensureGroup(parts[0]);
        groupProps[parts[0]] = objects[path]!.properties;
      } else if (parts.length == 2) {
        final g = parts[0];
        ensureGroup(g);
        final o = objects[path]!;
        channelsByGroup[g]!.add(TdmsChannelData(g, parts[1], o.properties, o.data));
      }
    }

    return TdmsFile(rootProps, [
      for (final g in groupOrder) TdmsGroup(g, groupProps[g] ?? <String, Object>{}, channelsByGroup[g]!),
    ]);
  }
}

class _Obj {
  _Obj(this.path);
  final String path;
  int dataType = 0;
  int numValues = 0;
  final Map<String, Object> properties = {};
  final List<double> data = [];

  /// DAQmx format-changing scaler layout: set when this object carries DAQmx
  /// raw data, with the buffer/offset/stride that locate its samples.
  bool daqmx = false;
  int daqmxBuffer = 0;
  int daqmxOffset = 0;
  int daqmxStride = 0;
}

class _Cursor {
  _Cursor(this._b) : _d = ByteData.sublistView(_b);
  final Uint8List _b;
  final ByteData _d;
  int pos = 0;

  /// Endianness of the current segment after its ToC — its version, segment
  /// offsets, metadata, and raw data. The lead-in tag and ToC mask are always
  /// little-endian; the ToC big-endian flag selects this.
  Endian endian = Endian.little;

  int get remaining => _b.length - pos;
  int get length => _b.length;

  /// Reads a signed integer of [width] bytes at an absolute [at] (random access,
  /// for DAQmx stride decoding). Does not move [pos].
  int intAt(int at, int width) {
    if (at < 0 || at + width > _b.length) {
      throw TdmsFormatException('read past end of data at $at');
    }
    switch (width) {
      case 1:
        return _d.getInt8(at);
      case 2:
        return _d.getInt16(at, endian);
      case 4:
        return _d.getInt32(at, endian);
      case 8:
        return _d.getInt64(at, endian);
      default:
        throw TdmsFormatException('unsupported DAQmx element width $width');
    }
  }

  void _need(int n) {
    if (n < 0 || pos + n > _b.length) {
      throw TdmsFormatException('unexpected end of data: need $n byte(s) at offset $pos of ${_b.length}');
    }
  }

  void skip(int n) {
    _need(n);
    pos += n;
  }

  Uint8List bytes(int n) {
    _need(n);
    final s = _b.sublist(pos, pos + n);
    pos += n;
    return s;
  }

  int byte() {
    _need(1);
    return _b[pos++];
  }

  int i8() {
    _need(1);
    final v = _d.getInt8(pos);
    pos += 1;
    return v;
  }

  int u8() {
    _need(1);
    final v = _d.getUint8(pos);
    pos += 1;
    return v;
  }

  int i16() {
    _need(2);
    final v = _d.getInt16(pos, endian);
    pos += 2;
    return v;
  }

  int u16() {
    _need(2);
    final v = _d.getUint16(pos, endian);
    pos += 2;
    return v;
  }

  int i32() {
    _need(4);
    final v = _d.getInt32(pos, endian);
    pos += 4;
    return v;
  }

  int u32() {
    _need(4);
    final v = _d.getUint32(pos, endian);
    pos += 4;
    return v;
  }

  int i64() {
    _need(8);
    final v = _d.getInt64(pos, endian);
    pos += 8;
    return v;
  }

  int u64() {
    _need(8);
    final v = _d.getUint64(pos, endian);
    pos += 8;
    return v;
  }

  double f32() {
    _need(4);
    final v = _d.getFloat32(pos, endian);
    pos += 4;
    return v;
  }

  double f64() {
    _need(8);
    final v = _d.getFloat64(pos, endian);
    pos += 8;
    return v;
  }

  /// NI timestamp raw value as seconds since 1904-01-01 UTC (u64 fractions of a
  /// second, then i64 seconds).
  double timestamp1904Seconds() {
    final frac = u64();
    final sec = i64();
    final fracUnsigned = frac >= 0 ? frac.toDouble() : frac + _twoPow64;
    return sec + fracUnsigned / _twoPow64;
  }

  /// Reads a length-prefixed UTF-8 string. Malformed bytes are replaced rather
  /// than thrown, so arbitrary input never raises a (non-TDMS) FormatException.
  String str() {
    final n = u32();
    _need(n);
    final s = utf8.decode(_b.sublist(pos, pos + n), allowMalformed: true);
    pos += n;
    return s;
  }
}

/// Byte width of a fixed-size raw element type (-1 if variable/unsupported).
int _typeWidth(int code) => TdsType.fromCode(code)?.width ?? -1;

/// Reads one fixed-size raw element as a double (the channel data model).
double _readElem(_Cursor r, int code) {
  switch (TdsType.fromCode(code)) {
    case TdsType.i8:
      return r.i8().toDouble();
    case TdsType.u8:
      return r.u8().toDouble();
    case TdsType.i16:
      return r.i16().toDouble();
    case TdsType.u16:
      return r.u16().toDouble();
    case TdsType.i32:
      return r.i32().toDouble();
    case TdsType.u32:
      return r.u32().toDouble();
    case TdsType.i64:
      return r.i64().toDouble();
    case TdsType.u64:
      {
        final v = r.u64();
        return v >= 0 ? v.toDouble() : v + _twoPow64;
      }
    case TdsType.singleFloat:
      return r.f32();
    case TdsType.doubleFloat:
      return r.f64();
    case TdsType.boolean:
      return r.byte() != 0 ? 1.0 : 0.0;
    case TdsType.timestamp:
      return r.timestamp1904Seconds();
    case TdsType.string:
    case null:
      throw TdmsFormatException('unsupported channel data type $code');
  }
}

DateTime _readTimestamp(_Cursor r) {
  final frac = r.u64();
  final sec = r.i64();
  final fracUnsigned = frac >= 0 ? frac.toDouble() : frac + _twoPow64;
  final micros = (sec * 1000000) + ((fracUnsigned / _twoPow64) * 1000000).round();
  return DateTime.utc(1904).add(Duration(microseconds: micros));
}

/// Reads one property value (or null for a void property).
Object? _readProp(_Cursor r, int code) {
  if (code == 0) return null;
  switch (TdsType.fromCode(code)) {
    case TdsType.i8:
      return r.i8();
    case TdsType.i16:
      return r.i16();
    case TdsType.i32:
      return r.i32();
    case TdsType.i64:
      return r.i64();
    case TdsType.u8:
      return r.u8();
    case TdsType.u16:
      return r.u16();
    case TdsType.u32:
      return r.u32();
    case TdsType.u64:
      return r.u64();
    case TdsType.singleFloat:
      return r.f32();
    case TdsType.doubleFloat:
      return r.f64();
    case TdsType.string:
      return r.str();
    case TdsType.boolean:
      return r.byte() != 0;
    case TdsType.timestamp:
      return _readTimestamp(r);
    case null:
      throw TdmsFormatException('unsupported TDMS property type: $code');
  }
}

/// Reads one channel's raw data into [obj], handling fixed-size types and the
/// string layout (a u32 offset array followed by the UTF-8 bytes; not yet
/// surfaced as values, but consumed to stay aligned).
void _readChannelRaw(_Cursor r, _Obj obj) {
  final t = obj.dataType;
  final n = obj.numValues;
  if (n < 0) throw TdmsFormatException('negative raw-data count $n');

  if (t == TdsType.string.code) {
    if (n > r.remaining ~/ 4) {
      throw TdmsFormatException('string offset count $n exceeds remaining ${r.remaining} bytes');
    }
    var lastOffset = 0;
    for (var i = 0; i < n; i++) {
      lastOffset = r.u32();
    }
    if (lastOffset < 0 || lastOffset > r.remaining) {
      throw TdmsFormatException('string data size $lastOffset exceeds remaining ${r.remaining} bytes');
    }
    r.skip(lastOffset);
    return;
  }

  final w = _typeWidth(t);
  if (w <= 0) throw TdmsFormatException('unsupported channel data type $t');
  if (n > r.remaining ~/ w) {
    throw TdmsFormatException('raw-data count $n exceeds remaining ${r.remaining} bytes');
  }
  for (var k = 0; k < n; k++) {
    obj.data.add(_readElem(r, t));
  }
}

/// Reads interleaved raw data (sample-major: all channels' value 0, then all
/// channels' value 1, …). Assumes a common sample count (the first channel's).
void _readInterleaved(_Cursor r, List<_Obj> chans) {
  if (chans.isEmpty) return;
  var perSample = 0;
  for (final obj in chans) {
    if (obj.dataType == TdsType.string.code) {
      throw TdmsFormatException('interleaved string data is not supported');
    }
    final w = _typeWidth(obj.dataType);
    if (w <= 0) throw TdmsFormatException('unsupported channel data type ${obj.dataType}');
    perSample += w;
  }
  final n = chans.first.numValues;
  if (n < 0) throw TdmsFormatException('negative raw-data count $n');
  if (perSample > 0 && n > r.remaining ~/ perSample) {
    throw TdmsFormatException('interleaved raw-data ($n x $perSample B) exceeds remaining ${r.remaining} bytes');
  }
  for (var s = 0; s < n; s++) {
    for (final obj in chans) {
      obj.data.add(_readElem(r, obj.dataType));
    }
  }
}

/// Parses a DAQmx format-changing/digital-line scaler index into [obj]'s layout
/// (buffer, byte offset within the stride, and stride), using the first scaler.
/// Recognized by the raw-data index sentinels 0x1269 (format-changing) and
/// 0x1369 (digital-line), not by any ToC flag.
void _readDaqmxIndex(_Cursor r, _Obj obj) {
  r.u32();
  r.u32();
  final count = r.u64();
  final scalerCount = r.u32();
  if (scalerCount < 0 || scalerCount > r.remaining ~/ 20) {
    throw TdmsFormatException('DAQmx scaler count $scalerCount exceeds remaining');
  }
  var buffer = 0;
  var offset = 0;
  for (var s = 0; s < scalerCount; s++) {
    r.u32();
    final bufferIndex = r.u32();
    final byteOffset = r.u32();
    r.u32();
    r.u32();
    if (s == 0) {
      buffer = bufferIndex;
      offset = byteOffset;
    }
  }
  final widthCount = r.u32();
  if (widthCount < 0 || widthCount > r.remaining ~/ 4) {
    throw TdmsFormatException('DAQmx width count $widthCount exceeds remaining');
  }
  var stride = 0;
  for (var w = 0; w < widthCount; w++) {
    final width = r.u32();
    if (w == buffer) stride = width;
  }
  obj
    ..daqmx = true
    ..dataType = -1
    ..numValues = count
    ..daqmxBuffer = buffer
    ..daqmxOffset = offset
    ..daqmxStride = stride;
}

/// Decodes one segment of DAQmx raw data: an interleaved buffer of fixed
/// [stride] bytes per sample, each channel at its byte offset. Element width is
/// inferred from the gaps between channel offsets. Applies the linear scale when
/// the channel's data is stored unscaled.
void _readDaqmx(_Cursor r, List<_Obj> chans, int rawStart, int rawLen) {
  if (chans.isEmpty) return;
  final stride = chans.first.daqmxStride;
  if (stride <= 0) throw TdmsFormatException('invalid DAQmx stride $stride');
  for (final c in chans) {
    if (c.daqmxStride != stride || c.daqmxBuffer != chans.first.daqmxBuffer) {
      throw TdmsFormatException('multi-buffer DAQmx raw data is not supported');
    }
  }
  if (rawStart < 0 || rawStart + rawLen > r.length) {
    throw TdmsFormatException('DAQmx raw data exceeds the buffer');
  }
  final samples = rawLen ~/ stride;
  final offsets = {for (final c in chans) c.daqmxOffset}.toList()..sort();
  int widthAt(int offset) {
    final i = offsets.indexOf(offset);
    final next = i + 1 < offsets.length ? offsets[i + 1] : stride;
    return next - offset;
  }

  for (final c in chans) {
    final width = widthAt(c.daqmxOffset);
    final scale = _linearScale(c);
    for (var s = 0; s < samples; s++) {
      final raw = r.intAt(rawStart + s * stride + c.daqmxOffset, width);
      c.data.add(scale.apply ? raw * scale.slope + scale.intercept : raw.toDouble());
    }
  }
}

/// Finds the linear scale to apply to a DAQmx channel: the highest-indexed
/// `NI_Scale[N]_Linear_*`, applied only when `NI_Scaling_Status` is `unscaled`.
({double slope, double intercept, bool apply}) _linearScale(_Obj o) {
  final slopeKey = RegExp(r'^NI_Scale\[(\d+)\]_Linear_Slope$');
  double? slope;
  var intercept = 0.0;
  var best = -1;
  for (final e in o.properties.entries) {
    final m = slopeKey.firstMatch(e.key);
    final v = e.value;
    if (m != null && v is num) {
      final n = int.parse(m.group(1)!);
      if (n > best) {
        best = n;
        slope = v.toDouble();
        final ic = o.properties['NI_Scale[$n]_Linear_Y_Intercept'];
        intercept = ic is num ? ic.toDouble() : 0.0;
      }
    }
  }
  final apply = slope != null && o.properties['NI_Scaling_Status'] == 'unscaled';
  return (slope: slope ?? 1.0, intercept: intercept, apply: apply);
}

void _u32(BytesBuilder b, int v) {
  final d = ByteData(4)..setUint32(0, v, Endian.little);
  b.add(d.buffer.asUint8List());
}

void _u64(BytesBuilder b, int v) {
  final d = ByteData(8)..setUint64(0, v, Endian.little);
  b.add(d.buffer.asUint8List());
}

void _i64(BytesBuilder b, int v) {
  final d = ByteData(8)..setInt64(0, v, Endian.little);
  b.add(d.buffer.asUint8List());
}

void _f64(BytesBuilder b, double v) {
  final d = ByteData(8)..setFloat64(0, v, Endian.little);
  b.add(d.buffer.asUint8List());
}

/// Encodes one raw channel element of [t] (little-endian). Integers take
/// `v.toInt()`. String/bool/timestamp channels are not supported by the writer.
void _writeElem(BytesBuilder b, TdsType t, double v) {
  final d = ByteData(8);
  switch (t) {
    case TdsType.i8:
      d.setInt8(0, v.toInt());
      b.add(d.buffer.asUint8List(0, 1));
    case TdsType.u8:
      d.setUint8(0, v.toInt());
      b.add(d.buffer.asUint8List(0, 1));
    case TdsType.i16:
      d.setInt16(0, v.toInt(), Endian.little);
      b.add(d.buffer.asUint8List(0, 2));
    case TdsType.u16:
      d.setUint16(0, v.toInt(), Endian.little);
      b.add(d.buffer.asUint8List(0, 2));
    case TdsType.i32:
      d.setInt32(0, v.toInt(), Endian.little);
      b.add(d.buffer.asUint8List(0, 4));
    case TdsType.u32:
      d.setUint32(0, v.toInt(), Endian.little);
      b.add(d.buffer.asUint8List(0, 4));
    case TdsType.i64:
      d.setInt64(0, v.toInt(), Endian.little);
      b.add(d.buffer.asUint8List(0, 8));
    case TdsType.u64:
      d.setUint64(0, v.toInt(), Endian.little);
      b.add(d.buffer.asUint8List(0, 8));
    case TdsType.singleFloat:
      d.setFloat32(0, v, Endian.little);
      b.add(d.buffer.asUint8List(0, 4));
    case TdsType.doubleFloat:
      d.setFloat64(0, v, Endian.little);
      b.add(d.buffer.asUint8List(0, 8));
    case TdsType.string:
    case TdsType.boolean:
    case TdsType.timestamp:
      throw ArgumentError('TdmsWriter cannot write channel type $t');
  }
}

void _str(BytesBuilder b, String s) {
  final u = utf8.encode(s);
  _u32(b, u.length);
  b.add(u);
}

void _writeProps(BytesBuilder b, Map<String, Object> props) {
  _u32(b, props.length);
  props.forEach((k, v) => _prop(b, k, v));
}

void _prop(BytesBuilder b, String name, Object value) {
  _str(b, name);
  switch (value) {
    case final String s:
      _u32(b, TdsType.string.code);
      _str(b, s);
    case final bool x:
      _u32(b, TdsType.boolean.code);
      b.addByte(x ? 1 : 0);
    case final int i:
      _u32(b, TdsType.i64.code);
      _i64(b, i);
    case final double d:
      _u32(b, TdsType.doubleFloat.code);
      _f64(b, d);
    default:
      throw ArgumentError('Unsupported TDMS property type: ${value.runtimeType}');
  }
}

String _esc(String s) => s.replaceAll("'", "''");
String _groupPath(String g) => "/'${_esc(g)}'";
String _channelPath(String g, String c) => "/'${_esc(g)}'/'${_esc(c)}'";

final RegExp _segment = RegExp("'((?:[^']|'')*)'");
List<String> _parsePath(String path) =>
    [for (final m in _segment.allMatches(path)) m.group(1)!.replaceAll("''", "'")];

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
