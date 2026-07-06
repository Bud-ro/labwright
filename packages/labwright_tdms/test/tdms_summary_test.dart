import 'dart:convert';

import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

void main() {
  test('summarizes groups/channels with stats and is JSON-encodable', () {
    final bytes =
        (TdmsWriter()..writeSegment(
              [
                TdmsChannel(group: 'M', name: 'v', data: const [1.0, 3.0, 2.0], properties: {'unit': 'V'}),
                TdmsChannel(group: 'M', name: 'note', data: const [], properties: {'value': 'hi'}),
              ],
              fileProperties: {'operator': 'loop'},
            ))
            .toBytes();

    final s = tdmsSummary(bytes);
    expect(s['properties'], {'operator': 'loop'});

    final groups = s['groups'] as List;
    final m = groups.single as Map<String, Object?>;
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
    expect(note.containsKey('min'), isFalse, reason: 'empty channels carry no min/max/mean stats');

    expect(() => jsonEncode(s), returnsNormally);
  });
}
