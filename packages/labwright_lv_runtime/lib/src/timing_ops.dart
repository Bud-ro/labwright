import 'dart:io';

import 'numeric_ops.dart';
import 'values.dart';

const int kLvMaxWaitMilliseconds = 2147483647;

final Stopwatch _timer = Stopwatch()..start();

int lvMillisecondTimer() => lvToU32(_timer.elapsedMilliseconds);

int lvWaitMs(int milliseconds) {
  sleep(Duration(milliseconds: milliseconds.clamp(0, kLvMaxWaitMilliseconds)));
  return lvMillisecondTimer();
}

/// Tick Count (ms).
int lvTickCount() => lvMillisecondTimer();

/// Wait Until Next ms Multiple: waits until the millisecond timer is a multiple of [multiple]
/// and returns it; a multiple of zero or less waits nothing.
int lvWaitUntilNextMsMultiple(int multiple) {
  if (multiple <= 0) return lvMillisecondTimer();
  final now = lvMillisecondTimer();
  final remainder = now % multiple;
  if (remainder != 0) sleep(Duration(milliseconds: multiple - remainder));
  return lvMillisecondTimer();
}

/// Seconds between the LabVIEW epoch (1904-01-01 00:00:00 UTC) and the Unix epoch.
const int kLvEpochOffsetSeconds = 2082844800;

/// Get Date/Time In Seconds: the current time as a timestamp.
LvTimestamp lvGetDateTimeInSeconds() => lvTimestampOfDateTime(DateTime.now().toUtc());

/// The timestamp of [time], to microsecond precision.
LvTimestamp lvTimestampOfDateTime(DateTime time) {
  final micros = time.toUtc().microsecondsSinceEpoch;
  final seconds = micros ~/ 1000000 - (micros < 0 && micros % 1000000 != 0 ? 1 : 0);
  final fractionMicros = micros - seconds * 1000000;
  return LvTimestamp(seconds: seconds + kLvEpochOffsetSeconds, fraction: _fractionOfMicros(fractionMicros));
}

int _fractionOfMicros(int micros) =>
    (BigInt.from(micros) * (BigInt.one << 64) ~/ BigInt.from(1000000)).toSigned(64).toInt();

/// [timestamp] as a UTC [DateTime], to microsecond precision.
DateTime lvDateTimeOfTimestamp(LvTimestamp timestamp) {
  final micros = (BigInt.from(timestamp.fraction).toUnsigned(64) * BigInt.from(1000000) >> 64).toInt();
  return DateTime.fromMicrosecondsSinceEpoch(
    (timestamp.seconds - kLvEpochOffsetSeconds) * 1000000 + micros,
    isUtc: true,
  );
}

/// To Time Stamp: seconds since the LabVIEW epoch as a timestamp.
LvTimestamp lvToTimeStamp(double seconds) {
  final whole = seconds.floor();
  return LvTimestamp(seconds: whole, fraction: ((seconds - whole) * 18446744073709551616.0).toInt());
}

/// A timestamp as seconds since the LabVIEW epoch, as To Double Precision Float reads one.
double lvTimestampToDouble(LvTimestamp timestamp) =>
    timestamp.seconds + BigInt.from(timestamp.fraction).toUnsigned(64).toDouble() / 18446744073709551616.0;

const List<String> _kWeekdays = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

const List<String> _kMonths = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// Format Date/Time String: [timestamp] spelled by [format]'s time format codes (`%a %A %b %B
/// %c %d %H %I %j %m %M %p %S %Nu %U %w %W %x %X %y %Y %z %Z %%`, `N` a digit of precision), in UTC when [utc]
/// else in the local zone; an unknown code is written literally and an empty format reads as
/// `%c`. The locale-specific codes `%c`, `%x` and `%X` spell the ISO forms
/// `YYYY-MM-DD HH:MM:SS`, `YYYY-MM-DD` and `HH:MM:SS`; `%Z` is the zone's abbreviation.
String lvFormatDateTimeString(String format, LvTimestamp timestamp, {bool utc = false}) {
  final universal = lvDateTimeOfTimestamp(timestamp);
  final time = utc ? universal : universal.toLocal();
  final codes = format.isEmpty ? '%c' : format;
  final out = StringBuffer();
  String two(int value) => value.toString().padLeft(2, '0');
  for (var i = 0; i < codes.length; i++) {
    final unit = codes[i];
    if (unit != '%' || i + 1 >= codes.length) {
      out.write(unit);
      continue;
    }
    var next = codes[++i];
    var digits = 0;
    if (RegExp(r'\d').hasMatch(next) && i + 1 < codes.length && codes[i + 1] == 'u') {
      digits = int.parse(next);
      next = codes[++i];
    }
    switch (next) {
      case 'a':
        out.write(_kWeekdays[time.weekday % 7].substring(0, 3));
      case 'A':
        out.write(_kWeekdays[time.weekday % 7]);
      case 'b':
        out.write(_kMonths[time.month - 1].substring(0, 3));
      case 'B':
        out.write(_kMonths[time.month - 1]);
      case 'c':
        out.write(
          '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}:${two(time.second)}',
        );
      case 'd':
        out.write(two(time.day));
      case 'H':
        out.write(two(time.hour));
      case 'I':
        out.write(two(time.hour % 12 == 0 ? 12 : time.hour % 12));
      case 'j':
        out.write(_dayOfYear(time).toString().padLeft(3, '0'));
      case 'm':
        out.write(two(time.month));
      case 'M':
        out.write(two(time.minute));
      case 'p':
        out.write(time.hour < 12 ? 'AM' : 'PM');
      case 'S':
        out.write(two(time.second));
      case 'u':
        final fraction = BigInt.from(timestamp.fraction).toUnsigned(64).toDouble() / 18446744073709551616.0;
        out.write(fraction.toStringAsFixed(digits).substring(1));
      case 'U':
        out.write(two(_weekOfYear(time, firstWeekday: DateTime.sunday)));
      case 'w':
        out.write(time.weekday % 7);
      case 'W':
        out.write(two(_weekOfYear(time, firstWeekday: DateTime.monday)));
      case 'x':
        out.write('${time.year}-${two(time.month)}-${two(time.day)}');
      case 'X':
        out.write('${two(time.hour)}:${two(time.minute)}:${two(time.second)}');
      case 'y':
        out.write(two(time.year % 100));
      case 'Y':
        out.write(time.year);
      case 'z':
        final offset = time.timeZoneOffset;
        final sign = offset.isNegative ? '-' : '+';
        final total = offset.abs();
        out.write('$sign${two(total.inHours)}:${two(total.inMinutes % 60)}:${two(total.inSeconds % 60)}');
      case 'Z':
        out.write(time.timeZoneName);
      case '%':
        out.write('%');
      default:
        out.write('%$next');
    }
  }
  return out.toString();
}

const List<int> _kDaysBeforeMonth = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];

bool _isLeapYear(int year) => year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);

int _dayOfYear(DateTime time) =>
    _kDaysBeforeMonth[time.month - 1] + time.day + (time.month > 2 && _isLeapYear(time.year) ? 1 : 0);

int _weekOfYear(DateTime time, {required int firstWeekday}) {
  final dayOfYear = _dayOfYear(time);
  final weekday = time.weekday % 7;
  final firstDay = firstWeekday % 7;
  final offset = (weekday - firstDay + 7) % 7;
  return (dayOfYear - 1 - offset + 7) ~/ 7;
}
