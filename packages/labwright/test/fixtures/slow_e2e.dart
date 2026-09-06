import 'package:labwright/labwright.dart';

void main() {
  test('slow gate', () async {
    log('working');
    await Future<void>.delayed(const Duration(milliseconds: 800));
  });

  test('fast follower', () {
    expect(1, equals(1));
  });
}
