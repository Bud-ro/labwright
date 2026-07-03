// Investigative map of an old-format binary TOF1 record region — the working
// surface for decoding the container nesting that [binaryPropertyRecords] does
// not yet recover. Prints, in offset order: decoded leaf records (name = value),
// container candidates, and the `0xffffffff` group delimiters.
//
// Defaults to the content-exact Rosetta oracle `OutputVoltage_BIN.seq` (pass a
// path to inspect another fetched binary). Run:
//   dart run tool/binary_record_map.dart [path/to/file.seq]
//
// What the map has established (validated on the OutputVoltage twin):
//   * A property record leads with `0x40`/`0x44`, carries two zero framing u32s
//     at +2 and +10, and a `size` word at +6. `size` is 4 (bare) or 6 (valued)
//     for LEAF records — those are decoded by [binaryPropertyRecords].
//   * `size > 16` marks a CONTAINER/descriptor record (`Objs`, `Obj`, and the
//     result-string holders `Status`/`ReportText`). `size` is NOT the byte span
//     of the container's children: it recurs at a fixed value per property type
//     (e.g. `Str:Status` is always 36) regardless of content, so it reads as a
//     type-descriptor constant, not a nesting extent. (Refuted: `at{,+6,+14,+22}
//     + size` does not land on the group delimiters.)
//   * ~0x40 leads also occur mid-value (inside f64 bytes); those fail the
//     double-zero framing test (their `size` reads as a power-of-two like
//     `0x02000000`) and are filtered out here.
//
// Open (the next decode): the sequence/step TREE is not framed by `size`. It is
// most likely held in the header node-table at the region start (a run of
// pool-index words before the first framed record) — to be cracked by
// differential analysis across the Rosetta twin set.
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';

const _leadBytes = {0x40, 0x44};
const _maxLeafSize = 16;
const _sizeSanityCap = 100000;

File _defaultOracle() {
  const rel = 'corpus/seq/rosetta/OutputVoltage_BIN.seq';
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    for (final base in ['${dir.path}/packages/labwright_seq/$rel', '${dir.path}/$rel']) {
      if (File(base).existsSync()) return File(base);
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return File(rel);
}

void main(List<String> args) {
  final file = args.isNotEmpty ? File(args[0]) : _defaultOracle();
  if (!file.existsSync()) {
    stderr.writeln('not found: ${file.path} (fetch the corpus, or pass a path)');
    exit(1);
  }
  final bytes = Uint8List.fromList(file.readAsBytesSync());
  final body = inflateBinaryBody(bytes);
  final layout = analyzeBinaryBody(bytes);
  if (body == null || layout == null) {
    stderr.writeln('not an inflatable binary TOF1 file: ${file.path}');
    exit(1);
  }
  final recordRegionLength = layout.recordRegionLength;
  final view = ByteData.sublistView(body);

  final pool = <String>[];
  var at = recordRegionLength;
  while (at < body.length) {
    final start = at;
    while (at < body.length && body[at] != 0) {
      at++;
    }
    pool.add(String.fromCharCodes(body.sublist(start, at)));
    at++;
  }
  String name(int index) => index >= 0 && index < pool.length ? pool[index] : '<$index>';

  var leaves = 0;
  var containers = 0;
  var delimiters = 0;
  for (var offset = 0; offset + 4 <= recordRegionLength; offset++) {
    if (view.getUint32(offset, Endian.little) == 0xffffffff && offset % 4 == 0) {
      delimiters++;
      continue;
    }
    if (!_leadBytes.contains(body[offset]) || offset + 22 > recordRegionLength) continue;
    final zeroA = view.getUint32(offset + 2, Endian.little);
    final zeroB = view.getUint32(offset + 10, Endian.little);
    final size = view.getUint32(offset + 6, Endian.little);
    if (zeroA != 0 || zeroB != 0 || size < 2 || size > _sizeSanityCap) continue;
    final typeIndex = view.getUint32(offset + 14, Endian.little);
    final nameIndex = view.getUint32(offset + 18, Endian.little);
    if (typeIndex >= pool.length || nameIndex >= pool.length) continue;
    if (size <= _maxLeafSize) {
      leaves++;
    } else {
      containers++;
      stdout.writeln('  container @0x${offset.toRadixString(16).padLeft(4, '0')} '
          'size=$size ${name(typeIndex)}:${name(nameIndex)}');
    }
  }

  final records = binaryPropertyRecords(bytes);
  stdout
    ..writeln('${file.uri.pathSegments.last}: recordRegion=$recordRegionLength bytes, '
        'pool=${pool.length} names')
    ..writeln('leaf records decoded: ${records.length} '
        '(${records.where((r) => r.value != null).length} valued)')
    ..writeln('framed-leaf candidates: $leaves · container candidates: $containers '
        '· group delimiters: $delimiters');
}
