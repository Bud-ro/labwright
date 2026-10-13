import 'dart:typed_data';

import 'values.dart';

class LvArrayNd<T extends List<Object?>> {
  LvArrayNd(this.data, this.dims);
  final T data;
  final Uint32List dims;
  int offsetOf(List<int> indices) {
    var offset = 0;
    for (var axis = 0; axis < dims.length; axis++) {
      offset = offset * dims[axis] + indices[axis];
    }
    return offset;
  }

  int get outerLength => dims.isEmpty ? 0 : dims.first;
  T rowAt(int index) {
    if (dims.length != 2) {
      throw StateError('rowAt is defined for a 2-D array; this one has ${dims.length} dimensions');
    }
    final width = dims[1];
    return data.sublist(index * width, (index + 1) * width) as T;
  }
}

int lvIterationCount(List<int> bounds) => bounds.reduce((a, b) => a < b ? a : b);

/// Search 1D Array: the index at or after [start] of the first element equal to [element], or
/// −1 when none is. A start index below zero is not decoded and throws.
int lvSearch1dArray<T>(List<T> array, T element, [int start = 0]) {
  if (start < 0) {
    throw RangeError.value(start, 'start', "LabVIEW's Search 1D Array rule for a negative start index is not decoded");
  }
  for (var index = start; index < array.length; index++) {
    if (lvSameValue(array[index], element)) return index;
  }
  return -1;
}
