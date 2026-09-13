/// `HLPP` / `DLLP` — the context-help document path and a linked DLL's path: one `PTH0`
/// path filling the payload.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     magic                      4cc      "PTH0"
/// 4       4     length                     u32      bytes that follow this word
/// 8       2     pathType                   u16      role TODO; 1 with an empty first component is
///                                                   a relative path
/// 10      2     componentCount             u16      number of components
/// 12      rest  components                 pstr[componentCount] the path components
/// ```
///
/// [decodeHelpPath] requires the payload to be one complete `PTH0` and returns its [ViPath].
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../pth0.dart';

const BlockLayout helpPathLayout = pth0Layout;

ViPath decodeHelpPath(Uint8List bytes) => decodePth0(bytes);
