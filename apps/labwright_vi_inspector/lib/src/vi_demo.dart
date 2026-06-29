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

  const rsrcMagic = [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a];
  const formatVersion = 3;
  const infoSectionOffset = 32;
  const blockInfoListOffset = 0x34;

  final header = BytesBuilder()..add(rsrcMagic);
  be16(header, formatVersion);
  header
    ..add(fileType.codeUnits)
    ..add('LBVW'.codeUnits);
  be32(header, infoSectionOffset);
  be32(header, 0);
  be32(header, 0x20);
  be32(header, 0);
  final headerBytes = header.toBytes();

  final info = BytesBuilder()..add(headerBytes);
  be32(info, 0);
  be32(info, 0);
  be32(info, 0x20);
  be32(info, blockInfoListOffset);
  be32(info, 0);
  be32(info, blocks.length);
  for (final t in blocks) {
    info
      ..add(t.codeUnits)
      ..add(const [0, 0, 0, 0, 0, 0, 0, 0]);
  }
  info
    ..addByte(name.length)
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
