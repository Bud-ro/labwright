import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Erdos Miller's snippet example: the current time, shown as a time stamp and as a double.
ViModel buildSnippetExample() {
  final vi = ViModel.empty(name: 'snippet_example.vi');
  final asTimeStamp = vi.indicator(BdType.timestamp, 'Current Time (time stamp)');
  final asDouble = vi.indicator(BdType.dbl, 'Current Time (double)');

  final toDouble = vi.add(BdPrimitive(PrimOp.toDoublePrecisionFloat));
  final now = vi.add(BdPrimitive(PrimOp.getDateTimeInSeconds));
  vi.connect([toDouble.terminal('double precision float'), asDouble]);
  vi.connect([now.terminal('current time'), asTimeStamp, toDouble.terminal('number')]);
  vi.write();
  return vi;
}
