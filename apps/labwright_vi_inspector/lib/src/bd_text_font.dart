import 'dart:io';

import 'package:flutter/services.dart';

/// The font family the block-diagram painter lays out and paints text with:
/// the bundled, metric-compatible Selawik by default, swapped to the host
/// system's own Windows UI face when [loadSystemUiFont] finds and registers
/// one.
String bdTextFontFamily = 'Selawik';

/// The registration name for the host system's UI face (see
/// [loadSystemUiFont]).
const String kBdSystemUiFamily = 'BdSystemUi';

/// Registers the host system's own Windows UI text face (`segoeui.ttf` +
/// `segoeuib.ttf`) for diagram text and prefers it over the bundled Selawik,
/// returning whether a face was found.
///
/// Licensing: the face is read AT RUNTIME from the host's licensed Windows
/// installation and is never bundled, committed, or written anywhere —
/// redistributing the font is not licensed, while rendering with the copy
/// the user's own Windows install provides is. Probed locations: the
/// `LW_SEGOE_DIR` environment override, then the standard install font
/// directory (`C:\Windows\Fonts` natively; `/mnt/c/Windows/Fonts` under
/// WSL). Absent a face, the bundled Selawik stays in effect.
Future<bool> loadSystemUiFont() async {
  final dirs = [
    Platform.environment['LW_SEGOE_DIR'],
    r'C:\Windows\Fonts',
    '/mnt/c/Windows/Fonts',
  ];
  for (final dir in dirs) {
    if (dir == null) continue;
    final sep = dir.contains('\\') ? '\\' : '/';
    final regular = File('$dir${sep}segoeui.ttf');
    if (!regular.existsSync()) continue;
    final loader = FontLoader(kBdSystemUiFamily)
      ..addFont(Future.value(ByteData.sublistView(regular.readAsBytesSync())));
    final bold = File('$dir${sep}segoeuib.ttf');
    if (bold.existsSync()) {
      loader.addFont(
        Future.value(ByteData.sublistView(bold.readAsBytesSync())),
      );
    }
    await loader.load();
    bdTextFontFamily = kBdSystemUiFamily;
    return true;
  }
  return false;
}
