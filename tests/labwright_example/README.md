# labwright_example

A worked, end-to-end example of authoring a Labwright test the way QA would: a
simulated PSU-board test (`psuTest`) with power-on, 3V3/5V rail checks and a
serial-number phase, using a `SimulatedDaq` peripheral, measurements with limits,
and `RequirementRef`s for traceability — runnable via the runner
(`dart run labwright_example:psu --dut <id> --out <dir>`). It doubles as the
toolkit's cross-package integration suite, exercising engine → runner →
TDMS/JSON/JUnit round-trips and the full sharded-CI pipeline (`tdms-merge` →
aggregate `junit` → `trace --min-coverage`) so the documented workflow can't
silently drift. Not published (it's an example/test package).

Part of the Labwright monorepo · BSD-3-Clause.
