import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Display Current Time in LabVIEW VI", second snippet: the current time as a time
/// stamp and formatted to the millisecond.
ViModel buildDisplayCurrentTime() {
  final vi = ViModel.empty(name: 'Display Current Time.vi');
  final formatted = vi.indicator(BdType.string, 'Date Formatted with Milliseconds');
  final stamp = vi.indicator(BdType.timestamp, 'LabVIEW TimeStamp');

  final format = vi.add(BdConstant.string('%m/%d/%Y%H:%M:%S%3u', label: 'time format string (%c)'));
  final toText = vi.add(BdPrimitive(PrimOp.formatDateTimeString));
  final now = vi.add(BdPrimitive(PrimOp.getDateTimeInSeconds));
  vi.connect(format, toText.terminal('time format string'));
  vi.connect(toText.terminal('date/time string'), formatted);
  vi.connect(now.terminal('current time'), toText.terminal('time stamp'));
  vi.connect(now.terminal('current time'), stamp);
  vi.write();
  return vi;
}
