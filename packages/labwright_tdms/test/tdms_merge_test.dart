import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

TdmsFile _file(List<TdmsChannel> channels, {Map<String, Map<String, Object>> groupProps = const {}}) =>
    TdmsReader.read((TdmsWriter()..writeSegment(channels, groupProperties: groupProps)).toBytes());

void main() {
  test('merges disjoint files into the union of their channels', () {
    final a = _file([TdmsChannel(group: 'A', name: 'x', data: const [1.0, 2.0])]);
    final b = _file([TdmsChannel(group: 'B', name: 'y', data: const [3.0])]);
    final merged = TdmsReader.read(mergeTdms([a, b]));

    expect(merged.group('A')!.channel('x')!.data, [1.0, 2.0]);
    expect(merged.group('B')!.channel('y')!.data, [3.0]);
  });

  test('suffixes group+channel name collisions instead of dropping them', () {
    final a = _file([TdmsChannel(group: 'G', name: 'v', data: const [1.0], properties: {'src': 'a'})]);
    final b = _file([TdmsChannel(group: 'G', name: 'v', data: const [2.0], properties: {'src': 'b'})]);
    final c = _file([TdmsChannel(group: 'G', name: 'v', data: const [3.0])]);
    final merged = TdmsReader.read(mergeTdms([a, b, c]));

    final g = merged.group('G')!;
    expect(g.channels.map((ch) => ch.name), ['v', 'v#2', 'v#3']);
    expect(g.channel('v')!.data, [1.0]);
    expect(g.channel('v')!.properties['src'], 'a');
    expect(g.channel('v#2')!.data, [2.0]);
    expect(g.channel('v#2')!.properties['src'], 'b');
    expect(g.channel('v#3')!.data, [3.0]);
  });

  test('different channels in the same group coexist; group props union (first wins)', () {
    final a = _file([TdmsChannel(group: 'G', name: 'a', data: const [1.0])], groupProps: const {
      'G': {'owner': 'shardA', 'only_a': '1'},
    });
    final b = _file([TdmsChannel(group: 'G', name: 'b', data: const [2.0])], groupProps: const {
      'G': {'owner': 'shardB', 'only_b': '2'},
    });
    final merged = TdmsReader.read(mergeTdms([a, b]));

    final g = merged.group('G')!;
    expect(g.channel('a')!.data, [1.0]);
    expect(g.channel('b')!.data, [2.0]);
    expect(g.properties['owner'], 'shardA');
    expect(g.properties['only_a'], '1');
    expect(g.properties['only_b'], '2');
  });

  test('mergeTdmsChannels is the order-preserving primitive', () {
    final a = _file([TdmsChannel(group: 'A', name: 'x', data: const [1.0])]);
    final b = _file([TdmsChannel(group: 'A', name: 'x', data: const [2.0])]);
    final chans = mergeTdmsChannels([a, b]);
    expect(chans.map((c) => '${c.group}/${c.name}'), ['A/x', 'A/x#2']);
  });
}
