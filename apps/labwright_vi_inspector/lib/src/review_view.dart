import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'diagram_view.dart';
import 'generated_dart_view.dart';

/// Side-by-side review surface (the migration plan's "VI graph next to generated
/// Dart" check): the recovered **block diagram** on the left, the **generated
/// Dart scaffold / JSON IR** on the right. Read-only; a thin composition over the
/// existing [ViDiagramView] and [GeneratedDartView].
///
/// On a narrow viewport the two stack vertically so neither is unusably squeezed.
class ViReviewView extends StatelessWidget {
  const ViReviewView({super.key, required this.model, this.viName});

  final ViModel? model;
  final String? viName;

  @override
  Widget build(BuildContext context) {
    final diagram = ViDiagramView(
      key: ValueKey('review-bd:$model'),
      diagrams: model?.blockDiagrams,
      emptyHint: 'No block-diagram objects recovered in this file.',
    );
    final dart = GeneratedDartView(model: model, viName: viName);

    final sideBySide = LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 720) {
          return Column(
            children: [
              Expanded(child: diagram),
              const Divider(height: 1),
              Expanded(child: dart),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: diagram),
            const VerticalDivider(width: 1),
            Expanded(child: dart),
          ],
        );
      },
    );

    final m = model;
    if (m == null) return sideBySide;
    return Column(
      children: [
        _RecoverySummary(m),
        const Divider(height: 1),
        Expanded(child: sideBySide),
      ],
    );
  }
}

/// An honest "what we recovered vs what's still unknown" strip for the Review
/// tab, derived entirely from real model counts — never fabricated, and explicit
/// that only STRUCTURE is recovered (dataflow/wires are not).
class _RecoverySummary extends StatelessWidget {
  const _RecoverySummary(this.model);
  final ViModel model;

  @override
  Widget build(BuildContext context) {
    final objs = [for (final d in model.blockDiagrams) ...d.objects];
    final classified = objs.where((o) => o.category != ViObjectKind.unknown).length;
    final unknown = objs.length - classified;
    final structures = objs.where((o) => o.category == ViObjectKind.structure).length;
    final nodes = objs.where((o) => o.category == ViObjectKind.node).length;
    final parts = <String>[
      '${objs.length} BD objects',
      '$classified classified / $unknown unknown',
      '$structures structures',
      '$nodes nodes',
      '${model.subViNames.length} subVI calls',
      '${model.types.length} types',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Recovered: ${parts.join('  ·  ')}',
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          const Text('Structure only — node→node dataflow / wires are not recovered, so the Dart is a scaffold.',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
    );
  }
}
