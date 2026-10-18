import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../corpus_dirs.dart';
import '../shape_probe.dart';

const int _kOpenHigh = 0x7fffffff;
const int _kOpenLow = -0x80000000;

const String _kDefaultSuffix = ', Default';

int _defaultFrame(BdObject structure) => structure.caseFrames?.defaultFrameIndex ?? kViFirstFrameIsDefault;

String? _renderNumeric(ViSelectorRange range) {
  if (range.isSingle) return '${range.low}';
  if (range.isClosed) {
    return range.high == range.low + 1 ? '${range.low}, ${range.high}' : '${range.low}..${range.high}';
  }
  if (range.lowBound == ViSelectorBound.inclusive && range.highBound == ViSelectorBound.unbounded) {
    return range.high == _kOpenHigh ? '${range.low}..' : null;
  }
  if (range.lowBound == ViSelectorBound.unbounded && range.highBound == ViSelectorBound.inclusive) {
    return range.low == _kOpenLow ? '..${range.high}' : null;
  }
  return null;
}

String _unescape(String label) => label
    .replaceAllMapped(RegExp(r'\\([0-9a-fA-F]{2})'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)))
    .replaceAll(r'\"', '"')
    .replaceAll(r'\\', r'\');

String? _fromHex(String label) {
  final words = label.split(', ');
  final values = [
    for (final word in words)
      if (RegExp(r'^[0-9a-fA-F]{1,8}(\.\.[0-9a-fA-F]{1,8})?$').hasMatch(word))
        word.split('..').map((part) => int.parse(part, radix: 16).toSigned(32)).join('..')
      else
        null,
  ];
  return values.contains(null) ? null : values.join(', ');
}

String _canonical(String label) =>
    label.replaceAll(RegExp(r'\s*,\s*'), ', ').replaceAll(RegExp(r'\s*\.\.\s*'), '..').trim();

Map<int, int> _statedCounts(List<DecodedSection> sections) {
  final stated = <int, int>{};
  for (final section in sections) {
    if (!(BlockTag.of(section.tag)?.isRecordHeap ?? false)) continue;
    final body = section.bytes;
    if (body.length < 6) continue;
    walkHeapObjects<(int, int)>(
      body,
      onObjectOpen: (offset, kind, oid, parent) => (kind, oid),
      onRecord: (offset, length, lead, enclosing) {
        if (enclosing == null || enclosing.$1 != BdObjectClass.caseStructure.code) return;
        final attr = decodeHeapAttr(body, offset);
        if (attr?.rawTag == HeapAttribute.selectNRightType.raw && attr?.asInt != null) {
          stated[enclosing.$2] ??= attr!.asInt!;
        }
      },
    );
  }
  return stated;
}

Map<String, int> _census(CorpusVi vi) {
  final counts = <String, int>{};
  void bump(String key) => counts[key] = (counts[key] ?? 0) + 1;
  final sections = vi.decoded;
  final model = vi.model;
  if (sections == null || model == null) return counts;
  final Map<int, int> stated;
  try {
    stated = _statedCounts(sections);
  } catch (_) {
    return counts;
  }
  for (final diagram in model.blockDiagrams) {
    for (final structure in diagram.objects) {
      if (structure.objectClass != BdObjectClass.caseStructure) continue;
      final frames = structure.caseFrames!;
      final ranges = frames.selectorRanges;
      if (ranges.isEmpty) continue;
      if (stated[structure.oid] case final count? when count != ranges.length) bump('countDisagree');
      final frameCount = diagram
          .childrenOf(structure)
          .where((child) => child.objectClass == BdObjectClass.frame)
          .length;
      for (final range in ranges) {
        if (range.frame < 0 || range.frame >= frameCount) bump('frameOutOfRange');
      }
      final fallback = _defaultFrame(structure);
      final named = {for (final range in ranges) range.frame};
      for (var frame = 0; frame < frameCount; frame++) {
        if (!named.contains(frame) && fallback != frame) bump('frameUnreachable');
      }

      final selectorLabel = diagram
          .childrenOf(structure)
          .where((child) => child.objectClass == BdObjectClass.caseSelectorLabel)
          .map((child) => child.label)
          .whereType<String>()
          .firstOrNull;
      if (selectorLabel == null) continue;
      var want = _canonical(selectorLabel);
      final wantsDefault = want.endsWith(_kDefaultSuffix) || want == 'Default';
      if (wantsDefault) want = want == 'Default' ? '' : want.substring(0, want.length - _kDefaultSuffix.length);
      final displayed = [
        for (final range in ranges)
          if (range.frame == structure.frames?.visibleFrameIndex) range,
      ];
      if (displayed.isEmpty) continue;
      if (const {'True', 'False', 'Error', 'No Error'}.contains(want)) {
        final entry = displayed.length == 1 ? displayed.single : null;
        final wantsSet = want == 'True' || want == 'Error';
        final sentinel =
            !wantsSet && entry?.lowBound == ViSelectorBound.unbounded && entry?.highBound == ViSelectorBound.inclusive;
        final agrees = sentinel || (entry != null && entry.isSingle && entry.low == (wantsSet ? 1 : 0));
        final shape = want == 'True' || want == 'False' ? 'bool' : 'error';
        bump('$shape${agrees ? 'Agree' : 'Disagree'}');
        continue;
      }
      final pool = frames.selectorStrings;
      if (pool.isNotEmpty) {
        final values = [
          for (final range in displayed)
            if (range.isSingle && range.low >= 0 && range.low < pool.length) pool[range.low] else null,
        ];
        if (values.contains(null)) continue;
        final rendered = values.map((value) => '"$value"').join(', ');
        if (rendered == want || rendered == _unescape(want)) {
          bump('stringAgree');
        } else if (!values.every((value) => value!.trim().isEmpty)) {
          bump('stringDisagree');
        }
        continue;
      }
      final rendered = [for (final range in displayed) _renderNumeric(range)];
      if (rendered.contains(null)) continue;
      if (rendered.join(', ') == want || rendered.join(', ') == _fromHex(want)) {
        bump('numericAgree');
      } else if (RegExp(r'^-?[0-9][-0-9 ,.]*$').hasMatch(want)) {
        bump('numericDisagree');
      }
    }
  }
  return counts;
}

const selectorRangeCensusLaw = CorpusLaw('selector_range_census', _census);

void selectorRangeCensusTests() {
  test('every selector range names a frame the structure has, and no frame is unreachable', () async {
    expect(
      await selectorRangeCensusLaw.nonzero({'frameOutOfRange', 'frameUnreachable', 'countDisagree'}),
      const <String, Map<String, int>>{},
    );
  });

  test('the displayed frame\'s ranges reproduce its selector label', () async {
    expect(
      await selectorRangeCensusLaw.nonzero({'boolDisagree', 'errorDisagree', 'numericDisagree', 'stringDisagree'}),
      const <String, Map<String, int>>{},
    );
    final counts = await selectorRangeCensusLaw.results;
    for (final shape in const ['bool', 'error', 'numeric', 'string']) {
      expect(counts.any((c) => (c['${shape}Agree'] ?? 0) > 0), isTrue, reason: shape);
    }
  });
}
