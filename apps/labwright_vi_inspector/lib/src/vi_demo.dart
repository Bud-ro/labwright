import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

class ViLoad {
  const ViLoad.ok(this.summary) : error = null;
  const ViLoad.failed(this.error) : summary = null;

  final ViSummary? summary;
  final String? error;

  bool get isOk => summary != null;
}

ViLoad summarize(Uint8List bytes) {
  try {
    return ViLoad.ok(parseVi(bytes));
  } on ViFormatException catch (e) {
    return ViLoad.failed('Not a LabVIEW RSRC (.vi/.ctl) file: ${e.message}');
  } catch (e) {
    return ViLoad.failed('Could not parse this file: $e');
  }
}
