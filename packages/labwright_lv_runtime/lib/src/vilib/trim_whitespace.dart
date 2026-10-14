/// Which end of a string `Trim Whitespace.vi` trims; its `location` ring, in ring order.
enum LvTrimLocation { both, start, end }

/// `Trim Whitespace.vi`: [string] without the spaces, tabs, carriage returns and line feeds at
/// the end(s) [location] names.
String lvTrimWhitespace({required String string, LvTrimLocation location = LvTrimLocation.both}) {
  var start = 0, end = string.length;
  if (location != LvTrimLocation.end) {
    while (start < end && _isWhitespace(string.codeUnitAt(start))) {
      start++;
    }
  }
  if (location != LvTrimLocation.start) {
    while (end > start && _isWhitespace(string.codeUnitAt(end - 1))) {
      end--;
    }
  }
  return string.substring(start, end);
}

bool _isWhitespace(int code) => code == 0x20 || code == 0x09 || code == 0x0d || code == 0x0a;
