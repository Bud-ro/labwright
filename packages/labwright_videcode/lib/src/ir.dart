import 'dart:typed_data';

import 'decode.dart';
import 'heap.dart';
import 'meta.dart';

/// A read-only, **partial-fidelity** model of a decoded VI — the Stage 4 IR seed.
///
/// This aggregates the layers that are **reliably decoded and corpus-validated**
/// into one structure: container/block component sizes, the LabVIEW version +
/// embedded title, the grouped string tables (control/enum labels), and the
/// length-prefixed `C4` leaf records of the heap. It is the documented **plug-in
/// point** for a future VI→Dart auto-translator (Stage 5): the translator
/// consumes a [ViModel] rather than re-parsing bytes, so new heap-decoding work
/// flows into translation by enriching this model.
///
/// Fidelity is deliberately **partial and honest**. The heap's nested object tree
/// (~77% of a `BDEx` body — see `docs/vi-rsrc-and-heap-format.md`) is not yet
/// decoded, so this model intentionally does **not** contain a node/wire graph.
/// It exposes what is provable today; richer structure (typed nodes, wires,
/// terminals) is added here as more of the heap opcode model is confirmed —
/// never fabricated.
class ViModel {
  const ViModel({
    required this.version,
    required this.title,
    required this.components,
    required this.stringTables,
    required this.heapRecords,
  });

  /// LabVIEW version the VI was saved in (e.g. `10.0`), or null if unrecoverable.
  final String? version;

  /// The VI's embedded title/description (from the `vers` block), or null.
  final String? title;

  /// Per-block size summary (block diagram / front panel / type data weights),
  /// largest decompressed first.
  final List<BlockComponent> components;

  /// String tables (grouped labels: enum/ring items, captions, …), order- and
  /// offset-preserving. Tables framed by the confirmed `C4 2E` opcode carry
  /// [HeapStringTable.framed] == true.
  final List<HeapStringTable> stringTables;

  /// The length-prefixed `C4` leaf records of the heaps (the reliably-framed
  /// objects: string tables, `C4 2D`/`1F` value records, …).
  final List<HeapRecord> heapRecords;

  /// All distinct, deduped label strings across [stringTables], order-preserving.
  /// Convenience for "what does this VI contain".
  List<String> get labels {
    final seen = <String>{};
    final out = <String>[];
    for (final t in stringTables) {
      for (final s in t.strings) {
        if (seen.add(s)) out.add(s);
      }
    }
    return out;
  }
}

/// Builds the [ViModel] for a `.vi` — the single entry point for the read-only
/// understanding of a VI. Total: returns a model or throws [ViFormatException]
/// for a malformed container (never a `RangeError`).
ViModel buildViModel(Uint8List viBytes) => buildViModelFromDecoded(decodeSections(viBytes));

/// [buildViModel] over already-decoded sections.
ViModel buildViModelFromDecoded(Iterable<DecodedSection> decoded) {
  final list = decoded is List<DecodedSection> ? decoded : decoded.toList();
  final ver = versionFromSections(list.map((d) => d.section));
  return ViModel(
    version: ver.version,
    title: ver.title,
    components: componentsFromDecoded(list),
    stringTables: heapStringTablesFromDecoded(list),
    heapRecords: heapC4RecordsFromDecoded(list),
  );
}
