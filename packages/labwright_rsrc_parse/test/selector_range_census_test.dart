@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'snapshot_check.dart';

/// Corpus census for the Case-structure **selector-range** decode
/// ([ViSelectorRange] / [ViHeapObject.selectorRanges]).
///
/// The store is the file's per-frame case-value list, and the only value it can
/// be checked against is the one the file also states in words: the `0x95`
/// selector label of the frame LabVIEW displays. So the census renders the
/// DISPLAYED frame's entries the way LabVIEW spells a selector label and
/// compares the two strings, bucketed by what the selector carries — a
/// disagreement on the one frame we can read would sink the whole store.
///
/// Also pinned are the structural laws a `switch` lowering rests on: every
/// entry names an existing frame, and every frame is either named by an entry
/// or is the one the Default reaches ([_defaultFrame]).

/// The signed-32-bit extremes an open bound stores in place of a value.
const int _kOpenHigh = 0x7fffffff;
const int _kOpenLow = -0x80000000;

/// The suffix LabVIEW appends to the Default frame's own selector label.
const String _kDefaultSuffix = ', Default';

/// The frame a Case [structure] falls back to: the `0x254` record's index, or
/// frame 0 when the record is absent ([kViFirstFrameIsDefault]).
int _defaultFrame(ViHeapObject structure) => structure.defaultFrameIndex ?? kViFirstFrameIsDefault;

/// How LabVIEW spells one entry of a numeric selector's label. Null for a bound
/// combination outside the four value-carrying shapes (the error-cluster
/// sentinels, whose words are not selector values).
String? _renderNumeric(ViSelectorRange range) {
  if (range.isSingle) return '${range.low}';
  if (range.isClosed) {
    // A two-value span is spelled as the list LabVIEW writes it back as.
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

/// [label] with LabVIEW's string-display escapes undone: `\\` is one backslash
/// and `\HH` the byte its two hex digits spell.
String _unescape(String label) => label
    .replaceAllMapped(RegExp(r'\\([0-9a-fA-F]{2})'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)))
    .replaceAll(r'\\', r'\');

/// [label] read as the signed 32-bit values its hexadecimal words spell, in the
/// decimal form [_renderNumeric] writes. Null when it is not such a label.
String? _fromHex(String label) {
  final words = label.split(', ');
  final values = [
    for (final word in words)
      if (RegExp(r'^[0-9a-fA-F]{1,8}$').hasMatch(word)) int.parse(word, radix: 16).toSigned(32) else null,
  ];
  return values.contains(null) ? null : values.join(', ');
}

/// Whether [range] is one of the error-cluster spellings, whose stored words
/// are sentinels rather than selector values: an open low end that is not the
/// `..high` shape.
bool _isSentinel(ViSelectorRange range) =>
    range.lowBound == ViSelectorBound.unbounded &&
    (range.highBound == ViSelectorBound.unbounded || range.low == range.high);

/// Whether [first] and [second] both match some value, read as closed spans
/// over the stored words (a single value is the span `low..low`).
bool _overlap(ViSelectorRange first, ViSelectorRange second) => first.low <= second.high && second.low <= first.high;

/// A selector label reduced to the form the renders above produce: LabVIEW
/// writes the separators with optional spaces.
String _canonical(String label) =>
    label.replaceAll(RegExp(r'\s*,\s*'), ', ').replaceAll(RegExp(r'\s*\.\.\s*'), '..').trim();

/// Per Case-structure oid, the `0x255` record's value — the file's own count of
/// the structure's range entries, read straight off the heap so it is an
/// independent check that the group decode drops none.
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
        if (enclosing == null || enclosing.$1 != kViCaseStructureCode) return;
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
      if (structure.kind != kViCaseStructureCode) continue;
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
      // Whether two entries naming DIFFERENT frames can both match one value.
      // A consumer that tests the entries in order relies on them not.
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
          .where((child) => child.kind == kViSelectorLabelCode)
          .map((child) => child.label)
          .whereType<String>()
          .firstOrNull;
      if (selectorLabel == null) {
        bump('noLabel');
        continue;
      }
      var want = _canonical(selectorLabel);
      // The Default frame's label carries the suffix; stripping it here scores
      // the VALUE set, and the suffix itself is scored on its own below.
      // The suffix is what LabVIEW writes on the Default frame's own label, so
      // a label carrying it must sit on the frame the rule names. The converse
      // is NOT a law and is not asserted: LabVIEW omits the suffix when the
      // entries already exhaust the selector (a boolean's two frames), even
      // though the fallback frame is still where an unmatched value would go.
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
        // A Default-only frame carries no entry, so its label is the suffix
        // alone — already scored above.
        bump(want.isEmpty ? 'defaultOnlyFrame' : 'displayedUnnamed');
        continue;
      }
      // A label reading `Error` / `No Error` is the error-cluster form, whose
      // two frames carry sentinel words rather than selector values.
      // A boolean selector, and an error cluster's status, are both stored as
      // the single values 0 and 1. The No Error frame also has a sentinel
      // spelling whose words are not selector values.
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
          // The label escapes what a LabVIEW string display escapes; the pool
          // holds the characters themselves.
          bump('stringEscaped');
        } else if (values.every((value) => value!.trim().isEmpty)) {
          // A pool value that is only whitespace: the label does not render it
          // back, so there is nothing to compare.
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
        // The selector's display format is hexadecimal, so the label spells the
        // same value in another radix.
        bump('numericRadix');
      } else if (RegExp(r'^-?[0-9][-0-9 ,.]*$').hasMatch(want)) {
        bump('numericDisagree');
      } else {
        // An enum item name, or another rendering whose text the store does not
        // hold — outside what this census can score.
        bump('labelNotDecimal');
      }
    }
  }
  return counts;
}

void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('selector-range census (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

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
