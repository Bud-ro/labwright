/// LabVIEW's **flat byte form** — the representation `Type Cast` reinterprets
/// a value through.
///
/// One law covers every carrier: a value's bytes are its scalars written
/// **big-endian**, an array's are its elements' bytes end to end, and a
/// string's are its characters as bytes. Nothing else rides along: no
/// dimension vector, no length prefix, no padding between elements.
///
/// A LabVIEW string is a byte sequence carried in Dart as Latin-1 code units,
/// so a character above `U+00FF` has no byte and [lvFlatOfString] rejects it
/// rather than truncating.
///
/// Target: the Dart **native** runtime — see the width model in
/// `numeric_ops.dart` for why `int` is read as a signed 64-bit carrier.
library;

import 'dart:convert';
import 'dart:typed_data';

/// The flat bytes of the integer [value] at [bits] wide.
Uint8List lvFlatOfInt(int value, int bits) {
  final size = bits ~/ 8;
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = (value >>> (8 * (size - 1 - i))) & 0xFF;
  }
  return bytes;
}

/// The flat bytes of the floating [value] at [bits] wide (32 or 64).
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

/// The flat bytes of a string — its characters as Latin-1 bytes.
Uint8List lvFlatOfString(String value) => latin1.encode(value);

/// The flat bytes of a 1-D array of [bits]-wide integers, in index order.
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

/// The [bits]-wide integer the flat [bytes] hold, as a raw bit pattern — the
/// caller renormalizes it to the LabVIEW type's own width, which is what
/// re-establishes the sign of a narrow signed carrier.
int lvIntOfFlat(Uint8List bytes, int bits) {
  _requireExact(bytes.length, bits ~/ 8);
  var value = 0;
  for (final byte in bytes) {
    value = (value << 8) | byte;
  }
  return value;
}

/// The [bits]-wide floating value the flat [bytes] hold.
double lvFloatOfFlat(Uint8List bytes, int bits) {
  _requireExact(bytes.length, bits ~/ 8);
  final view = ByteData.sublistView(bytes);
  return bits == 32 ? view.getFloat32(0) : view.getFloat64(0);
}

/// The string the flat [bytes] hold — one character per byte.
String lvStringOfFlat(Uint8List bytes) => latin1.decode(bytes);

/// The [bits]-wide integers the flat [bytes] hold, as raw bit patterns. The
/// caller stores them in the element's exact-width typed list, which is what
/// re-establishes the sign of a narrow signed element.
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

// TODO(lv-typecast-size): what LabVIEW's Type Cast does when the operand's
// bytes do not fill the target type exactly — whether it zero-pads, truncates,
// or yields nothing — is not established from the file format, so a
// mismatched cast raises rather than inventing a result.
void _requireExact(int length, int size) {
  if (length != size) {
    throw ArgumentError.value(length, 'bytes', 'a $size-byte type cast needs exactly $size bytes');
  }
}

// TODO(lv-typecast-size): see [_requireExact].
void _requireWhole(int length, int size) {
  if (length % size != 0) {
    throw ArgumentError.value(length, 'bytes', 'a $size-byte element type cast needs a multiple of $size bytes');
  }
}
