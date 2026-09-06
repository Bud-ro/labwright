import 'dart:io';

import 'numeric_ops.dart';

const int kLvMaxWaitMilliseconds = 2147483647;

final Stopwatch _timer = Stopwatch()..start();

int lvMillisecondTimer() => lvToU32(_timer.elapsedMilliseconds);

int lvWaitMs(int milliseconds) {
  sleep(Duration(milliseconds: milliseconds.clamp(0, kLvMaxWaitMilliseconds)));
  return lvMillisecondTimer();
}
