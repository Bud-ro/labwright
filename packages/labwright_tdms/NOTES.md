# labwright_tdms — decode notes

Format findings that don't have a natural home in code (named constants and per-field
meanings live in the `///` docs on `tdms.dart`).

## Segment / channel layout
- Raw-data-carrying channels persist across segments: a segment **without** a new-object-list
  ToC flag reuses the prior `active` channel set. This is how DAQmx and incremental files
  split the channel layout (metadata) from the data across separate segments.

## DAQmx format-changing scaler raw-data index
On-disk layout of a DAQmx format-changing scaler raw-data index (recognized by the
`0x1269` format-changing / `0x1369` digital-line scaler sentinels, **not** by a ToC bit):

| field | type | notes |
|---|---|---|
| overall data type | u32 | `0xFFFFFFFF` for scaler-based |
| dimension | u32 | always 1 in the corpus |
| value count | u64 | |
| scaler count | u32 | |
| *per scaler* → data type | u32 | |
| &nbsp;&nbsp;buffer index | u32 | |
| &nbsp;&nbsp;byte offset within stride | u32 | |
| &nbsp;&nbsp;sample-format bitmap | u32 | |
| &nbsp;&nbsp;scale id | u32 | |
| width count | u32 | |
| *per width* → raw width/stride | u32 | |

The reader uses the **first scaler only**.
