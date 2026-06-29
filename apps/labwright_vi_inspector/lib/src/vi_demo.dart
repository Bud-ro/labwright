import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Builds a minimal but valid LabVIEW **RSRC** byte buffer so the inspector can
/// be demoed without a real `.vi` on hand. Mirrors the structure `parseVi`
/// expects (header + repeated info section + block-info list + trailing name).
Uint8List demoViBytes({
  String fileType = 'LVIN',
  List<String> blocks = const ['vers', 'FPHb', 'BDHb', 'CONP', 'LIvi'],
  String name = 'demo.vi',
}) {
  void be16(BytesBuilder b, int v) => b.add((ByteData(2)..setUint16(0, v)).buffer.asUint8List());
  void be32(BytesBuilder b, int v) => b.add((ByteData(4)..setUint32(0, v)).buffer.asUint8List());

  final header = BytesBuilder()..add(const [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a]); // RSRC\r\n
  be16(header, 3); // format version
  header
    ..add(fileType.codeUnits) // file type (4 bytes)
    ..add('LBVW'.codeUnits); // creator (4 bytes)
  be32(header, 32); // info section offset (right after this 32-byte header)
  be32(header, 0); // info size (unused by parser)
  be32(header, 0x20); // data offset (unused)
  be32(header, 0); // data size (unused)
  final headerBytes = header.toBytes();

  final info = BytesBuilder()..add(headerBytes); // info section repeats the header
  be32(info, 0);
  be32(info, 0);
  be32(info, 0x20);
  be32(info, 0x34); // offset to the block-info list
  be32(info, 0);
  be32(info, blocks.length); // block count
  for (final t in blocks) {
    info
      ..add(t.codeUnits)
      ..add(const [0, 0, 0, 0, 0, 0, 0, 0]); // two u32 per entry (unused here)
  }
  info
    ..addByte(name.length) // trailing length-prefixed VI name
    ..add(name.codeUnits);

  return (BytesBuilder()
        ..add(headerBytes)
        ..add(info.toBytes()))
      .toBytes();
}

/// Result of trying to parse a buffer: either a [summary] or a human [error].
class ViLoad {
  const ViLoad.ok(this.summary) : error = null;
  const ViLoad.failed(this.error) : summary = null;

  final ViSummary? summary;
  final String? error;

  bool get isOk => summary != null;
}

/// Parses [bytes] into a [ViLoad], turning a [ViFormatException] into a friendly
/// message instead of throwing. Keeps the UI layer free of try/catch.
ViLoad summarize(Uint8List bytes) {
  try {
    return ViLoad.ok(parseVi(bytes));
  } on ViFormatException catch (e) {
    return ViLoad.failed('Not a LabVIEW RSRC (.vi/.ctl) file: ${e.message}');
  } catch (e) {
    // Defense in depth: `parseVi` is proven total by the viparse fuzz suite, but
    // a UI importer pointed at random internet files must never crash — surface
    // anything unforeseen calmly instead of taking down the app.
    return ViLoad.failed('Could not parse this file: $e');
  }
}

/// Human descriptions for the common 4-char RSRC block tags, so the inventory
/// reads as more than opaque codes. Unknown tags fall back to "resource block".
const Map<String, String> kBlockGlossary = {
  'BDHb': 'Block diagram — compiled logic',
  'BDHP': 'Block diagram — heap',
  'FPHb': 'Front panel — UI',
  'FPHP': 'Front panel — heap',
  'CONP': 'Connector pane — I/O signature',
  'CPC2': 'Connector pane — compiled',
  'LIvi': 'Sub-VI links',
  'LIbd': 'Sub-VI links — block diagram',
  'LIfp': 'Sub-VI links — front panel',
  'vers': 'Version info',
  'LVSR': 'VI state record',
  'VICD': 'Compiled code',
  'DFDS': 'Default data',
  'icl8': 'Icon — 8-bit',
};
