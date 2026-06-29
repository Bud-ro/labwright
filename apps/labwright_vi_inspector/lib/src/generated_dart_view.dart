import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Read-only view of the VI→IR→Dart pipeline output for the loaded VI: the
/// honest structural Dart scaffold ([generateDartScaffold]) and, toggled, the
/// JSON IR ([viModelToJson]). This is the review surface the migration plan
/// calls for — it shows what we can recover (structures, node/subVI stubs, the
/// call surface) while being explicit that dataflow wiring is not yet recovered.
///
/// Purely a renderer over an already-built [ViModel]; no parsing or editing.
class GeneratedDartView extends StatefulWidget {
  const GeneratedDartView({super.key, required this.model, this.viName});

  /// The decoded model, or null when the loaded file yielded none.
  final ViModel? model;

  /// The VI's name (used as the generated function's name); `.vi` stripped and
  /// sanitized by the generator. Null falls back to a generic name.
  final String? viName;

  @override
  State<GeneratedDartView> createState() => _GeneratedDartViewState();
}

enum _Mode { dart, json }

class _GeneratedDartViewState extends State<GeneratedDartView> {
  _Mode _mode = _Mode.dart;

  static const double _minFont = 9;
  static const double _maxFont = 28;
  double _fontSize = 13;
  void _bumpFont(double delta) =>
      setState(() => _fontSize = (_fontSize + delta).clamp(_minFont, _maxFont));

  String _functionName() {
    final n = widget.viName?.trim();
    if (n == null || n.isEmpty) return 'vi';
    final base = n.split(RegExp(r'[\\/]')).last;
    final stripped = base.toLowerCase().endsWith('.vi') ? base.substring(0, base.length - 3) : base;
    return stripped.isEmpty ? 'vi' : stripped;
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    if (model == null) {
      return const Center(child: Text('No model recovered — nothing to generate for this file.'));
    }
    final text = _mode == _Mode.dart
        ? generateDartScaffold(model, name: _functionName())
        : const JsonEncoder.withIndent('  ').convert(viModelToJson(model));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                SegmentedButton<_Mode>(
                  segments: const [
                    ButtonSegment(value: _Mode.dart, icon: Icon(Icons.code, size: 16), label: Text('Generated Dart')),
                    ButtonSegment(value: _Mode.json, icon: Icon(Icons.data_object, size: 16), label: Text('JSON IR')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                ),
                const SizedBox(width: 12),
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
                const SizedBox(width: 12),
                const Text(
                  'Read-only · structural outline, dataflow wiring not yet recovered',
                  style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Scrollbar(
            child: SingleChildScrollView(
              primary: true,
              padding: const EdgeInsets.all(8),
              child: SelectableText(
                text,
                style: TextStyle(fontFamily: 'monospace', fontSize: _fontSize, height: 1.4),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
