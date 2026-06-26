import 'package:flutter/material.dart';

import 'sequence_outline.dart';

/// The Sequences tab: a tree of sequences → Setup/Main/Cleanup groups → steps.
/// In-file SequenceCall steps are tappable and jump to the called sequence.
class SequencesView extends StatefulWidget {
  const SequencesView({super.key, required this.outline});
  final SeqOutline outline;

  @override
  State<SequencesView> createState() => _SequencesViewState();
}

class _SequencesViewState extends State<SequencesView> {
  final _scroll = ScrollController();
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
    final n = widget.outline.sequences.length;
    _keys = List.generate(n, (_) => GlobalKey());
    // Expand the first sequence by default so the view isn't all collapsed.
    _expanded = List.generate(n, (i) => i == 0);
  }

  void _jumpTo(int index) {
    setState(() => _expanded[index] = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[index].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 300), alignment: 0.1);
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seqs = widget.outline.sequences;
    if (seqs.isEmpty) {
      return const Center(child: Text('No sequences in this file.'));
    }
    return ListView.builder(
      controller: _scroll,
      itemCount: seqs.length,
      itemBuilder: (context, i) {
        final seq = seqs[i];
        return ExpansionTile(
          key: _keys[i],
          initiallyExpanded: _expanded[i],
          onExpansionChanged: (v) => _expanded[i] = v,
          title: Text(seq.name,
              style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('${seq.stepCount} steps'
              '${seq.parameters.isNotEmpty ? ' · ${seq.parameters.length} params' : ''}'
              '${seq.locals.isNotEmpty ? ' · ${seq.locals.length} locals' : ''}'),
          childrenPadding: const EdgeInsets.only(left: 16, bottom: 8),
          children: [
            _vars(context, 'Parameters', seq.parameters),
            _vars(context, 'Locals', seq.locals),
            for (final g in seq.groups) _group(context, g),
          ].whereType<Widget>().toList(),
        );
      },
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
          for (final v in vars)
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 2),
              child: Text('• ${v.label}',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
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
        for (final s in g.steps) _step(context, s),
      ],
    );
  }

  Widget _step(BuildContext context, StepOutline s) {
    final chips = <Widget>[];
    if (s.adapter != null) {
      chips.add(_chip(context, '${s.adapter}: ${s.target}', Colors.teal));
    }
    if (s.isInFileCall) {
      chips.add(ActionChip(
        label: const Text('→ go to sequence'),
        visualDensity: VisualDensity.compact,
        onPressed: () => _jumpTo(s.callTargetIndex!),
      ));
    } else if (s.externalCall != null) {
      chips.add(_chip(
          context,
          s.externalCall!.isEmpty ? 'external' : 'external: ${s.externalCall}',
          Colors.orange));
    }
    if (s.limits != null) {
      chips.add(_chip(context, 'limits ${s.limits}', Colors.indigo));
    }
    for (final note in s.notes) {
      chips.add(_chip(context, note, Colors.blueGrey));
    }

    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              style: DefaultTextStyle.of(context).style,
              children: [
                TextSpan(
                    text: s.name,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                TextSpan(
                    text: '  [${s.type}]',
                    style: TextStyle(color: Theme.of(context).hintColor)),
              ],
            ),
          ),
          if (chips.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(spacing: 6, runSpacing: 4, children: chips),
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
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(
              fontFamily: 'monospace', fontSize: 12, color: color)),
    );
  }
}
