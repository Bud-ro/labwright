/// The TDMS data model: the on-disk type catalog and the parsed in-memory
/// shapes ([TdmsFile] → [TdmsGroup] → [TdmsChannelData]).
library;

/// LabVIEW TDMS data-type codes (`tdsDataType`), with each type's fixed element
/// width in bytes (`-1` = variable-length, i.e. string).
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
  timestamp(0x44, 16);

  const TdsType(this.code, this.width);

  /// The on-disk `tdsDataType` code.
  final int code;

  /// Fixed element width in bytes, or `-1` for variable-length (string).
  final int width;

  /// The type for [code], or null if unknown/unsupported.
  static TdsType? fromCode(int code) {
    for (final type in values) {
      if (type.code == code) return type;
    }
    return null;
  }
}

/// Thrown when TDMS bytes are malformed — truncated, or with declared
/// lengths/counts that exceed the data. The reader bounds-checks every read, so
/// it raises this (never `RangeError`, an out-of-memory, or a hang) on bad input.
class TdmsFormatException implements Exception {
  TdmsFormatException(this.message);
  final String message;
  @override
  String toString() => 'TdmsFormatException: $message';
}

/// One channel's worth of data to write in a segment. [data] is always supplied
/// as doubles; [type] selects the on-disk numeric encoding (default
/// [TdsType.doubleFloat]). Integer types take `value.toInt()`. String/bool/
/// timestamp channels are not written. Properties may be String/int/double/bool.
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

/// Parsed TDMS file: root [properties] plus ordered [groups].
class TdmsFile {
  TdmsFile(this.properties, this.groups);

  final Map<String, Object> properties;

  final List<TdmsGroup> groups;

  /// The group named [name], or null if absent.
  TdmsGroup? group(String name) {
    for (final group in groups) {
      if (group.name == name) return group;
    }
    return null;
  }
}

/// One TDMS group (a named collection of channels).
class TdmsGroup {
  TdmsGroup(this.name, this.properties, this.channels);

  final String name;

  final Map<String, Object> properties;

  final List<TdmsChannelData> channels;

  /// The channel named [name] in this group, or null if absent.
  TdmsChannelData? channel(String name) {
    for (final channel in channels) {
      if (channel.name == name) return channel;
    }
    return null;
  }
}

/// One channel's decoded data and metadata. Numeric samples are surfaced as
/// doubles; non-numeric channels carry their value(s) in [properties] with empty
/// [data].
class TdmsChannelData {
  TdmsChannelData(this.group, this.name, this.properties, this.data);

  final String group;

  final String name;

  final Map<String, Object> properties;

  /// Decoded numeric samples (empty for non-numeric channels).
  final List<double> data;
}
