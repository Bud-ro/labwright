@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

const int _kOpenHigh = 0x7fffffff;
const int _kOpenLow = -0x80000000;

const String _kDefaultSuffix = ', Default';

int _defaultFrame(ViHeapObject structure) => structure.defaultFrameIndex ?? kViFirstFrameIsDefault;

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
    .replaceAll(r'\\', r'\');

String? _fromHex(String label) {
  final words = label.split(', ');
  final values = [
    for (final word in words)
      if (RegExp(r'^[0-9a-fA-F]{1,8}$').hasMatch(word)) int.parse(word, radix: 16).toSigned(32) else null,
  ];
  return values.contains(null) ? null : values.join(', ');
}

bool _isSentinel(ViSelectorRange range) =>
    range.lowBound == ViSelectorBound.unbounded &&
    (range.highBound == ViSelectorBound.unbounded || range.low == range.high);

bool _overlap(ViSelectorRange first, ViSelectorRange second) => first.low <= second.high && second.low <= first.high;

String _canonical(String label) =>
    label.replaceAll(RegExp(r'\s*,\s*'), ', ').replaceAll(RegExp(r'\s*\.\.\s*'), '..').trim();

Map<int, int> _statedCounts(List<DecodedSection> sections) {
  final stated = <int, int>{};
  for (final section in sections) {
    if (!kHeapSectionTags.contains(section.tag)) continue;
    final body = section.bytes;
    if (body.length < 6) continue;
    walkHeapObjects<(int, int)>(
      body,
      onObjectOpen: (span, kind, oid, parent) => (kind, oid),
      onRecord: (span, enclosing) {
        if (enclosing == null || enclosing.$1 != HeapObjectClass.bdStructureFrame.code) return;
        final attr = decodeHeapAttr(body, span.offset);
        if (attr?.rawTag == HeapAttribute.selectNRightType.raw && attr?.asInt != null) {
          stated[enclosing.$2] ??= attr!.asInt!;
        }
      },
    );
  }
  return stated;
}

Map<String, int> _census(Uint8List bytes, String path) {
  final counts = <String, int>{};
  void bump(String key) => counts[key] = (counts[key] ?? 0) + 1;
  final ViModel model;
  final Map<int, int> stated;
  try {
    final sections = decodeSections(bytes).toList();
    model = buildViModelFromDecoded(sections);
    stated = _statedCounts(sections);
  } catch (_) {
    return counts;
  }
  for (final diagram in model.blockDiagrams) {
    for (final structure in diagram.objects) {
      if (structure.objectClass != HeapObjectClass.bdStructureFrame) continue;
      bump('structures');
      final ranges = structure.selectorRanges;
      if (ranges.isEmpty) {
        bump('noRanges');
        continue;
      }
      bump('withRanges');
      if (stated[structure.oid] case final count?) {
        bump(count == ranges.length ? 'countAgree' : 'countDisagree');
      }
      final frameCount = diagram.children(structure.oid).where((child) => child.kind == kViFrameCode).length;
      for (final range in ranges) {
        bump(range.frame >= 0 && range.frame < frameCount ? 'frameInRange' : 'frameOutOfRange');
      }
      for (var i = 0; i < ranges.length; i++) {
        for (var j = i + 1; j < ranges.length; j++) {
          if (ranges[i].frame == ranges[j].frame) continue;
          if (_isSentinel(ranges[i]) || _isSentinel(ranges[j])) {
            bump('rangesSentinel');
          } else {
            bump(_overlap(ranges[i], ranges[j]) ? 'rangesOverlap' : 'rangesDisjoint');
          }
        }
      }
      final fallback = _defaultFrame(structure);
      bump(structure.defaultFrameIndex != null ? 'defaultRecorded' : 'defaultUnrecorded');
      final named = {for (final range in ranges) range.frame};
      for (var frame = 0; frame < frameCount; frame++) {
        bump(named.contains(frame) || fallback == frame ? 'frameReachable' : 'frameUnreachable');
      }

      final selectorLabel = diagram
          .children(structure.oid)
          .where((child) => child.objectClass == HeapObjectClass.bdSelectorLabel)
          .map((child) => child.label)
          .whereType<String>()
          .firstOrNull;
      if (selectorLabel == null) {
        bump('noLabel');
        continue;
      }
      var want = _canonical(selectorLabel);
      final wantsDefault = want.endsWith(_kDefaultSuffix) || want == 'Default';
      if (wantsDefault) {
        bump(fallback == structure.visibleFrameIndex ? 'defaultAgree' : 'defaultDisagree');
      }
      if (wantsDefault) want = want == 'Default' ? '' : want.substring(0, want.length - _kDefaultSuffix.length);
      final displayed = [
        for (final range in ranges)
          if (range.frame == structure.visibleFrameIndex) range,
      ];
      if (displayed.isEmpty) {
        bump(want.isEmpty ? 'defaultOnlyFrame' : 'displayedUnnamed');
        continue;
      }
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
      if (structure.selectorStrings.isNotEmpty) {
        final pool = structure.selectorStrings;
        final values = [
          for (final range in displayed)
            if (range.isSingle && range.low >= 0 && range.low < pool.length) pool[range.low] else null,
        ];
        if (values.contains(null)) {
          bump('stringUnrendered');
        } else if (values.map((value) => '"$value"').join(', ') == want) {
          bump('stringAgree');
        } else if (values.map((value) => '"$value"').join(', ') == _unescape(want)) {
          bump('stringEscaped');
        } else if (values.every((value) => value!.trim().isEmpty)) {
          bump('stringWhitespace');
        } else {
          bump('stringDisagree');
        }
        continue;
      }
      final rendered = [for (final range in displayed) _renderNumeric(range)];
      if (rendered.contains(null)) {
        bump('numericUnrendered');
        continue;
      }
      if (rendered.join(', ') == want) {
        bump('numericAgree');
      } else if (rendered.join(', ') == _fromHex(want)) {
        bump('numericRadix');
      } else if (RegExp(r'^-?[0-9][-0-9 ,.]*$').hasMatch(want)) {
        bump('numericDisagree');
      } else {
        bump('labelNotDecimal');
      }
    }
  }
  return counts;
}

void main() {
  final all = corpusVis();

  late final Map<String, int> counts;
  setUpAll(() async {
    final results = await corpusParallel(all, _census);
    counts = {};
    for (final result in results) {
      result.forEach((key, value) => counts[key] = (counts[key] ?? 0) + value);
    }
  });

  test('every selector range names a frame the structure has, and no frame is unreachable', () {
    expect(counts['frameOutOfRange'] ?? 0, 0, reason: 'a selector range names a frame index the structure has not got');
    expect(counts['frameUnreachable'] ?? 0, 0, reason: 'a frame is named by no range and is not the Default');
    expect(counts['countDisagree'] ?? 0, 0, reason: 'the decoded range list is not the length the file states');
  });

  test('the displayed frame\'s ranges reproduce its selector label', () {
    for (final shape in const ['bool', 'error', 'numeric', 'string']) {
      expect(counts['${shape}Disagree'] ?? 0, 0, reason: 'the $shape selector label disagrees with the decoded ranges');
      expect(counts['${shape}Agree'] ?? 0, greaterThan(0), reason: 'no $shape selector label was scored at all');
    }
  });

  test('selector-range census matches the committed snapshot exactly', () {
    printOnFailure('measured: ${[for (final key in counts.keys.toList()..sort()) '$key ${counts[key]}'].join(', ')}');
    expectCorpusSnapshot('selector_ranges', counts);
  });
}
