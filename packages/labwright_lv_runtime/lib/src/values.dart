import 'dart:typed_data';

class LvPath {
  const LvPath({required this.components, required this.absolute, this.valid = true});
  final List<String> components;
  final bool absolute;
  final bool valid;
  bool get isEmpty => valid && !absolute && components.isEmpty;
  static const LvPath notAPath = LvPath(components: [], absolute: false, valid: false);

  @override
  bool operator ==(Object other) => other is LvPath && lvSameValue(this, other);

  @override
  int get hashCode => Object.hash(valid, absolute, Object.hashAll(components));
}

/// LabVIEW's 128-bit absolute time: [seconds] since 1904-01-01 00:00:00 UTC as a signed 64-bit
/// integer, then [fraction] of a second as an unsigned 64-bit integer, the sum being the time.
class LvTimestamp {
  const LvTimestamp({required this.seconds, required this.fraction});
  final int seconds;
  final int fraction;
  static const LvTimestamp epoch = LvTimestamp(seconds: 0, fraction: 0);
  @override
  bool operator ==(Object other) => other is LvTimestamp && other.seconds == seconds && other.fraction == fraction;
  @override
  int get hashCode => Object.hash(seconds, fraction);
}

class LvRefnum {
  const LvRefnum(this.id);
  final int id;
  static const LvRefnum none = LvRefnum(0);
}

/// A numeric representation, as a variant records the type of the number it holds.
enum LvNumericType {
  i8(8, isFloat: false),
  i16(16, isFloat: false),
  i32(32, isFloat: false),
  i64(64, isFloat: false),
  u8(8, isFloat: false),
  u16(16, isFloat: false),
  u32(32, isFloat: false),
  u64(64, isFloat: false),
  sgl(32, isFloat: true),
  dbl(64, isFloat: true);

  const LvNumericType(this.bits, {required this.isFloat});

  final int bits;

  final bool isFloat;
}

/// A variant: any value with the attributes set on it, the numeric representation of a number
/// it holds, and the type descriptor of the value when the program that made it supplied one.
class LvVariant {
  const LvVariant(this.value, {this.attributes = const {}, this.typeDescriptor, this.numeric});

  final Object? value;

  final LvNumericType? numeric;

  /// The attributes by name, each a variant of its own.
  final Map<String, LvVariant> attributes;

  final Uint8List? typeDescriptor;

  /// An empty variant, which holds no value.
  static const LvVariant empty = LvVariant(null);

  LvVariant withAttributes(Map<String, LvVariant> attributes) =>
      LvVariant(value, attributes: attributes, typeDescriptor: typeDescriptor, numeric: numeric);
}

class LvError {
  const LvError({required this.status, required this.code, required this.source});
  final bool status;
  final int code;
  final String source;
  static const LvError none = LvError(status: false, code: 0, source: '');
}

LvError lvMergeErrors(List<LvError> errors) {
  for (final error in errors) {
    if (error.status) return error;
  }
  for (final error in errors) {
    if (error.code != 0) return error;
  }
  return LvError.none;
}

/// Whether two values are the same as LabVIEW's equality compares them: paths by their
/// components, validity and absoluteness, everything else by `==`.
bool lvSameValue(Object? left, Object? right) {
  if (left is LvPath && right is LvPath) {
    if (left.valid != right.valid || left.absolute != right.absolute) return false;
    if (left.components.length != right.components.length) return false;
    for (var i = 0; i < left.components.length; i++) {
      if (left.components[i] != right.components[i]) return false;
    }
    return true;
  }
  return left == right;
}
