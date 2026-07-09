import 'dart:typed_data';

import 'package:super_clipboard/super_clipboard.dart';

/// Writes an image to the system clipboard as an actual image (PNG), not text.
/// Injected into the images view so the real OS-backed implementation can be
/// swapped for a fake in tests.
abstract class ImageClipboard {
  /// Writes [pngBytes] to the clipboard as a PNG image. Returns true on success,
  /// false when no clipboard is available (e.g. an unsupported platform) or the
  /// write fails.
  Future<bool> copyPng(Uint8List pngBytes);
}

/// The OS-backed [ImageClipboard]: puts a PNG on the system clipboard via
/// `super_clipboard` (PNG is a first-class clipboard format on desktop and web).
/// Total: returns false rather than throwing when the platform exposes no
/// clipboard or the native write fails.
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
