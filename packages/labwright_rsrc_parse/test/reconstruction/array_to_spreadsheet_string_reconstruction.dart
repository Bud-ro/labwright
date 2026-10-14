import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Stack Overflow 53146805: one Array To Spreadsheet String node, unwired.
ViModel buildArrayToSpreadsheetString() {
  final vi = ViModel.empty(name: 'Array To Spreadsheet String.vi');
  final bd = vi.blockDiagram;
  bd.diagram.add(
    BdPrimitive.create(
      bd,
      PrimOp.arrayToSpreadsheetString,
      at: const HeapRect(top: 15, left: 0, bottom: 47, right: 32),
      label: 'Array To Spreadsheet String',
      labelAt: const HeapRect(top: -15, left: 0, bottom: 0, right: 151),
    ),
  );
  bd.write();
  return vi;
}
