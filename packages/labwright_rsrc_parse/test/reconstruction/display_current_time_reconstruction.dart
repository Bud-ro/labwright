import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Display Current Time in LabVIEW VI", second snippet: the current time as a time
/// stamp and formatted to the millisecond.
ViModel buildDisplayCurrentTime() {
  final vi = ViModel.empty(name: 'Display Current Time.vi');
  final bd = vi.blockDiagram;
  final format = bd.diagram.add(
    BdConstant.create(bd, BdType.string, '%m/%d/%Y%H:%M:%S%3u', label: 'time format string (%c)'),
  );
  final formatted = bd.indicator(BdType.string, 'Date Formatted with Milliseconds');
  final stamp = bd.indicator(BdType.timestamp, 'LabVIEW TimeStamp');
  final toText = bd.diagram.add(BdPrimitive.create(bd, PrimOp.formatDateTimeString));
  final now = bd.diagram.add(BdPrimitive.create(bd, PrimOp.getDateTimeInSeconds));
  bd.connect(format.out, toText.terminal('time format string'));
  bd.connect(toText.terminal('date/time string'), formatted.terminal);
  bd.connect(now.terminal('current time'), toText.terminal('time stamp'));
  bd.connect(now.terminal('current time'), stamp.terminal);
  bd.write();
  return vi;
}
