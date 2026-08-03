/// The runtime a **translated LabVIEW VI** links against.
///
/// Code lowered from a block diagram calls into this library for everything
/// that is LabVIEW's semantics rather than Dart's: the fixed-width integer
/// conversions, the bit rotations, the byte-string operations, the flat byte
/// form a Type Cast reinterprets, the multi-dimensional array carrier, and the
/// reference/error values a wire carries.
///
/// It depends on nothing. A generated artifact must not pull in the
/// transpiler that produced it — that is a build-time tool — so the runtime
/// is its own package and the transpiler only ever names its members.
library;

export 'src/array_ops.dart';
export 'src/flat_ops.dart';
export 'src/numeric_ops.dart';
export 'src/string_ops.dart';
export 'src/values.dart';
