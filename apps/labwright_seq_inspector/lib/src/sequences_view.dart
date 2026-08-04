import 'package:flutter/material.dart';
import 'package:labwright_seq/labwright_seq.dart';

import 'sequence_outline.dart';
import 'ui.dart';

/// Chip color per module adapter. A new code-bearing adapter that lacks a color
/// is caught by the unit test rather than silently rendering as the fallback.
/// The flow-control adapters ([SeqAdapter.none]/[SeqAdapter.unknown]) are
/// intentionally absent and render with [adapterFallbackColor].
const Map<SeqAdapter, Color> adapterColors = {
  SeqAdapter.labView: Colors.teal,
  SeqAdapter.sequenceCall: Colors.deepPurple,
  SeqAdapter.cModule: Colors.brown,
  SeqAdapter.python: Colors.green,
};

/// Chip color for adapters with no assigned color (see [adapterColors]).
const adapterFallbackColor = Colors.blueGrey;

/// The chip color for [adapter], falling back to [adapterFallbackColor].
Color adapterColor(SeqAdapter adapter) =>
    adapterColors[adapter] ?? adapterFallbackColor;

/// The Sequences tab: a tree of sequences → Setup/Main/Cleanup groups → steps.
/// In-file SequenceCall steps are tappable and jump to the called sequence.
class SequencesView extends StatefulWidget {
  const SequencesView({
    super.key,
    required this.outline,
    this.searchFocusNode,
    this.typeCount,
  });
  final SeqOutline outline;

  /// Optional focus node for the search field (so a parent shortcut can focus
  /// it, e.g. Ctrl/Cmd+F).
  final FocusNode? searchFocusNode;

  /// The file's type-list count, surfaced in the summary header when given.
  final int? typeCount;

  @override
  State<SequencesView> createState() => _SequencesViewState();
}

class _SequencesViewState extends State<SequencesView> {
  final _scroll = ScrollController();
  final _searchController = TextEditingController();
  String _query = '';

  /// Keys and expansion state, indexed by ORIGINAL outline position so jump
  /// targets stay valid regardless of what the filter currently shows.
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
    // Indexed by ORIGINAL outline position (not filtered position) so jump
    // targets stay correct while a filter is applied.
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
        if (widget.outline.plugins != null)
          _pluginsCard(context, widget.outline.plugins!),
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
                  // Forces a rebuild on query change so ExpansionTiles pick up the new
                  // force-expanded state while filtering; removing this silently
                  // breaks filter expansion.
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
                          if (seq.comment != null &&
                              !(filtering || _expanded[orig]))
                            Text(
                              seq.comment!,
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
                        if (seq.comment != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2, bottom: 6),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                seq.comment!,
                                style: TextStyle(
                                  fontStyle: FontStyle.italic,
                                  color: Theme.of(context).hintColor,
                                ),
                              ),
                            ),
                          ),
                        _vars(context, 'Parameters', seq.parameters),
                        _vars(context, 'Locals', seq.locals),
                        for (final group in seq.groups) _group(context, group),
                      ].whereType<Widget>().toList(),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget? _vars(BuildContext context, String label, List<VarOutline> vars) {
    if (vars.isEmpty) return null;
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
    if (s.isInFileCall) {
      chips.add(
        ActionChip(
          label: const Text('→ go to sequence'),
          visualDensity: VisualDensity.compact,
          onPressed: () => _jumpTo(s.callTargetIndex!),
        ),
      );
    } else if (s.externalCall != null) {
      chips.add(
        _chip(
          context,
          s.externalCall!.isEmpty ? 'external' : 'external: ${s.externalCall}',
          Colors.orange,
        ),
      );
    }
    final limitRows = [
      ...?s.limitsDetail?.rows,
      if (s.units != null && s.limitsDetail != null) ('Units', s.units!),
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
    if (s.flowHeader != null) {
      chips.insert(0, _chip(context, s.flowHeader!, Colors.teal));
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
          if (s.comment != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                s.comment!,
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
          if (limitRows.isNotEmpty) _limitsTable(context, limitRows),
          if (s.callArgs.isNotEmpty) _argsTable(context, s.callArgs),
          if (s.measurementParams.isNotEmpty)
            _paramsTable(context, s.measurementParams),
          if (s.connectorParams.isNotEmpty)
            _connectorTable(context, s.connectorParams),
          if (s.expressions.isNotEmpty) _expressions(context, s.expressions),
        ],
      ),
    );
  }

  /// The step's set expressions (precondition / pre / post / status / loop-while)
  /// as dim monospace `label: expression` rows — they can be long, so they get
  /// their own lines rather than chips.
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

  /// The module call's bound arguments as a `name (dir) → expr` mini-table,
  /// mirroring [_limitsTable] — the editor's "Module > Parameters" view.
  Widget _argsTable(BuildContext context, List<CallArgOutline> args) {
    final theme = Theme.of(context);
    const color = Colors.deepPurple;
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
            'Arguments',
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
          const SizedBox(height: 2),
          Table(
            columnWidths: const {
              0: IntrinsicColumnWidth(),
              1: FlexColumnWidth(),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              for (final arg in args)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(
                        right: 16,
                        top: 1,
                        bottom: 1,
                      ),
                      child: Text(
                        arg.label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(arg.value, style: monoStyle),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// A measurement step's typed parameters as arg `name (dir) → type = value`
  /// mini-table, mirroring [_argsTable] — the editor's measurement "Parameters".
  Widget _paramsTable(
    BuildContext context,
    List<MeasurementParamOutline> params,
  ) {
    final theme = Theme.of(context);
    const color = Colors.teal;
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
            'Parameters',
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
          const SizedBox(height: 2),
          Table(
            columnWidths: const {
              0: IntrinsicColumnWidth(),
              1: FlexColumnWidth(),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              for (final param in params)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(
                        right: 16,
                        top: 1,
                        bottom: 1,
                      ),
                      child: Text(
                        param.label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(param.cell, style: monoStyle),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// A LabVIEW VI call's connector pane as a `#conn label → type ←expr`
  /// mini-table, mirroring [_argsTable] — the editor's "VI > connector pane".
  Widget _connectorTable(
    BuildContext context,
    List<ConnectorParamOutline> params,
  ) {
    final theme = Theme.of(context);
    const color = Colors.blue;
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
            'Connector pane',
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
          const SizedBox(height: 2),
          Table(
            columnWidths: const {
              0: IntrinsicColumnWidth(),
              1: FlexColumnWidth(),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              for (final param in params)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(
                        right: 16,
                        top: 1,
                        bottom: 1,
                      ),
                      child: Text(
                        param.label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(param.cell, style: monoStyle),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// A file-level card listing the Semiconductor-Test-System resources the
  /// sequence depends on (pin map + spec/levels/timing/pattern files) — the
  /// structured view of `SeqFile.measurementPlugIns` (also in the Dump tab).
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
          Table(
            columnWidths: const {
              0: IntrinsicColumnWidth(),
              1: FlexColumnWidth(),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              for (final (label, value) in mp.rows)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(
                        right: 16,
                        top: 1,
                        bottom: 1,
                      ),
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
          ),
        ],
      ),
    );
  }

  Widget _limitsTable(BuildContext context, List<(String, String)> rows) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 6, left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.indigo.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(cornerRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Limits',
            style: theme.textTheme.labelSmall?.copyWith(color: Colors.indigo),
          ),
          const SizedBox(height: 2),
          Table(
            columnWidths: const {
              0: IntrinsicColumnWidth(),
              1: FlexColumnWidth(),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              for (final (label, value) in rows)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(
                        right: 16,
                        top: 1,
                        bottom: 1,
                      ),
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
          ),
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
