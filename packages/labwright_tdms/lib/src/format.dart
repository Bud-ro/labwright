const List<int> leadInTag = [0x54, 0x44, 0x53, 0x6D];

/// 4713 is TDMS v2.0.
const int tdmsFormatVersion = 4713;
const int leadInByteLength = 28;

enum TocFlag {
  metaData(1 << 1),
  newObjList(1 << 2),
  rawData(1 << 3),
  interleaved(1 << 5),
  bigEndian(1 << 6)
  ;

  const TocFlag(this.mask);
  final int mask;
  bool isSetIn(int tocMask) => (tocMask & mask) != 0;
}

const int noRawDataIndex = 0xFFFFFFFF;
const int sameLayoutAsPreviousIndex = 0;
const int daqmxFormatChangingIndex = 0x1269;
const int daqmxDigitalLineIndex = 0x1369;
const int plainRawDataIndexByteLength = 16;
const int channelArrayDimension = 1;
