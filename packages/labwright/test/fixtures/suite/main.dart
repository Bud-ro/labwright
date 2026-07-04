// The plug-in convention: ONE process, one top-level main.dart, every test
// module reached from here by hand. The sibling standalone fixtures double
// as modules — their main()s are just registration functions.
import '../green_e2e.dart' as green;
import '../red_e2e.dart' as red;

Future<void> main() async {
  await green.main(); // async bench setup inside, then registrations
  red.main();
}
