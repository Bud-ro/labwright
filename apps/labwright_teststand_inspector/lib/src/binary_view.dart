import 'package:flutter/material.dart';
import 'package:labwright_teststand/labwright_teststand.dart';

import 'document_view.dart';

/// Recon view for a binary `TOF1` document: a header/facts table, an explicit
/// honest note that the record tree isn't decoded yet, and the recovered string
/// table in a scrollable list with a visible count.
class BinaryView extends StatelessWidget {
  const BinaryView({super.key, required this.doc});
  final BinarySeqDocument doc;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = binaryHeaderRows(doc);
    // Prefer the largest contiguous table; fall back to all recovered strings.
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
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'The record tree is not yet decoded — the view below is a '
                        'recon of strings recovered from the inflated body.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text('Recovered strings (${strings.length})',
                  style: theme.textTheme.titleSmall),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: strings.isEmpty
              ? const Center(child: Text('No strings recovered.'))
              : ListView.builder(
                  itemCount: strings.length,
                  itemBuilder: (context, i) {
                    final s = strings[i];
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: Text('0x${s.offset.toRadixString(16)}',
                          style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: theme.hintColor)),
                      title: SelectableText(s.text,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12)),
                    );
                  },
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
          TableRow(children: [
            Padding(
              padding: const EdgeInsets.only(right: 16, top: 2, bottom: 2),
              child: Text(label,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(value,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
          ]),
      ],
    );
  }
}
