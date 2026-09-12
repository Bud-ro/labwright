import 'package:flutter/material.dart';
import 'package:labwright_seq/labwright_seq.dart';

import 'sequence_outline.dart';
import 'ui.dart';

const Map<SeqAdapter, Color> adapterColors = {
  SeqAdapter.labView: Colors.teal,
  SeqAdapter.sequenceCall: Colors.deepPurple,
  SeqAdapter.cModule: Colors.brown,
  SeqAdapter.python: Colors.green,
  SeqAdapter.dotNet: Colors.indigo,
};

const adapterFallbackColor = Colors.blueGrey;

Color adapterColor(SeqAdapter adapter) =>
    adapterColors[adapter] ?? adapterFallbackColor;

class SequencesView extends StatefulWidget {
  const SequencesView({
    super.key,
    required this.outline,
    this.searchFocusNode,
    this.typeCount,
  });
  final SeqOutline outline;

  final FocusNode? searchFocusNode;

  final int? typeCount;

  @override
  State<SequencesView> createState() => _SequencesViewState();
}

class _SequencesViewState extends State<SequencesView> {
  final _scroll = ScrollController();
  final _searchController = TextEditingController();
  String _query = '';

  late List<GlobalKey> _keys;
  late List<bool> _expanded;

  @override
  void initState() {
    super.initState();
    _resetState();
  }

  @override
  void didUpdateWidget(SequencesView old) {
    super.didUpdateWidget(old);
    if (old.outline != widget.outline) _resetState();
  }

  void _resetState() {
    final sequenceCount = widget.outline.sequences.length;
    _keys = List.generate(sequenceCount, (_) => GlobalKey());
    _expanded = List.generate(sequenceCount, (i) => i == 0);
  }

  void _jumpTo(int index) {
    setState(() {
      _query = '';
      _searchController.clear();
      _expanded[index] = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[index].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
          alignment: 0.1,
        );
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.outline.sequences.isEmpty) {
      return const Center(child: Text('No sequences in this file.'));
    }
    final filtering = _query.trim().isNotEmpty;
    final shown = filterSequences(widget.outline, _query).sequences;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              outlineSummary(widget.outline, typeCount: widget.typeCount),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
          ),
        ),
        if (widget.outline.plugins case final plugins?)
          _pluginsCard(context, plugins),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
          child: TextField(
            controller: _searchController,
            focusNode: widget.searchFocusNode,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: 'Filter sequences (name, step, type, target, limits)…',
              border: const OutlineInputBorder(),
              suffixIcon: filtering
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                    )
                  : null,
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? const Center(child: Text('No matching sequences.'))
              : ListView.builder(
                  controller: _scroll,
                  // A new key per query: ExpansionTile reads initiallyExpanded only on creation.
                  key: ValueKey(_query),
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final seq = shown[i];
                    final orig = widget.outline.indexOf(seq.name) ?? i;
                    return ExpansionTile(
                      key: _keys[orig],
                      initiallyExpanded: filtering || _expanded[orig],
                      onExpansionChanged: (v) =>
                          setState(() => _expanded[orig] = v),
                      title: Text(
                        seq.name,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${seq.stepCount} steps'
                            '${seq.parameters.isNotEmpty ? ' · ${seq.parameters.length} params' : ''}'
                            '${seq.locals.isNotEmpty ? ' · ${seq.locals.length} locals' : ''}',
                          ),
                          if (seq.comment case final comment?
                              when !(filtering || _expanded[orig]))
                            Text(
                              comment,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontStyle: FontStyle.italic,
                                color: Theme.of(context).hintColor,
                              ),
                            ),
                        ],
                      ),
                      childrenPadding: const EdgeInsets.only(
                        left: 16,
                        bottom: 8,
                      ),
                      children: [
                        if (seq.comment case final comment?)
                          Padding(
                            padding: const EdgeInsets.only(top: 2, bottom: 6),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                comment,
                                style: TextStyle(
                                  fontStyle: FontStyle.italic,
                                  color: Theme.of(context).hintColor,
                                ),
                              ),
                            ),
                          ),
                        if (seq.parameters.isNotEmpty)
                          _vars(context, 'Parameters', seq.parameters),
                        if (seq.locals.isNotEmpty)
                          _vars(context, 'Locals', seq.locals),
                        for (final group in seq.groups) _group(context, group),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _vars(BuildContext context, String label, List<VarOutline> vars) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          for (final variable in vars)
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 2),
              child: Text('• ${variable.label}', style: monoStyle),
            ),
        ],
      ),
    );
  }

  Widget _group(BuildContext context, StepGroupOutline g) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 2),
          child: Text(g.name, style: Theme.of(context).textTheme.labelLarge),
        ),
        for (final step in g.steps) _step(context, step),
      ],
    );
  }

  Widget _step(BuildContext context, StepOutline s) {
    final chips = <Widget>[];
    if (s.runMode != null) {
      chips.add(_chip(context, 'mode: ${s.runMode}', Colors.deepOrange));
    }
    final td = s.targetDisplay;
    final adapter = s.adapter;
    if (adapter != null && td != null) {
      final chip = _chip(
        context,
        '${adapter.name}: ${td.label}',
        adapterColor(adapter),
      );
      chips.add(
        td.label != td.tooltip
            ? Tooltip(message: td.tooltip, child: chip)
            : chip,
      );
    } else if (adapter != null) {
      chips.add(_chip(context, adapter.name, adapterColor(adapter)));
    }
    if (s.callTargetIndex case final target?) {
      chips.add(
        ActionChip(
          label: const Text('→ go to sequence'),
          visualDensity: VisualDensity.compact,
          onPressed: () => _jumpTo(target),
        ),
      );
    } else if (s.externalCall case final external?) {
      chips.add(
        _chip(
          context,
          external.isEmpty ? 'external' : 'external: $external',
          Colors.orange,
        ),
      );
    }
    final units = s.units;
    final limitRows = [
      ...?s.limitsDetail?.rows,
      if (units != null && s.limitsDetail != null) ('Units', units),
    ];
    if (s.limits != null && limitRows.isEmpty) {
      chips.add(_chip(context, 'limits ${s.limits}', Colors.indigo));
    }
    if (s.units != null && s.limitsDetail == null) {
      chips.add(_chip(context, 'units ${s.units}', Colors.indigo));
    }
    if (s.dataSource != null && s.limitsDetail == null) {
      chips.add(_chip(context, 'data-source ${s.dataSource}', Colors.indigo));
    }
    for (final note in s.notes) {
      chips.add(_chip(context, note, Colors.blueGrey));
    }
    if (s.flowHeader case final header?) {
      chips.insert(0, _chip(context, header, Colors.teal));
    }

    return Padding(
      padding: EdgeInsets.only(left: 8 + s.flowDepth * 16.0, top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              style: DefaultTextStyle.of(context).style,
              children: [
                TextSpan(
                  text: s.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                TextSpan(
                  text: '  [${s.type}]',
                  style: TextStyle(color: Theme.of(context).hintColor),
                ),
              ],
            ),
          ),
          if (s.comment case final comment?)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                comment,
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ),
          if (chips.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(spacing: 6, runSpacing: 4, children: chips),
            ),
          if (limitRows.isNotEmpty)
            _rowsCard(context, 'Limits', Colors.indigo, limitRows),
          if (s.callArgs.isNotEmpty)
            _rowsCard(context, 'Arguments', Colors.deepPurple, [
              for (final arg in s.callArgs) (arg.label, arg.value),
            ]),
          if (s.measurementParams.isNotEmpty)
            _rowsCard(context, 'Parameters', Colors.teal, [
              for (final param in s.measurementParams)
                (param.label, param.cell),
            ]),
          if (s.connectorParams.isNotEmpty)
            _rowsCard(context, 'Connector pane', Colors.blue, [
              for (final param in s.connectorParams) (param.label, param.cell),
            ]),
          if (s.expressions.isNotEmpty) _expressions(context, s.expressions),
        ],
      ),
    );
  }

  Widget _expressions(BuildContext context, List<(String, String)> rows) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: RichText(
                text: TextSpan(
                  style: monoStyle.copyWith(color: theme.hintColor),
                  children: [
                    TextSpan(text: '$label: '),
                    TextSpan(
                      text: value,
                      style: monoStyle.copyWith(
                        color: theme.colorScheme.secondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _rowsCard(
    BuildContext context,
    String title,
    Color color,
    List<(String, String)> rows,
  ) {
    return Container(
      margin: const EdgeInsets.only(top: 6, left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(cornerRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: color),
          ),
          const SizedBox(height: 2),
          _rowsTable(context, rows),
        ],
      ),
    );
  }

  Widget _rowsTable(BuildContext context, List<(String, String)> rows) {
    final theme = Theme.of(context);
    return Table(
      columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        for (final (label, value) in rows)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 16, top: 1, bottom: 1),
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text(value, style: monoStyle),
              ),
            ],
          ),
      ],
    );
  }

  Widget _pluginsCard(BuildContext context, MeasurementPluginsOutline mp) {
    final theme = Theme.of(context);
    const color = Colors.green;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(cornerRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.folder_special_outlined, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                'Measurement plug-ins',
                style: theme.textTheme.labelSmall?.copyWith(color: color),
              ),
            ],
          ),
          const SizedBox(height: 2),
          _rowsTable(context, mp.rows),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(cornerRadius),
      ),
      child: Text(label, style: monoStyle.copyWith(color: color)),
    );
  }
}
