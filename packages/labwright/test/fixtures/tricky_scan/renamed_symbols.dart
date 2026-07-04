// "Something insane": labwright imported under a rename, test aliased
// again locally. Scan is reachability-based, so symbol names are
// irrelevant — this file is plugged and must not be flagged.
import 'package:labwright/labwright.dart' as lab;

const registerCheck = lab.test; // an aliased tear-off, why not

void register() {
  lab.test('renamed test symbol', () {
    lab.expect(true, lab.isTrue);
  });
  registerCheck('tear-off registered test', () {
    lab.expect(2, lab.equals(2));
  });
}
