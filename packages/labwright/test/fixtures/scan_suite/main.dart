// Scan fixture: main.dart plugs in exactly one module; the sibling
// unplugged.dart is deliberately NOT imported — `labwright scan` must name
// it.
import 'plugged.dart' as plugged;

void main() {
  plugged.register();
}
