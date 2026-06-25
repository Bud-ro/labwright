/// Decoder for the `CONP` / `CPC2` blocks — the VI's **connector pane** (its
/// terminal interface).
///
/// Corpus finding (7568 VIs): `CONP` is **2 bytes** in 7550 of them, and that
/// big-endian u16 is a **valid 1-based index into the `VCTP` type pool** in
/// 7550/7550 (100%) — i.e. CONP names the VI's connector-pane *type descriptor*
/// by its position in the pool (resolve it with the type-pool decoder to get the
/// pane's terminal pattern + per-terminal types + name). `CPC2` has the same
/// 2-byte shape and is almost never byte-equal to `CONP` (56/7533), so it is a
/// *separate* index (a second/compiled conpane reference), not a duplicate.
///
/// A rare older form is longer (≥28 B) and carries the descriptor inline (note
/// the `00 f0` function-type code); that inline layout is not yet decoded — we
/// flag it rather than guess.
///
/// Clean-room, corpus-grounded; index-validity is CONFIRMED, the
/// "this is the conpane type" reading is LIKELY.
library;

import 'dart:typed_data';

import 'block_catalog.dart' show BlockConfidence;
import 'viparse.dart' show ViSection;

/// A decoded `CONP`/`CPC2` connector-pane reference.
class ViConnectorPane {
  const ViConnectorPane({required this.rawLength, this.typeIndex, required this.isInline});

  /// The block length in bytes (2 for the common index form).
  final int rawLength;

  /// The 1-based `VCTP` index of the connector-pane type descriptor, for the
  /// common 2-byte form. Resolve against the type pool to get the terminals.
  /// CONFIRMED in-range (100% of corpus 2-byte CONP). Null for the inline form.
  final int? typeIndex;

  /// True for the rare older ≥28-byte layout that stores the descriptor inline
  /// instead of as a pool index. Its internal structure is not yet decoded.
  final bool isInline;

  /// Confidence that [typeIndex] is a valid `VCTP` index (corpus: 100%).
  static const BlockConfidence indexConfidence = BlockConfidence.confirmed;

  /// Confidence that the indexed descriptor is the connector pane specifically.
  static const BlockConfidence semanticConfidence = BlockConfidence.likely;
}

/// Decodes a `CONP`/`CPC2` block body. Total: returns null on an empty buffer.
ViConnectorPane? decodeConnectorPane(Uint8List b) {
  if (b.isEmpty) return null;
  if (b.length == 2) {
    return ViConnectorPane(rawLength: 2, typeIndex: (b[0] << 8) | b[1], isInline: false);
  }
  // Older inline form (≥28 B observed): not yet decoded — flag, don't guess.
  return ViConnectorPane(rawLength: b.length, isInline: true);
}

/// Finds and decodes the `CONP` (preferred) or `CPC2` connector-pane block.
/// (`CONP`/`CPC2` are uncompressed, so raw [ViSection] bytes suffice.)
ViConnectorPane? connectorPaneFromSections(Iterable<ViSection> sections) {
  ViSection? conp, cpc2;
  for (final s in sections) {
    if (s.tag == 'CONP') conp = s;
    if (s.tag == 'CPC2') cpc2 = s;
  }
  final pick = conp ?? cpc2;
  return pick == null ? null : decodeConnectorPane(pick.bytes);
}
