# labwright_core

The Labwright test engine: the hardware-free heart of the toolkit. You author a
`Test` as an ordered list of `Phase`s (plain Dart callables) that acquire
`Measurement`s — declared values checked by composable `Validators` (`inRange`,
`approx`, `isOneOf`, …) — through a `PhaseContext`, optionally pulling in
injected `Peripheral`s. Running a test opens its peripherals, executes phases
(worst-outcome wins; a failing non-`continueOnFailure` phase aborts the rest as
skipped), always cleans up, and yields an immutable `TestRecord`; a `Station`
event stream exposes progress live for UIs. The model mirrors the proven OpenHTF
shape in idiomatic Dart, with no DSL.

Part of the Labwright monorepo · BSD-3-Clause.
