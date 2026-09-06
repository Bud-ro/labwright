import 'package:flutter/material.dart';

import 'src/bd_text_font.dart';
import 'src/vi_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadSystemUiFont();
  runApp(const ViInspectorApp());
}

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
