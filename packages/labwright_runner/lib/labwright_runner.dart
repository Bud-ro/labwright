/// Runs a Labwright [Test] and persists the result.
///
/// [runCli] is the entrypoint a test's `main` calls; [writeRecord] persists a
/// [TestRecord] as JSON + TDMS + JUnit XML; [recordToTdms] maps a record to TDMS
/// bytes; [tdmsToRecordJson] reverses that, reconstructing a trace-ready record
/// map from a self-describing `.tdms` alone; [recordJsonToJUnit] /
/// [recordsToJUnitSuites] emit JUnit XML for CI test UIs. Also includes the CI
/// dispatcher ([shardTests] / [mergeRuns]).
library;

export 'src/junit.dart';
export 'src/record_from_tdms.dart';
export 'src/record_tdms.dart';
export 'src/runner.dart';
export 'src/shard.dart';
