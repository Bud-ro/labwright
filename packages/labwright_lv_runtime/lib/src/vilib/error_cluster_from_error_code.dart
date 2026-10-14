import '../values.dart';

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
