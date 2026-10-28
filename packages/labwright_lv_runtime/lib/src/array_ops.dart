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

/// Sort 1D Array over elements with a natural order: numbers by value, strings by code units,
/// booleans false before true.
List<T> lvSort1dArray<T>(List<T> array) {
  final sorted = List<T>.of(array);
  sorted.sort(lvCompareValues);
  return sorted;
}

/// LabVIEW's ordering of two scalar values of one type: numbers numerically (NaN after every
/// number), strings by code units, booleans false before true, paths by their text; a pair this
/// runtime does not order throws.
int lvCompareValues(Object? a, Object? b) {
  if (a is num && b is num) {
    if (a is double && a.isNaN) return b is double && b.isNaN ? 0 : 1;
    if (b is double && b.isNaN) return -1;
    return a.compareTo(b);
  }
  if (a is String && b is String) return _compareCodeUnits(a, b);
  if (a is bool && b is bool) return a == b ? 0 : (a ? 1 : -1);
  if (a is LvPath && b is LvPath) return _compareCodeUnits(a.components.join('/'), b.components.join('/'));
  if (a is LvTimestamp && b is LvTimestamp) {
    return a.seconds != b.seconds ? a.seconds.compareTo(b.seconds) : a.fraction.compareTo(b.fraction);
  }
  throw UnsupportedError("LabVIEW's ordering of ${a.runtimeType} against ${b.runtimeType} is not decoded");
}

int _compareCodeUnits(String a, String b) {
  final length = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    final difference = a.codeUnitAt(i) - b.codeUnitAt(i);
    if (difference != 0) return difference;
  }
  return a.length - b.length;
}

/// Transpose 2D Array: `[i, j]` becomes `[j, i]`.
LvArrayNd<T> lvTranspose2dArray<T extends List<Object?>>(LvArrayNd<T> array, T Function(int length) allocate) {
  if (array.dims.length != 2) {
    throw ArgumentError.value(array.dims.length, 'dims', 'Transpose 2D Array takes a 2-D array');
  }
  final rows = array.dims[0], columns = array.dims[1];
  final out = allocate(rows * columns);
  for (var row = 0; row < rows; row++) {
    for (var column = 0; column < columns; column++) {
      out[column * rows + row] = array.data[row * columns + column];
    }
  }
  return LvArrayNd(out, Uint32List.fromList([columns, rows]));
}

/// Array Max & Min over a 1-D array: the first maximum and minimum and their indices; an empty
/// array gives [empty] for both values and -1 for both indices.
({T maxValue, int maxIndex, T minValue, int minIndex}) lvArrayMaxAndMin<T>(List<T> array, T empty) {
  if (array.isEmpty) return (maxValue: empty, maxIndex: -1, minValue: empty, minIndex: -1);
  var maxIndex = 0, minIndex = 0;
  for (var i = 1; i < array.length; i++) {
    if (lvCompareValues(array[i], array[maxIndex]) > 0) maxIndex = i;
    if (lvCompareValues(array[i], array[minIndex]) < 0) minIndex = i;
  }
  return (maxValue: array[maxIndex], maxIndex: maxIndex, minValue: array[minIndex], minIndex: minIndex);
}

/// Or Array Elements: false for an empty array.
bool lvOrArrayElements(List<bool> array) => array.any((element) => element);

/// And Array Elements: true for an empty array.
bool lvAndArrayElements(List<bool> array) => array.every((element) => element);

/// Split 1D Array: the elements before [index] and from it on; an index below zero splits at
/// zero and one past the end splits at the end.
(List<T>, List<T>) lvSplit1dArray<T>(List<T> array, int index) {
  final at = index < 0 ? 0 : (index > array.length ? array.length : index);
  return (array.sublist(0, at), array.sublist(at));
}

/// Delete From Array over a 1-D array: [length] elements from [index] removed, and those
/// elements. Without an index the last [length] elements go; a range past either end is cut
/// to the array.
({List<T> remaining, List<T> deleted}) lvDeleteFromArray<T>(List<T> array, {int? index, int length = 1}) {
  final count = length < 0 ? 0 : length;
  var start = index ?? array.length - count;
  if (start < 0) start = 0;
  if (start > array.length) start = array.length;
  var end = start + count;
  if (end > array.length) end = array.length;
  return (remaining: [...array.sublist(0, start), ...array.sublist(end)], deleted: array.sublist(start, end));
}

/// Array Subset over a 1-D array: [length] elements from [index], cut to the array; a null
/// length takes the rest.
List<T> lvArraySubset<T>(List<T> array, int index, [int? length]) {
  var start = index < 0 ? 0 : index;
  if (start > array.length) start = array.length;
  var end = length == null ? array.length : start + (length < 0 ? 0 : length);
  if (end > array.length) end = array.length;
  return array.sublist(start, end);
}

/// Insert Into Array over a 1-D array: [elements] inserted before [index]; without an index
/// they are appended, and an index past the end appends too.
List<T> lvInsertIntoArray<T>(List<T> array, List<T> elements, [int? index]) {
  var at = index ?? array.length;
  if (at < 0) at = 0;
  if (at > array.length) at = array.length;
  return [...array.sublist(0, at), ...elements, ...array.sublist(at)];
}

/// Rotate 1D Array: every element moved [n] places toward the end, wrapping around.
List<T> lvRotate1dArray<T>(List<T> array, int n) {
  if (array.isEmpty) return array;
  final shift = n % array.length;
  if (shift == 0) return List<T>.of(array);
  return [...array.sublist(array.length - shift), ...array.sublist(0, array.length - shift)];
}

/// Threshold 1D Array: the fractional index at which the ascending [array] crosses [threshold],
/// searched from [startIndex]: `i + (threshold - a[i]) / (a[i+1] - a[i])` for the first `i` with
/// `a[i+1] >= threshold`; the start index when the threshold is below its element, and the
/// last index when the array never reaches the threshold.
double lvThreshold1dArray(List<num> array, num threshold, [int startIndex = 0]) {
  var start = startIndex < 0 ? 0 : startIndex;
  if (array.isEmpty) return 0;
  if (start >= array.length) start = array.length - 1;
  if (threshold <= array[start]) return start.toDouble();
  for (var i = start; i + 1 < array.length; i++) {
    final low = array[i], high = array[i + 1];
    if (high >= threshold) {
      return high == low ? (i + 1).toDouble() : i + (threshold - low) / (high - low);
    }
  }
  return (array.length - 1).toDouble();
}
