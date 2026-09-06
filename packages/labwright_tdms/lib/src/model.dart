enum TdsType {
  i8(1, 1),
  i16(2, 2),
  i32(3, 4),
  i64(4, 8),
  u8(5, 1),
  u16(6, 2),
  u32(7, 4),
  u64(8, 8),
  singleFloat(9, 4),
  doubleFloat(10, 8),
  string(0x20, -1),
  boolean(0x21, 1),
  timestamp(0x44, 16)
  ;

  const TdsType(this.code, this.width);

  final int code;

  final int width;

  static TdsType? fromCode(int code) {
    for (final type in values) {
      if (type.code == code) return type;
    }
    return null;
  }
}

class TdmsFormatException implements Exception {
  TdmsFormatException(this.message);
  final String message;
  @override
  String toString() => 'TdmsFormatException: $message';
}

class TdmsChannel {
  TdmsChannel({
    required this.group,
    required this.name,
    required this.data,
    this.type = TdsType.doubleFloat,
    this.properties = const {},
  });

  final String group;
  final String name;
  final List<double> data;
  final TdsType type;
  final Map<String, Object> properties;
}

class TdmsFile {
  TdmsFile(this.properties, this.groups);

  final Map<String, Object> properties;

  final List<TdmsGroup> groups;

  TdmsGroup? group(String name) {
    for (final group in groups) {
      if (group.name == name) return group;
    }
    return null;
  }
}

class TdmsGroup {
  TdmsGroup(this.name, this.properties, this.channels);

  final String name;

  final Map<String, Object> properties;

  final List<TdmsChannelData> channels;

  TdmsChannelData? channel(String name) {
    for (final channel in channels) {
      if (channel.name == name) return channel;
    }
    return null;
  }
}

class TdmsChannelData {
  TdmsChannelData(this.group, this.name, this.properties, this.data);

  final String group;

  final String name;

  final Map<String, Object> properties;

  final List<double> data;
}
