# labwright_daq

The Labwright data-acquisition hardware-abstraction layer (HAL): device-agnostic
channel interfaces — `AnalogInput`, `AnalogOutput`, `DigitalIO`, `Counter`, and
sample streams — vended by a `DaqDevice` (a `labwright_core` peripheral). A test
written against these runs unchanged whether it talks to the bundled
`SimulatedDaq` backend (deterministic, hardware-free, great for CI) or, once it
lands, a real device over the owned clean-room `native/qdaq` driver. It also
includes record/replay (`RecordingDaq`/`ReplayDaq`) so any captured run can be
re-executed deterministically for offline debugging and regression.

Part of the Labwright monorepo · BSD-3-Clause.
