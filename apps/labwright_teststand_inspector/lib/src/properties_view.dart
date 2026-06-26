import 'package:flutter/material.dart';

import 'property_outline.dart';

/// The Properties tab: a lazy, expandable tree over the raw PropertyObject
/// model ([PropertyNode]). Each node shows its name, type/kind, attributes, and
/// — for leaves — the scalar value.
class PropertiesView extends StatelessWidget {
  const PropertiesView({super.key, required this.root});
  final PropertyNode root;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(8),
      // The root (Data) is expanded so the tree opens onto something useful.
      children: [_PropertyTile(node: root, depth: 0, initiallyExpanded: true)],
    );
  }
}

class _PropertyTile extends StatelessWidget {
  const _PropertyTile({
    required this.node,
    required this.depth,
    this.initiallyExpanded = false,
  });

  final PropertyNode node;
  final int depth;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _title(theme);
    final subtitle = _subtitle(theme);

    if (node.isLeaf) {
      return Padding(
        padding: EdgeInsets.only(left: 16.0 * depth + 8, top: 2, bottom: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [title, if (subtitle != null) subtitle],
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(left: 16.0 * depth),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        tilePadding: const EdgeInsets.symmetric(horizontal: 8),
        childrenPadding: EdgeInsets.zero,
        dense: true,
        title: title,
        subtitle: subtitle,
        children: [
          for (final child in node.children)
            _PropertyTile(node: child, depth: depth + 1),
        ],
      ),
    );
  }

  Widget _title(ThemeData theme) {
    final spans = <TextSpan>[
      TextSpan(
          text: node.label,
          style: const TextStyle(
              fontFamily: 'monospace', fontWeight: FontWeight.w600)),
    ];
    if (node.typeLabel.isNotEmpty) {
      spans.add(TextSpan(
        text: '  ${node.typeLabel}',
        style: TextStyle(
            fontFamily: 'monospace', fontSize: 12, color: theme.hintColor),
      ));
    }
    if (node.isLeaf && node.value != null) {
      spans.add(TextSpan(
        text: '  = ${node.value}',
        style: TextStyle(fontFamily: 'monospace', color: theme.colorScheme.primary),
      ));
    }
    return RichText(text: TextSpan(style: theme.textTheme.bodyMedium, children: spans));
  }

  Widget? _subtitle(ThemeData theme) {
    if (node.attributes.isEmpty) return null;
    // className/typeName already shown via typeLabel; surface the rest verbatim.
    final shown = node.attributes.entries
        .where((e) => e.key != 'classname' && e.key != 'typename')
        .map((e) => '${e.key}=${e.value}')
        .toList();
    if (shown.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Wrap(
        spacing: 6,
        runSpacing: 2,
        children: [
          for (final a in shown)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(a,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
            ),
        ],
      ),
    );
  }
}
