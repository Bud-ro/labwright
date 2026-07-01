# labwright_tdms

A pure-Dart reader and non-streaming writer for NI's **TDMS** binary measurement format.
`TdmsReader` and `TdmsWriter` are the core types for this. Additional utilities are
provided for:
- CSV import/export (`csvToTdms` / `tdmsToCsv`). 
- Inspection (`tdms-inspect`)

TODO: These should probably be deleted. Either out of scope or wholly inappropriate:
- Structural + Value diffs via `diffTdms`
- JSON structure summary
- `mergeTdms` for combining sharded run archives.

These utilities are exposed as the `tdms2csv`, `tdms-summary`, `csv2tdms`,
`tdms-diff`, and `tdms-merge` CLIs.
