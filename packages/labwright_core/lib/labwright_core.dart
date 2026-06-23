/// Labwright test engine.
///
/// Core model (mirrors the proven OpenHTF shape, in idiomatic Dart):
/// a [Test] is an ordered list of [Phase]s plus the [Peripheral]s they need; a
/// phase acquires [Measurement]s (checked by [Validators]) through its
/// [PhaseContext]; running a test yields a [TestRecord].
///
/// The Station API (a live `TestEvent` stream + `StationState` snapshot) exposes
/// run progress in-process for UIs/dashboards.
library;

export 'src/context.dart';
export 'src/events.dart';
export 'src/measurement.dart';
export 'src/outcome.dart';
export 'src/peripheral.dart';
export 'src/phase.dart';
export 'src/record.dart';
export 'src/requirement.dart';
export 'src/station.dart';
export 'src/test.dart';
export 'src/validators.dart';

/// ABI/protocol version shared with the owned native libraries (`native/qdaq`,
/// `native/viparse`). Must stay in lockstep with their `*_abi_version()`.
const int labwrightAbiVersion = 0;
