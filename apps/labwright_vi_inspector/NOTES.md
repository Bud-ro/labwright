# labwright_vi_inspector — notes

Rendering decisions that aren't obvious from the widget code (the *why*, not the *how*).
Corpus percentages are probed against the `labwright_rsrc_parse` corpus; re-probe before
relying on an exact figure. Block/format facts surfaced by the hex view (FTAB, FPTD, LVSR,
heap-walk coverage, LIBN/VINS) live in `packages/labwright_rsrc_parse/NOTES.md`.

## Diagram rendering (`faithful_controls.dart`)
- **Structure frames are drawn outline-only (no fill)** so deeply-nested frames don't
  accumulate a muddy tint — structures contain other structures ~79% of the time.
- **Node boxes are translucent placeholders** so overlapping sibling nodes (~37% of cases)
  show through. A recovered subVI name is deliberately **not** drawn inside the box: it
  already renders as the node's own floating `0xa` label, and re-printing it would
  double-print across ~42.3k corpus nodes. The name stays reachable via the
  `controlTooltip` hover.

## Summary view (`vi_screen.dart`)
- The embedded 20×20 RGB picture is deliberately **not** shown as a per-VI identity icon:
  across the corpus it is a generic shared LabVIEW glyph (checkmark/X), so presenting it
  beside the name would imply an identity it doesn't carry. It remains viewable as a typed
  display in the hex viewer.
