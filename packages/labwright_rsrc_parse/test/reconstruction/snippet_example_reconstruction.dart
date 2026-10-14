import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Erdos Miller's snippet example: the current time, shown as a time stamp and as a double.
ViModel buildSnippetExample() {
  final vi = ViModel.empty(name: 'snippet_example.vi');
  final bd = vi.blockDiagram;
  final asTimeStamp = bd.indicator(
    BdType.timestamp,
    'Current Time (time stamp)',
    at: (x: 88, y: 8),
    labelAt: const HeapRect(top: -1, left: 32, bottom: 16, right: 176),
  );
  final asDouble = bd.indicator(
    BdType.dbl,
    'Current Time (double)',
    at: (x: 88, y: 49),
    labelAt: const HeapRect(top: -1, left: 32, bottom: 16, right: 153),
  );
  final toDouble = bd.diagram.add(
    BdPrimitive.create(bd, PrimOp.toDoublePrecisionFloat, at: const HeapRect(top: 41, left: 45, bottom: 73, right: 77)),
  );
  final now = bd.diagram.add(
    BdPrimitive.create(bd, PrimOp.getDateTimeInSeconds, at: const HeapRect(top: 0, left: 0, bottom: 32, right: 32)),
  );
  bd.connect(toDouble.terminal('double precision float'), asDouble.terminal);
  bd.connect(now.terminal('current time'), asTimeStamp.terminal);
  bd.connect(now.terminal('current time'), toDouble.terminal('number'), bendX: 43);
  bd.write();
  return vi;
}
