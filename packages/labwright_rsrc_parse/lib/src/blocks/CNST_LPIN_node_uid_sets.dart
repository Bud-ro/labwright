/// `CNST` / `LPIN` - Constant-Node and Loop-Invariant-Node UID Sets: [ViNodeUidSet]
///
/// These are both lists of object IDs. They are likely used to perform
/// constant folding, or optimize loop runs.
///   - `CNST` contains the list of constant nodes, wires, or nodes only fed by constant nodes.
///   - `LPIN` contains the list of nodes/wires inside loops that never change value between iterations.
///
/// The exception to both of these are cases and sequences. Objects in those structures are
/// exempted from `CNST` and `LPIN` presumably because a frame/case may never run.
///
/// ```text
/// offset  size  field    type   meaning
/// 0       rest  ids      u32[]  Block-diagram object ids, rising.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../word_grid.dart';

final class ViNodeUidSet extends ViWordGrid {
  ViNodeUidSet(Uint8List bytes) : super(bytes, layout) {
    assert(() {
      for (var i = 1; i < length; i++) {
        if (this[i] <= this[i - 1]) return false;
      }
      return true;
    }(), 'the ids rise strictly');
  }

  bool contains(int oid) {
    var low = 0, high = length;
    while (low < high) {
      final mid = (low + high) >> 1;
      final id = this[mid];
      if (id == oid) return true;
      if (id < oid) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return false;
  }

  static Uint8List encode(List<int> ids) {
    final out = Uint8List(_ids.wordSize * ids.length);
    _ids.write(ByteData.sublistView(out), ids);
    return out;
  }

  static const _ids = U32List(0); // Block-diagram object ids, rising.

  static const layout = ByteLayout([_ids]);
}
