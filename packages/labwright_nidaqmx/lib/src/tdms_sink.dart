// Bridge from a DAQ sample stream (DaqmxApi.readStream) to NI's TDMS format via
// labwright_tdms. Each stream chunk becomes one TDMS segment — the format's native
// streaming shape — so a long acquisition writes incrementally. Raw integer formats
// are stored as their matching TdsType (i16/i32/…), preserving the device's native
// codes without widening to f64 on disk.

import 'dart:async';
import 'dart:typed_data';

import 'package:labwright_tdms/labwright_tdms.dart';

import 'streaming.dart';

/// On-disk TDMS type for a stream [format].
TdsType tdsTypeFor(DaqSampleFormat format) => switch (format) {
      DaqSampleFormat.volts => TdsType.doubleFloat,
      DaqSampleFormat.rawI16 => TdsType.i16,
      DaqSampleFormat.rawI32 => TdsType.i32,
      DaqSampleFormat.rawU16 => TdsType.u16,
      DaqSampleFormat.rawU32 => TdsType.u32,
    };

/// Records a DAQ [stream] of [format] chunks into TDMS bytes under
/// `<group>/<channel>`, one segment per chunk. When [rateHz] is given, the first
/// segment carries the TDMS waveform timing properties (`wf_increment` = 1/rate) so
/// the result opens as a time-based waveform in DIAdem/LabVIEW. [channelProperties]
/// are merged onto the first segment.
///
/// Returns the complete TDMS byte buffer when the stream closes. Cancel/stop the
/// upstream DAQ stream to end a continuous acquisition before calling — this drains
/// whatever the stream yields.
Future<Uint8List> recordStreamToTdms(
  Stream<TypedData> stream, {
  required DaqSampleFormat format,
  required String group,
  required String channel,
  double? rateHz,
  Map<String, Object> channelProperties = const {},
}) async {
  final writer = TdmsWriter();
  final tds = tdsTypeFor(format);
  var first = true;
  await for (final chunk in stream) {
    final props = first
        ? <String, Object>{
            if (rateHz != null && rateHz > 0) ...{
              'wf_increment': 1.0 / rateHz,
              'wf_start_offset': 0.0,
            },
            ...channelProperties,
          }
        : const <String, Object>{};
    writer.writeSegment([
      TdmsChannel(group: group, name: channel, data: _toDoubles(chunk), type: tds, properties: props),
    ]);
    first = false;
  }
  return writer.toBytes();
}

/// TdmsChannel takes `List<double>`; widen integer chunks (the on-disk encoding is
/// still the compact [TdsType] chosen above — TdmsWriter truncates via `toInt()`).
List<double> _toDoubles(TypedData chunk) {
  if (chunk is Float64List) return chunk;
  if (chunk is Int16List) return [for (final v in chunk) v.toDouble()];
  if (chunk is Int32List) return [for (final v in chunk) v.toDouble()];
  if (chunk is Uint16List) return [for (final v in chunk) v.toDouble()];
  if (chunk is Uint32List) return [for (final v in chunk) v.toDouble()];
  throw ArgumentError('unsupported chunk type ${chunk.runtimeType}');
}
