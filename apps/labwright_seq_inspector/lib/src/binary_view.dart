import 'package:flutter/material.dart';
import 'package:labwright_seq/labwright_seq.dart';

import 'document_view.dart';
import 'ui.dart';

class BinaryView extends StatelessWidget {
  const BinaryView({super.key, required this.doc, this.coverage});
  final BinarySeqDocument doc;

  final BinaryByteCoverage? coverage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = binaryHeaderRows(doc);
    final sections = binaryRecoverySections(doc);
    final strings = doc.stringTable.isNotEmpty ? doc.stringTable : doc.strings;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Binary TOF1 file', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              _factsTable(theme, rows),
              if (coverage case final cov?) ...[
                const SizedBox(height: 12),
                _CoveragePanel(coverage: cov),
              ],
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer.withValues(
                    alpha: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(cornerRadius),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Strings recovered from the inflated body. Decoded '
                        'sequences and steps are in the Sequences and Logic tabs.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: [
              for (final section in sections)
                ExpansionTile(
                  dense: true,
                  title: Text(
                    '${section.title} (${section.items.length})',
                    style: theme.textTheme.titleSmall,
                  ),
                  children: [
                    for (final item in section.items)
                      ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        title: SelectableText(item, style: monoStyle),
                      ),
                  ],
                ),
              ExpansionTile(
                dense: true,
                title: Text(
                  'All recovered strings (${strings.length})',
                  style: theme.textTheme.titleSmall,
                ),
                children: [
                  if (strings.isEmpty)
                    const ListTile(
                      dense: true,
                      title: Text('No strings recovered.'),
                    )
                  else
                    for (final entry in strings)
                      ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: Text(
                          '0x${entry.offset.toRadixString(16)}',
                          style: monoStyle.copyWith(
                            fontSize: 11,
                            color: theme.hintColor,
                          ),
                        ),
                        title: SelectableText(entry.text, style: monoStyle),
                      ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _factsTable(ThemeData theme, List<(String, String)> rows) {
    return Table(
      columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        for (final (label, value) in rows)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 16, top: 2, bottom: 2),
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(value, style: monoStyle),
              ),
            ],
          ),
      ],
    );
  }
}

class _Tier {
  const _Tier(this.label, this.bytes, this.color);
  final String label;
  final int bytes;
  final Color color;
}

class _CoveragePanel extends StatelessWidget {
  const _CoveragePanel({required this.coverage});
  final BinaryByteCoverage coverage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = coverage;
    final tiers = <_Tier>[
      _Tier('string pool', c.poolBytes, const Color(0xFF4C8C4C)),
      _Tier(
        'record · semantic',
        c.recordSemanticBytes,
        theme.colorScheme.primary,
      ),
      _Tier(
        'record · structural',
        c.recordStructuralBytes,
        const Color(0xFFD9A441),
      ),
      _Tier(
        'record · undecoded',
        c.recordUndecodedBytes,
        const Color(0xFF8A8A8A),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Binary body coverage', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(cornerRadius),
          child: SizedBox(
            height: 18,
            child: Row(
              children: [
                for (final tier in tiers)
                  if (tier.bytes > 0)
                    Expanded(
                      flex: tier.bytes,
                      child: Container(color: tier.color),
                    ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 14,
          runSpacing: 4,
          children: [
            for (final tier in tiers)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(
                      color: tier.color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Text(
                    '${tier.label}  ${_fmt(tier.bytes)} · ${_pct(tier.bytes, c.bodyBytes)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Record region ${_fmt(c.recordRegionBytes)}: '
          '${(c.recordSemanticRatio * 100).toStringAsFixed(1)}% decoded, '
          '${(c.recordAccountedRatio * 100).toStringAsFixed(1)}% accounted · '
          'body ${(c.bodySemanticRatio * 100).toStringAsFixed(1)}% decoded.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
      ],
    );
  }

  static String _pct(int part, int total) =>
      total == 0 ? '—' : '${(100 * part / total).toStringAsFixed(1)}%';

  static String _fmt(int byteCount) => byteCount >= 1024
      ? '${(byteCount / 1024).toStringAsFixed(1)} KB'
      : '$byteCount B';
}
