/// TDMS wire-format constants shared by the reader and writer.
///
/// A TDMS file is a sequence of segments, each opening with a 28-byte lead-in:
/// the `TDSm` tag, a table-of-contents bitmask, the format version, and two
/// u64 offsets (end of segment, start of raw data) measured from the byte
/// after the lead-in.
library;

/// Segment lead-in tag: the ASCII bytes `TDSm` that open every segment.
const List<int> leadInTag = [0x54, 0x44, 0x53, 0x6D];

/// TDMS format version written/expected in each segment lead-in (4713 = v2.0).
const int tdmsFormatVersion = 4713;

/// Byte length of a segment lead-in: tag (4) + ToC (4) + version (4) +
/// next-segment offset (8) + raw-data offset (8).
const int leadInByteLength = 28;

/// Table-of-contents flags: which parts a segment carries and how its raw data
/// is laid out. The ToC mask itself (and the lead-in tag) is always
/// little-endian; [bigEndian] switches everything after it.
enum TocFlag {
  /// Segment carries a metadata block (object list + properties).
  metaData(1 << 1),

  /// Segment declares a fresh object list (replaces the accumulated one).
  newObjList(1 << 2),

  /// Segment carries raw channel data after the metadata.
  rawData(1 << 3),

  /// Raw data is interleaved sample-major across channels.
  interleaved(1 << 5),

  /// Everything after the ToC mask is big-endian.
  bigEndian(1 << 6);

  const TocFlag(this.mask);

  /// This flag's bit in the ToC mask.
  final int mask;

  /// Whether this flag is set in [tocMask].
  bool isSetIn(int tocMask) => (tocMask & mask) != 0;
}

/// Raw-data index sentinel: this object has no raw data in this segment.
const int noRawDataIndex = 0xFFFFFFFF;

/// Raw-data index sentinel: same layout as this object's previous segment.
const int sameLayoutAsPreviousIndex = 0;

/// Raw-data index sentinel: DAQmx format-changing scaler layout follows.
const int daqmxFormatChangingIndex = 0x1269;

/// Raw-data index sentinel: DAQmx digital-line scaler layout follows.
const int daqmxDigitalLineIndex = 0x1369;

/// Byte length of the plain raw-data index the writer emits:
/// type code (4) + array dimension (4) + value count (8).
const int plainRawDataIndexByteLength = 16;

/// Array dimension written for every channel (TDMS raw data is 1-dimensional).
const int channelArrayDimension = 1;
