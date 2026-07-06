import 'package:flutter/material.dart';
import 'package:labwright_seq/labwright_seq.dart';

import 'properties_view.dart';
import 'property_outline.dart';

/// The Types tab: the file's custom **type palette** (`SeqFile.types`) — the
/// data/step types a sequence file defines or references. Each type is rendered
/// as an expandable [PropertyTile] (so its members, type-inheritance and
/// `⋄ overridden` markers show, same as the Properties tab), in a virtualized
/// list so files with thousands of types stay responsive. A search box filters
/// by type name / class. Shows nothing fabricated — an empty palette says so.
class TypesView extends StatefulWidget {
  const TypesView({super.key, required this.types, this.searchFocusNode});

  /// The file's type list, in document order. May be empty.
  final List<SeqProperty> types;
  final FocusNode? searchFocusNode;

  @override
  State<TypesView> createState() => _TypesViewState();
}

class _TypesViewState extends State<TypesView> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _matches(SeqProperty t, String q) =>
      t.name.toLowerCase().contains(q) ||
      (t.className?.toLowerCase().contains(q) ?? false) ||
      (t.typeName?.toLowerCase().contains(q) ?? false);

  @override
  Widget build(BuildContext context) {
    if (widget.types.isEmpty) {
      return const Center(child: Text('This file defines no types.'));
    }
    final needle = _query.trim().toLowerCase();
    final shown = needle.isEmpty
        ? widget.types
        : widget.types.where((t) => _matches(t, needle)).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: widget.searchFocusNode,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: 'Filter types (name, class)…',
                    border: const OutlineInputBorder(),
                    suffixIcon: needle.isNotEmpty
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
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  '${shown.length}/${widget.types.length}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? const Center(child: Text('No matching types.'))
              : ListView.builder(
                  // Forces a rebuild on query change so ExpansionTiles pick up the new
                  // force-expanded state while filtering; removing this silently
                  // breaks filter expansion.
                  key: ValueKey(_query),
                  padding: const EdgeInsets.all(8),
                  itemCount: shown.length,
                  itemBuilder: (context, i) =>
                      PropertyTile(node: PropertyNode.of(shown[i]), depth: 0),
                ),
        ),
      ],
    );
  }
}
