// Lives OUTSIDE the scanned folder (tricky_scan/) but is imported by its
// main.dart — and imports a module BACK INSIDE the folder. That module is
// plugged in transitively and must not be flagged.
import '../tricky_scan/via_outside.dart' as via_outside;

void registerAll() {
  via_outside.register();
}
