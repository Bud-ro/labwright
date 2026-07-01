/// Decoder for the `HLPP` block — the VI's **help-document path** (the file the
/// "Detailed help" link opens), stored in LabVIEW's `PTH0` path format.
///
/// Corpus-confirmed (128/128): the block is `"PTH0"` + `i32 innerLen`
/// (== blockLen-8) + `i16 pathType` + `i16 componentCount` + that many
/// Pascal-string path components (`[u8 len][chars]`). Joining the components with
/// `/` gives the path (e.g. `<helpdir>/JKI/Caraya/README.html`). Self-consistent:
/// 12-byte header + Σ(1+len) == block length.
///
/// Clean-room. The `PTH0` framing + component recovery are CONFIRMED; the exact
/// `pathType` enumeration (relative / absolute / UNC) is not yet pinned (LIKELY).
library;

import 'dart:typed_data';

/// ASCII `"PTH0"` — the four magic bytes that head a LabVIEW path record.
const List<int> _pth0Magic = [0x50, 0x54, 0x48, 0x30];

/// A decoded `PTH0` path (from an `HLPP` block).
class ViHelpPath {
  const ViHelpPath({
    required this.rawLength,
    required this.isPth0,
    required this.pathType,
    required this.components,
  });

  final int rawLength;

  final bool isPth0;

  /// `i16 @8` — the path kind (0 = relative-style in the corpus; full enumeration
  /// not yet pinned). LIKELY.
  final int pathType;

  /// The path components in order (`<helpdir>`, `JKI`, `Caraya`, `README.html`).
  final List<String> components;

  String get path => components.join('/');
}

/// Decodes an `HLPP` (`PTH0`) body. Null when too short for the header; returns
/// `isPth0: false` (empty path) when the magic is absent rather than guessing.
ViHelpPath? decodeHelpPath(Uint8List b) {
  if (b.length < 12) return null;
  final isPth0 =
      b[0] == _pth0Magic[0] && b[1] == _pth0Magic[1] && b[2] == _pth0Magic[2] && b[3] == _pth0Magic[3];
  if (!isPth0) {
    return ViHelpPath(rawLength: b.length, isPth0: false, pathType: 0, components: const []);
  }
  final bd = ByteData.sublistView(b);
  final pathType = bd.getUint16(8);
  final count = bd.getUint16(10);
  final components = <String>[];
  var p = 12;
  for (var i = 0; i < count; i++) {
    if (p >= b.length) break;
    final len = b[p];
    p++;
    if (p + len > b.length) break;
    components.add(String.fromCharCodes(b.sublist(p, p + len)));
    p += len;
  }
  return ViHelpPath(rawLength: b.length, isPth0: true, pathType: pathType, components: components);
}
