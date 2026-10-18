/// How well a heap object class's role is established.
enum ClassConfidence {
  /// Named from a corpus law or a reference render.
  confirmed,

  /// Named from consistent corpus evidence without a direct check.
  inferred,

  /// Only the class code and its category are known.
  kindOnly,
}

/// A lookup table from class code to class, [unknown] where no class has the code.
List<T> classCodeTable<T>(List<T> values, T unknown, int Function(T) codeOf) {
  final codeCount = values.fold(0, (count, c) => codeOf(c) >= count ? codeOf(c) + 1 : count);
  final table = List<T>.filled(codeCount, unknown);
  for (final c in values) {
    if (c != unknown) table[codeOf(c)] = c;
  }
  return table;
}
