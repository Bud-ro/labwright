import 'model.dart';

enum ChannelDiffStatus {
  onlyInA,

  onlyInB,

  lengthMismatch,

  valueDiff,
}

Map<String, Object?> diffTdms(TdmsFile a, TdmsFile b, {double tol = 0.0}) {
  final groupNamesA = {for (final group in a.groups) group.name};
  final groupNamesB = {for (final group in b.groups) group.name};
  final onlyInA = [
    for (final group in a.groups)
      if (!groupNamesB.contains(group.name)) group.name,
  ];
  final onlyInB = [
    for (final group in b.groups)
      if (!groupNamesA.contains(group.name)) group.name,
  ];

  final channels = <Map<String, Object?>>[];
  for (final groupA in a.groups) {
    final groupB = b.group(groupA.name);
    if (groupB == null) continue;
    final channelNamesA = {for (final channel in groupA.channels) channel.name};
    for (final channelA in groupA.channels) {
      final channelB = groupB.channel(channelA.name);
      if (channelB == null) {
        channels.add({
          'group': groupA.name,
          'name': channelA.name,
          'status': ChannelDiffStatus.onlyInA.name,
          'lenA': channelA.data.length,
        });
        continue;
      }
      final delta = _valueDelta(channelA.data, channelB.data, tol);
      ChannelDiffStatus? status;
      if (channelA.data.length != channelB.data.length) {
        status = ChannelDiffStatus.lengthMismatch;
      } else if (delta['firstDiffIndex'] != null) {
        status = ChannelDiffStatus.valueDiff;
      }
      if (status != null) {
        channels.add({
          'group': groupA.name,
          'name': channelA.name,
          'status': status.name,
          'lenA': channelA.data.length,
          'lenB': channelB.data.length,
          ...delta,
        });
      }
    }
    for (final channelB in groupB.channels) {
      if (!channelNamesA.contains(channelB.name)) {
        channels.add({
          'group': groupA.name,
          'name': channelB.name,
          'status': ChannelDiffStatus.onlyInB.name,
          'lenB': channelB.data.length,
        });
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

Map<String, Object?> _valueDelta(List<double> a, List<double> b, double tol) {
  final commonLen = a.length < b.length ? a.length : b.length;
  var maxAbs = 0.0;
  int? firstDiff;
  for (var i = 0; i < commonLen; i++) {
    final absDelta = (a[i] - b[i]).abs();
    if (absDelta > maxAbs) maxAbs = absDelta;
    if (firstDiff == null && absDelta > tol) firstDiff = i;
  }
  return {'firstDiffIndex': firstDiff, 'maxAbsDelta': maxAbs};
}
