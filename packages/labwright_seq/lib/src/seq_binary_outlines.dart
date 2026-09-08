part of 'seq_binary.dart';

const _stepToken = 'Step';
const _stepNameWordGap = 2;
const _stepContainerTokens = {'Objs', 'Data'};
const _stepExpressionKinds = {'Expression', 'ExprValue'};

bool _looksLikeUniqueId(String text) => text.length >= 15 && RegExp(r'[;\\<>^\]]').hasMatch(text);

List<String> binaryStepNames(Uint8List seqBytes) => _withLayout(seqBytes, _stepNamesFromBody);

List<String> _stepNamesFromBody(Uint8List body, int recordRegionLength) {
  final pool = _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final stepToken = pool.indexOf(_stepToken);
  if (stepToken < 0) return const [];
  final view = ByteData.sublistView(body);
  int wordAt(int offset) => view.getUint32(offset, Endian.little);
  String? poolAt(int index) => index > 0 && index < pool.length && pool[index].isNotEmpty ? pool[index] : null;

  final seen = <String>{};
  final names = <String>[];
  for (var offset = 0; offset + (_stepNameWordGap + 2) * _u32Bytes <= recordRegionLength; offset++) {
    if (wordAt(offset) != stepToken) continue;
    final kind = poolAt(wordAt(offset + _u32Bytes));
    final name = poolAt(wordAt(offset + _stepNameWordGap * _u32Bytes));
    final container = poolAt(wordAt(offset + (_stepNameWordGap + 1) * _u32Bytes));
    if (name == null || container == null || kind == null) continue;
    if (!_stepContainerTokens.contains(container)) continue;
    if (!_looksLikeUniqueId(kind) && !_stepExpressionKinds.contains(kind)) continue;
    if (seen.add(name)) names.add(name);
  }
  return names;
}

final _stepGroupNames = {for (final group in StepGroup.values) group.key};

const _sequenceLeadingSubPropNames = {'Parameters', 'Locals'};

final _sequenceSubPropHead = ['Parameters', 'Locals', StepGroup.main.key, StepGroup.setup.key, StepGroup.cleanup.key];
const _sequenceSubPropTailNames = {'GotoCleanupOnFail', 'RecordResults', 'RTS', 'Requirements', 'FailureAction'};

final _sequenceSubPropClasses = {
  'Parameters': SeqValueClass.object,
  'Locals': SeqValueClass.object,
  StepGroup.main.key: SeqValueClass.objects,
  StepGroup.setup.key: SeqValueClass.objects,
  StepGroup.cleanup.key: SeqValueClass.objects,
  'RecordResults': SeqValueClass.boolean,
  'GotoCleanupOnFail': SeqValueClass.boolean,
  'RTS': SeqValueClass.object,
  'Requirements': SeqValueClass.object,
  'FailureAction': SeqValueClass.number,
};

const _sequenceRecordMaxSubProps = 12;

class _SequenceRecordWalk {
  const _SequenceRecordWalk(
    this.offset,
    this.name,
    this.comment,
    this.headWords,
    this.subpropCount,
    this.subProps,
    this.end,
  );
  final int offset;
  final String name;

  final int headWords;

  final String? comment;
  final int subpropCount;
  final List<(BinaryTypeField, int)> subProps;
  final int end;
}

List<_SequenceRecordWalk> _sequenceRecordWalks(
  ByteData view,
  List<String> pool,
  int recordRegionLength,
  List<BinaryTypeRecord> table,
  int typeIndexBase, [
  _DecodeSink sink = _DecodeSink.none,
]) {
  final seqIdx = <int>{
    for (var poolIndex = 1; poolIndex < pool.length; poolIndex++)
      if (pool[poolIndex] == 'Sequence') poolIndex,
  };
  if (seqIdx.isEmpty) return const [];
  int u32(int offset) => view.getUint32(offset, Endian.little);
  String? poolAt(int word) => word > 0 && word < pool.length && pool[word].isNotEmpty ? pool[word] : null;
  final parser = _TypeBodyParser(view, pool, recordRegionLength, table, null, typeIndexBase)
    ..ops = sink
    .._partialStepArraysOk = true;

  (List<(BinaryTypeField, int)>, int) walkSubProps(int from, int count) {
    final subProps = <(BinaryTypeField, int)>[];
    final seenTail = <String>{};
    var cur = from;
    while (subProps.length < count) {
      final poolIndex = subProps.length;
      final mField = sink.mark();
      final parsed = parser.parseFieldAt(cur);
      if (parsed == null) break;
      final (field, fieldEnd) = parsed;
      var gated = false;
      if (poolIndex < _sequenceSubPropHead.length) {
        gated = field.name != _sequenceSubPropHead[poolIndex];
      } else {
        gated = !_sequenceSubPropTailNames.contains(field.name) || !seenTail.add(field.name);
      }
      if (!gated) gated = field.valueClass != _sequenceSubPropClasses[field.name];
      if (!gated &&
          _stepGroupNames.contains(field.name) &&
          field.children.any((child) => child.valueClass != SeqValueClass.step)) {
        gated = true;
      }
      if (gated) {
        sink.rollback(mField);
        break;
      }
      cur = fieldEnd;
      subProps.add((field, cur));
      if (_stepGroupNames.contains(field.name) &&
          ((!field.isEmptyArray && field.children.isEmpty) || field.partialArray)) {
        break;
      }
    }
    return (subProps, cur);
  }

  final walks = <_SequenceRecordWalk>[];
  var offset = 0;
  while (offset + 3 * _u32Bytes <= recordRegionLength) {
    if (!seqIdx.contains(u32(offset))) {
      offset++;
      continue;
    }
    final name = poolAt(u32(offset + _u32Bytes));
    if (name == null) {
      offset++;
      continue;
    }
    _SequenceRecordWalk? walked;
    for (final withComment in const [false, true]) {
      final countAt = offset + (withComment ? 3 : 2) * _u32Bytes;
      if (countAt + _u32Bytes > recordRegionLength) continue;
      final count = u32(countAt);
      if (count < 1 || count > _sequenceRecordMaxSubProps) continue;
      final mCand = sink.mark();
      final (subProps, end) = walkSubProps(countAt + _u32Bytes, count);
      if (subProps.isEmpty || subProps.first.$1.name != 'Parameters') {
        sink.rollback(mCand);
        continue;
      }
      final commentWord = withComment ? u32(offset + 2 * _u32Bytes) : 0;
      final comment = withComment && commentWord > _sequenceRecordMaxSubProps ? poolAt(commentWord) : null;
      sink.poolRef(offset, u32(offset));
      sink.poolRef(offset + _u32Bytes, u32(offset + _u32Bytes));
      if (withComment) {
        if (comment != null) {
          sink.poolRef(offset + 2 * _u32Bytes, commentWord);
        } else {
          sink.u32(offset + 2 * _u32Bytes, commentWord, _OpSource.struct);
        }
      }
      sink.u32(countAt, count, _OpSource.model);
      walked = _SequenceRecordWalk(offset, name, comment, withComment ? 4 : 3, count, subProps, end);
      break;
    }
    if (walked == null) {
      offset++;
      continue;
    }
    walks.add(walked);
    sink.claim(offset, offset + walked.headWords * _u32Bytes, _tierSemantic);
    var fieldStart = offset + walked.headWords * _u32Bytes;
    for (final (_, fieldEnd) in walked.subProps) {
      sink.claim(fieldStart, fieldEnd, _tierSemantic);
      fieldStart = fieldEnd;
    }
    offset = walked.end > offset ? walked.end : offset + 1;
  }
  return walks;
}

const _stepDataSubPropNames = {'Measurement', 'PinMapPath'};

class BinaryStepRef {
  const BinaryStepRef(
    this.name, {
    this.typeName,
    this.viPath,
    this.pythonModule,
    this.pythonFunction,
    this.tsSubProps = const [],
    this.dataSubProps = const [],
  });

  final String name;

  final String? typeName;

  final List<BinaryTypeField> tsSubProps;

  final List<BinaryTypeField> dataSubProps;

  final String? viPath;
  final String? pythonModule;
  final String? pythonFunction;

  @override
  String toString() => 'BinaryStepRef($name${typeName != null ? ': $typeName' : ''})';
}

class BinarySequenceOutline {
  const BinarySequenceOutline({
    required this.name,
    required this.setup,
    required this.main,
    required this.cleanup,
    this.ungrouped = const [],
    this.leadingSubProps = const [],
    this.tailSubProps = const [],
    this.comment,
    this.groupArrays = const [],
  });

  final String name;

  final List<BinaryStepRef> setup;
  final List<BinaryStepRef> main;
  final List<BinaryStepRef> cleanup;

  final List<BinaryStepRef> ungrouped;

  final List<BinaryTypeField> leadingSubProps;

  final List<BinaryTypeField> tailSubProps;

  final String? comment;

  final List<BinaryTypeField> groupArrays;
}

List<BinarySequenceOutline> binarySequenceOutlines(Uint8List seqBytes) =>
    _withLayout(seqBytes, _sequenceOutlinesFromBody);

List<BinarySequenceOutline> _sequenceOutlinesFromBody(
  Uint8List body,
  int recordRegionLength, [
  List<String>? sharedPool,
  List<String>? sharedTypeNames,
  List<BinaryTypeRecord>? sharedTypeRecords,
  _DecodeSink sink = _DecodeSink.none,
]) {
  final pool = sharedPool ?? _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final view = ByteData.sublistView(body);

  final table = sharedTypeRecords ?? _typeRecordsFromBody(body, recordRegionLength, sharedPool: pool);
  final typeIndexBase = deriveTypeIndexBase(view, pool, recordRegionLength, table);
  final recordWalks = _sequenceRecordWalks(view, pool, recordRegionLength, table, typeIndexBase, sink);

  final sequenceDecls = <(int, String)>[];
  for (var offset = 0; offset + _minDeclarationBytes <= recordRegionLength; offset++) {
    final decl = _objectDeclarationPath(body, view, pool, offset, recordRegionLength);
    if (decl == null || !_isSequenceDeclaration(decl.$1)) continue;
    sequenceDecls.add((offset, decl.$1[1]));
    sink.claim(offset, decl.$2, _tierSemantic);
    sink.byte(offset, body[offset], _OpSource.struct);
    sink.byte(offset + 1, body[offset + 1], _OpSource.struct);
    for (
      var wordOffset = offset + _PropRecordField.zeroA.offset;
      wordOffset + _u32Bytes <= decl.$2;
      wordOffset += _u32Bytes
    ) {
      final word = view.getUint32(wordOffset, Endian.little);
      if (word == 0) {
        sink.u32(wordOffset, 0, _OpSource.grammar);
      } else {
        sink.poolRef(wordOffset, word);
      }
    }
  }
  if (sequenceDecls.isEmpty) {
    for (final walk in recordWalks) {
      sequenceDecls.add((walk.offset, walk.name));
    }
  }
  if (sequenceDecls.isEmpty) return const [];

  final markers = <(int, StepGroup)>[];
  for (final record in _propertyRecordsFromBody(body, recordRegionLength)) {
    final group = StepGroup.byKey(record.name);
    if (group != null && record.leafType == PropertyLeafType.objects) {
      markers.add((record.offset, group));
    }
  }

  final typeNames = sharedTypeNames ?? _typeNamesFromBody(body, recordRegionLength, pool);
  final stepToken = pool.indexOf(_stepToken);
  final found = <(int, String, int)>[];
  int wordAt(int offset) => view.getUint32(offset, Endian.little);
  String? poolAt(int index) => index > 0 && index < pool.length && pool[index].isNotEmpty ? pool[index] : null;
  if (stepToken > 0) {
    for (var offset = 0; offset + (_stepNameWordGap + 2) * _u32Bytes <= recordRegionLength; offset++) {
      if (wordAt(offset) != stepToken) continue;
      final typeWord = wordAt(offset + _u32Bytes);
      final kind = poolAt(typeWord);
      final name = poolAt(wordAt(offset + _stepNameWordGap * _u32Bytes));
      final container = poolAt(wordAt(offset + (_stepNameWordGap + 1) * _u32Bytes));
      if (name == null || container == null || kind == null) continue;
      if (!_stepContainerTokens.contains(container)) continue;
      if (!_looksLikeUniqueId(kind) && !_stepExpressionKinds.contains(kind)) continue;
      found.add((offset, name, typeWord - 1));
    }
  }
  Set<int> indicesOf(String token) => {
    for (var poolIndex = 1; poolIndex < pool.length; poolIndex++)
      if (pool[poolIndex] == token) poolIndex,
  };
  final viPathIdx = indicesOf('VIPath');
  final modulePathIdx = indicesOf('ModulePath');
  final functionIdx = indicesOf('FunctionOrAttributeName');
  String? pairIn(int start, int end, Set<int> nameIdx) {
    if (nameIdx.isEmpty) return null;
    for (var offset = start; offset + 2 * _u32Bytes <= end; offset++) {
      if (!nameIdx.contains(wordAt(offset))) continue;
      final value = poolAt(wordAt(offset + _u32Bytes));
      if (value != null) {
        sink.claim(offset, offset + 2 * _u32Bytes, _tierSemantic);
        sink.poolRef(offset, wordAt(offset));
        sink.poolRef(offset + _u32Bytes, wordAt(offset + _u32Bytes));
        return value;
      }
    }
    return null;
  }

  final tsParser = _TypeBodyParser(view, pool, recordRegionLength, table, null, typeIndexBase)..ops = sink;

  final steps = <(int, BinaryStepRef)>[];
  for (var stepIndex = 0; stepIndex < found.length; stepIndex++) {
    final (offset, name, typeIndex) = found[stepIndex];
    final spanEnd = stepIndex + 1 < found.length ? found[stepIndex + 1].$1 : recordRegionLength;
    final (fields: tsSubProps, end: tsEnd) = tsParser.parseStepTs(offset + 4 * _u32Bytes);
    sink.claim(offset, offset + 4 * _u32Bytes, _tierSemantic);
    sink.poolRef(offset, wordAt(offset));
    final typeWord = wordAt(offset + _u32Bytes);
    if (typeIndex >= 0 && typeIndex < typeNames.length) {
      sink.u32(offset + _u32Bytes, typeWord, _OpSource.model);
    } else {
      sink.u32(offset + _u32Bytes, typeWord, _OpSource.struct);
    }
    sink.poolRef(offset + 2 * _u32Bytes, wordAt(offset + 2 * _u32Bytes));
    sink.poolRef(offset + 3 * _u32Bytes, wordAt(offset + 3 * _u32Bytes));
    if (tsSubProps.isNotEmpty && tsEnd != null) {
      sink.claim(offset + 4 * _u32Bytes, tsEnd, _tierSemantic);
    }
    final dataSubProps = <BinaryTypeField>[];
    if (tsSubProps.isNotEmpty && tsEnd != null) {
      var cur = tsEnd;
      while (cur < spanEnd) {
        final mData = sink.mark();
        final parsed = tsParser.parseFieldAt(cur);
        if (parsed == null) break;
        final (field, fieldEnd) = parsed;
        if (!_stepDataSubPropNames.contains(field.name) || fieldEnd > spanEnd) {
          sink.rollback(mData);
          break;
        }
        dataSubProps.add(field);
        sink.claim(cur, fieldEnd, _tierSemantic);
        cur = fieldEnd;
      }
    }
    steps.add((
      offset,
      BinaryStepRef(
        name,
        typeName: typeIndex >= 0 && typeIndex < typeNames.length ? typeNames[typeIndex] : null,
        viPath: pairIn(offset, spanEnd, viPathIdx),
        pythonModule: pairIn(offset, spanEnd, modulePathIdx),
        pythonFunction: pairIn(offset, spanEnd, functionIdx),
        tsSubProps: tsSubProps,
        dataSubProps: dataSubProps,
      ),
    ));
  }

  sequenceDecls.sort((left, right) => left.$1.compareTo(right.$1));
  final outlines = {
    for (final (_, name) in sequenceDecls) name: {for (final group in StepGroup.values) group: <BinaryStepRef>[]},
  };
  String sequenceAt(int offset) {
    var owner = sequenceDecls.first.$2;
    for (final (declOffset, name) in sequenceDecls) {
      if (declOffset < offset) owner = name;
    }
    return owner;
  }

  final ungrouped = <String, List<BinaryStepRef>>{
    for (final (_, name) in sequenceDecls) name: <BinaryStepRef>[],
  };
  for (final (stepOffset, step) in steps) {
    StepGroup? group;
    for (final (markerOffset, markerGroup) in markers) {
      if (markerOffset < stepOffset) group = markerGroup;
    }
    final owner = sequenceAt(stepOffset);
    if (group == null) {
      ungrouped[owner]!.add(step);
      continue;
    }
    outlines[owner]![group]!.add(step);
  }

  final leading = _sequenceLeadingSubProps(
    body,
    view,
    pool,
    recordRegionLength,
    table,
    typeIndexBase,
    {
      for (final (_, name) in sequenceDecls) name,
    },
    sink,
  );

  final tail = _sequenceTailSubProps(view, pool, recordRegionLength, table, typeIndexBase, sequenceDecls, sink);

  final groups = <String, List<BinaryTypeField>>{};
  final comments = <String, String>{};
  for (final walk in recordWalks) {
    if (groups.containsKey(walk.name) || comments.containsKey(walk.name)) continue;
    final walked = [
      for (final (field, _) in walk.subProps)
        if (_stepGroupNames.contains(field.name)) field,
    ];
    if (walked.isNotEmpty) groups[walk.name] = walked;
    if (walk.comment != null) comments[walk.name] = walk.comment!;
  }

  final seenNames = <String>{};
  return [
    for (final (_, name) in sequenceDecls)
      if (seenNames.add(name))
        BinarySequenceOutline(
          name: name,
          setup: outlines[name]![StepGroup.setup]!,
          main: outlines[name]![StepGroup.main]!,
          cleanup: outlines[name]![StepGroup.cleanup]!,
          ungrouped: ungrouped[name]!,
          leadingSubProps: leading[name] ?? const [],
          tailSubProps: tail[name] ?? const [],
          comment: comments[name],
          groupArrays: groups[name] ?? const [],
        ),
  ];
}

Map<String, List<BinaryTypeField>> _sequenceTailSubProps(
  ByteData view,
  List<String> pool,
  int recordRegionLength,
  List<BinaryTypeRecord> table,
  int typeIndexBase,
  List<(int, String)> sequenceDecls, [
  _DecodeSink sink = _DecodeSink.none,
]) {
  if (sequenceDecls.isEmpty) return const {};
  int u32(int offset) => view.getUint32(offset, Endian.little);
  Set<int> indicesOf(String token) => {
    for (var poolIndex = 1; poolIndex < pool.length; poolIndex++)
      if (pool[poolIndex] == token) poolIndex,
  };
  final anchors = [
    for (final spec in _tailSubProps) (indicesOf(spec.name), indicesOf(spec.className.wire), spec),
  ];
  final sorted = [...sequenceDecls]..sort((left, right) => left.$1.compareTo(right.$1));
  String ownerOf(int offset) {
    var owner = sorted.first.$2;
    for (final (declOffset, name) in sorted) {
      if (declOffset < offset) owner = name;
    }
    return owner;
  }

  final parser = _TypeBodyParser(view, pool, recordRegionLength, table, null, typeIndexBase)..ops = sink;
  final result = <String, List<BinaryTypeField>>{};
  final seenPerOwner = <String, Set<String>>{};
  for (var offset = 0; offset + 4 * _u32Bytes <= recordRegionLength; offset++) {
    for (final (nameIdx, classIdx, spec) in anchors) {
      if (u32(offset + _u32Bytes) != 0) continue;
      if (!classIdx.contains(u32(offset + 2 * _u32Bytes))) continue;
      if (!nameIdx.contains(u32(offset + 3 * _u32Bytes))) continue;
      final mAnchor = sink.mark();
      final parsed = parser.parseFieldAt(offset);
      if (parsed == null) continue;
      final (field, fieldEnd) = parsed;
      final owner = ownerOf(offset);
      final seen = seenPerOwner.putIfAbsent(owner, () => <String>{});
      if (!spec.accepts(field) || !seen.add(spec.name)) {
        sink.rollback(mAnchor);
        continue;
      }
      sink.claim(offset, fieldEnd, _tierSemantic);
      result.putIfAbsent(owner, () => <BinaryTypeField>[]).add(field);
    }
  }
  return result;
}

class _TailSubProp {
  const _TailSubProp(this.name, this.className, this.accepts);
  final String name;
  final SeqValueClass className;
  final bool Function(BinaryTypeField) accepts;
}

final _tailSubProps = <_TailSubProp>[
  _TailSubProp('RecordResults', SeqValueClass.boolean, (field) => field.name == 'RecordResults' && field.value != null),
  _TailSubProp('FailureAction', SeqValueClass.number, (field) => field.name == 'FailureAction' && field.value != null),
  _TailSubProp(
    'Requirements',
    SeqValueClass.object,
    (field) =>
        field.name == 'Requirements' &&
        field.valueClass == SeqValueClass.object &&
        field.children.any((child) => child.name == 'Links' && child.valueClass == SeqValueClass.strings),
  ),
  _TailSubProp(
    'RTS',
    SeqValueClass.object,
    (field) => field.name == 'RTS' && field.valueClass == SeqValueClass.object && field.children.isNotEmpty,
  ),
];

Map<String, List<BinaryTypeField>> _sequenceLeadingSubProps(
  Uint8List body,
  ByteData view,
  List<String> pool,
  int recordRegionLength,
  List<BinaryTypeRecord> table,
  int typeIndexBase,
  Set<String> sequenceNames, [
  _DecodeSink sink = _DecodeSink.none,
]) {
  final sequenceToken = pool.indexOf('Sequence');
  if (sequenceToken <= 0) return const {};
  final nameIndices = <int, String>{
    for (var poolIndex = 1; poolIndex < pool.length; poolIndex++)
      if (sequenceNames.contains(pool[poolIndex])) poolIndex: pool[poolIndex],
  };
  if (nameIndices.isEmpty) return const {};
  int u32(int offset) => view.getUint32(offset, Endian.little);
  final result = <String, List<BinaryTypeField>>{};
  final parser = _TypeBodyParser(view, pool, recordRegionLength, table, null, typeIndexBase)..ops = sink;
  for (var offset = 0; offset + 3 * _u32Bytes <= recordRegionLength; offset += 1) {
    if (u32(offset) != sequenceToken) continue;
    final name = nameIndices[u32(offset + _u32Bytes)];
    if (name == null || result.containsKey(name)) continue;
    final count = u32(offset + 2 * _u32Bytes);
    if (count < 1 || count > _typeMaxFields) continue;
    final mWalk = sink.mark();
    final decoded = parser.parseLeadingSubProps(offset + 3 * _u32Bytes, count, _stepGroupNames);
    final subProps = <BinaryTypeField>[];
    var keptEnd = offset + 3 * _u32Bytes;
    for (final (field, fieldEnd) in decoded) {
      if (!_sequenceLeadingSubPropNames.contains(field.name)) break;
      subProps.add(field);
      keptEnd = fieldEnd;
    }
    if (subProps.isEmpty) {
      sink.rollback(mWalk);
      continue;
    }
    sink.rollbackTailFrom(mWalk, keptEnd);
    sink.poolRef(offset, u32(offset));
    sink.poolRef(offset + _u32Bytes, u32(offset + _u32Bytes));
    sink.u32(offset + 2 * _u32Bytes, count, _OpSource.model);
    sink.claim(offset, keptEnd, _tierSemantic);
    result[name] = subProps;
  }
  return result;
}
