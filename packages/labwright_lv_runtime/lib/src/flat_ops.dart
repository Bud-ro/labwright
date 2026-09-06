import 'dart:convert';
import 'dart:typed_data';

Uint8List lvFlatOfInt(int value, int bits) {
  final size = bits ~/ 8;
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = (value >>> (8 * (size - 1 - i))) & 0xFF;
  }
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
  for (var i = 0; i < values.length; i++) {
    final value = values[i];
    for (var lane = 0; lane < size; lane++) {
      bytes[i * size + lane] = (value >>> (8 * (size - 1 - lane))) & 0xFF;
    }
  }
  return bytes;
}

int lvIntOfFlat(Uint8List bytes, int bits) {
  _requireExact(bytes.length, bits ~/ 8);
  var value = 0;
  for (final byte in bytes) {
    value = (value << 8) | byte;
  }
  return value;
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
  final values = List<int>.filled(bytes.length ~/ size, 0);
  for (var i = 0; i < values.length; i++) {
    var value = 0;
    for (var lane = 0; lane < size; lane++) {
      value = (value << 8) | bytes[i * size + lane];
    }
    values[i] = value;
  }
  return values;
}

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
