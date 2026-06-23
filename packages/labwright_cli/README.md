# labwright_cli

One unified `labwright` command-line entrypoint that dispatches to the rest of
the toolkit: inspect/convert/summarize/diff/merge TDMS files, import CSV, inspect
LabVIEW VIs, lint a requirements file, build a requirement trace matrix (gating
CI on coverage/drift), and emit JUnit XML — over `record.json` or self-describing
`.tdms` inputs. The dispatcher is free of process globals (I/O via injected sinks,
exit codes returned via a named `ExitCodes`), so every subcommand is unit-tested,
and a drift-guard test asserts every command shown in the usage text is actually
wired. See `docs/tools.md` in the repository for the full catalog.

Part of the Labwright monorepo · BSD-3-Clause.
