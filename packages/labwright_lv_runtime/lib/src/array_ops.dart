/// LabVIEW's **array** carriers and the loop rules that shape them.
///
/// A 1-D array is the element's exact-width storage — a `dart:typed_data` list
/// for a numeric element, a plain `List<T>` otherwise — so no carrier type is
/// needed for it here. A multi-dimensional array is [LvArrayNd].
library;

import 'dart:typed_data';

/// A LabVIEW multi-dimensional array: a flat, **row-major** typed buffer plus
/// its dimension lengths.
///
/// LabVIEW arrays are rectangular, so one buffer and a length vector is the
/// exact shape — a list of rows would admit ragged shapes LabVIEW forbids and
/// cost an indirection per row.
class LvArrayNd<T extends List<Object?>> {
  LvArrayNd(this.data, this.dims);

  /// The elements, row-major: the last dimension varies fastest.
  final T data;

  /// The length of each dimension, outermost first.
  final Uint32List dims;

  /// The flat [data] offset of the element at [indices], one index per
  /// dimension in [dims] order.
  int offsetOf(List<int> indices) {
    var offset = 0;
    for (var axis = 0; axis < dims.length; axis++) {
      offset = offset * dims[axis] + indices[axis];
    }
    return offset;
  }
}

/// LabVIEW's For loop iteration count: the smallest of the wired count
/// terminal and every auto-indexed input array's length.
int lvIterationCount(List<int> bounds) => bounds.reduce((a, b) => a < b ? a : b);
