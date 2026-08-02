import 'package:flutter/material.dart';

import 'src/bd_text_font.dart';
import 'src/vi_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Prefer the host system's own Windows UI face for diagram text when one
  // is installed (runtime-only; see [loadSystemUiFont] for the licensing
  // rationale) — the bundled Selawik stays the fallback.
  await loadSystemUiFont();
  runApp(const ViInspectorApp());
}

/// Example Labwright VI inspector: import a LabVIEW `.vi`/`.ctl` and see what it
/// is and does.
class ViInspectorApp extends StatelessWidget {
  const ViInspectorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Labwright VI Inspector',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const ViInspectorScreen(),
    );
  }
}
