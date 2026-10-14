import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Display Current Time in LabVIEW VI", first snippet: the current time shown as a time
/// stamp.
ViModel buildCurrentTimeStamp() {
  final vi = ViModel.empty(name: 'Display Current Time.vi');
  final bd = vi.blockDiagram;
  final stamp = bd.indicator(
    BdType.timestamp,
    'LabVIEW TimeStamp 2',
    at: (x: 147, y: 35),
    labelAt: const HeapRect(top: -35, left: 0, bottom: -18, right: 122),
    icon: true,
  );
  final now = bd.diagram.add(
    BdPrimitive.create(
      bd,
      PrimOp.getDateTimeInSeconds,
      at: const HeapRect(top: 38, left: 0, bottom: 70, right: 32),
      label: 'Get Date/Time In Seconds',
      labelAt: const HeapRect(top: -32, left: 0, bottom: 0, right: 81),
    ),
  );
  bd.connect(now.terminal('current time'), stamp.terminal);
  bd.write();
  return vi;
}
