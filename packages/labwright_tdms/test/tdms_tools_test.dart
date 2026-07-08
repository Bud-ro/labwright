// diffTdms / mergeTdms / tdmsSummary / inspectTdms.
import 'dart:convert';

import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

import 'util.dart';

void main() {
  group('diffTdms', () {
    TdmsFile one(List<double> data) => reread([ch('M', 'v', data)]);

    test('identical files: identical=true, no channels, JSON-encodable', () {
      final d = diffTdms(one([1, 2, 3]), one([1, 2, 3]));
      expect(d['identical'], isTrue);
      expect(d['channels'], isEmpty);
      expect(() => jsonEncode(d), returnsNormally);
    });

    test('value difference carries first index and max delta', () {
      final d = diffTdms(one([1, 2, 3]), one([1, 2.5, 3]));
      expect(d['identical'], isFalse);
      final c = (d['channels'] as List).single as Map<String, Object?>;
      expect(c['status'], 'valueDiff');
      expect(c['firstDiffIndex'], 1);
      expect(c['maxAbsDelta'], closeTo(0.5, 1e-12));
    });

    test('tolerance absorbs small differences', () {
      expect(diffTdms(one([1, 2]), one([1, 2.05]), tol: 0.1)['identical'], isTrue);
      expect(diffTdms(one([1, 2]), one([1, 2.05]), tol: 0.01)['identical'], isFalse);
    });

    test('added/removed channels and groups, and length mismatch', () {
      // dart format off
      final a = reread([ch('M', 'v', [1, 2]), ch('OnlyA', 'x', [9])]);
      final b = reread([ch('M', 'v', [1, 2, 3]), ch('M', 'added', [7])]);
      // dart format on
      final d = diffTdms(a, b);
      expect(d['identical'], isFalse);
      expect(d['groupsOnlyInA'], ['OnlyA']);
      expect(d['groupsOnlyInB'], isEmpty);
      final chans = (d['channels'] as List).cast<Map<String, Object?>>();
      final v = chans.firstWhere((c) => c['name'] == 'v');
      expect(v['status'], 'lengthMismatch');
      expect(v['lenA'], 2);
      expect(v['lenB'], 3);
      expect(chans.firstWhere((c) => c['name'] == 'added')['status'], 'onlyInB');
    });

    test('a channel present only in A within a shared group', () {
      // dart format off
      final d = diffTdms(reread([ch('G', 'a', [1]), ch('G', 'gone', [2])]), reread([ch('G', 'a', [1])]));
      // dart format on
      final c = (d['channels'] as List).single as Map<String, Object?>;
      expect(c['status'], 'onlyInA');
      expect(c['lenA'], 1);
    });
  });

  group('mergeTdms', () {
    test('disjoint files merge to the union of their channels', () {
      // dart format off
      final merged = TdmsReader.read(mergeTdms([reread([ch('A', 'x', [1, 2])]), reread([ch('B', 'y', [3])])]));
      expect(channelsOf(merged), {'A/x': [1, 2], 'B/y': [3]});
      // dart format on
    });

    test('group+channel name collisions get #N suffixes, properties kept', () {
      // dart format off
      final merged = TdmsReader.read(mergeTdms([
        reread([ch('G', 'v', [1], props: {'src': 'a'})]),
        reread([ch('G', 'v', [2], props: {'src': 'b'})]),
        reread([ch('G', 'v', [3])]),
      ]));
      expect(channelsOf(merged), {'G/v': [1], 'G/v#2': [2], 'G/v#3': [3]});
      // dart format on
      final g = merged.group('G')!;
      expect(g.channel('v')!.properties['src'], 'a');
      expect(g.channel('v#2')!.properties['src'], 'b');
    });

    test('same-group channels coexist; group properties union, first wins', () {
      // dart format off
      final merged = TdmsReader.read(mergeTdms([
        reread([ch('G', 'a', [1])], groupProps: const {'G': {'owner': 'shardA', 'only_a': '1'}}),
        reread([ch('G', 'b', [2])], groupProps: const {'G': {'owner': 'shardB', 'only_b': '2'}}),
      ]));
      expect(channelsOf(merged), {'G/a': [1], 'G/b': [2]});
      // dart format on
      expect(merged.group('G')!.properties, {'owner': 'shardA', 'only_a': '1', 'only_b': '2'});
    });

    test('mergeTdmsChannels is the order-preserving primitive', () {
      // dart format off
      final chans = mergeTdmsChannels([reread([ch('A', 'x', [1])]), reread([ch('A', 'x', [2])])]);
      // dart format on
      expect(chans.map((c) => '${c.group}/${c.name}'), ['A/x', 'A/x#2']);
    });
  });

  group('tdmsSummary', () {
    test('groups/channels with stats, JSON-encodable; empty channels carry no stats', () {
      final s = tdmsSummary(
        write(
          [
            ch('M', 'v', [1, 3, 2], props: {'unit': 'V'}),
            ch('M', 'note', [], props: {'value': 'hi'}),
          ],
          fileProps: {'operator': 'loop'},
        ),
      );
      expect(s['properties'], {'operator': 'loop'});
      final m = (s['groups'] as List).single as Map<String, Object?>;
      expect(m['name'], 'M');
      final channels = (m['channels'] as List).cast<Map<String, Object?>>();
      final v = channels.firstWhere((c) => c['name'] == 'v');
      expect(v['count'], 3);
      expect(v['min'], 1.0);
      expect(v['max'], 3.0);
      expect(v['mean'], 2.0);
      expect((v['properties'] as Map)['unit'], 'V');
      final note = channels.firstWhere((c) => c['name'] == 'note');
      expect(note['count'], 0);
      expect(note.containsKey('min'), isFalse);
      expect(() => jsonEncode(s), returnsNormally);
    });
  });

  group('inspectTdms', () {
    test('renders groups, channels, stats and properties', () {
      final report = inspectTdms(
        write(
          [
            ch('Meas', 'rail_V', [3.30, 3.31, 3.29], props: {'unit': 'V'}),
            ch('Meas', 'serial', [], props: {'value': 'SN1'}),
          ],
          fileProps: {'operator': 'loop'},
        ),
      );
      for (final fragment in [
        'group "Meas"',
        'channel "rail_V": 3 values',
        'operator = loop',
        'min=3.29',
        'max=3.31',
        'channel "serial": 0 values',
        'value=SN1',
      ]) {
        expect(report, contains(fragment));
      }
    });

    test('previews only the first N values', () {
      final report = inspectTdms(
        write([
          ch('M', 'v', [1, 2, 3, 4, 5, 6, 7]),
        ]),
        preview: 3,
      );
      expect(report, contains('7 values'));
      expect(report, contains(', ...]'));
    });
  });
}
