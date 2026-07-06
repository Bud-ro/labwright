import 'dart:typed_data';

import 'model.dart';
import 'writer.dart';

/// Unions the channels of several parsed TDMS files into one flat channel list,
/// preserving order (file by file, group by group, channel by channel) and each
/// channel's properties. When two channels would land on the same group+name,
/// later ones are deterministically suffixed (`v` -> `v#2` -> `v#3`) rather than
/// dropped, so nothing is silently lost when aggregating sharded run outputs.
///
/// This is the composable primitive; [mergeTdms] wraps it to emit bytes.
List<TdmsChannel> mergeTdmsChannels(List<TdmsFile> files) {
  // Dedup key: group + NUL + channel. NUL cannot appear in a name, so the key
  // is collision-proof (group "a b"/channel "c" never equals group "a"/"b c").
  String key(String group, String channel) => '$group\u0000$channel';
  final takenKeys = <String>{};
  final merged = <TdmsChannel>[];
  for (final file in files) {
    for (final group in file.groups) {
      for (final channel in group.channels) {
        var name = channel.name;
        for (var suffix = 2; takenKeys.contains(key(group.name, name)); suffix++) {
          name = '${channel.name}#$suffix';
        }
        takenKeys.add(key(group.name, name));
        merged.add(
          TdmsChannel(
            group: group.name,
            name: name,
            data: channel.data,
            properties: channel.properties,
          ),
        );
      }
    }
  }
  return merged;
}

/// Merges several parsed TDMS files into a single TDMS byte stream: the union of
/// their channels (see [mergeTdmsChannels]) plus group and root properties
/// unioned across files (first file wins on a key conflict). Channels are
/// re-encoded as doubles, matching how the reader decodes numeric data.
Uint8List mergeTdms(List<TdmsFile> files) {
  final channels = mergeTdmsChannels(files);

  final groupProperties = <String, Map<String, Object>>{};
  for (final file in files) {
    for (final group in file.groups) {
      final merged = groupProperties.putIfAbsent(group.name, () => <String, Object>{});
      for (final property in group.properties.entries) {
        merged.putIfAbsent(property.key, () => property.value);
      }
    }
  }

  final fileProperties = <String, Object>{};
  for (final file in files) {
    for (final property in file.properties.entries) {
      fileProperties.putIfAbsent(property.key, () => property.value);
    }
  }

  return (TdmsWriter()..writeSegment(channels, fileProperties: fileProperties, groupProperties: groupProperties))
      .toBytes();
}
