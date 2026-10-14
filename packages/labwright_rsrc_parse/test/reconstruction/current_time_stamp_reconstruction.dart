import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Display Current Time in LabVIEW VI", first snippet: the current time shown as a time
/// stamp.
ViModel buildCurrentTimeStamp() {
  final vi = ViModel.empty(name: 'Display Current Time.vi');
  final bd = vi.blockDiagram;
  final stamp = bd.indicator(BdType.timestamp, 'LabVIEW TimeStamp 2');
  final now = bd.diagram.add(BdPrimitive.create(bd, PrimOp.getDateTimeInSeconds));
  bd.connect(now.terminal('current time'), stamp.terminal);
  bd.write();
  return vi;
}
