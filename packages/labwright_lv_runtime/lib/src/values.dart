/// The LabVIEW values that are neither a number, a boolean, a string nor an
/// array: the reference handles and the self-describing carriers a diagram
/// passes along a wire.
///
/// Each is deliberately **opaque** in exactly the places the file format has
/// not been decoded. A carrier that pretended to more structure than is
/// decoded would put fabricated data in a translated program; a carrier that
/// exists but holds only what was recovered lets the wire be typed, which is
/// what a translation needs first.
library;

import 'dart:typed_data';

/// A LabVIEW **file path**.
///
/// LabVIEW stores a path as a component list with a root marker rather than as
/// a string, which is why it is not carried as one: the same path renders with
/// different separators per platform, and a relative path has no root at all.
class LvPath {
  const LvPath({required this.components, required this.absolute});

  /// The path components, outermost first, with no separators.
  final List<String> components;

  /// Whether the path is rooted rather than relative.
  final bool absolute;

  /// Whether this is the **empty path**: relative, naming no component. It is
  /// the form a `PTH0` record with the relative type word and a zero component
  /// count carries. A rooted path is never empty, however few components it
  /// names — `/` names a directory where the empty path names nothing.
  bool get isEmpty => !absolute && components.isEmpty;
}

/// An opaque LabVIEW **reference handle** — a queue, a notifier, a VI
/// reference, an open file.
///
/// A refnum descriptor carries a discriminator selecting the reference class;
/// which class each value selects is not decoded, so every refnum shares this
/// one handle type rather than specializing per class.
class LvRefnum {
  const LvRefnum(this.id);

  /// The handle's identity, unique within the process that created it.
  final int id;
}

/// A LabVIEW **variant**: a self-describing value kept as its flattened bytes
/// plus the type descriptor that reads them.
///
/// Variant payload layout is not decoded, so the bytes are carried verbatim
/// rather than interpreted; the descriptor travels with them so a later decode
/// can read the pair without losing anything.
class LvVariant {
  const LvVariant({required this.flattened, required this.typeDescriptor});

  /// The value's flattened bytes.
  final Uint8List flattened;

  /// The `VCTP` type descriptor bytes that describe [flattened].
  final Uint8List typeDescriptor;
}

/// A LabVIEW **error cluster** `{status, code, source}` — the value that
/// travels the error wire threaded through most diagrams.
class LvError {
  const LvError({required this.status, required this.code, required this.source});

  /// Whether this is an error rather than a warning or a clear state.
  final bool status;

  /// The error code; zero when there is neither an error nor a warning.
  final int code;

  /// Where the error came from, as LabVIEW's call-chain text.
  final String source;

  /// The cleared value: no error, no warning, no source.
  static const LvError none = LvError(status: false, code: 0, source: '');
}
