import 'dart:io';

import 'values.dart';

/// Which end of a string `Trim Whitespace.vi` trims; its `location` ring, in ring order.
enum LvTrimLocation { both, start, end }

/// `Space Constant.vi`: one space.
String lvSpaceConstant() => ' ';

/// `Application Directory.vi`: the directory the running program was started from.
LvPath lvApplicationDirectory() {
  final directory = File(Platform.resolvedExecutable).parent;
  final segments = Uri.file(directory.path).pathSegments.where((segment) => segment.isNotEmpty).toList();
  return LvPath(components: segments, absolute: true);
}

/// `Trim Whitespace.vi`: [string] without the spaces, tabs, carriage returns and line feeds at
/// the end(s) [location] names.
String lvTrimWhitespace({required String string, LvTrimLocation location = LvTrimLocation.both}) {
  final text = string;
  var start = 0, end = text.length;
  if (location != LvTrimLocation.end) {
    while (start < end && _isWhitespace(text.codeUnitAt(start))) {
      start++;
    }
  }
  if (location != LvTrimLocation.start) {
    while (end > start && _isWhitespace(text.codeUnitAt(end - 1))) {
      end--;
    }
  }
  return text.substring(start, end);
}

bool _isWhitespace(int code) => code == 0x20 || code == 0x09 || code == 0x0d || code == 0x0a;

/// `Color to RGB.vi`: the red, green and blue bytes of a LabVIEW colour word, `0x00RRGGBB`.
({int red, int green, int blue}) lvColorToRgb({required int color}) =>
    (red: (color >> 16) & 0xff, green: (color >> 8) & 0xff, blue: color & 0xff);

/// `Error Cluster From Error Code.vi`: an error whose status is set when [errorCode] is not 0,
/// whose source is [message], and which gives way to an incoming error. TODO: the call chain
/// [showCallChain] appends to the source is not modelled; the source is [message] alone.
LvError lvErrorClusterFromErrorCode({
  required int errorCode,
  String message = '',
  bool showCallChain = true,
  LvError errorIn = LvError.none,
}) {
  if (errorIn.status) return errorIn;
  return LvError(status: errorCode != 0, code: errorCode, source: message);
}
