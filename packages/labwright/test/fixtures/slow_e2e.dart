// Fixture: a slow first test followed by a fast one — the window for driving
// a Stop while a run is in flight (the slow body gives the action time to
// land deterministically before the queue is consulted again).
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
