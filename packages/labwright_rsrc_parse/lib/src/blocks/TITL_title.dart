/// `TITL` - Window Title: [ViTitle]
///
/// The front panel's window title when it is not the VI's name, from VI Properties » Window
/// Appearance; 898 of 8316 VIs carry one, and 864 of those differ from the file name.
///
/// ```text
/// offset  size  field    type   meaning
/// 0       …     title    pstr   The window title.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViTitle extends ByteRecord {
  ViTitle(Uint8List bytes) : super(bytes, layout) {
    assert(view.lengthInBytes > 0 && _title.endIn(view) == view.lengthInBytes, 'a title is one Pascal string');
  }

  /// The window title.
  String get text => _title.read(view);

  static const _title = PStr(0);

  static const layout = ByteLayout([_title]);
}
