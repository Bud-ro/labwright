// The suite IS this program: `dart run e2e/main.dart` (add
// -Dlabwright.viewer=false for headless CI, --define=labwright.seed=N to
// reproduce a shuffled order). Registration then execution: bench setup is
// ordinary code here, every module registers its tests, and bodies run one
// at a time after main returns — no scanning, no IPC, no child processes.
import 'psu_board_test.dart' as psu_board;

void main() {
  psu_board.register();
}
