// Instrumented scan fixture — every edge that could fool a naive
// reachability walk:
//  * a module plugged in THROUGH a helper that lives OUTSIDE this folder;
//  * a module reached only via an EXPORT (decoy_mentions re-exports
//    renamed_symbols' register — and is itself full of comment/string
//    decoys mentioning ghost.dart);
//  * renamed/aliased test symbols (none of scan's business — reachability
//    is the only signal);
//  * conditional imports (both branches must count as plugged);
//  * ghost.dart: genuinely unplugged, mentioned only in decoys — the one
//    file scan must flag.
import '../outside/bench_helpers.dart' as bench;
import 'conditional_io.dart' if (dart.library.js_interop) 'conditional_js.dart' as conditional;
import 'decoy_mentions.dart' as decoy;

void main() {
  bench.registerAll();
  decoy.register(); // renamed_symbols.register, via the export
  conditional.register();
}
