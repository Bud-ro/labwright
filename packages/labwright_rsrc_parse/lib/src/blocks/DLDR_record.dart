/// `DLDR` - DLDR Record: [ViDldrRecord]
///
/// An in-memory structure of seven 32-bit slots written to the file verbatim. The one LabVIEW
/// 7.1 file in the corpus saves it live: slots 0, 2, 3 and 6 hold distinct values of pointer
/// shape (`0x0153b4e8` and three within 80 KB of it) and slots 1, 4 and 5 are 0. Every later
/// version saves it cleared: slot 0 holds 1 and the rest 0, in all 4161 other files. What the
/// slots address is not decoded and cannot be from saved files alone; more LabVIEW 7.x saves
/// would show whether the pointer pattern is stable, not what it points at. The record is
/// present in every standard VI that carries `DFDS`, absent from the 96 global, polymorphic and
/// control VIs that carry `DFDS`, and present in one polymorphic VI. Neither the expansion of
/// the tag nor the slots' roles is attested; pylabview reads the same 28 bytes as two words and
/// 20 opaque bytes under the guess "DataLog Data Record".
///
/// ```text
/// offset  size  field    type   meaning
/// 0       28    slots    u32[7] Pointer-sized slots: live 32-bit pointers in the LabVIEW 7.1 file, else 1
///                               then six zeros; roles TODO.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../word_grid.dart';

final class ViDldrRecord extends ViWordGrid {
  ViDldrRecord(Uint8List bytes) : super(bytes, layout);

  static Uint8List encode(List<int> slots) {
    final out = Uint8List(layout.size!);
    _slots.write(ByteData.sublistView(out), slots);
    return out;
  }

  // dart format off
  static const _slots = U32List(0, length: 7); // Pointer-sized slots: live 32-bit pointers in the LabVIEW 7.1 file, else 1 then six zeros; roles TODO.

  static const layout = ByteLayout([_slots]);
  // dart format on
}
