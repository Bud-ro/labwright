import 'dart:typed_data';

import 'decode.dart';
import 'graph.dart';
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
    this.description,
    required this.components,
    required this.stringTables,
    required this.heapRecords,
    this.diagrams = const <ViDiagram>[],
  });

  /// LabVIEW version the VI was saved in (e.g. `10.0`), or null if unrecoverable.
  final String? version;

  /// The VI's embedded title/description (from the `vers` block), or null.
  final String? title;

  /// The VI's top-level description / help text (from the `CPC2` block), or null.
  final String? description;

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

  /// The recovered block-diagram graph(s) — one per walkable `BDEx` section:
  /// objects (nodes/terminals/wires) with bounds, labels, and wire connections.
  /// **Partial/honest**: object kinds are raw class codes and wire direction is
  /// undecoded, but the object/edge structure is corpus-validated.
  final List<ViDiagram> diagrams;

  /// The bounding rectangles of the VI's objects, decoded from the `C4 2D`
  /// records (position/size of controls, nodes, decorations). Partial but real
  /// spatial structure — the seed of a read-only layout/graph view.
  List<HeapRect> get objectBounds => [
        for (final r in heapRecords)
          if (r.bounds != null) r.bounds!,
      ];

  /// The **labeled, positioned objects** of the VI: each pairs a `C4 2D` bounds
  /// record with the `C4 2E` label table that immediately follows it in the heap
  /// record stream. Corpus-validated association (99.8% of label tables are
  /// immediately preceded by a bounds record), but **partial**: only *labeled*
  /// objects are assembled — unlabeled decorations/nodes and wires are not — and
  /// this is not yet the full block-diagram graph.
  List<ViObject> get objects => assembleObjects(heapRecords, stringTables);

  /// Single-string **captions** (control names/labels) decoded from `C4 22`
  /// records — distinct from [labels] (which come from `C4 2E` string *tables*).
  /// Deduped, order-preserving.
  List<String> get captions {
    final seen = <String>{};
    final out = <String>[];
    for (final r in heapRecords) {
      if (r.kind != HeapOpcode.caption) continue;
      final s = r.text;
      if (s != null && seen.add(s)) out.add(s);
    }
    return out;
  }

  /// External **symbol / C-function names** the VI references (from `C4 C4`
  /// records in the type heap), e.g. `ps2000aRunStreaming` — the Call-Library
  /// functions this VI invokes. Deduped, order-preserving.
  List<String> get symbolNames {
    final seen = <String>{};
    final out = <String>[];
    for (final r in heapRecords) {
      if (r.kind != HeapOpcode.symbolName) continue;
      final s = r.text;
      if (s != null && seen.add(s)) out.add(s);
    }
    return out;
  }

  /// External **library/DLL paths** the VI references (from `C4 A4` `PTH0`
  /// records), e.g. `ps5000.dll`. Deduped, order-preserving.
  List<String> get paths {
    final seen = <String>{};
    final out = <String>[];
    for (final r in heapRecords) {
      final p = r.path;
      if (p != null && seen.add(p)) out.add(p);
    }
    return out;
  }

  /// The VI's **description / help text** blocks, extracted from `C4 19` records
  /// (control tooltips, often HTML-ish). Heuristic text recovery; deduped,
  /// order-preserving.
  List<String> get descriptions {
    final seen = <String>{};
    final out = <String>[];
    for (final r in heapRecords) {
      final s = r.descriptionText;
      if (s != null && seen.add(s)) out.add(s);
    }
    return out;
  }

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

/// A **named, positioned VI object** assembled from adjacent heap records: a
/// `C4 2D` bounds record immediately followed by either a `C4 22` caption or a
/// `C4 2E` string-table label.
///
/// Heuristic but corpus-validated: 99.8% of label tables and 99.4% of captions
/// sit immediately after a bounds record. Partial: represents only named/labeled
/// objects (not unlabeled nodes/wires), and is not the full block-diagram graph.
class ViObject {
  const ViObject({
    required this.sectionTag,
    required this.bounds,
    required this.boundsOffset,
    required this.nameOffset,
    this.caption,
    this.labels = const <String>[],
  });

  /// The section the object lives in (`BDEx` = block diagram, `FPHb` = front panel).
  final String sectionTag;

  /// The object's bounding rectangle (position + size).
  final HeapRect bounds;

  /// The object's single caption (from a `C4 22` record), or null if it was named
  /// by a label table instead.
  final String? caption;

  /// The object's label-table strings (from a `C4 2E` record; e.g. enum items),
  /// or empty if it was named by a caption instead.
  final List<String> labels;

  /// Byte offset of the bounds (`C4 2D`) record within the decompressed section.
  final int boundsOffset;

  /// Byte offset of the naming record (caption or label run) within the section.
  final int nameOffset;

  /// The object's primary name — its [caption], else the first label, else null.
  String? get name => caption ?? (labels.isEmpty ? null : labels.first);
}

/// Assembles [ViObject]s by pairing each `C4 22` caption or framed `C4 2E` label
/// table with the `C4 2D` bounds record immediately preceding it (within
/// [maxRecordGap] `C4` records, same section). One bounds pairs with one name.
/// Total.
List<ViObject> assembleObjects(List<HeapRecord> records, List<HeapStringTable> stringTables,
    {int maxRecordGap = 3}) {
  // Framed tables keyed by (section, payload offset). A framed C4 2E record's
  // payload starts at record.offset + 3, which equals the table's run offset.
  final framed = <String, HeapStringTable>{};
  for (final t in stringTables) {
    if (t.framed) framed['${t.sectionTag}@${t.offset}'] = t;
  }

  final out = <ViObject>[];
  HeapRecord? lastBounds;
  var lastBoundsIdx = -1;
  String? section;
  var idx = 0;
  for (final r in records) {
    if (r.sectionTag != section) {
      section = r.sectionTag;
      lastBounds = null;
      lastBoundsIdx = -1;
    }
    final inRange = lastBounds != null && idx - lastBoundsIdx <= maxRecordGap;
    if (r.kind == HeapOpcode.bounds && r.bounds != null) {
      lastBounds = r;
      lastBoundsIdx = idx;
    } else if (r.kind == HeapOpcode.caption && inRange) {
      final cap = r.text;
      if (cap != null) {
        out.add(ViObject(
          sectionTag: r.sectionTag,
          bounds: lastBounds.bounds!,
          caption: cap,
          boundsOffset: lastBounds.offset,
          nameOffset: r.offset,
        ));
        lastBounds = null; // consume
      }
    } else if (r.kind == HeapOpcode.stringTable && inRange) {
      final t = framed['${r.sectionTag}@${r.offset + r.headerLength}'];
      if (t != null) {
        out.add(ViObject(
          sectionTag: r.sectionTag,
          bounds: lastBounds.bounds!,
          labels: t.strings,
          boundsOffset: lastBounds.offset,
          nameOffset: r.offset,
        ));
        lastBounds = null; // consume
      }
    }
    idx++;
  }
  return out;
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
    description: cpc2Description(list.map((d) => d.section)),
    components: componentsFromDecoded(list),
    stringTables: heapStringTablesFromDecoded(list),
    heapRecords: heapC4RecordsFromDecoded(list),
    diagrams: [
      for (final d in list)
        if (d.tag == 'BDEx' && d.bytes.length >= 6) buildDiagram(d.bytes, sectionTag: d.tag),
    ],
  );
}
