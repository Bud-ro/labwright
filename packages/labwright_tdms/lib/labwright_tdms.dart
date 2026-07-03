/// Read and write NI's TDMS binary format.
///
/// [TdmsWriter] appends segments (lead-in / metadata / raw data); call
/// `writeSegment` repeatedly to stream more samples into the same channels.
/// [TdmsReader] parses the bytes back into a [TdmsFile]. Byte-oriented and pure,
/// so it round-trips in tests with no disk or NI tooling. (Verifying that output
/// opens in LabVIEW/DIAdem is a separate, hardware/tooling-gated step.)
///
/// Also provides data utilities: [tdmsToCsv]/[csvToTdms], [tdmsSummary] and
/// [inspectTdms], [diffTdms] (compare two files), and [mergeTdms] (union several
/// files into one archive).
library;

export 'src/csv.dart';
export 'src/csv_import.dart';
export 'src/diff.dart';
export 'src/inspect.dart';
export 'src/merge.dart';
export 'src/model.dart';
export 'src/reader.dart';
export 'src/summary.dart';
export 'src/writer.dart';
