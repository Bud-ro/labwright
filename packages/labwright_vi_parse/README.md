# labwright_vi_parse

A clean-room, LabVIEW-less reader for the LabVIEW **RSRC** container (`.vi` /
`.ctl` / `.llb`). `parseVi` turns the bytes into a `ViSummary` — file type,
version, the resource-block inventory, and capability flags (front panel, block
diagram, connector pane, sub-VI links) that describe *what a VI is and does* —
and it's fuzz-hardened to fail cleanly on malformed input. `readViSections` goes
a layer deeper, extracting each block's raw **section** bytes from the data area
(validated across 435 real VIs, 20k+ sections, zero crashes) — the input to the
decode pipeline (decompression → heap → graph → IR), which lives in this same
package. This powers the `vi-inspect` CLI; turning the `BDHb`/`BDEx` heap into
an IR graph is the in-progress next stage.

Part of the Labwright monorepo · BSD-3-Clause.
