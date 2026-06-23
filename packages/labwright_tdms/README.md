# labwright_tdms

A pure-Dart reader and writer for NI's **TDMS** binary measurement format
(lead-in / metadata / raw-data segments), validated against real LabVIEW files
including digital, big-endian, timestamp, interleaved, and DAQmx
format-changing-scaler (linear-scaled) data — and fuzz-hardened so malformed
input fails cleanly rather than crashing. Beyond `TdmsReader`/`TdmsWriter` it
ships data utilities QA actually reach for: CSV import/export (`csvToTdms` /
`tdmsToCsv`), a JSON structure summary, a human inspector, structural+value
`diffTdms`, and `mergeTdms` for combining sharded run archives — exposed as the
`tdms-inspect`, `tdms2csv`, `tdms-summary`, `csv2tdms`, `tdms-diff`, and
`tdms-merge` CLIs.

Part of the Labwright monorepo · BSD-3-Clause.
