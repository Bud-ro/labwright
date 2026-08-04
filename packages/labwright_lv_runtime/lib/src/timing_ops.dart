/// The **millisecond timer** a block diagram reads and waits on.
///
/// LabVIEW's published reference describes this timer only through
/// DIFFERENCES: a Wait (ms) of 10 ms started when the timer read 112 ms
/// finishes when it reads 122 ms. It states no origin, so this runtime does not
/// invent one — [lvMillisecondTimer] counts from the first read in the process
/// and only the difference between two readings carries meaning.
///
/// Target: the Dart **native** runtime. Waiting synchronously — which is what
/// the reference describes, a node that does not complete until the time has
/// elapsed — requires blocking the calling thread, which the web compilers
/// cannot do.
library;

import 'dart:io';

/// The width the reference draws on the timer's terminal. The counter wraps at
/// this modulus, every 4 294 967 296 ms (about 49.7 days).
const int _kTimerModulus = 0x100000000;

/// The longest wait the reference states the function performs: 2 147 483 647
/// ms, about 24.86 days. A larger request waits this long and no longer.
///
/// The reference writes this bound twice, once in decimal and once as a
/// hexadecimal literal a digit short of the decimal it sits beside; the decimal
/// is the one reproduced here.
const int kLvMaxWaitMilliseconds = 2147483647;

/// The monotonic source behind [lvMillisecondTimer], started on first read.
final Stopwatch _timer = Stopwatch()..start();

/// The millisecond timer's current value, truncated to the terminal's 32-bit
/// width.
///
/// Monotonic apart from the 32-bit wrap: it is driven by an elapsed-time
/// counter rather than the wall clock, so a clock adjustment cannot move it
/// backwards.
int lvMillisecondTimer() => _timer.elapsedMilliseconds % _kTimerModulus;

/// LabVIEW's Wait (ms) function: blocks for [milliseconds], then answers the
/// millisecond timer.
///
/// The wait is a **floor**. The reference gives the platform-dependent side of
/// this two ways — a real-time target waits at least the requested value, a
/// desktop Windows target may return up to one millisecond early — and this
/// runtime provides the stricter of the two on every platform, so a diagram
/// written against either reading still holds. The extra millisecond a desktop
/// LabVIEW may skip is a property of the host's timer, not of the diagram, and
/// is not reproduced.
///
/// Requests are clamped into `0 .. `[kLvMaxWaitMilliseconds]. A request of 0
/// returns immediately; the reference additionally has it yield the CPU, which
/// is a scheduling effect with nothing to observe it in a single lowered
/// diagram running on one thread.
///
/// Resolution is the host's. The reference says as much of LabVIEW itself —
/// the timer is system dependent and may be coarser than one millisecond.
int lvWaitMs(int milliseconds) {
  final requested = milliseconds < 0
      ? 0
      : milliseconds > kLvMaxWaitMilliseconds
      ? kLvMaxWaitMilliseconds
      : milliseconds;
  if (requested > 0) {
    // `sleep` may return early on a signal, and a coarse host timer can land
    // just short of the deadline; the loop is what makes the wait a floor.
    final deadline = _timer.elapsedMilliseconds + requested;
    var remaining = requested;
    while (remaining > 0) {
      sleep(Duration(milliseconds: remaining));
      remaining = deadline - _timer.elapsedMilliseconds;
    }
  }
  return lvMillisecondTimer();
}
