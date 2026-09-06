import 'dart:typed_data';

import 'model.dart';
import 'writer.dart';

List<TdmsChannel> mergeTdmsChannels(List<TdmsFile> files) {
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
