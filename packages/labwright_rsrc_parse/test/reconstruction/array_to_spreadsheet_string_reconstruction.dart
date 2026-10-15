import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Stack Overflow 53146805: one Array To Spreadsheet String node, unwired.
ViModel buildArrayToSpreadsheetString() {
  final vi = ViModel.empty(name: 'Array To Spreadsheet String.vi');
  vi.add(BdPrimitive(PrimOp.arrayToSpreadsheetString));
  vi.write();
  return vi;
}
