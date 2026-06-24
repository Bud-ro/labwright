import 'package:flutter/material.dart';
import 'package:labwright_videcode/labwright_videcode.dart';

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

    return LayoutBuilder(
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
  }
}
