import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// NI's "Display Current Time in LabVIEW VI", second snippet: the current time as a time
/// stamp and formatted to the millisecond.
ViModel buildDisplayCurrentTime() {
  final vi = ViModel.empty(name: 'Display Current Time.vi');
  final bd = vi.blockDiagram;
  final format = bd.diagram.add(
    BdConstant.create(
      bd,
      BdType.string,
      '%m/%d/%Y%H:%M:%S%3u',
      label: 'time format string (%c)',
      at: const HeapRect(top: 0, left: 0, bottom: 19, right: 159),
      labelAt: const HeapRect(top: -17, left: 33, bottom: 0, right: 159),
    ),
  );
  final formatted = bd.indicator(
    BdType.string,
    'Date Formatted with Milliseconds',
    at: (x: 330, y: 40),
    labelAt: const HeapRect(top: -33, left: 0, bottom: -16, right: 180),
    icon: true,
  );
  final stamp = bd.indicator(
    BdType.timestamp,
    'LabVIEW TimeStamp',
    at: (x: 95, y: 103),
    labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 113),
    icon: true,
  );
  final toText = bd.diagram.add(
    BdPrimitive.create(
      bd,
      PrimOp.formatDateTimeString,
      at: const HeapRect(top: 48, left: 165, bottom: 80, right: 197),
      label: 'Format Date/Time String',
      labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 134),
    ),
  );
  final now = bd.diagram.add(
    BdPrimitive.create(
      bd,
      PrimOp.getDateTimeInSeconds,
      at: const HeapRect(top: 48, left: 3, bottom: 80, right: 35),
      label: 'Get Date/Time In Seconds',
      labelAt: const HeapRect(top: -17, left: -1, bottom: 0, right: 139),
    ),
  );
  bd.connect(format.out, toText.terminal('time format string'), bendX: 162);
  bd.connect(toText.terminal('date/time string'), formatted.terminal);
  bd.connect(now.terminal('current time'), toText.terminal('time stamp'), bendX: 75);
  bd.connect(now.terminal('current time'), stamp.terminal);
  bd.write();
  return vi;
}
