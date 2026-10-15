import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Erdos Miller's snippet example: the current time, shown as a time stamp and as a double.
ViModel buildSnippetExample() {
  final vi = ViModel.empty(name: 'snippet_example.vi');
  final asTimeStamp = vi.indicator(BdType.timestamp, 'Current Time (time stamp)');
  final asDouble = vi.indicator(BdType.dbl, 'Current Time (double)');

  final toDouble = vi.add(BdPrimitive(PrimOp.toDoublePrecisionFloat));
  final now = vi.add(BdPrimitive(PrimOp.getDateTimeInSeconds));
  toDouble['double precision float'] >> asDouble;
  now['current time'] >> asTimeStamp;
  now['current time'] >> toDouble['number'];
  vi.write();
  return vi;
}
