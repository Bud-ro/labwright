import 'package:flutter/material.dart';
import 'package:labwright_videcode/labwright_videcode.dart';

/// Read-only view of the VI's recovered **data-type dictionary** (the VCTP type
/// pool): named typedefs rendered structurally — enums with their item values,
/// clusters with their typed fields, others as `kind name`. This surfaces the
/// deep type recovery that otherwise only appears as comments in the generated
/// Dart scaffold.
class ViTypesView extends StatelessWidget {
  const ViTypesView({super.key, required this.model});

  final ViModel? model;

  String _render(ViModel m) {
    final named = namedTypes(m.types);
    final b = StringBuffer()
      ..writeln('// Recovered data types — VCTP type pool (${m.types.length} types, ${named.length} named).')
      ..writeln('// Honest inventory: kinds + structure recovered; not executable Dart.')
      ..writeln();
    for (final t in named) {
      if (t.enumItems.isNotEmpty) {
        b.writeln('enum ${t.name} { ${t.enumItems.join(', ')} }');
      } else if (t.members.isNotEmpty) {
        final fields = clusterFields(t, m.types)
            .map((f) => f.name != null ? '  ${typeLabel(f, m.types)} ${f.name};' : '  ${typeLabel(f, m.types)};')
            .join('\n');
        b.writeln('${t.name} {\n$fields\n}');
      } else {
        b.writeln('${typeLabel(t, m.types)} ${t.name}');
      }
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final m = model;
    if (m == null || m.types.isEmpty) {
      return const Center(child: Text('No data types recovered (VCTP) for this file.'));
    }
    return Scrollbar(
      child: SingleChildScrollView(
        primary: true,
        padding: const EdgeInsets.all(8),
        child: SelectableText(
          _render(m),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4),
        ),
      ),
    );
  }
}
