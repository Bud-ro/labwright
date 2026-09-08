part of 'seq_binary.dart';

const _fieldHasValueBit = 0x2;
const _fieldAttrBits = 0x4 | 0x8 | 0x20 | 0x40;
const _fieldFramedBit = 0x80;
const _fieldHasExtDataBit = 0x100;
const _fieldHasFormatBit = 0x200;

const _fieldHasNumericRepBit = 0x800;

const _fieldKnownFlagBits =
    _fieldHasValueBit |
    _fieldAttrBits |
    _fieldFramedBit |
    _fieldHasExtDataBit |
    _fieldHasFormatBit |
    _fieldHasNumericRepBit;

int _minAttrWords(int fieldFlags) => ((fieldFlags >> 3) & 1) + ((fieldFlags >> 5) & 1) + ((fieldFlags >> 6) & 1);

/// Field record wire forms; `DELIM` is [_recordDelimiter].
enum _FieldForm {
  /// `[name][value][attr words…][0]`
  compact,

  /// `[0][0][DELIM][name][childCount][children…]`
  descriptor,

  /// `[flags|0x80][0][DELIM][X][name][value…][attrs…][0]`
  framed,

  /// `[flags][0][DELIM][name][value?][attrs…][0]`
  framedLite,

  /// `[flags][0][cls][name][value-part][format?][extras…][0]`
  plain,
}

enum BinaryNumericRepresentation {
  int64(2, 'Int64'),

  uint64(3, 'UInt64')
  ;

  const BinaryNumericRepresentation(this.code, this.xmlName);

  final int code;

  final String xmlName;

  static BinaryNumericRepresentation? of(int code) => switch (code) {
    2 => int64,
    3 => uint64,
    _ => null,
  };

  static bool isInteger(int code) => of(code) != null;
}

const _typeMaxFields = 200;

const _maxArrayElements = 4096;

const _tailedValueClasses = {
  SeqValueClass.boolean,
  SeqValueClass.string,
  SeqValueClass.number,
  SeqValueClass.numbers,
  SeqValueClass.strings,
  SeqValueClass.objects,
  SeqValueClass.expression,
  SeqValueClass.path,
  SeqValueClass.reference,
};

const _unvaluedScalarClasses = {
  SeqValueClass.boolean,
  SeqValueClass.string,
  SeqValueClass.number,
  SeqValueClass.reference,
};

const _boundedArrayClasses = {SeqValueClass.numbers, SeqValueClass.strings, SeqValueClass.objects};

/// TODO: the 17-byte inter-record preamble is not decoded.
class _TypeBodyParser {
  _TypeBodyParser(this.view, this.pool, this.recordRegionLength, this.table, [this.bodyEndBoundary, int? typeIndexBase])
    : typeIndexBase = typeIndexBase ?? deriveTypeIndexBase(view, pool, recordRegionLength, table);

  final ByteData view;
  final List<String> pool;
  final int recordRegionLength;
  final List<BinaryTypeRecord> table;

  _DecodeSink ops = _DecodeSink.none;

  final int typeIndexBase;

  bool _validTypeWord(int typeWord) {
    final tableIndex = typeWord - 1 - typeIndexBase;
    return tableIndex >= 0 && tableIndex < table.length;
  }

  BinaryTypeRecord _tableRef(int typeWord) => table[typeWord - 1 - typeIndexBase];

  final int? bodyEndBoundary;

  int _u32(int offset) => view.getUint32(offset, Endian.little);
  String? _tok(int word) => word > 0 && word < pool.length && pool[word].isNotEmpty ? pool[word] : null;

  static final _rootClassPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,39}$');

  String? _clsTok(int word) {
    if (word != 0) return _tok(word);
    if (pool.isEmpty) return null;
    final root = pool[0];
    return _rootClassPattern.hasMatch(root) ? root : null;
  }

  static final _boundPattern = RegExp(r'^(\[\d*\])+$');
  static bool _isBoundToken(String? token) => token != null && _boundPattern.hasMatch(token);

  bool _usedSpec = false;

  int _depth = 0;

  bool _inInstance = false;

  bool _partialStepArraysOk = false;

  bool _lastArrayPartial = false;

  Map<String, int>? _numericReprContext;

  static Map<String, int>? _reprsOf(BinaryTypeRecord ref) {
    Map<String, int>? out;
    for (final field in ref.fields ?? const <BinaryTypeField>[]) {
      final code = field.numericRepresentation;
      if (code != null && BinaryNumericRepresentation.isInteger(code)) {
        (out ??= {})[field.name] = code;
      }
    }
    return out;
  }

  int? _attrTail(int from, {int minWords = 0, List<int>? attrsOut}) {
    final rollbackMark = ops.mark();
    var offset = from;
    for (var attrIndex = 0; attrIndex <= _fieldMaxAttrWords; attrIndex++) {
      if (offset + _u32Bytes > recordRegionLength) return _blockBail(rollbackMark);
      final word = _u32(offset);
      if (word == 0 && attrIndex >= minWords) {
        ops.u32(offset, 0, _OpSource.grammar);
        return offset + _u32Bytes;
      }
      if (attrsOut != null) {
        attrsOut.add(word);
        ops.u32(offset, word, _OpSource.model);
      } else {
        ops.u32(offset, word, _OpSource.struct);
      }
      offset += _u32Bytes;
    }
    return _blockBail(rollbackMark);
  }

  /// TODO: only the extent is walked; spec contents are not decoded.
  int? _elementSpec(int offset) {
    final rollbackMark = ops.mark();
    final end = _elementSpecWalk(offset);
    ops.rollback(rollbackMark);
    return end;
  }

  int? _elementSpecWalk(int offset) {
    var cursor = offset;
    if (cursor >= recordRegionLength) return null;
    if (view.getUint8(cursor) == 0) cursor++;
    if (!_canRead(cursor) || _u32(cursor) != _recordDelimiter) return null;
    cursor += _u32Bytes;
    if (!_canRead(cursor)) return null;
    final typeWord = _u32(cursor);
    var typeWordOmitted = false;
    if (typeWord == _recordDelimiter) {
      typeWordOmitted = true;
      cursor += _u32Bytes;
    } else {
      if (!_validTypeWord(typeWord)) return null;
      cursor += _u32Bytes;
      if (!_canRead(cursor) || _u32(cursor) != _recordDelimiter) return null;
      cursor += _u32Bytes;
    }
    if (!_canRead(cursor)) return null;
    var tagged = false;
    if (_tok(_u32(cursor)) != null &&
        cursor + 2 * _u32Bytes <= recordRegionLength &&
        _u32(cursor + _u32Bytes) == 0x20000) {
      cursor += _u32Bytes;
    }
    if (_u32(cursor) == 0x20000) {
      tagged = true;
      cursor += _u32Bytes;
      if (!_canRead(cursor)) return null;
    }
    final count = _u32(cursor);
    if ((count < 1 && !tagged && typeWordOmitted) || count > _typeMaxFields) return null;
    cursor += _u32Bytes;
    final items = _fields(cursor, count);
    if (items == null) return null;
    return _attrTail(items.$2);
  }

  bool _canRead(int offset) => offset + _u32Bytes <= recordRegionLength;

  Null _blockBail(int rollbackMark) {
    ops.rollback(rollbackMark);
    return null;
  }

  static List<int>? _boundDims(String token) {
    final dims = <int>[];
    for (final match in RegExp(r'\[(\d*)\]').allMatches(token)) {
      final dim = int.tryParse(match.group(1)!);
      if (dim == null) return null;
      dims.add(dim);
    }
    return dims.isEmpty ? null : dims;
  }

  static int? _boundCount(String lbound, String ubound) {
    final lower = _boundDims(lbound);
    final upper = _boundDims(ubound);
    if (lower == null || upper == null || lower.length != upper.length) return null;
    var count = 1;
    for (var dimension = 0; dimension < lower.length; dimension++) {
      if (upper[dimension] < lower[dimension]) return null;
      count *= upper[dimension] - lower[dimension] + 1;
      if (count > _maxArrayElements) return null;
    }
    return count;
  }

  (List<BinaryTypeField>, int)? _stepElementPrefix(int offset, int count) {
    final elements = <BinaryTypeField>[];
    var cursor = offset;
    for (var elementIndex = 0; elementIndex < count; elementIndex++) {
      final rollbackMark = ops.mark();
      final element = _arrayElement(cursor);
      if (element == null || element.$1.valueClass != SeqValueClass.step) {
        ops.rollback(rollbackMark);
        break;
      }
      elements.add(element.$1);
      cursor = element.$2;
    }
    if (elements.isEmpty) return null;
    return (elements, cursor);
  }

  (List<BinaryTypeField>, int)? _populatedArrayTail(int offset, String lbound, String ubound, {List<int>? attrsOut}) {
    _lastArrayPartial = false;
    final count = _boundCount(lbound, ubound);
    if (count == null) return null;
    if (_inInstance) {
      if (offset < recordRegionLength && view.getUint8(offset) == 0) {
        for (final start in _protoSpecEnds(offset + 1)) {
          final rollbackMark = ops.mark();
          final attrsMark = attrsOut?.length;
          ops.byte(offset, 0, _OpSource.grammar);
          ops.copy(offset + 1, start);
          final elements = _elementRun(start, count);
          if (elements == null) {
            ops.rollback(rollbackMark);
            continue;
          }
          final after = _attrTail(elements.$2, attrsOut: attrsOut);
          if (after != null) {
            _usedSpec = true;
            return (elements.$1, after);
          }
          ops.rollback(rollbackMark);
          if (attrsMark != null) attrsOut!.length = attrsMark;
        }
      }
    }
    final mDecl = ops.mark();
    final attrsDeclMark = attrsOut?.length;
    final tail = _attrTail(offset, attrsOut: attrsOut);
    if (tail == null || tail >= recordRegionLength || view.getUint8(tail) != 0) {
      ops.rollback(mDecl);
      if (attrsDeclMark != null) attrsOut!.length = attrsDeclMark;
      return null;
    }
    ops.byte(tail, 0, _OpSource.grammar);
    for (final start in _protoSpecEnds(tail + 1)) {
      final rollbackMark = ops.mark();
      ops.copy(tail + 1, start);
      final elements = _elementRun(start, count);
      if (elements == null) {
        ops.rollback(rollbackMark);
        continue;
      }
      _usedSpec = true;
      return (elements.$1, elements.$2);
    }
    if (_partialStepArraysOk && !_inInstance) {
      for (final start in _protoSpecEnds(tail + 1)) {
        final rollbackMark = ops.mark();
        ops.copy(tail + 1, start);
        final prefix = _stepElementPrefix(start, count);
        if (prefix != null) {
          _usedSpec = true;
          _lastArrayPartial = true;
          return prefix;
        }
        ops.rollback(rollbackMark);
      }
    }
    ops.rollback(mDecl);
    if (attrsDeclMark != null) attrsOut!.length = attrsDeclMark;
    return null;
  }

  List<int> _protoSpecEnds(int offset) {
    final ends = <int>[];
    final six = _protoSpec(offset);
    if (six != null) ends.add(six);
    var cursor = offset;
    if (cursor < recordRegionLength && view.getUint8(cursor) == 0) cursor++;
    if (cursor + 5 * _u32Bytes <= recordRegionLength &&
        _u32(cursor) == _recordDelimiter &&
        _u32(cursor + _u32Bytes) == _recordDelimiter &&
        _tok(_u32(cursor + 2 * _u32Bytes)) != null &&
        _u32(cursor + 3 * _u32Bytes) == 0 &&
        _u32(cursor + 4 * _u32Bytes) == 0) {
      final five = cursor + 5 * _u32Bytes;
      if (!ends.contains(five)) ends.add(five);
    }
    ends.add(offset);
    return ends;
  }

  (List<BinaryTypeField>, int)? _scalarArrayTail(int offset, String lbound, String ubound, {List<int>? attrsOut}) {
    final count = _boundCount(lbound, ubound);
    if (count == null) return null;
    if (offset + count * _f64Bytes > recordRegionLength) return null;
    final rollbackMark = ops.mark();
    final elements = <BinaryTypeField>[];
    var cursor = offset;
    for (var elementIndex = 0; elementIndex < count; elementIndex++, cursor += _f64Bytes) {
      final value = view.getFloat64(cursor, Endian.little);
      if (!value.isFinite || (value != 0 && value.abs() < _smallestNormalF64)) {
        return _blockBail(rollbackMark);
      }
      ops.f64(cursor, value);
      final text = value == value.truncateToDouble() && value.abs() < 1e15 ? '${value.truncate()}' : '$value';
      elements.add(BinaryTypeField('', className: SeqValueClass.number.wire, value: text));
    }
    final attrsMark = attrsOut?.length;
    final after = _attrTail(cursor, attrsOut: attrsOut);
    if (after == null) {
      ops.rollback(rollbackMark);
      if (attrsMark != null) attrsOut!.length = attrsMark;
      return null;
    }
    return (elements, after);
  }

  (String, int)? _elemProtoTail(int offset) {
    if (offset + 3 * _u32Bytes > recordRegionLength) return null;
    final className = _tok(_u32(offset));
    if (className == null) return null;
    if (_u32(offset + _u32Bytes) != _recordDelimiter) return null;
    if (_u32(offset + 2 * _u32Bytes) != 0) return null;
    final rollbackMark = ops.mark();
    final after = _attrTail(offset + 3 * _u32Bytes);
    ops.rollback(rollbackMark);
    if (after == null) return null;
    return (className, after);
  }

  (List<BinaryTypeField>, int)? _elementRun(int offset, int count) {
    final rollbackMark = ops.mark();
    var cursor = offset;
    final elements = <BinaryTypeField>[];
    for (var elementIndex = 0; elementIndex < count; elementIndex++) {
      final element = _arrayElement(cursor);
      if (element == null) return _blockBail(rollbackMark);
      elements.add(element.$1);
      cursor = element.$2;
    }
    return (elements, cursor);
  }

  int? _protoSpec(int offset) {
    var cursor = offset;
    if (cursor >= recordRegionLength) return null;
    if (view.getUint8(cursor) == 0) cursor++;
    if (cursor + 6 * _u32Bytes > recordRegionLength) return null;
    if (_u32(cursor) != _recordDelimiter || _u32(cursor + _u32Bytes) != _recordDelimiter) {
      return null;
    }
    final value = _u32(cursor + 2 * _u32Bytes);
    if (value != 0 && _tok(value) == null) return null;
    if (_u32(cursor + 3 * _u32Bytes) != 0) return null;
    if (_u32(cursor + 5 * _u32Bytes) != 0) return null;
    if (value == 0 && _u32(cursor + 4 * _u32Bytes) == 0) return null;
    return cursor + 6 * _u32Bytes;
  }

  (BinaryTypeField, int)? _arrayElement(int offset) {
    for (final start in [offset, if (offset < recordRegionLength && view.getUint8(offset) == 0) offset + 1]) {
      if (!_canRead(start) || _u32(start) != _recordDelimiter) continue;
      final rollbackMark = ops.mark();
      if (start > offset) ops.byte(offset, 0, _OpSource.grammar);
      final block = _elementBlock(start);
      if (block == null) ops.rollback(rollbackMark);
      return block;
    }
    if (!_canRead(offset)) return null;
    if (_tok(_u32(offset)) == _stepToken) return _stepElement(offset);
    final outer = _inInstance;
    _inInstance = true;
    final field = _field(offset);
    _inInstance = outer;
    return field;
  }

  (BinaryTypeField, int)? _stepElement(int offset) {
    if (offset + 4 * _u32Bytes > recordRegionLength) return null;
    if (_tok(_u32(offset)) != 'Step') return null;
    final typeWord = _u32(offset + _u32Bytes);
    if (!_validTypeWord(typeWord)) return null;
    final name = _tok(_u32(offset + 2 * _u32Bytes));
    if (name == null) return null;
    final count = _u32(offset + 3 * _u32Bytes);
    if (count > _typeMaxFields) return null;
    final ref = _tableRef(typeWord);
    final rollbackMark = ops.mark();
    ops.poolRef(offset, _u32(offset));
    ops.u32(offset + _u32Bytes, typeWord, _OpSource.model);
    ops.poolRef(offset + 2 * _u32Bytes, _u32(offset + 2 * _u32Bytes));
    ops.u32(offset + 3 * _u32Bytes, count, _OpSource.model);
    final outerInstance = _inInstance;
    final outerRepr = _numericReprContext;
    _inInstance = true;
    _numericReprContext = _reprsOf(ref);
    final children = _fields(offset + 4 * _u32Bytes, count);
    _inInstance = outerInstance;
    _numericReprContext = outerRepr;
    if (children == null) return _blockBail(rollbackMark);
    final attrs = <int>[];
    final after = _attrTail(children.$2, attrsOut: attrs);
    if (after == null) return _blockBail(rollbackMark);
    return (
      BinaryTypeField(
        name,
        className: SeqValueClass.step.wire,
        typeName: ref.name,
        children: children.$1,
        instanceOverrides: true,
        attrWords: attrs,
      ),
      after,
    );
  }

  (BinaryTypeField, int)? _elementBlock(int offset) {
    final rollbackMark = ops.mark();
    ops.u32(offset, _recordDelimiter, _OpSource.grammar);
    var cursor = offset + _u32Bytes;
    if (!_canRead(cursor)) return _blockBail(rollbackMark);
    final typeWord = _u32(cursor);
    cursor += _u32Bytes;
    if (!_canRead(cursor)) return _blockBail(rollbackMark);
    final word3 = _u32(cursor);
    var name = '';
    BinaryTypeRecord? ref;
    if (word3 == _recordDelimiter) {
      if (!_validTypeWord(typeWord)) return _blockBail(rollbackMark);
      ref = _tableRef(typeWord);
      ops.u32(offset + _u32Bytes, typeWord, _OpSource.model);
      ops.u32(cursor, _recordDelimiter, _OpSource.grammar);
      final word4At = cursor + _u32Bytes;
      if (ref.name == 'Expression' && _canRead(word4At) && _u32(word4At) > _typeMaxFields) {
        final value = _tok(_u32(word4At));
        if (value != null) {
          ops.poolRef(word4At, _u32(word4At));
          final attrs = <int>[];
          final after = _attrTail(word4At + _u32Bytes, attrsOut: attrs);
          if (after != null) {
            return (
              BinaryTypeField(
                '',
                className: SeqValueClass.expression.wire,
                typeName: 'Expression',
                value: value,
                attrWords: attrs,
              ),
              after,
            );
          }
        }
        return _blockBail(rollbackMark);
      }
    } else {
      final named = _tok(word3);
      if (named == null || typeWord == 0 || _tok(typeWord) == null) return _blockBail(rollbackMark);
      name = named;
      ops.poolRef(offset + _u32Bytes, typeWord);
      ops.poolRef(cursor, word3);
    }
    cursor += _u32Bytes;
    if (!_canRead(cursor)) return _blockBail(rollbackMark);
    final count = _u32(cursor);
    if (count > _typeMaxFields) return _blockBail(rollbackMark);
    ops.u32(cursor, count, _OpSource.model);
    cursor += _u32Bytes;
    final outerInstance = _inInstance;
    final outerRepr = _numericReprContext;
    _inInstance = true;
    _numericReprContext = ref != null ? _reprsOf(ref) : null;
    final children = _fields(cursor, count);
    _inInstance = outerInstance;
    _numericReprContext = outerRepr;
    if (children == null) return _blockBail(rollbackMark);
    final attrs = <int>[];
    final after = _attrTail(children.$2, attrsOut: attrs);
    if (after == null) return _blockBail(rollbackMark);
    return (
      BinaryTypeField(
        name,
        className: ref != null ? (ref.className ?? SeqValueClass.object.wire) : null,
        typeName: ref?.name,
        children: children.$1,
        instanceOverrides: true,
        attrWords: attrs,
      ),
      after,
    );
  }

  /// TODO: only the extent is walked; block contents are not decoded.
  int? _extBlocksFrom(int offset, int remaining) {
    if (remaining == 0) return offset;
    if (offset + 10 > recordRegionLength) return null;
    if (_tok(_u32(offset)) == null) return null;
    final slotAt = offset + _u32Bytes + 2;
    if (slotAt + _u32Bytes <= recordRegionLength) {
      final slot = _u32(slotAt);
      if (slot == _recordDelimiter || _tok(slot) != null) {
        final rest = _extBlocksFrom(slotAt + _u32Bytes, remaining - 1);
        if (rest != null) return rest;
      }
    }
    final structEnd = offset + _u32Bytes + 2 + 20;
    if (structEnd > recordRegionLength) return null;
    return _extBlocksFrom(structEnd, remaining - 1);
  }

  int? _extTail(int from) {
    var cursor = from;
    for (var attrCount = 0; attrCount <= _fieldMaxAttrWords; attrCount++, cursor += _u32Bytes) {
      if (cursor + _u32Bytes > recordRegionLength) return null;
      final count = _u32(cursor);
      if (count == 0) return null;
      if (count <= _typeMaxExtBlocks) {
        final end = _extBlocksFrom(cursor + _u32Bytes, count);
        if (end != null && end + _u32Bytes <= recordRegionLength && _u32(end) == 0) {
          ops.blob(cursor, end);
          for (var wordOffset = from; wordOffset < cursor; wordOffset += _u32Bytes) {
            ops.u32(wordOffset, _u32(wordOffset), _OpSource.struct);
          }
          ops.u32(cursor, count, _OpSource.struct);
          ops.copy(cursor + _u32Bytes, end);
          ops.u32(end, 0, _OpSource.grammar);
          return end + _u32Bytes;
        }
      }
    }
    return null;
  }

  int? _refSpec(int offset) {
    var cursor = offset;
    if (cursor >= recordRegionLength) return null;
    if (view.getUint8(cursor) == 0) cursor++;
    if (cursor + 5 * _u32Bytes > recordRegionLength || _u32(cursor) != _recordDelimiter) {
      return null;
    }
    if (_u32(cursor + _u32Bytes) == 0) return null;
    for (var index = 2; index < 5; index++) {
      if (_u32(cursor + index * _u32Bytes) != 0) return null;
    }
    return cursor + 5 * _u32Bytes;
  }

  int? lastFieldOffset;

  int? lastEndOffset;

  List<(BinaryTypeField, int)> parseLeadingSubProps(int offset, int max, Set<String> groupNames) {
    _usedSpec = false;
    _depth = 0;
    final fields = <(BinaryTypeField, int)>[];
    var cur = offset;
    for (var index = 0; index < max; index++) {
      if (cur + 4 * _u32Bytes <= recordRegionLength) {
        final className = _tok(_u32(cur + 2 * _u32Bytes));
        final name = _tok(_u32(cur + 3 * _u32Bytes));
        if (className == 'Objs' && name != null && groupNames.contains(name)) {
          return fields;
        }
      }
      final field = _field(cur);
      if (field == null) return fields;
      cur = field.$2;
      fields.add((field.$1, cur));
    }
    return fields;
  }

  (BinaryTypeField, int)? parseFieldAt(int offset) {
    _usedSpec = false;
    _depth = 0;
    final parsed = _field(offset);
    if (parsed != null) lastEndOffset = parsed.$2;
    return parsed;
  }

  ({List<BinaryTypeField> fields, int? end}) parseStepTs(int offset) {
    const none = (fields: <BinaryTypeField>[], end: null);
    if (offset + 5 * _u32Bytes > recordRegionLength) return none;
    if (_u32(offset) != 0 || _u32(offset + _u32Bytes) != 0 || _u32(offset + 2 * _u32Bytes) != _recordDelimiter) {
      return none;
    }
    if (_tok(_u32(offset + 3 * _u32Bytes)) != 'TS') return none;
    final fullMark = ops.mark();
    if (parseFieldAt(offset) case (final full, final end) when full.name == 'TS' && full.children.isNotEmpty) {
      return (fields: full.children, end: end);
    }
    ops.rollback(fullMark);
    final idMark = ops.mark();
    if (parseFieldAt(offset + 5 * _u32Bytes) case (final idField, final end)
        when idField.valueClass == SeqValueClass.string &&
            idField.name == 'Id' &&
            (idField.value?.startsWith('ID#:') ?? false)) {
      ops.u32(offset, 0, _OpSource.grammar);
      ops.u32(offset + _u32Bytes, 0, _OpSource.grammar);
      ops.u32(offset + 2 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
      ops.poolRef(offset + 3 * _u32Bytes, _u32(offset + 3 * _u32Bytes));
      ops.u32(offset + 4 * _u32Bytes, _u32(offset + 4 * _u32Bytes), _OpSource.model);
      return (fields: [idField], end: end);
    }
    ops.rollback(idMark);
    return none;
  }

  List<BinaryTypeField>? parse(int after) {
    lastFieldOffset = null;
    _usedSpec = false;
    if (after + 2 * _u32Bytes > recordRegionLength || _u32(after) != 0) {
      return null;
    }
    final rollbackMark = ops.mark();
    final count = _u32(after + _u32Bytes);
    (List<BinaryTypeField>, int)? parsed;
    if (count <= _typeMaxFields) {
      ops.u32(after, 0, _OpSource.grammar);
      ops.u32(after + _u32Bytes, count, _OpSource.model);
      parsed = _fields(after + 2 * _u32Bytes, count);
      if (parsed == null) ops.rollback(rollbackMark);
    }
    if (parsed == null && count >= 1 && count <= _typeMaxExtBlocks) {
      final extEnd = _extBlocksFrom(after + 2 * _u32Bytes, count);
      if (extEnd != null && extEnd + _u32Bytes <= recordRegionLength) {
        final subCount = _u32(extEnd);
        if (subCount <= _typeMaxFields) {
          ops.u32(after, 0, _OpSource.grammar);
          ops.u32(after + _u32Bytes, count, _OpSource.struct);
          ops.copy(after + 2 * _u32Bytes, extEnd);
          ops.u32(extEnd, subCount, _OpSource.model);
          parsed = _fields(extEnd + _u32Bytes, subCount);
          if (parsed == null) ops.rollback(rollbackMark);
          if (parsed != null) ops.blob(after + _u32Bytes, extEnd);
        }
      }
    }
    if (parsed == null) {
      final boundary = bodyEndBoundary;
      if (boundary == null) return null;
      ops.u32(after, 0, _OpSource.grammar);
      parsed = _fieldsUntil(after + _u32Bytes, boundary);
      if (parsed == null) return _blockBail(rollbackMark);
    }
    final boundary = bodyEndBoundary;
    if (_usedSpec && boundary != null && parsed.$2 > boundary) return _blockBail(rollbackMark);
    lastEndOffset = parsed.$2;
    return parsed.$1;
  }

  (List<BinaryTypeField>, int)? _fieldsUntil(int from, int boundary) {
    final rollbackMark = ops.mark();
    var offset = from;
    final fields = <BinaryTypeField>[];
    while (offset < boundary && fields.length <= _typeMaxFields) {
      final parsed = _fields(offset, 1);
      if (parsed == null) return _blockBail(rollbackMark);
      fields.addAll(parsed.$1);
      offset = parsed.$2;
    }
    if (offset != boundary) return _blockBail(rollbackMark);
    return (fields, offset);
  }

  T? _trial<T>(T? Function() body) {
    final rollbackMark = ops.mark();
    final parsed = body();
    if (parsed == null) ops.rollback(rollbackMark);
    return parsed;
  }

  (List<BinaryTypeField>, int)? _fields(int from, int count) {
    if (_depth >= _maxFieldDepth) return null;
    _depth++;
    try {
      return _trial(() => _fieldsInner(from, count));
    } finally {
      _depth--;
    }
  }

  (List<BinaryTypeField>, int)? _fieldsInner(int from, int count) {
    var offset = from;
    final fields = <BinaryTypeField>[];
    for (var elementIndex = 0; elementIndex < count; elementIndex++) {
      final field = _field(offset);
      if (field == null) return null;
      offset = field.$2;
      var specBytes = 0;
      if (field.$1.isArray && (field.$1.children.isEmpty || !_inInstance)) {
        while (true) {
          final specEnd = _elementSpec(offset) ?? _refSpec(offset) ?? _protoSpec(offset);
          if (specEnd == null) break;
          ops.copy(offset, specEnd);
          specBytes += specEnd - offset;
          offset = specEnd;
          _usedSpec = true;
        }
        if (specBytes == 0) {
          var lead = offset;
          if (lead < recordRegionLength && view.getUint8(lead) == 0) lead++;
          if (lead + _u32Bytes <= recordRegionLength && _u32(lead) == _recordDelimiter) {
            return null;
          }
        }
      }
      if (specBytes > 0) {
        ops.blob(field.$2, field.$2 + specBytes);
        fields.add(field.$1.withElementSpecBytes(specBytes));
      } else {
        fields.add(field.$1);
      }
    }
    return (fields, offset);
  }

  (BinaryTypeField, int)? _field(int offset) {
    lastFieldOffset = offset;
    return _trial(() => _fieldParse(offset));
  }

  (BinaryTypeField, int)? _fieldParse(int offset) {
    if (offset + 6 * _u32Bytes > recordRegionLength) return null;
    final fieldFlags = _u32(offset);
    return switch (_fieldFormAt(offset, fieldFlags)) {
      _FieldForm.compact => _parseCompactField(offset),
      _FieldForm.descriptor => _parseDescriptorField(offset),
      _FieldForm.framed => _parseFramedField(offset, fieldFlags),
      _FieldForm.framedLite => _parseFramedLiteField(offset, fieldFlags),
      _FieldForm.plain => _parsePlainField(offset, fieldFlags),
      null => null,
    };
  }

  _FieldForm? _fieldFormAt(int offset, int fieldFlags) {
    if (_u32(offset + _u32Bytes) != 0) return _FieldForm.compact;
    if (fieldFlags & ~_fieldKnownFlagBits != 0) return null;
    final delimited = _u32(offset + 2 * _u32Bytes) == _recordDelimiter;
    if (fieldFlags == 0 && delimited) return _FieldForm.descriptor;
    if (fieldFlags & _fieldFramedBit != 0) return _FieldForm.framed;
    return delimited ? _FieldForm.framedLite : _FieldForm.plain;
  }

  (BinaryTypeField, int)? _parseCompactField(int offset) {
    if (_inInstance) return null;
    final nameWord = _u32(offset);
    final valueWord = _u32(offset + _u32Bytes);
    final name = _tok(nameWord);
    final value = _tok(valueWord);
    if (name == null || value == null) return null;
    ops.poolRef(offset, nameWord);
    ops.poolRef(offset + _u32Bytes, valueWord);
    final attrs = <int>[];
    final after = _attrTail(offset + 2 * _u32Bytes, attrsOut: attrs);
    if (after == null) return null;
    return (BinaryTypeField(name, value: value, attrWords: attrs), after);
  }

  (BinaryTypeField, int)? _parseDescriptorField(int offset) {
    final name = _tok(_u32(offset + 3 * _u32Bytes));
    if (name == null) return null;
    final childCount = _u32(offset + 4 * _u32Bytes);
    if (childCount > _typeMaxFields) return null;
    ops.u32(offset, 0, _OpSource.grammar);
    ops.u32(offset + _u32Bytes, 0, _OpSource.grammar);
    ops.u32(offset + 2 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
    ops.poolRef(offset + 3 * _u32Bytes, _u32(offset + 3 * _u32Bytes));
    ops.u32(offset + 4 * _u32Bytes, childCount, _OpSource.model);
    final children = _fields(offset + 5 * _u32Bytes, childCount);
    if (children == null) return null;
    return (
      BinaryTypeField(
        name,
        className: SeqValueClass.object.wire,
        children: children.$1,
        instanceOverrides: true,
        fieldFlags: 0,
      ),
      children.$2,
    );
  }

  (BinaryTypeField, int)? _parseFramedField(int offset, int fieldFlags) {
    final valued = fieldFlags & _fieldHasValueBit != 0;
    final hasNumericRep = fieldFlags & _fieldHasNumericRepBit != 0;
    final minAttrs = _minAttrWords(fieldFlags);
    if (hasNumericRep) return null;
    if (_u32(offset + 2 * _u32Bytes) != _recordDelimiter) return null;
    final typeWord = _u32(offset + 3 * _u32Bytes);
    final nameWord = _u32(offset + 4 * _u32Bytes);
    final name = nameWord == _recordDelimiter && _inInstance ? '' : _tok(nameWord);
    if (name == null) return null;
    ops.u32(offset, fieldFlags, _OpSource.model);
    ops.u32(offset + _u32Bytes, 0, _OpSource.grammar);
    ops.u32(offset + 2 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
    if (nameWord == _recordDelimiter) {
      ops.u32(offset + 4 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
    } else {
      ops.poolRef(offset + 4 * _u32Bytes, nameWord);
    }
    var next = offset + 5 * _u32Bytes;
    String? value;
    var typeName = 'Expression';
    var className = SeqValueClass.expression.wire;
    final boundPair =
        valued &&
        next + 2 * _u32Bytes <= recordRegionLength &&
        _isBoundToken(_tok(_u32(next))) &&
        _isBoundToken(_tok(_u32(next + _u32Bytes)));
    if (boundPair) {
      final lbound = _tok(_u32(next))!;
      final ubound = _tok(_u32(next + _u32Bytes))!;
      ops.u32(offset + 3 * _u32Bytes, typeWord, _OpSource.model);
      ops.poolRef(next, _u32(next));
      ops.poolRef(next + _u32Bytes, _u32(next + _u32Bytes));
      if (ubound == '[]') {
        if (lbound != '[0]') return null;
        final attrs = <int>[];
        final tail = _attrTail(next + 2 * _u32Bytes, minWords: minAttrs, attrsOut: attrs);
        if (tail == null || tail >= recordRegionLength || view.getUint8(tail) != 0) {
          return null;
        }
        ops.byte(tail, 0, _OpSource.grammar);
        return (
          BinaryTypeField(
            name,
            className: SeqValueClass.objects.wire,
            arrayLBound: lbound,
            arrayUBound: ubound,
            intrinsicTypeId: typeWord == 0 ? null : typeWord,
            fieldFlags: fieldFlags,
            attrWords: attrs,
          ),
          tail + 1,
        );
      }
      final attrs = <int>[];
      final elements = _populatedArrayTail(next + 2 * _u32Bytes, lbound, ubound, attrsOut: attrs);
      if (elements == null) return null;
      return (
        BinaryTypeField(
          name,
          className: SeqValueClass.objects.wire,
          arrayLBound: lbound,
          arrayUBound: ubound,
          intrinsicTypeId: typeWord == 0 ? null : typeWord,
          children: elements.$1,
          fieldFlags: fieldFlags,
          attrWords: attrs,
        ),
        elements.$2,
      );
    }
    if (typeWord == 0) {
      ops.u32(offset + 3 * _u32Bytes, 0, _OpSource.grammar);
      if (valued) {
        value = _tok(_u32(next));
        if (value == null) return null;
        ops.poolRef(next, _u32(next));
        next += _u32Bytes;
      } else {
        value = _inInstance ? null : '';
      }
    } else if (typeWord >= 1 && valued && _validTypeWord(typeWord) && _tableRef(typeWord).name == 'Expression') {
      value = _tok(_u32(next));
      if (value == null) return null;
      ops.u32(offset + 3 * _u32Bytes, typeWord, _OpSource.model);
      ops.poolRef(next, _u32(next));
      next += _u32Bytes;
    } else if (typeWord >= 2 && !valued && _validTypeWord(typeWord)) {
      final ref = _tableRef(typeWord);
      ops.u32(offset + 3 * _u32Bytes, typeWord, _OpSource.model);
      for (var attrCount = minAttrs; attrCount <= _fieldMaxAttrWords; attrCount++) {
        final countAt = next + attrCount * _u32Bytes;
        if (countAt + _u32Bytes > recordRegionLength) break;
        final word = _u32(countAt);
        if (word == 0) break;
        if (word < 1 || word > _typeMaxFields) continue;
        final mInst = ops.mark();
        final instAttrs = <int>[];
        for (var attrIndex = 0; attrIndex < attrCount; attrIndex++) {
          instAttrs.add(_u32(next + attrIndex * _u32Bytes));
          ops.u32(next + attrIndex * _u32Bytes, instAttrs[attrIndex], _OpSource.model);
        }
        ops.u32(countAt, word, _OpSource.model);
        final outerInstance = _inInstance;
        final outerRepr = _numericReprContext;
        _inInstance = true;
        _numericReprContext = _reprsOf(ref);
        final children = _fields(countAt + _u32Bytes, word);
        _inInstance = outerInstance;
        _numericReprContext = outerRepr;
        if (children != null) {
          return (
            BinaryTypeField(
              name,
              className: ref.className ?? SeqValueClass.object.wire,
              typeName: ref.name,
              children: children.$1,
              instanceOverrides: true,
              fieldFlags: fieldFlags,
              attrWords: instAttrs,
            ),
            children.$2,
          );
        }
        ops.rollback(mInst);
      }
      className = ref.className ?? SeqValueClass.object.wire;
      typeName = ref.name;
      value = _inInstance
          ? null
          : switch (SeqValueClass.from(className)) {
              SeqValueClass.string || SeqValueClass.path || SeqValueClass.expression => '',
              SeqValueClass.boolean => 'false',
              SeqValueClass.number => '0',
              _ => null,
            };
    } else if (typeWord == 1 && !valued) {
      ops.u32(offset + 3 * _u32Bytes, 1, _OpSource.grammar);
      final attrsFrom = next;
      next += minAttrs * _u32Bytes;
      if (next + _u32Bytes > recordRegionLength) return null;
      var overrideCount = _u32(next);
      for (var attrCount = 0; overrideCount > _typeMaxFields && attrCount < _fieldMaxAttrWords; attrCount++) {
        next += _u32Bytes;
        if (next + _u32Bytes > recordRegionLength) return null;
        overrideCount = _u32(next);
      }
      if (overrideCount > _typeMaxFields) return null;
      final customAttrs = <int>[];
      for (var wordOffset = attrsFrom; wordOffset < next; wordOffset += _u32Bytes) {
        customAttrs.add(_u32(wordOffset));
        ops.u32(wordOffset, customAttrs.last, _OpSource.model);
      }
      ops.u32(next, overrideCount, _OpSource.model);
      next += _u32Bytes;
      final outer = _inInstance;
      _inInstance = true;
      final overrides = _fields(next, overrideCount);
      _inInstance = outer;
      if (overrides == null) return null;
      return (
        BinaryTypeField(
          name,
          className: SeqValueClass.object.wire,
          children: overrides.$1,
          instanceOverrides: true,
          fieldFlags: fieldFlags,
          attrWords: customAttrs,
        ),
        overrides.$2,
      );
    } else {
      return null;
    }
    final attrs = <int>[];
    final after = _attrTail(next, minWords: minAttrs, attrsOut: attrs);
    if (after == null) return null;
    return (
      BinaryTypeField(
        name,
        className: className,
        typeName: typeName,
        value: value,
        fieldFlags: fieldFlags,
        attrWords: attrs,
      ),
      after,
    );
  }

  (BinaryTypeField, int)? _parseFramedLiteField(int offset, int fieldFlags) {
    final valued = fieldFlags & _fieldHasValueBit != 0;
    final hasNumericRep = fieldFlags & _fieldHasNumericRepBit != 0;
    final minAttrs = _minAttrWords(fieldFlags);
    if (hasNumericRep) return null;
    final name = _tok(_u32(offset + 3 * _u32Bytes));
    if (name == null) return null;
    ops.u32(offset, fieldFlags, _OpSource.model);
    ops.u32(offset + _u32Bytes, 0, _OpSource.grammar);
    ops.u32(offset + 2 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
    ops.poolRef(offset + 3 * _u32Bytes, _u32(offset + 3 * _u32Bytes));
    var next = offset + 4 * _u32Bytes;
    if (!valued) {
      for (var attrCount = minAttrs; attrCount <= _fieldMaxAttrWords; attrCount++) {
        final countAt = next + attrCount * _u32Bytes;
        if (countAt + _u32Bytes > recordRegionLength) break;
        final word = _u32(countAt);
        if (word == 0) break;
        if (word < 1 || word > _typeMaxFields) continue;
        final mObj = ops.mark();
        final objAttrs = <int>[];
        for (var attrIndex = 0; attrIndex < attrCount; attrIndex++) {
          objAttrs.add(_u32(next + attrIndex * _u32Bytes));
          ops.u32(next + attrIndex * _u32Bytes, objAttrs[attrIndex], _OpSource.model);
        }
        ops.u32(countAt, word, _OpSource.model);
        final outerInstance = _inInstance;
        _inInstance = true;
        final children = _fields(countAt + _u32Bytes, word);
        _inInstance = outerInstance;
        if (children != null) {
          return (
            BinaryTypeField(
              name,
              className: 'Obj',
              children: children.$1,
              instanceOverrides: true,
              fieldFlags: fieldFlags,
              attrWords: objAttrs,
            ),
            children.$2,
          );
        }
        ops.rollback(mObj);
      }
    }
    var value = _inInstance ? null : '';
    if (valued) {
      if (_u32(next) == _recordDelimiter) {
        ops.u32(next, _recordDelimiter, _OpSource.grammar);
        next += _u32Bytes;
      } else {
        final stored = _tok(_u32(next));
        if (stored == null) return null;
        value = stored;
        ops.poolRef(next, _u32(next));
        next += _u32Bytes;
      }
    }
    final attrs = <int>[];
    final after = _attrTail(next, minWords: minAttrs, attrsOut: attrs);
    if (after == null) return null;
    return (BinaryTypeField(name, value: value, fieldFlags: fieldFlags, attrWords: attrs), after);
  }

  (BinaryTypeField, int)? _parsePlainField(int offset, int fieldFlags) {
    final hasExtData = fieldFlags & _fieldHasExtDataBit != 0;
    final valued = fieldFlags & _fieldHasValueBit != 0;
    final hasFormat = fieldFlags & _fieldHasFormatBit != 0;
    final hasNumericRep = fieldFlags & _fieldHasNumericRepBit != 0;
    final minAttrs = _minAttrWords(fieldFlags);
    final className = _clsTok(_u32(offset + 2 * _u32Bytes));
    final name = _tok(_u32(offset + 3 * _u32Bytes));
    if (className == null || name == null) return null;
    final valueClass = SeqValueClass.from(className);
    ops.u32(offset, fieldFlags, _OpSource.model);
    ops.u32(offset + _u32Bytes, 0, _OpSource.grammar);
    ops.poolRef(offset + 2 * _u32Bytes, _u32(offset + 2 * _u32Bytes));
    ops.poolRef(offset + 3 * _u32Bytes, _u32(offset + 3 * _u32Bytes));
    var next = offset + 4 * _u32Bytes;
    if (!valued && !_tailedValueClasses.contains(valueClass)) {
      if (hasNumericRep) return null;
      for (var attrCount = 0; attrCount <= _fieldMaxAttrWords; attrCount++) {
        final countAt = next + attrCount * _u32Bytes;
        if (countAt + _u32Bytes > recordRegionLength) break;
        final childCount = _u32(countAt);
        if (childCount > _typeMaxFields) continue;
        if (childCount == 0 && fieldFlags == 0x4 && countAt + 2 * _u32Bytes <= recordRegionLength) {
          final adjacent = _u32(countAt + _u32Bytes);
          if (adjacent >= 1 && adjacent <= _typeMaxFields) {
            final mAdj = ops.mark();
            final adjAttrs = <int>[];
            for (var attrIndex = 0; attrIndex < attrCount; attrIndex++) {
              adjAttrs.add(_u32(next + attrIndex * _u32Bytes));
              ops.u32(next + attrIndex * _u32Bytes, adjAttrs[attrIndex], _OpSource.model);
            }
            adjAttrs.add(0);
            ops.u32(countAt, 0, _OpSource.model);
            ops.u32(countAt + _u32Bytes, adjacent, _OpSource.model);
            final children = _fields(countAt + 2 * _u32Bytes, adjacent);
            if (children != null) {
              return (
                BinaryTypeField(
                  name,
                  className: className,
                  children: children.$1,
                  fieldFlags: fieldFlags,
                  attrWords: adjAttrs,
                ),
                children.$2,
              );
            }
            ops.rollback(mAdj);
          }
        }
        final mDecl = ops.mark();
        final declAttrs = <int>[];
        for (var attrIndex = 0; attrIndex < attrCount; attrIndex++) {
          declAttrs.add(_u32(next + attrIndex * _u32Bytes));
          ops.u32(next + attrIndex * _u32Bytes, declAttrs[attrIndex], _OpSource.model);
        }
        ops.u32(countAt, childCount, _OpSource.model);
        final children = _fields(countAt + _u32Bytes, childCount);
        if (children == null) {
          ops.rollback(mDecl);
          continue;
        }
        return (
          BinaryTypeField(
            name,
            className: className,
            children: children.$1,
            fieldFlags: fieldFlags,
            attrWords: declAttrs,
          ),
          children.$2,
        );
      }
      return null;
    }
    if (!valued) {
      int? repr;
      if (hasNumericRep) {
        if (valueClass != SeqValueClass.number || !_canRead(next)) return null;
        repr = _u32(next);
        ops.u32(next, repr, _OpSource.model);
        next += _u32Bytes;
      }
      final attrs = <int>[];
      final after = hasExtData ? _extTail(next) : _attrTail(next, minWords: minAttrs, attrsOut: attrs);
      if (after == null) return null;
      if (!_unvaluedScalarClasses.contains(valueClass)) return null;
      return (
        BinaryTypeField(
          name,
          className: className,
          value: _inInstance || valueClass == SeqValueClass.reference
              ? null
              : switch (valueClass) {
                  SeqValueClass.boolean => 'false',
                  SeqValueClass.number => '0',
                  _ => '',
                },
          numericRepresentation: repr,
          fieldFlags: fieldFlags,
          attrWords: attrs,
        ),
        after,
      );
    }
    if (_boundedArrayClasses.contains(valueClass) &&
        next + 2 * _u32Bytes <= recordRegionLength &&
        _isBoundToken(_tok(_u32(next))) &&
        _isBoundToken(_tok(_u32(next + _u32Bytes)))) {
      if (hasNumericRep) return null;
      final lbound = _tok(_u32(next))!;
      final ubound = _tok(_u32(next + _u32Bytes))!;
      ops.poolRef(next, _u32(next));
      ops.poolRef(next + _u32Bytes, _u32(next + _u32Bytes));
      if (valueClass == SeqValueClass.objects && ubound != '[]') {
        final attrs = <int>[];
        final elements = _populatedArrayTail(next + 2 * _u32Bytes, lbound, ubound, attrsOut: attrs);
        if (elements != null) {
          return (
            BinaryTypeField(
              name,
              className: className,
              arrayLBound: lbound,
              arrayUBound: ubound,
              children: elements.$1,
              fieldFlags: fieldFlags,
              attrWords: attrs,
              partialArray: _lastArrayPartial,
            ),
            elements.$2,
          );
        }
      }
      if (valueClass == SeqValueClass.numbers && valued && ubound != '[]') {
        final attrs = <int>[];
        final run = _scalarArrayTail(next + 2 * _u32Bytes, lbound, ubound, attrsOut: attrs);
        if (run != null) {
          return (
            BinaryTypeField(
              name,
              className: className,
              arrayLBound: lbound,
              arrayUBound: ubound,
              children: run.$1,
              fieldFlags: fieldFlags,
              attrWords: attrs,
            ),
            run.$2,
          );
        }
      }
      final attrs = <int>[];
      var after = _attrTail(next + 2 * _u32Bytes, minWords: minAttrs, attrsOut: attrs);
      if (after == null) return null;
      if (valueClass == SeqValueClass.objects) {
        if (after >= recordRegionLength || view.getUint8(after) != 0) {
          return null;
        }
        ops.byte(after, 0, _OpSource.grammar);
        after += 1;
        if (ubound == '[]') {
          final proto = _elemProtoTail(after);
          if (proto != null) {
            ops.blob(after, proto.$2);
            ops.copy(after, proto.$2);
            return (
              BinaryTypeField(
                name,
                className: className,
                arrayLBound: lbound,
                arrayUBound: ubound,
                elementSpecBytes: proto.$2 - after,
                fieldFlags: fieldFlags,
                attrWords: attrs,
              ),
              proto.$2,
            );
          }
        }
      }
      return (
        BinaryTypeField(
          name,
          className: className,
          arrayLBound: lbound,
          arrayUBound: ubound,
          fieldFlags: fieldFlags,
          attrWords: attrs,
        ),
        after,
      );
    }
    switch (valueClass) {
      case SeqValueClass.string when !hasNumericRep:
        final value = _tok(_u32(next));
        if (value == null) return null;
        ops.poolRef(next, _u32(next));
        final attrs = <int>[];
        final after = hasExtData
            ? _extTail(next + _u32Bytes)
            : _attrTail(next + _u32Bytes, minWords: minAttrs, attrsOut: attrs);
        if (after == null) return null;
        return (
          BinaryTypeField(name, className: className, value: value, fieldFlags: fieldFlags, attrWords: attrs),
          after,
        );
      case SeqValueClass.boolean when !hasNumericRep:
        final value = view.getUint8(next);
        if (value > 1) return null;
        ops.byte(next, value, _OpSource.model);
        final attrs = <int>[];
        final after = hasExtData ? _extTail(next + 1) : _attrTail(next + 1, minWords: minAttrs, attrsOut: attrs);
        if (after == null) return null;
        return (
          BinaryTypeField(
            name,
            className: className,
            value: value == 1 ? 'true' : 'false',
            fieldFlags: fieldFlags,
            attrWords: attrs,
          ),
          after,
        );
      case SeqValueClass.number:
        int? repr;
        if (hasNumericRep) {
          if (!_canRead(next)) return null;
          repr = _u32(next);
          ops.u32(next, repr, _OpSource.model);
          next += _u32Bytes;
        }
        if (next + 2 * _u32Bytes > recordRegionLength) return null;
        var integer = repr != null
            ? BinaryNumericRepresentation.isInteger(repr)
            : _inInstance && _numericReprContext?[name] != null;
        if (!integer) {
          final raw = view.getFloat64(next, Endian.little);
          if (raw != 0 && raw.isFinite && raw.abs() < _smallestNormalF64) integer = true;
        }
        final String text;
        if (integer) {
          final value = view.getInt64(next, Endian.little);
          ops.i64(next, value);
          text = '$value';
        } else {
          final value = view.getFloat64(next, Endian.little);
          ops.f64(next, value);
          text = value == value.truncateToDouble() && value.abs() < 1e15 ? '${value.truncate()}' : '$value';
        }
        next += 2 * _u32Bytes;
        if (hasFormat) {
          if (next + _u32Bytes > recordRegionLength || _tok(_u32(next)) == null) {
            return null;
          }
          ops.poolRef(next, _u32(next));
          next += _u32Bytes;
        }
        final attrs = <int>[];
        final after = hasExtData ? _extTail(next) : _attrTail(next, minWords: minAttrs, attrsOut: attrs);
        if (after == null) return null;
        return (
          BinaryTypeField(
            name,
            className: className,
            value: text,
            numericRepresentation: repr,
            fieldFlags: fieldFlags,
            attrWords: attrs,
          ),
          after,
        );
      default:
        return null;
    }
  }
}

class BinaryTypeField {
  const BinaryTypeField(
    this.name, {
    this.className,
    this.typeName,
    this.value,
    this.arrayLBound,
    this.arrayUBound,
    this.children = const [],
    this.instanceOverrides = false,
    this.elementSpecBytes,
    this.intrinsicTypeId,
    this.numericRepresentation,
    this.fieldFlags,
    this.attrWords = const [],
    this.partialArray = false,
  });

  final String name;

  final String? className;

  SeqValueClass? get valueClass => SeqValueClass.of(className);

  final String? typeName;

  final String? value;

  final String? arrayLBound;
  final String? arrayUBound;

  bool get isArray => arrayUBound != null;

  bool get isEmptyArray => arrayUBound == '[]';

  final List<BinaryTypeField> children;

  final int? elementSpecBytes;

  final bool instanceOverrides;

  /// TODO: the intrinsic-type id → name map is not decoded.
  final int? intrinsicTypeId;

  final int? numericRepresentation;

  bool get typeNameEngineIntrinsic => intrinsicTypeId != null || (instanceOverrides && typeName == null);

  bool get isPlainDeclaration => children.isNotEmpty && !instanceOverrides && typeName == null;

  final int? fieldFlags;

  final List<int> attrWords;

  final bool partialArray;

  BinaryTypeField withElementSpecBytes(int bytes) => BinaryTypeField(
    name,
    className: className,
    typeName: typeName,
    value: value,
    arrayLBound: arrayLBound,
    arrayUBound: arrayUBound,
    children: children,
    instanceOverrides: instanceOverrides,
    elementSpecBytes: bytes,
    intrinsicTypeId: intrinsicTypeId,
    numericRepresentation: numericRepresentation,
    fieldFlags: fieldFlags,
    attrWords: attrWords,
    partialArray: partialArray,
  );
}
