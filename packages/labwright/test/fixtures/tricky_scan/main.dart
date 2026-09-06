import '../outside/bench_helpers.dart' as bench;
import 'conditional_io.dart' if (dart.library.js_interop) 'conditional_js.dart' as conditional;
import 'decoy_mentions.dart' as decoy;

void main() {
  bench.registerAll();
  decoy.register();
  conditional.register();
}
