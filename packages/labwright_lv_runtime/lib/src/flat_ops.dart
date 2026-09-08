import 'dart:convert';
import 'dart:typed_data';

Uint8List lvFlatOfInt(int value, int bits) {
  final bytes = Uint8List(bits ~/ 8);
  _setUint(ByteData.sublistView(bytes), 0, value, bits);
  return bytes;
}

Uint8List lvFlatOfFloat(double value, int bits) {
  final bytes = Uint8List(bits ~/ 8);
  final view = ByteData.sublistView(bytes);
  if (bits == 32) {
    view.setFloat32(0, value);
  } else {
    view.setFloat64(0, value);
  }
  return bytes;
}

Uint8List lvFlatOfString(String value) => latin1.encode(value);
Uint8List lvFlatOfIntList(List<int> values, int bits) {
  final size = bits ~/ 8;
  final bytes = Uint8List(values.length * size);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < values.length; i++) {
    _setUint(view, i * size, values[i], bits);
  }
  return bytes;
}

int lvIntOfFlat(Uint8List bytes, int bits) {
  _requireExact(bytes.length, bits ~/ 8);
  return _getUint(ByteData.sublistView(bytes), 0, bits);
}

double lvFloatOfFlat(Uint8List bytes, int bits) {
  _requireExact(bytes.length, bits ~/ 8);
  final view = ByteData.sublistView(bytes);
  return bits == 32 ? view.getFloat32(0) : view.getFloat64(0);
}

String lvStringOfFlat(Uint8List bytes) => latin1.decode(bytes);
List<int> lvIntListOfFlat(Uint8List bytes, int bits) {
  final size = bits ~/ 8;
  _requireWhole(bytes.length, size);
  final view = ByteData.sublistView(bytes);
  final values = List<int>.filled(bytes.length ~/ size, 0);
  for (var i = 0; i < values.length; i++) {
    values[i] = _getUint(view, i * size, bits);
  }
  return values;
}

int _getUint(ByteData view, int offset, int bits) => switch (bits) {
  8 => view.getUint8(offset),
  16 => view.getUint16(offset),
  32 => view.getUint32(offset),
  _ => view.getUint64(offset),
};

void _setUint(ByteData view, int offset, int value, int bits) => switch (bits) {
  8 => view.setUint8(offset, value),
  16 => view.setUint16(offset, value),
  32 => view.setUint32(offset, value),
  _ => view.setUint64(offset, value),
};

// TODO(lv-typecast-size): LabVIEW's Type Cast of a byte count that does not fill the target type is not decoded; this throws.
void _requireExact(int length, int size) {
  if (length != size) {
    throw ArgumentError.value(length, 'bytes', 'a $size-byte type cast needs exactly $size bytes');
  }
}

void _requireWhole(int length, int size) {
  if (length % size != 0) {
    throw ArgumentError.value(length, 'bytes', 'a $size-byte element type cast needs a multiple of $size bytes');
  }
}
