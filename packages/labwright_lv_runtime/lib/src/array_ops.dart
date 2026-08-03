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

  /// The number of **outermost-dimension** slices — the iteration count of a
  /// loop auto-indexing this array.
  int get outerLength => dims.isEmpty ? 0 : dims.first;

  /// The slice at outermost index [index]: a copy of the [dims]`[1]` elements
  /// [data] holds contiguously there, since the last dimension varies fastest.
  ///
  /// Two-dimensional arrays only. A deeper array's slice carries a dimension
  /// vector of its own, which this return type has no room for.
  T rowAt(int index) {
    if (dims.length != 2) {
      throw StateError('rowAt is defined for a 2-D array; this one has ${dims.length} dimensions');
    }
    final width = dims[1];
    return data.sublist(index * width, (index + 1) * width) as T;
  }
}

/// LabVIEW's For loop iteration count: the smallest of the wired count
/// terminal and every auto-indexed input array's length.
int lvIterationCount(List<int> bounds) => bounds.reduce((a, b) => a < b ? a : b);
