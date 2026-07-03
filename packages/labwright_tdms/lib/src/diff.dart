import 'tdms.dart';

/// How a single channel differs between two TDMS files. The `.name` of each
/// value is exactly the string emitted in the `status` field of a [diffTdms]
/// channel entry, so the JSON contract is stable and consumers can match on it.
enum ChannelDiffStatus {
  /// Present in file A but not file B.
  onlyInA,

  /// Present in file B but not file A.
  onlyInB,

  /// Present in both, but with different sample counts.
  lengthMismatch,

  /// Same length, but values differ beyond the tolerance.
  valueDiff,
}

/// Compares two parsed TDMS files and returns a JSON-encodable summary of how
/// they differ: groups present in only one file, channels added/removed within
/// shared groups, and per-channel numeric differences (length mismatch, the
/// first index where `|a - b| > tol`, and the max absolute delta over the common
/// prefix). Useful for regression comparison of recorded runs.
///
/// `identical` is true when there are no structural differences and every shared
/// channel agrees to within [tol]. Only differing channels are listed under
/// `channels` (equal ones are omitted to keep the report focused). [tol] defaults
/// to exact equality.
Map<String, Object?> diffTdms(TdmsFile a, TdmsFile b, {double tol = 0.0}) {
  final groupsA = {for (final g in a.groups) g.name};
  final groupsB = {for (final g in b.groups) g.name};
  final onlyInA = [for (final g in a.groups) if (!groupsB.contains(g.name)) g.name];
  final onlyInB = [for (final g in b.groups) if (!groupsA.contains(g.name)) g.name];

  final channels = <Map<String, Object?>>[];
  for (final ga in a.groups) {
    final gb = b.group(ga.name);
    if (gb == null) continue;
    final namesA = {for (final c in ga.channels) c.name};
    for (final ca in ga.channels) {
      final cb = gb.channel(ca.name);
      if (cb == null) {
        channels.add({'group': ga.name, 'name': ca.name, 'status': ChannelDiffStatus.onlyInA.name, 'lenA': ca.data.length});
        continue;
      }
      final delta = _valueDelta(ca.data, cb.data, tol);
      if (ca.data.length != cb.data.length) {
        channels.add({
          'group': ga.name,
          'name': ca.name,
          'status': ChannelDiffStatus.lengthMismatch.name,
          'lenA': ca.data.length,
          'lenB': cb.data.length,
          ...delta,
        });
      } else if (delta['firstDiffIndex'] != null) {
        channels.add({
          'group': ga.name,
          'name': ca.name,
          'status': ChannelDiffStatus.valueDiff.name,
          'lenA': ca.data.length,
          'lenB': cb.data.length,
          ...delta,
        });
      }
    }
    for (final cb in gb.channels) {
      if (!namesA.contains(cb.name)) {
        channels.add({'group': ga.name, 'name': cb.name, 'status': ChannelDiffStatus.onlyInB.name, 'lenB': cb.data.length});
      }
    }
  }

  return {
    'identical': onlyInA.isEmpty && onlyInB.isEmpty && channels.isEmpty,
    'tol': tol,
    'groupsOnlyInA': onlyInA,
    'groupsOnlyInB': onlyInB,
    'channels': channels,
  };
}

/// Max absolute delta over the common prefix and the first index exceeding
/// [tol]. Returns `firstDiffIndex: null` when every compared pair is within tol.
Map<String, Object?> _valueDelta(List<double> a, List<double> b, double tol) {
  final n = a.length < b.length ? a.length : b.length;
  var maxAbs = 0.0;
  int? firstDiff;
  for (var i = 0; i < n; i++) {
    final d = (a[i] - b[i]).abs();
    if (d > maxAbs) maxAbs = d;
    if (firstDiff == null && d > tol) firstDiff = i;
  }
  return {'firstDiffIndex': firstDiff, 'maxAbsDelta': maxAbs};
}
