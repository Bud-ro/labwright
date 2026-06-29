import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

void main() {
  test('renders groups, channels, stats and properties', () {
    final bytes = (TdmsWriter()
          ..writeSegment(
            [
              TdmsChannel(group: 'Meas', name: 'rail_V', data: [3.30, 3.31, 3.29], properties: {'unit': 'V'}),
              TdmsChannel(group: 'Meas', name: 'serial', data: [], properties: {'value': 'SN1'}),
            ],
            fileProperties: {'operator': 'loop'},
          ))
        .toBytes();

    final report = inspectTdms(bytes);

    expect(report, contains('group "Meas"'));
    expect(report, contains('channel "rail_V": 3 values'));
    expect(report, contains('operator = loop'));
    expect(report, contains('min=3.29'));
    expect(report, contains('max=3.31'));
    expect(report, contains('channel "serial": 0 values'));
    expect(report, contains('value=SN1'));
  });

  test('previews only the first N values', () {
    final bytes = (TdmsWriter()
          ..writeSegment([TdmsChannel(group: 'M', name: 'v', data: [1, 2, 3, 4, 5, 6, 7].map((e) => e.toDouble()).toList())]))
        .toBytes();
    final report = inspectTdms(bytes, preview: 3);
    expect(report, contains('7 values'));
    expect(report, contains(', ...]'));
  });
}
