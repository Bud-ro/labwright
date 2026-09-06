import '../green_e2e.dart' as green;
import '../red_e2e.dart' as red;

Future<void> main() async {
  await green.main();
  red.main();
}
