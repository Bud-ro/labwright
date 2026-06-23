/// A reusable, injected interface to one piece of hardware or external service
/// that a [phase] talks to (a DAQ channel set, an instrument, a DUT link, …).
///
/// Concrete peripherals live in other packages (e.g. `labwright_daq`); the engine
/// only manages their lifecycle and hands them to phases via the phase context.
/// [open] is called once before the test's phases run; [close] is always called
/// afterward (in reverse order), even if a phase throws.
abstract class Peripheral {
  /// Unique name within a test (used for lookup when several share a type).
  String get name;

  /// Acquire/connect. Throwing here aborts the test with [Outcome.error].
  Future<void> open() async {}

  /// Release/disconnect. Should not throw; errors here are swallowed so one
  /// peripheral's cleanup can't mask the test result.
  Future<void> close() async {}
}
