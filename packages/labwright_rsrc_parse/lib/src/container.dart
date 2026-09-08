import 'dart:typed_data';

import 'viparse.dart' show ViFormatException, readViSections;

const _maxPlausibleBlockCount = 100000;

class ViHeader {
  ViHeader({
    required this.magic,
    required this.formatVersion,
    required this.fileTypeBytes,
    required this.creatorBytes,
    required this.infoOffset,
    required this.infoSize,
    required this.dataOffset,
    required this.dataSize,
  });

  final Uint8List magic;

  final int formatVersion;

  final Uint8List fileTypeBytes;

  final Uint8List creatorBytes;

  final int infoOffset;

  final int infoSize;

  final int dataOffset;

  final int dataSize;

  String get fileType => String.fromCharCodes(fileTypeBytes);
  String get creator => String.fromCharCodes(creatorBytes);

  static const int byteSize = 32;

  static const List<int> _magic = [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a];

  static void _requireRsrcMagic(Uint8List bytes) {
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) throw ViFormatException('not an RSRC/.vi file (bad magic)');
    }
  }

  factory ViHeader.parse(Uint8List bytes) {
    if (bytes.length < byteSize) throw ViFormatException('too small for an RSRC header');
    _requireRsrcMagic(bytes);
    final view = ByteData.sublistView(bytes);
    return ViHeader(
      magic: Uint8List.fromList(bytes.sublist(0, 6)),
      formatVersion: view.getUint16(6),
      fileTypeBytes: Uint8List.fromList(bytes.sublist(8, 12)),
      creatorBytes: Uint8List.fromList(bytes.sublist(12, 16)),
      infoOffset: view.getUint32(16),
      infoSize: view.getUint32(20),
      dataOffset: view.getUint32(24),
      dataSize: view.getUint32(28),
    );
  }

  ViHeader withDataSize(int dataSize) => ViHeader(
    magic: magic,
    formatVersion: formatVersion,
    fileTypeBytes: fileTypeBytes,
    creatorBytes: creatorBytes,
    infoOffset: dataOffset + dataSize,
    infoSize: infoSize,
    dataOffset: dataOffset,
    dataSize: dataSize,
  );

  Uint8List serialize() {
    final out = Uint8List(byteSize);
    final view = ByteData.sublistView(out);
    out.setRange(0, 6, magic);
    view.setUint16(6, formatVersion);
    out.setRange(8, 12, fileTypeBytes);
    out.setRange(12, 16, creatorBytes);
    view
      ..setUint32(16, infoOffset)
      ..setUint32(20, infoSize)
      ..setUint32(24, dataOffset)
      ..setUint32(28, dataSize);
    return out;
  }
}

class ViInfoSubheader {
  ViInfoSubheader({
    required this.headerCopy,
    required this.reservedA,
    required this.blockListRel,
    required this.reservedB,
  });

  final ViHeader headerCopy;

  // TODO: the third word of reservedA is not decoded.
  final Uint8List reservedA;

  final int blockListRel;

  final Uint8List reservedB;

  int? get reservedAMarker => reservedA.length >= 12 ? ByteData.sublistView(reservedA).getUint32(8) : null;

  int? get viNameOffset => reservedB.length == 4 ? ByteData.sublistView(reservedB).getUint32(0) : null;

  factory ViInfoSubheader.parse(Uint8List infoArea) {
    if (infoArea.length < 0x30) throw ViFormatException('info area too small for a subheader');
    final view = ByteData.sublistView(infoArea);
    final blockListRel = view.getUint32(0x2c);
    if (blockListRel < 0x30 || blockListRel > infoArea.length) {
      throw ViFormatException('implausible blockListRel $blockListRel');
    }
    return ViInfoSubheader(
      headerCopy: ViHeader.parse(Uint8List.sublistView(infoArea, 0, ViHeader.byteSize)),
      reservedA: Uint8List.fromList(infoArea.sublist(32, 0x2c)),
      blockListRel: blockListRel,
      reservedB: Uint8List.fromList(infoArea.sublist(0x30, blockListRel)),
    );
  }

  Uint8List serialize() {
    final blr = ByteData(4)..setUint32(0, blockListRel);
    return (BytesBuilder()
          ..add(headerCopy.serialize())
          ..add(reservedA)
          ..add(blr.buffer.asUint8List())
          ..add(reservedB))
        .toBytes();
  }
}

class ViBlockListEntry {
  ViBlockListEntry({required this.tagBytes, required this.sectionCountMinus1, required this.descRel});

  final Uint8List tagBytes;

  final int sectionCountMinus1;

  final int descRel;

  String get tag => String.fromCharCodes(tagBytes);

  static const int byteSize = 12;

  factory ViBlockListEntry.parse(Uint8List info, int at) {
    final view = ByteData.sublistView(info);
    return ViBlockListEntry(
      tagBytes: Uint8List.fromList(info.sublist(at, at + 4)),
      sectionCountMinus1: view.getUint32(at + 4),
      descRel: view.getUint32(at + 8),
    );
  }

  void writeInto(ByteData view, Uint8List out, int at) {
    out.setRange(at, at + 4, tagBytes);
    view
      ..setUint32(at + 4, sectionCountMinus1)
      ..setUint32(at + 8, descRel);
  }
}

class ViBlockList {
  ViBlockList({required this.entries, this.finalEntry});

  final List<ViBlockListEntry> entries;

  final ViBlockListEntry? finalEntry;

  List<ViBlockListEntry> get allEntries => [...entries, if (finalEntry != null) finalEntry!];

  int get count => entries.length;

  int get byteLength => 4 + (entries.length + (finalEntry == null ? 0 : 1)) * ViBlockListEntry.byteSize;

  factory ViBlockList.parse(Uint8List infoArea, int blockListRel) {
    if (blockListRel + 4 > infoArea.length) throw ViFormatException('block list out of range');
    final view = ByteData.sublistView(infoArea);
    final count = view.getUint32(blockListRel);
    if (count > _maxPlausibleBlockCount) throw ViFormatException('implausible block count $count');
    final end = blockListRel + 4 + count * ViBlockListEntry.byteSize;
    if (end > infoArea.length) throw ViFormatException('block list entries out of range');
    final hasFinal = end + ViBlockListEntry.byteSize <= infoArea.length && _printableTagAt(infoArea, end);
    return ViBlockList(
      entries: [
        for (var i = 0; i < count; i++)
          ViBlockListEntry.parse(infoArea, blockListRel + 4 + i * ViBlockListEntry.byteSize),
      ],
      finalEntry: hasFinal ? ViBlockListEntry.parse(infoArea, end) : null,
    );
  }

  static bool _printableTagAt(Uint8List infoArea, int at) {
    for (var i = at; i < at + 4; i++) {
      if (infoArea[i] < 0x20 || infoArea[i] >= 0x7f) return false;
    }
    return true;
  }

  Uint8List serialize() {
    final out = Uint8List(byteLength);
    final view = ByteData.sublistView(out);
    view.setUint32(0, entries.length);
    final all = allEntries;
    for (var i = 0; i < all.length; i++) {
      all[i].writeInto(view, out, 4 + i * ViBlockListEntry.byteSize);
    }
    return out;
  }
}

class ViSectionDescriptor {
  ViSectionDescriptor({
    required this.word0,
    required this.secRel,
    required this.word8,
    required this.nameRef,
    required this.word16,
  });

  /// TODO: not decoded.
  final int word0;

  final int secRel;

  /// TODO: not decoded.
  final int word8;

  /// TODO: the name table this index points into is not located.
  final int nameRef;

  /// TODO: not decoded.
  final int word16;

  static const int commonWord16 = 0xFFFFFFFF;

  static const int byteSize = 20;

  bool get isNamed => nameRef != 0;

  factory ViSectionDescriptor.parse(Uint8List info, int at) {
    if (at < 0 || at + byteSize > info.length) throw ViFormatException('descriptor out of range at $at');
    final view = ByteData.sublistView(info);
    return ViSectionDescriptor(
      word0: view.getUint32(at),
      secRel: view.getUint32(at + 4),
      word8: view.getUint32(at + 8),
      nameRef: view.getUint32(at + 12),
      word16: view.getUint32(at + 16),
    );
  }

  ViSectionDescriptor withSecRel(int secRel) => ViSectionDescriptor(
    word0: word0,
    secRel: secRel,
    word8: word8,
    nameRef: nameRef,
    word16: word16,
  );

  Uint8List serialize() {
    final out = Uint8List(byteSize);
    ByteData.sublistView(out)
      ..setUint32(0, word0)
      ..setUint32(4, secRel)
      ..setUint32(8, word8)
      ..setUint32(12, nameRef)
      ..setUint32(16, word16);
    return out;
  }
}

class ViNameTable {
  ViNameTable({required this.header, required this.trailingNameRecord});

  final Uint8List header;

  int? get headerValue => header.length == 12 ? ByteData.sublistView(header).getUint32(4) : null;

  ViNameTable withHeaderValue(int secRel) {
    final out = Uint8List.fromList(header);
    ByteData.sublistView(out).setUint32(4, secRel);
    return ViNameTable(header: out, trailingNameRecord: trailingNameRecord);
  }

  final Uint8List trailingNameRecord;

  String? get trailingName => trailingNameRecord.isEmpty ? null : String.fromCharCodes(trailingNameRecord, 1);

  factory ViNameTable.parse(Uint8List tail, {int? nameStart}) {
    if (nameStart != null && nameStart >= 0 && nameStart < tail.length) {
      final len = tail[nameStart];
      if (len > 0 && nameStart + 1 + len == tail.length) {
        return ViNameTable(
          header: Uint8List.fromList(tail.sublist(0, nameStart)),
          trailingNameRecord: Uint8List.fromList(tail.sublist(nameStart)),
        );
      }
    }
    final start = _trailingPascalStart(tail);
    if (start == null) {
      return ViNameTable(header: Uint8List.fromList(tail), trailingNameRecord: Uint8List(0));
    }
    return ViNameTable(
      header: Uint8List.fromList(tail.sublist(0, start)),
      trailingNameRecord: Uint8List.fromList(tail.sublist(start)),
    );
  }

  static int? _trailingPascalStart(Uint8List bytes) {
    final maxLen = bytes.length - 1 < 255 ? bytes.length - 1 : 255;
    for (var len = maxLen; len >= 1; len--) {
      final lenPos = bytes.length - 1 - len;
      if (bytes[lenPos] == len && _printableRun(bytes, lenPos + 1)) return lenPos;
    }
    return null;
  }

  static bool _printableRun(Uint8List bytes, int from) {
    for (var i = from; i < bytes.length; i++) {
      if (bytes[i] < 0x20 || bytes[i] >= 0x7f) return false;
    }
    return true;
  }

  Uint8List serialize() =>
      (BytesBuilder()
            ..add(header)
            ..add(trailingNameRecord))
          .toBytes();
}

class ViInfoPreGap {
  ViInfoPreGap({required this.word0, required this.flags});

  /// TODO: not decoded.
  final int word0;

  final int flags;

  static const int byteSize = 8;

  bool get hasEmbeddedSections => flags == 0xFFFFFFFF;

  factory ViInfoPreGap.parse(Uint8List bytes) {
    if (bytes.length < byteSize) throw ViFormatException('preGap record too short (${bytes.length})');
    final view = ByteData.sublistView(bytes);
    return ViInfoPreGap(word0: view.getUint32(0), flags: view.getUint32(4));
  }

  Uint8List serialize() {
    final out = Uint8List(byteSize);
    ByteData.sublistView(out)
      ..setUint32(0, word0)
      ..setUint32(4, flags);
    return out;
  }
}

class ViInfoArea {
  ViInfoArea({
    required this.subheader,
    required this.blockList,
    required this.preGap,
    required this.descriptors,
    required this.nameTable,
  });

  final ViInfoSubheader subheader;
  final ViBlockList blockList;

  final ViInfoPreGap? preGap;

  final List<ViSectionDescriptor> descriptors;

  final ViNameTable nameTable;

  Uint8List get rest =>
      (BytesBuilder()
            ..add(preGap?.serialize() ?? Uint8List(0))
            ..add(_descriptorBytes())
            ..add(nameTable.serialize()))
          .toBytes();

  Uint8List _descriptorBytes() => Uint8List.fromList([for (final descriptor in descriptors) ...descriptor.serialize()]);

  static ({int start, int end})? _cleanDescriptorRun(
    Uint8List infoArea,
    ViBlockList blockList,
    int descBase,
    int restStart,
  ) {
    final maxRecords = infoArea.length ~/ ViSectionDescriptor.byteSize;
    var minStart = infoArea.length, maxEnd = 0;
    for (final entry in blockList.entries) {
      final sectionCount = entry.sectionCountMinus1 + 1;
      for (var sectionIndex = 0; sectionIndex < sectionCount && sectionIndex <= maxRecords; sectionIndex++) {
        final dpos = descBase + entry.descRel + sectionIndex * ViSectionDescriptor.byteSize;
        if (dpos + ViSectionDescriptor.byteSize > infoArea.length) return null;
        if (dpos < minStart) minStart = dpos;
        if (dpos + ViSectionDescriptor.byteSize > maxEnd) maxEnd = dpos + ViSectionDescriptor.byteSize;
      }
    }
    if (maxEnd > minStart &&
        minStart == restStart + ViInfoPreGap.byteSize &&
        (maxEnd - minStart) % ViSectionDescriptor.byteSize == 0) {
      return (start: minStart, end: maxEnd);
    }
    return null;
  }

  factory ViInfoArea.parse(Uint8List infoArea) {
    final subheader = ViInfoSubheader.parse(infoArea);
    final blockList = ViBlockList.parse(infoArea, subheader.blockListRel);
    final restStart = subheader.blockListRel + blockList.byteLength;
    final descBase = subheader.blockListRel + 8;

    final run = _cleanDescriptorRun(infoArea, blockList, descBase, restStart);
    if (run != null) {
      final total = (run.end - run.start) ~/ ViSectionDescriptor.byteSize;
      final viNameOffset = subheader.viNameOffset;
      return ViInfoArea(
        subheader: subheader,
        blockList: blockList,
        preGap: ViInfoPreGap.parse(Uint8List.fromList(infoArea.sublist(restStart, restStart + ViInfoPreGap.byteSize))),
        descriptors: [
          for (var i = 0; i < total; i++)
            ViSectionDescriptor.parse(infoArea, run.start + i * ViSectionDescriptor.byteSize),
        ],
        nameTable: ViNameTable.parse(
          Uint8List.fromList(infoArea.sublist(run.end)),
          nameStart: viNameOffset == null ? null : viNameOffset - run.end,
        ),
      );
    }
    return ViInfoArea(
      subheader: subheader,
      blockList: blockList,
      preGap: null,
      descriptors: const [],
      nameTable: ViNameTable.parse(Uint8List.fromList(infoArea.sublist(restStart))),
    );
  }

  int? get nameTableStart => preGap == null
      ? null
      : subheader.blockListRel +
            blockList.byteLength +
            ViInfoPreGap.byteSize +
            descriptors.length * ViSectionDescriptor.byteSize;

  int? get finalEntrySecRel {
    final entry = blockList.finalEntry;
    final start = nameTableStart;
    if (entry == null || start == null) return null;
    if (subheader.blockListRel + 8 + entry.descRel != start) return null;
    return nameTable.headerValue;
  }

  ViInfoArea withRemappedSecRels(Map<int, int> newSecRelByOld) {
    if (newSecRelByOld.isEmpty) return this;
    final finalSecRel = finalEntrySecRel;
    final newFinalSecRel = finalSecRel == null ? null : newSecRelByOld[finalSecRel];
    final accounted = {for (final descriptor in descriptors) descriptor.secRel, if (finalSecRel != null) finalSecRel};
    for (final MapEntry(key: oldSecRel, value: newSecRel) in newSecRelByOld.entries) {
      if (newSecRel != oldSecRel && !accounted.contains(oldSecRel)) {
        throw ViFormatException('section at $oldSecRel moved to $newSecRel but no descriptor accounts for it');
      }
    }
    return ViInfoArea(
      subheader: subheader,
      blockList: blockList,
      preGap: preGap,
      descriptors: [
        for (final descriptor in descriptors)
          if (newSecRelByOld[descriptor.secRel] case final newSecRel?
              when descriptor.word16 == ViSectionDescriptor.commonWord16)
            descriptor.withSecRel(newSecRel)
          else
            descriptor,
      ],
      nameTable: newFinalSecRel == null ? nameTable : nameTable.withHeaderValue(newFinalSecRel),
    );
  }

  Uint8List serialize() =>
      (BytesBuilder()
            ..add(subheader.serialize())
            ..add(blockList.serialize())
            ..add(rest))
          .toBytes();
}

class ViContainer {
  ViContainer({required this.header, required this.dataArea, required this.infoArea});

  final Uint8List header;

  final Uint8List dataArea;

  final Uint8List infoArea;

  ViHeader get parsedHeader => ViHeader.parse(header);

  ViInfoSubheader get parsedInfoSubheader => ViInfoSubheader.parse(infoArea);

  ViBlockList get parsedBlockList => ViBlockList.parse(infoArea, parsedInfoSubheader.blockListRel);

  ViInfoArea get parsedInfoArea => ViInfoArea.parse(infoArea);

  Uint8List serialize() => _concat3(parsedHeader.serialize(), dataArea, parsedInfoArea.serialize());

  factory ViContainer.parse(Uint8List bytes) {
    if (bytes.length < 32) throw ViFormatException('too small to be an RSRC file');
    ViHeader._requireRsrcMagic(bytes);
    final view = ByteData.sublistView(bytes);
    final infoOffset = view.getUint32(16);
    final dataOffset = view.getUint32(24);
    if (dataOffset < 32 || dataOffset > infoOffset || infoOffset > bytes.length) {
      throw ViFormatException(
        'unexpected region order (dataOffset=$dataOffset, infoOffset=$infoOffset, len=${bytes.length})',
      );
    }
    return ViContainer(
      header: Uint8List.sublistView(bytes, 0, dataOffset),
      dataArea: Uint8List.sublistView(bytes, dataOffset, infoOffset),
      infoArea: Uint8List.sublistView(bytes, infoOffset, bytes.length),
    );
  }

  Uint8List toBytes() => _concat3(header, dataArea, infoArea);
}

class ViVi {
  ViVi({required this.header, required this.dataSegments, required this.infoArea});

  final ViHeader header;
  final List<ViDataSegment> dataSegments;
  final ViInfoArea infoArea;

  factory ViVi.parse(Uint8List bytes) {
    final container = ViContainer.parse(bytes);
    return ViVi(
      header: ViHeader.parse(container.header),
      dataSegments: ViExport.decomposeDataArea(bytes),
      infoArea: ViInfoArea.parse(container.infoArea),
    );
  }

  String? get name => infoArea.nameTable.trailingName;

  Iterable<ViSectionData> get sections => dataSegments.whereType<ViSectionData>();

  ViVi withSectionEdited({required int secRel, required Uint8List newPayload}) =>
      ViVi.parse(ViExport.editSection(serialize(), secRel: secRel, newPayload: newPayload));

  Uint8List serialize() {
    final data = ViExport.rebuildDataArea(dataSegments);
    final newSecRelByOld = <int, int>{};
    var pos = 0;
    for (final segment in dataSegments) {
      switch (segment) {
        case ViGap(:final bytes):
          pos += bytes.length;
        case ViSectionData(:final secRel, :final payload):
          newSecRelByOld[secRel] = pos;
          pos += 4 + payload.length;
      }
    }
    return _concat3(
      header.withDataSize(data.length).serialize(),
      data,
      infoArea.withRemappedSecRels(newSecRelByOld).serialize(),
    );
  }
}

sealed class ViDataSegment {
  const ViDataSegment();
}

class ViGap extends ViDataSegment {
  const ViGap(this.bytes);
  final Uint8List bytes;
}

class ViSectionData extends ViDataSegment {
  const ViSectionData({required this.secRel, required this.payload});
  final int secRel;
  final Uint8List payload;
}

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _concat3(Uint8List a, Uint8List b, Uint8List c) {
  final out = Uint8List(a.length + b.length + c.length);
  out
    ..setRange(0, a.length, a)
    ..setRange(a.length, a.length + b.length, b)
    ..setRange(a.length + b.length, out.length, c);
  return out;
}

abstract final class ViExport {
  static List<ViDataSegment> decomposeDataArea(Uint8List viBytes) {
    final container = ViContainer.parse(viBytes);
    final data = container.dataArea;
    final bd = ByteData.sublistView(data);
    final secRels = <int>{for (final section in readViSections(viBytes)) section.dataOffset}.toList()..sort();
    final segs = <ViDataSegment>[];
    var pos = 0;
    for (final secRel in secRels) {
      if (secRel < pos || secRel + 4 > data.length) continue;
      if (secRel > pos) segs.add(ViGap(Uint8List.sublistView(data, pos, secRel)));
      final len = bd.getUint32(secRel);
      final end = secRel + 4 + len;
      if (end > data.length) {
        segs.add(ViGap(Uint8List.sublistView(data, secRel)));
        pos = data.length;
        break;
      }
      segs.add(ViSectionData(secRel: secRel, payload: Uint8List.sublistView(data, secRel + 4, end)));
      pos = end;
    }
    if (pos < data.length) segs.add(ViGap(Uint8List.sublistView(data, pos)));
    return segs;
  }

  static Uint8List rebuildDataArea(List<ViDataSegment> segments) {
    final out = BytesBuilder();
    for (final segment in segments) {
      switch (segment) {
        case ViGap(:final bytes):
          out.add(bytes);
        case ViSectionData(:final payload):
          final prefix = ByteData(4)..setUint32(0, payload.length);
          out
            ..add(prefix.buffer.asUint8List())
            ..add(payload);
      }
    }
    return out.toBytes();
  }

  static Uint8List editSection(Uint8List viBytes, {required int secRel, required Uint8List newPayload}) {
    final container = ViContainer.parse(viBytes);
    final segs = decomposeDataArea(viBytes);
    if (!_listEquals(rebuildDataArea(segs), container.dataArea)) {
      throw ViFormatException('data area does not cleanly decompose; refusing to edit');
    }
    if (!segs.whereType<ViSectionData>().any((s) => s.secRel == secRel)) {
      throw ViFormatException('no section at secRel $secRel to edit');
    }
    final newSegs = [
      for (final segment in segs)
        if (segment is ViSectionData && segment.secRel == secRel)
          ViSectionData(secRel: secRel, payload: newPayload)
        else
          segment,
    ];
    return ViVi(
      header: ViHeader.parse(container.header),
      dataSegments: newSegs,
      infoArea: ViInfoArea.parse(container.infoArea),
    ).serialize();
  }
}
