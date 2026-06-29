# Test Corpus
This folder is where the files used in development of the `.seq` and `.vi` parses go.
Additionally JSON is used to host snapshots of relevant progress/coverage indicators.

TODO: This README needs fragmented into the SEQ and VI counterparts. Considering how different everything is,
it's better to silo this into each package. See `packages/labwright_rsrc_parse/tool/coverage.dart`'s TODOs.

TODO: Unify the format for the sources. Also let's make it to where the entire freaking repos aren't downloaded
if possible. 

- `baseline.json`: Gives an indication of % coverage for each set of VIs. Measures the % of bytes we claim to understand.
- `seq-sources.json`: Various `.seq` we can download and parse, with licenses permissive of that.
- `snapshot.json`: Snapshots for VI parsing. Observed blocks, and the number of objects in the front panel and block diagram are recorded.
- `sources.json`: VI sources.