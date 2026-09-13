import 'dart:typed_data';

const List<int> _pth0Magic = [0x50, 0x54, 0x48, 0x30];

const _pth0HeaderLen = 12;

class ViHelpPath {
  const ViHelpPath({
    required this.rawLength,
    required this.isPth0,
    required this.pathType,
    required this.components,
  });

  final int rawLength;

  final bool isPth0;

  final int pathType;

  final List<String> components;

  String get path => components.join('/');

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
