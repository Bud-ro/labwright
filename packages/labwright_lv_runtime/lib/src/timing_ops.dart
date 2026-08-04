/// The **millisecond timer** a block diagram reads and waits on.
///
/// The published reference describes this timer only through DIFFERENCES — a
/// Wait (ms) of 10 ms started when the timer read 112 ms finishes when it reads
/// 122 ms — and states no origin, so [lvMillisecondTimer] counts from the first
/// read in the process.
///
/// Target: the Dart **native** runtime. [lvWaitMs] blocks the calling thread,
/// which the web compilers cannot do.
library;

import 'dart:io';

import 'numeric_ops.dart';

/// The longest wait the reference states the function performs, about 24.86
/// days. A larger request waits this long and no longer.
const int kLvMaxWaitMilliseconds = 2147483647;

/// The monotonic source behind [lvMillisecondTimer], started on first read.
final Stopwatch _timer = Stopwatch()..start();

/// The millisecond timer's current value, at the terminal's 32-bit width.
int lvMillisecondTimer() => lvToU32(_timer.elapsedMilliseconds);

/// LabVIEW's Wait (ms) function: blocks for [milliseconds], then answers the
/// millisecond timer.
int lvWaitMs(int milliseconds) {
  sleep(Duration(milliseconds: milliseconds.clamp(0, kLvMaxWaitMilliseconds)));
  return lvMillisecondTimer();
}
