import 'dart:typed_data';

class LvPath {
  const LvPath({required this.components, required this.absolute, this.valid = true});
  final List<String> components;
  final bool absolute;
  final bool valid;
  bool get isEmpty => valid && !absolute && components.isEmpty;
  static const LvPath notAPath = LvPath(components: [], absolute: false, valid: false);
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

class LvVariant {
  const LvVariant({required this.flattened, required this.typeDescriptor});
  final Uint8List flattened;
  final Uint8List typeDescriptor;
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
