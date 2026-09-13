import 'dart:typed_data';

import '../viparse.dart' show ViSection;

class ViConnectorPane {
  const ViConnectorPane({required this.rawLength, this.typeIndex, required this.isInline});

  final int rawLength;

  /// 1-based index into the VCTP type pool.
  final int? typeIndex;

  final bool isInline;

  Uint8List? serialize() {
    final index = typeIndex;
    if (isInline || index == null) return null;
    final out = Uint8List(2);
    ByteData.sublistView(out).setUint16(0, index);
    return out;
  }
}

ViConnectorPane? decodeConnectorPane(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  final inline = bytes.length != 2;
  return ViConnectorPane(
    rawLength: bytes.length,
    typeIndex: inline ? null : ByteData.sublistView(bytes).getUint16(0),
    isInline: inline,
  );
}

ViConnectorPane? connectorPaneFromSections(Iterable<ViSection> sections) {
  ViSection? conp, cpc2;
  for (final section in sections) {
    if (section.tag == 'CONP') conp = section;
    if (section.tag == 'CPC2') cpc2 = section;
  }
  final pick = conp ?? cpc2;
  return pick == null ? null : decodeConnectorPane(pick.bytes);
}
