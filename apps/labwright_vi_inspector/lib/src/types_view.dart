import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Read-only view of the VI's recovered **data-type dictionary** (the VCTP type
/// pool): named typedefs rendered structurally — enums with their item values,
/// clusters with their typed fields, others as `kind name`. This surfaces the
/// deep type recovery that otherwise only appears as comments in the generated
/// Dart scaffold.
class ViTypesView extends StatefulWidget {
  const ViTypesView({super.key, required this.model});

  final ViModel? model;

  @override
  State<ViTypesView> createState() => _ViTypesViewState();
}

class _ViTypesViewState extends State<ViTypesView> {
  // Caps so a large/hostile VCTP can't blow up the rendered string (the decoder
  // admits up to 200000 types, 512 members, 256 items) — mirrors the scaffold.
  static const int _typeCap = 500;
  static const int _itemCap = 64;

  // Adjustable monospace size (the fixed default was hard to read on 4K).
  static const double _minFont = 9;
  static const double _maxFont = 28;
  double _fontSize = 13;
  void _bumpFont(double delta) =>
      setState(() => _fontSize = (_fontSize + delta).clamp(_minFont, _maxFont));

  String _render(ViModel m) {
    final named = namedTypes(m.types);
    final b = StringBuffer()
      ..writeln('// Recovered data types — VCTP type pool (${m.types.length} types, ${named.length} named).')
      ..writeln('// Honest, heuristic inventory: kinds + structure recovered (names may be')
      ..writeln('// approximate for short strings); not executable Dart.')
      ..writeln();
    for (final t in named.take(_typeCap)) {
      if (t.enumItems.isNotEmpty) {
        final items = t.enumItems.take(_itemCap).join(', ');
        final more = t.enumItems.length > _itemCap ? ', …' : '';
        b.writeln('enum ${t.name} { $items$more }');
      } else if (t.members.isNotEmpty) {
        final fields = clusterFields(t, m.types)
            .take(_itemCap)
            .map((f) => f.name != null ? '  ${typeLabel(f, m.types)} ${f.name};' : '  ${typeLabel(f, m.types)};')
            .join('\n');
        final more = t.members.length > _itemCap ? '\n  // (+${t.members.length - _itemCap} more)' : '';
        b.writeln('${t.name} {\n$fields$more\n}');
      } else {
        b.writeln('${typeLabel(t, m.types)} ${t.name}');
      }
    }
    if (named.length > _typeCap) b.writeln('// (+${named.length - _typeCap} more named types not shown)');
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.model;
    if (m == null || m.types.isEmpty) {
      return const Center(child: Text('No data types recovered (VCTP) for this file.'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Smaller text',
                visualDensity: VisualDensity.compact,
                onPressed: _fontSize <= _minFont ? null : () => _bumpFont(-1),
                icon: const Icon(Icons.text_decrease, size: 18),
              ),
              Text('${_fontSize.round()}', style: const TextStyle(fontSize: 12)),
              IconButton(
                tooltip: 'Larger text',
                visualDensity: VisualDensity.compact,
                onPressed: _fontSize >= _maxFont ? null : () => _bumpFont(1),
                icon: const Icon(Icons.text_increase, size: 18),
              ),
            ],
          ),
        ),
        Expanded(
          child: Scrollbar(
            child: SingleChildScrollView(
              primary: true,
              padding: const EdgeInsets.all(8),
              child: SelectableText(
                _render(m),
                style: TextStyle(fontFamily: 'monospace', fontSize: _fontSize, height: 1.4),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
