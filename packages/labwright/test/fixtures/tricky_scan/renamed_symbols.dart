import 'package:labwright/labwright.dart' as lab;

const registerCheck = lab.test;

void register() {
  lab.test('renamed test symbol', () {
    lab.expect(true, lab.isTrue);
  });
  registerCheck('tear-off registered test', () {
    lab.expect(2, lab.equals(2));
  });
}
