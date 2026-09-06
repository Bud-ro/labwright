import 'dart:typed_data';

import 'package:labwright_tdms/labwright_tdms.dart';

TdmsChannel ch(
  String group,
  String name,
  List<double> data, {
  TdsType type = TdsType.doubleFloat,
  Map<String, Object> props = const {},
}) => TdmsChannel(group: group, name: name, data: data, type: type, properties: props);

Uint8List write(
  List<TdmsChannel> channels, {
  Map<String, Object> fileProps = const {},
  Map<String, Map<String, Object>> groupProps = const {},
}) => (TdmsWriter()..writeSegment(channels, fileProperties: fileProps, groupProperties: groupProps)).toBytes();

TdmsFile reread(
  List<TdmsChannel> channels, {
  Map<String, Object> fileProps = const {},
  Map<String, Map<String, Object>> groupProps = const {},
}) => TdmsReader.read(write(channels, fileProps: fileProps, groupProps: groupProps));

Map<String, List<double>> channelsOf(TdmsFile f) => {
  for (final g in f.groups)
    for (final c in g.channels) '${g.name}/${c.name}': c.data,
};
