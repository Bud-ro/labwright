/// One entrypoint for the Labwright NI toolkit. [run] dispatches subcommands —
/// TDMS inspect/csv/summary/diff/merge, CSV↔TDMS, VI inspect/summary,
/// requirement trace, requirements lint, and JUnit export — to the underlying
/// packages. It is process-global-free (I/O via sinks, exit code returned via
/// [ExitCodes]) so it is unit-testable. See `docs/tools.md` for the full catalog.
library;

export 'src/cli.dart';
