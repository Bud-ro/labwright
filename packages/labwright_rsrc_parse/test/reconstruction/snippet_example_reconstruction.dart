import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Erdos Miller's snippet example: the current time, shown as a time stamp and as a double.
ViModel buildSnippetExample() {
  final vi = ViModel.empty(name: 'snippet_example.vi');
  final bd = vi.blockDiagram;
  final asTimeStamp = bd.indicator(BdType.timestamp, 'Current Time (time stamp)');
  final asDouble = bd.indicator(BdType.dbl, 'Current Time (double)');
  final toDouble = bd.diagram.add(BdPrimitive.create(bd, PrimOp.toDoublePrecisionFloat));
  final now = bd.diagram.add(BdPrimitive.create(bd, PrimOp.getDateTimeInSeconds));
  bd.connect(toDouble.terminal('double precision float'), asDouble.terminal);
  bd.connect(now.terminal('current time'), asTimeStamp.terminal);
  bd.connect(now.terminal('current time'), toDouble.terminal('number'));
  bd.write();
  return vi;
}
