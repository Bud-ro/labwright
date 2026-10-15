import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Display Current Time in LabVIEW VI", first snippet: the current time shown as a time
/// stamp.
ViModel buildCurrentTimeStamp() {
  final vi = ViModel.empty(name: 'Display Current Time.vi');
  final stamp = vi.indicator(BdType.timestamp, 'LabVIEW TimeStamp 2');

  final now = vi.add(BdPrimitive(PrimOp.getDateTimeInSeconds));
  vi.connect([now.terminal('current time'), stamp]);
  vi.write();
  return vi;
}
