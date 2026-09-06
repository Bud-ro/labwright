import 'dart:typed_data';

class LvPath {
  const LvPath({required this.components, required this.absolute});
  final List<String> components;
  final bool absolute;
  bool get isEmpty => !absolute && components.isEmpty;
}

class LvRefnum {
  const LvRefnum(this.id);
  final int id;
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
