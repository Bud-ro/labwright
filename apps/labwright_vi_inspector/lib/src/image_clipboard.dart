import 'dart:typed_data';

import 'package:super_clipboard/super_clipboard.dart';

abstract class ImageClipboard {
  Future<bool> copyPng(Uint8List pngBytes);
}

class SystemImageClipboard implements ImageClipboard {
  const SystemImageClipboard();

  @override
  Future<bool> copyPng(Uint8List pngBytes) async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return false;
    final item = DataWriterItem()..add(Formats.png(pngBytes));
    try {
      await clipboard.write([item]);
      return true;
    } catch (_) {
      return false;
    }
  }
}
