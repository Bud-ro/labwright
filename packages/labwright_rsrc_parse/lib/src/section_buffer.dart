import 'dart:typed_data';

/// One splice of a section: the bytes [removed] at [start], and how many were [inserted] in
/// their place; applying `splice(start, start + inserted, removed)` takes it back.
class ViSectionEdit {
  const ViSectionEdit(this.section, this.start, this.removed, this.inserted);

  final ViSectionBuffer section;

  final int start;

  final Uint8List removed;

  final int inserted;
}

/// One section of a model: its tag, its index among the block's sections, and its inflated
/// payload. A loaded section shares the bytes it was decoded from until the first edit copies
/// them into a buffer with slack; [bytes] is always the live payload, [edited] whether it
/// differs from what was loaded.
class ViSectionBuffer {
  ViSectionBuffer(this.tag, this.index, Uint8List bytes, {required this.compressed, this.secRel})
    : _loaded = bytes,
      _bytes = bytes,
      _length = bytes.length;

  final String tag;

  final int index;

  /// Whether the file stores the section behind the compressed envelope.
  final bool compressed;

  /// The section's offset within the file's data area, null for a section the file does not
  /// hold.
  final int? secRel;

  final Uint8List _loaded;

  Uint8List _bytes;

  int _length;

  bool _edited = false;

  /// Told of every splice, with what it removed, so edits can be journalled and undone.
  void Function(ViSectionEdit edit)? onEdit;

  Uint8List get bytes => Uint8List.sublistView(_bytes, 0, _length);

  int get length => _length;

  /// Whether the payload differs from the one loaded.
  bool get edited {
    if (!_edited) return false;
    if (_length != _loaded.length) return true;
    for (var i = 0; i < _length; i++) {
      if (_bytes[i] != _loaded[i]) return true;
    }
    return false;
  }

  /// The payload to write into in place: the section's own copy, which the first call makes.
  Uint8List get writable {
    if (!_edited) {
      _bytes = Uint8List(_capacityFor(_length))..setRange(0, _length, _bytes);
      _edited = true;
    }
    return bytes;
  }

  /// Replaces the whole payload.
  void replace(List<int> payload) => splice(0, _length, payload);

  /// Overwrites the bytes at [at] with [bytes], in place.
  void write(int at, List<int> bytes) => splice(at, at + bytes.length, bytes);

  /// Applies [body] to the payload in place and journals the range it changed.
  void edit(void Function(Uint8List bytes) body) {
    final before = Uint8List.fromList(bytes);
    final target = writable;
    body(target);
    var first = 0;
    while (first < before.length && before[first] == target[first]) {
      first++;
    }
    if (first == before.length) return;
    var last = before.length;
    while (last > first && before[last - 1] == target[last - 1]) {
      last--;
    }
    onEdit?.call(ViSectionEdit(this, first, Uint8List.sublistView(before, first, last), last - first));
  }

  /// Replaces the bytes from [start] to [end] with [replacement], shifting what follows.
  void splice(int start, int end, List<int> replacement) {
    assert(0 <= start && start <= end && end <= _length, 'the splice lies inside the payload');
    final removed = onEdit == null ? null : Uint8List.fromList(Uint8List.sublistView(_bytes, start, end));
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
    if (removed != null) onEdit!(ViSectionEdit(this, start, removed, replacement.length));
  }

  /// Slack for later growth: twice the current buffer or what is needed, in 8 KiB quanta.
  int _capacityFor(int length) {
    final wanted = length > 2 * _bytes.length ? length : 2 * _bytes.length;
    return (wanted + _quantum - 1) ~/ _quantum * _quantum;
  }

  static const int _quantum = 8192;
}
