import 'package:flutter/material.dart';

import 'property_outline.dart';
import 'ui.dart';

/// The Properties tab: a lazy, expandable tree over the raw PropertyObject
/// model ([PropertyNode]), with a search box that filters by name, type, value,
/// or attributes while keeping matching nodes' ancestors. Each node shows its
/// name, type/kind, attributes, and — for leaves — the scalar value.
class PropertiesView extends StatefulWidget {
  const PropertiesView({super.key, required this.root, this.searchFocusNode});
  final PropertyNode root;

  /// Optional focus node for the search field (so a parent shortcut can focus
  /// it, e.g. Ctrl/Cmd+F).
  final FocusNode? searchFocusNode;

  @override
  State<PropertiesView> createState() => _PropertiesViewState();
}

class _PropertiesViewState extends State<PropertiesView> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtering = _query.trim().isNotEmpty;
    final filtered = filterTree(widget.root, _query);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: TextField(
            controller: _controller,
            focusNode: widget.searchFocusNode,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: 'Filter properties (name, value, type, attribute)…',
              border: const OutlineInputBorder(),
              suffixIcon: filtering
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _controller.clear();
                        setState(() => _query = '');
                      },
                    )
                  : null,
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: filtered == null
              ? const Center(child: Text('No matching properties.'))
              : ListView(
                  // Forces a rebuild on query change so ExpansionTiles pick up the new
                  // force-expanded state while filtering; removing this silently
                  // breaks filter expansion.
                  key: ValueKey(_query),
                  padding: const EdgeInsets.all(8),
                  children: [
                    PropertyTile(
                      node: filtered,
                      depth: 0,
                      initiallyExpanded: true,
                      forceExpanded: filtering,
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class PropertyTile extends StatelessWidget {
  const PropertyTile({
    required this.node,
    required this.depth,
    this.initiallyExpanded = false,
    this.forceExpanded = false,
  });

  final PropertyNode node;
  final int depth;
  final bool initiallyExpanded;
  final bool forceExpanded;

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
        initiallyExpanded: forceExpanded || initiallyExpanded,
        tilePadding: const EdgeInsets.symmetric(horizontal: 8),
        childrenPadding: EdgeInsets.zero,
        dense: true,
        title: title,
        subtitle: subtitle,
        children: [
          for (final child in node.children)
            PropertyTile(
              node: child,
              depth: depth + 1,
              forceExpanded: forceExpanded,
            ),
        ],
      ),
    );
  }

  Widget _title(ThemeData theme) {
    final spans = <TextSpan>[
      TextSpan(
        text: node.label,
        style: const TextStyle(
          fontFamily: monoFamily,
          fontWeight: FontWeight.w600,
        ),
      ),
    ];
    if (node.typeLabel.isNotEmpty) {
      spans.add(
        TextSpan(
          text: '  ${node.typeLabel}',
          style: monoStyle.copyWith(color: theme.hintColor),
        ),
      );
    }
    if (node.isInstanceOverride) {
      spans.add(
        TextSpan(
          text: '  ⋄ overridden',
          style: monoStyle.copyWith(
            color: theme.colorScheme.tertiary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    if (node.isLeaf && node.value != null) {
      spans.add(
        TextSpan(
          text: '  = ${node.value}',
          style: TextStyle(
            fontFamily: monoFamily,
            color: theme.colorScheme.primary,
          ),
        ),
      );
    }
    return RichText(
      text: TextSpan(style: theme.textTheme.bodyMedium, children: spans),
    );
  }

  /// Renders a synthetic binary-decoder marker as a human-readable chip;
  /// passes ordinary XML attributes through as `key=value`.
  static String _chipLabel(String key, String value) => switch (key) {
    '%BINELEMENTSPEC' => 'element type: $value bytes undecoded',
    '%BININTRINSIC' => 'intrinsic type id $value',
    '%BINARRAYUNDECODED' => 'array $value — elements undecoded',
    '%BINBODYUNDECODED' => 'body not yet decoded',
    _ => '$key=$value',
  };

  /// Attribute chips deliberately exclude the `classname`/`typename` keys
  /// (already surfaced via `node.typeLabel`) and the `%BINOVERRIDES`
  /// marker (surfaced as the "⋄ overridden" badge). The remaining
  /// synthetic `%BIN*` markers are rendered as readable labels rather
  /// than raw sentinel keys.
  Widget? _subtitle(ThemeData theme) {
    if (node.attributes.isEmpty) return null;
    final shown = node.attributes.entries
        .where(
          (e) =>
              e.key != 'classname' &&
              e.key != 'typename' &&
              e.key != '%BINOVERRIDES',
        )
        .map((e) => _chipLabel(e.key, e.value))
        .toList();
    if (shown.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Wrap(
        spacing: 6,
        runSpacing: 2,
        children: [
          for (final attribute in shown)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                attribute,
                style: const TextStyle(fontFamily: monoFamily, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}
