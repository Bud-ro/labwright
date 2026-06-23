import 'dart:typed_data';

import 'package:labwright_core/labwright_core.dart';
import 'package:labwright_tdms/labwright_tdms.dart';

/// Maps a [TestRecord] to a single-segment TDMS file: one group per phase
/// (`NN_phaseName`, index-prefixed to stay unique and ordered) and one channel
/// per measurement. Numeric measurements become channel data; non-numeric ones
/// are stored as a `value` property. Outcomes, units, limits, and requirement
/// references (`REQ-1@hash; REQ-2@hash`, on both channels and groups) ride along
/// as properties, so the TDMS is self-describing without record.json. The JSON
/// record remains the complete artifact; TDMS carries the measurement data in
/// the org's existing format.
Uint8List recordToTdms(TestRecord rec) {
  final channels = <TdmsChannel>[];
  final groupProperties = <String, Map<String, Object>>{};

  for (var i = 0; i < rec.phases.length; i++) {
    final p = rec.phases[i];
    final group = '${i.toString().padLeft(2, '0')}_${p.name}';
    groupProperties[group] = {
      'outcome': p.outcome.name,
      'durationMs': p.durationMs,
      if (p.error != null) 'error': p.error!,
      if (p.logs.isNotEmpty) 'logs': p.logs.join('\n'),
      if (p.requirements.isNotEmpty) 'requirements': encodeRequirementRefs(p.requirements),
    };

    for (final m in p.measurements) {
      final properties = <String, Object>{
        'outcome': m.outcome.name,
        'isSet': m.isSet,
        if (m.units != null) 'units': m.units!,
        if (m.checkedLimits.isNotEmpty) 'checkedLimits': m.checkedLimits.join('; '),
        if (m.failedLimits.isNotEmpty) 'failedLimits': m.failedLimits.join('; '),
        if (m.requirements.isNotEmpty) 'requirements': encodeRequirementRefs(m.requirements),
      };
      final value = m.value;
      final data = <double>[];
      if (value is num) {
        data.add(value.toDouble());
      } else if (value is bool || value is String) {
        properties['value'] = value!;
      } else if (value != null) {
        properties['value'] = value.toString();
      }
      channels.add(TdmsChannel(group: group, name: m.name, data: data, properties: properties));
    }
  }

  return (TdmsWriter()
        ..writeSegment(
          channels,
          fileProperties: {
            'testName': rec.testName,
            'dutId': rec.dutId,
            'outcome': rec.outcome.name,
            'durationMs': rec.durationMs,
            'start': rec.start.toUtc().toIso8601String(),
            'end': rec.end.toUtc().toIso8601String(),
            if (rec.error != null) 'error': rec.error!,
          },
          groupProperties: groupProperties,
        ))
      .toBytes();
}
