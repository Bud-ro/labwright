import 'package:labwright_core/labwright_core.dart';
import 'package:labwright_tdms/labwright_tdms.dart';

/// Reconstructs a record-JSON map (the shape `buildTraceMatrixFromRecordJson`
/// consumes) from a [TdmsFile] written by [recordToTdms]. Because that writer
/// embeds outcomes and requirement refs as channel/group properties, a `.tdms`
/// file is self-describing: you can build a trace matrix from it alone, with no
/// `record.json` alongside.
///
/// The returned shape is `{testName?, dutId?, outcome?, phases: [{name, outcome,
/// requirements: [{id, hash}], measurements: [{name, outcome, requirements:
/// [{id, hash}]}]}]}`. Group names keep their `NN_` order prefix only in the
/// TDMS; the prefix is stripped here so the phase name matches the original.
Map<String, Object?> tdmsToRecordJson(TdmsFile file) {
  final phases = <Map<String, Object?>>[
    for (final g in file.groups)
      {
        'name': g.name.replaceFirst(RegExp(r'^\d+_'), ''),
        'outcome': g.properties['outcome'],
        'requirements': _parseReqs(g.properties['requirements']),
        'measurements': <Map<String, Object?>>[
          for (final c in g.channels)
            {
              'name': c.name,
              'outcome': c.properties['outcome'],
              'requirements': _parseReqs(c.properties['requirements']),
            },
        ],
      },
  ];
  return {
    if (file.properties['testName'] != null) 'testName': file.properties['testName'],
    if (file.properties['dutId'] != null) 'dutId': file.properties['dutId'],
    if (file.properties['outcome'] != null) 'outcome': file.properties['outcome'],
    'phases': phases,
  };
}

/// Parses a `requirements` property (`REQ-1@hash; REQ-2@hash`) back into the
/// `[{id, hash}]` record-JSON shape, reusing the shared codec so the embed and
/// read paths share one format definition.
List<Map<String, Object?>> _parseReqs(Object? value) =>
    value is! String || value.isEmpty ? const [] : [for (final r in decodeRequirementRefs(value)) r.toJson()];
