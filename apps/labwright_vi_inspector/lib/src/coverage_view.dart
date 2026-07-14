import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Read-only **content-model fidelity** view for a `.vi`, driven by the writer
/// scoreboard ([attributeVi] → [WriterAttribution]). It makes the writer's
/// reconstruction visible: how much of the file is emitted from a typed,
/// understood model versus copied verbatim, at two levels — the raw **byte**
/// model (stored file bytes) and the **content** model (compressed heap sections
/// counted at their inflated size, since LabVIEW reads them through zlib) — plus
/// the byte-exact round-trip status and a per-category byte breakdown.
class ViCoverageView extends StatelessWidget {
  const ViCoverageView({super.key, required this.attribution});

  /// The byte attribution for the loaded VI, or null when it could not be
  /// computed (a non-RSRC container, or an error during attribution).
  final WriterAttribution? attribution;

  @override
  Widget build(BuildContext context) {
    final attr = attribution;
    if (attr == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Byte attribution is unavailable for this file (not an RSRC '
            'container, or attribution did not complete).',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Writer fidelity', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text(
          'How much of this VI the writer re-emits from a typed model versus '
          'copies verbatim, and whether it round-trips byte-for-byte.',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
        const SizedBox(height: 12),

        Row(
          children: [
            Expanded(
              child: _headline(
                context,
                label: 'Content model',
                value: _pct(attr.contentModelBytes, attr.contentTotalBytes),
                caption:
                    '${_fmt(attr.contentModelBytes)} of ${_fmt(attr.contentTotalBytes)} content bytes',
                color: const Color(0xFF4C8C4C),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _headline(
                context,
                label: 'Byte model',
                value: _pct(attr.modelBytes, attr.fileLength),
                caption:
                    '${_fmt(attr.modelBytes)} of ${_fmt(attr.fileLength)} file bytes',
                color: const Color(0xFF3F6FB0),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: _roundTripCard(context, attr)),
          ],
        ),
        const SizedBox(height: 16),

        _BarSection(
          title: 'Content level (compressed sections at inflated size)',
          total: attr.contentTotalBytes,
          segments: [
            _Seg('model', attr.contentModelBytes, const Color(0xFF4C8C4C)),
            _Seg('copied', attr.contentCopiedBytes, const Color(0xFF8A8A8A)),
          ],
        ),
        const SizedBox(height: 12),
        _BarSection(
          title: 'Byte level (stored file bytes)',
          total: attr.fileLength,
          segments: [
            _Seg('model', attr.modelBytes, const Color(0xFF3F6FB0)),
            _Seg('copied', attr.copiedBytes, const Color(0xFF8A8A8A)),
          ],
        ),
        const SizedBox(height: 16),

        if (attr.heapModelBugs > 0)
          Card(
            color: Colors.red.shade900,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${attr.heapModelBugs} heap record(s) the model expected to '
                      'reconstruct losslessly but did not.',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (attr.heapModelBugs > 0) const SizedBox(height: 12),

        const Text(
          'Model bytes (emitted from a typed field)',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        _catRow('RSRC header', attr.headerBytes, attr.contentTotalBytes),
        _catRow(
          'Info-area structs',
          attr.infoStructBytes,
          attr.contentTotalBytes,
        ),
        _catRow(
          'Section length prefixes',
          attr.sectionPrefixBytes,
          attr.contentTotalBytes,
        ),
        _catRow(
          'Typed block payloads',
          attr.typedPayloadBytes,
          attr.contentTotalBytes,
        ),
        _catRow(
          'Heap content (model)',
          attr.heapModelBytes,
          attr.contentTotalBytes,
        ),
        _catRow(
          'Alignment padding',
          attr.alignPadBytes,
          attr.contentTotalBytes,
        ),
        const SizedBox(height: 12),

        const Text(
          'Copied bytes (verbatim spans)',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        _catRow(
          'Info-area raw words',
          attr.infoRawBytes,
          attr.contentTotalBytes,
        ),
        _catRow('Data-area gaps', attr.gapBytes, attr.contentTotalBytes),
        _catRow(
          'Heap content (copied)',
          attr.heapCopiedBytes,
          attr.contentTotalBytes,
        ),
        _catRow(
          'Untyped payloads',
          attr.untypedPayloadBytes,
          attr.contentTotalBytes,
        ),
        const SizedBox(height: 16),

        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Inflated heap content: ${_fmt(attr.inflatedContentBytes)}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                const Text(
                  'A compressed heap section is stored as a zlib stream but read '
                  'through zlib, so the content model counts each such section at '
                  'its inflated size. The byte model instead counts the stored '
                  'zlib bytes, all copied — which is why the two percentages '
                  'differ.',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _headline(
    BuildContext context, {
    required String label,
    required String value,
    required String caption,
    required Color color,
  }) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: color.withValues(alpha: 0.5)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 2),
        Text(caption, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    ),
  );

  Widget _roundTripCard(BuildContext context, WriterAttribution attr) {
    final ok = attr.byteExact;
    final color = ok ? Colors.green : Colors.orange;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Round-trip',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                ok ? Icons.check_circle : Icons.error_outline,
                color: color,
                size: 26,
              ),
              const SizedBox(width: 6),
              Text(
                ok ? 'byte-exact' : 'differs',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          const Text(
            'parse → serialize',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  static Widget _catRow(String label, int bytes, int total) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(
          width: 200,
          child: Text(label, style: const TextStyle(color: Colors.grey)),
        ),
        SizedBox(
          width: 80,
          child: Text(_fmt(bytes), style: const TextStyle(fontSize: 13)),
        ),
        Text(
          _pct(bytes, total),
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    ),
  );

  static String _pct(int part, int total) =>
      total == 0 ? '—' : '${(100 * part / total).toStringAsFixed(1)}%';

  static String _fmt(int byteCount) => byteCount >= 1024
      ? '${(byteCount / 1024).toStringAsFixed(1)} KB'
      : '$byteCount B';
}

/// One labeled proportion of a stacked bar.
class _Seg {
  const _Seg(this.label, this.bytes, this.color);
  final String label;
  final int bytes;
  final Color color;
}

/// A titled stacked proportion bar with a legend of its segments (bytes + %).
class _BarSection extends StatelessWidget {
  const _BarSection({
    required this.title,
    required this.total,
    required this.segments,
  });
  final String title;
  final int total;
  final List<_Seg> segments;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 18,
            child: Row(
              children: [
                for (final seg in segments)
                  if (seg.bytes > 0)
                    Expanded(
                      flex: seg.bytes,
                      child: Container(color: seg.color),
                    ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 14,
          runSpacing: 4,
          children: [
            for (final seg in segments)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(
                      color: seg.color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Text(
                    '${seg.label}  ${ViCoverageView._fmt(seg.bytes)} · ${ViCoverageView._pct(seg.bytes, total)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}
