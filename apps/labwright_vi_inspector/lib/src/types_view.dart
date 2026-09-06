import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'vctp_view.dart';

class ViTypesView extends StatefulWidget {
  const ViTypesView({super.key, required this.model, this.vctpBytes});

  final ViModel? model;

  final Uint8List? vctpBytes;

  @override
  State<ViTypesView> createState() => _ViTypesViewState();
}

class _ViTypesViewState extends State<ViTypesView> {
  bool _showBytes = false;
  static const int _typeCap = 500;
  static const int _itemCap = 64;

  static const double _minFont = 9;
  static const double _maxFont = 28;
  double _fontSize = 13;
  void _bumpFont(double delta) =>
      setState(() => _fontSize = (_fontSize + delta).clamp(_minFont, _maxFont));

  String _render(ViModel m) {
    final named = namedTypes(m.types);
    final out = StringBuffer()
      ..writeln(
        '// Recovered data types — VCTP type pool (${m.types.length} types, ${named.length} named).',
      )
      ..writeln(
        '// Honest, heuristic inventory: kinds + structure recovered (names may be',
      )
      ..writeln('// approximate for short strings); not executable Dart.')
      ..writeln();
    for (final type in named.take(_typeCap)) {
      if (type.enumItems.isNotEmpty) {
        final items = type.enumItems.take(_itemCap).join(', ');
        final more = type.enumItems.length > _itemCap ? ', …' : '';
        out.writeln('enum ${type.name} { $items$more }');
      } else if (type.members.isNotEmpty) {
        final fields = clusterFields(type, m.types)
            .take(_itemCap)
            .map(
              (f) => f.name != null
                  ? '  ${typeLabel(f, m.types)} ${f.name};'
                  : '  ${typeLabel(f, m.types)};',
            )
            .join('\n');
        final more = type.members.length > _itemCap
            ? '\n  // (+${type.members.length - _itemCap} more)'
            : '';
        out.writeln('${type.name} {\n$fields$more\n}');
      } else {
        out.writeln('${typeLabel(type, m.types)} ${type.name}');
      }
    }
    if (named.length > _typeCap)
      out.writeln(
        '// (+${named.length - _typeCap} more named types not shown)',
      );
    return out.toString();
  }

  @override
  Widget build(BuildContext context) {
    final viModel = widget.model;
    if (viModel == null || viModel.types.isEmpty) {
      return const Center(
        child: Text('No data types recovered (VCTP) for this file.'),
      );
    }
    final vctpBytes = widget.vctpBytes;
    final canCorrelate =
        vctpBytes != null && vctpTypeSpans(vctpBytes).isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              if (!_showBytes) ...[
                IconButton(
                  tooltip: 'Smaller text',
                  visualDensity: VisualDensity.compact,
                  onPressed: _fontSize <= _minFont ? null : () => _bumpFont(-1),
                  icon: const Icon(Icons.text_decrease, size: 18),
                ),
                Text(
                  '${_fontSize.round()}',
                  style: const TextStyle(fontSize: 12),
                ),
                IconButton(
                  tooltip: 'Larger text',
                  visualDensity: VisualDensity.compact,
                  onPressed: _fontSize >= _maxFont ? null : () => _bumpFont(1),
                  icon: const Icon(Icons.text_increase, size: 18),
                ),
              ],
              const Spacer(),
              if (canCorrelate)
                SegmentedButton<bool>(
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(value: false, label: Text('Listing')),
                    ButtonSegment(value: true, label: Text('Bytes ↔ types')),
                  ],
                  selected: {_showBytes},
                  onSelectionChanged: (s) =>
                      setState(() => _showBytes = s.first),
                ),
            ],
          ),
        ),
        Expanded(
          child: _showBytes && vctpBytes != null
              ? VctpCorrelationView(body: vctpBytes)
              : Scrollbar(
                  child: SingleChildScrollView(
                    primary: true,
                    padding: const EdgeInsets.all(8),
                    child: SelectableText(
                      _render(viModel),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: _fontSize,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
