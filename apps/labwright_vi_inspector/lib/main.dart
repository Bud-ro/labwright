import 'package:flutter/material.dart';

import 'src/vi_screen.dart';

void main() => runApp(const ViInspectorApp());

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
