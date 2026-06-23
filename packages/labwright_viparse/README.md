# labwright_viparse

A clean-room, LabVIEW-less reader for the LabVIEW **RSRC** container (`.vi` /
`.ctl` / `.llb`). `parseVi` turns the bytes into a `ViSummary` — file type,
version, the resource-block inventory, and capability flags (front panel, block
diagram, connector pane, sub-VI links) that describe *what a VI is and does* —
and it's fuzz-hardened to fail cleanly on malformed input. This powers the
`vi-inspect` / `vi-summary` CLIs and is the foundation for the eventual
block-diagram-logic recovery; decoding the `BDHb` heap into an IR graph is
deliberately deferred until a corpus of real, non-trivial VI samples is available
(see the repo ADRs).

Part of the Labwright monorepo · BSD-3-Clause.
