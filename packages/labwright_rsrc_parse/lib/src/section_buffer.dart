import 'dart:typed_data';

/// One section of a model: its tag, its index among the block's sections, and its inflated
/// payload. A loaded section shares the bytes it was decoded from until the first edit copies
/// them into a buffer with slack; [bytes] is always the live payload, [edited] whether it
/// differs from what was loaded.
class ViSectionBuffer {
  ViSectionBuffer(this.tag, this.index, Uint8List bytes, {required this.compressed, this.secRel})
    : _bytes = bytes,
      _length = bytes.length;

  final String tag;

  final int index;

  /// Whether the file stores the section behind the compressed envelope.
  final bool compressed;

  /// The section's offset within the file's data area, null for a section the file does not
  /// hold.
  final int? secRel;

  Uint8List _bytes;

  int _length;

  bool _edited = false;

  Uint8List get bytes => Uint8List.sublistView(_bytes, 0, _length);

  int get length => _length;

  bool get edited => _edited;

  /// The payload to write into in place: the section's own copy, which the first call makes.
  Uint8List get writable {
    if (!_edited) splice(0, 0, const []);
    return bytes;
  }

  /// Replaces the whole payload.
  void replace(List<int> payload) => splice(0, _length, payload);

  /// Replaces the bytes from [start] to [end] with [replacement], shifting what follows.
  void splice(int start, int end, List<int> replacement) {
    assert(0 <= start && start <= end && end <= _length, 'the splice lies inside the payload');
    final tail = _length - end;
    final length = start + replacement.length + tail;
    if (!_edited || length > _bytes.length) {
      final grown = Uint8List(_capacityFor(length));
      grown.setRange(0, start, _bytes);
      grown.setRange(start + replacement.length, length, _bytes, end);
      _bytes = grown;
    } else if (replacement.length != end - start) {
      _bytes.setRange(start + replacement.length, length, _bytes, end);
    }
    _bytes.setRange(start, start + replacement.length, replacement);
    _length = length;
    _edited = true;
  }

  /// Slack for later growth: twice the current buffer or what is needed, in 8 KiB quanta.
  int _capacityFor(int length) {
    final wanted = length > 2 * _bytes.length ? length : 2 * _bytes.length;
    return (wanted + _quantum - 1) ~/ _quantum * _quantum;
  }

  static const int _quantum = 8192;
}
