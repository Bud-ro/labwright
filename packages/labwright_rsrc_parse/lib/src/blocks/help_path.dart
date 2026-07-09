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

/// The fixed `PTH0` header length: 4 magic bytes + `i16 pathType@8` +
/// `i16 componentCount@10`, before the first path component.
const _pth0HeaderLen = 12;

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

  /// Re-emits `"PTH0" [i32 innerLen == rawLength-8][i16 pathType][i16 count]`
  /// then each component as `[u8 len][chars]`. The `innerLen` is regenerated
  /// from the block length (`== rawLength-8` for every corpus `HLPP`). Null for a
  /// non-`PTH0` body (nothing to reconstruct). A component whose chars are not
  /// single-byte re-encodes lossily; the writer's byte-exact re-check keeps such
  /// a block copied rather than emitting a wrong path.
  Uint8List? serialize() {
    if (!isPth0) return null;
    var body = _pth0HeaderLen;
    for (final c in components) {
      body += 1 + c.length;
    }
    final out = Uint8List(body);
    final bd = ByteData.sublistView(out);
    out.setRange(0, 4, _pth0Magic);
    bd.setUint32(4, rawLength - 8);
    bd.setUint16(8, pathType);
    bd.setUint16(10, components.length);
    var pos = _pth0HeaderLen;
    for (final c in components) {
      out[pos++] = c.length & 0xff;
      for (var i = 0; i < c.length; i++) {
        out[pos++] = c.codeUnitAt(i) & 0xff;
      }
    }
    return out;
  }
}

/// Decodes an `HLPP` (`PTH0`) body. Null when too short for the header; returns
/// `isPth0: false` (empty path) when the magic is absent rather than guessing.
ViHelpPath? decodeHelpPath(Uint8List body) {
  if (body.length < _pth0HeaderLen) return null;
  final isPth0 = _pth0Magic.indexed.every((e) => body[e.$1] == e.$2);
  if (!isPth0) {
    return ViHelpPath(rawLength: body.length, isPth0: false, pathType: 0, components: const []);
  }
  final bd = ByteData.sublistView(body);
  final pathType = bd.getUint16(8);
  final count = bd.getUint16(10);
  final components = <String>[];
  var pos = _pth0HeaderLen;
  for (var i = 0; i < count; i++) {
    if (pos >= body.length) break;
    final len = body[pos];
    pos++;
    if (pos + len > body.length) break;
    components.add(String.fromCharCodes(body, pos, pos + len));
    pos += len;
  }
  return ViHelpPath(rawLength: body.length, isPth0: true, pathType: pathType, components: components);
}
