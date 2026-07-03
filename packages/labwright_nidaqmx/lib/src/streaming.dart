// Buffered ("clocked") streaming acquisition. Unlike the scalar read/write, this sets
// up a hardware sample clock and pulls blocks continuously — the real DAQ workload.
//
// Format matters for throughput: f64 ([DaqSampleFormat.volts]) is pre-scaled and
// convenient but moves 8 bytes/sample; the raw integer formats move the device's
// native ADC codes (2 bytes for a 16-bit device) with no per-sample scaling, which is
// what sustained high-speed acquisition and TDMS archival actually use.

import 'dart:typed_data';

import 'daqmx_api.dart';
import 'daqmx_constants.dart';

/// Sample format for [DaqmxApi.readStream]. Each maps to a DAQmx buffered read and a
/// concrete Dart typed list (the element type the stream yields).
enum DaqSampleFormat {
  /// `DAQmxReadAnalogF64` — pre-scaled volts. Stream yields `Float64List`.
  volts(8),

  /// `DAQmxReadBinaryI16` — raw signed 16-bit codes. Stream yields `Int16List`.
  rawI16(2),

  /// `DAQmxReadBinaryI32` — raw signed 32-bit codes. Stream yields `Int32List`.
  rawI32(4),

  /// `DAQmxReadBinaryU16` — raw unsigned 16-bit codes. Stream yields `Uint16List`.
  rawU16(2),

  /// `DAQmxReadBinaryU32` — raw unsigned 32-bit codes. Stream yields `Uint32List`.
  rawU32(4);

  const DaqSampleFormat(this.bytesPerSample);

  /// Width of one sample on the wire/in memory.
  final int bytesPerSample;
}

/// Transport for remote (gRPC) streaming. [inBandGrpc] streams samples over the gRPC
/// connection itself via `DataMoniker.StreamRead` — works anywhere, moderate rate.
/// The rest are NI's higher-throughput sideband transports negotiated by
/// `BeginSidebandStream`; they require native support and are not implemented here yet
/// (see README "Streaming"). Selected on `Daqmx.remote(..., sideband: ...)`.
enum SidebandStrategy {
  /// Samples ride the gRPC stream (`DataMoniker.StreamRead`). Implemented.
  inBandGrpc,

  /// Shared memory (same machine only). Native — not implemented.
  sharedMemory,

  /// Raw sockets over the network. Native — not implemented.
  sockets,

  /// RDMA (InfiniBand/RoCE NICs) for high-rate network streaming. Native — not implemented.
  rdma,
}

/// Typed convenience wrappers over [DaqmxApi.readStream] (the general primitive). Each
/// requests a format and yields the precise typed list, so callers avoid casting.
extension DaqmxStreams on DaqmxApi {
  /// Pre-scaled volts (`Float64List`). See [readStream].
  Stream<Float64List> readVoltageStream(
    String physicalChannel, {
    required double rateHz,
    int samplesPerChunk = 1000,
    int? totalSamples,
    double min = -10,
    double max = 10,
    int terminalConfig = DaqmxVal.cfgDefault,
  }) =>
      readStream(physicalChannel,
              rateHz: rateHz,
              samplesPerChunk: samplesPerChunk,
              totalSamples: totalSamples,
              min: min,
              max: max,
              terminalConfig: terminalConfig)
          .cast<Float64List>();

  /// Raw signed 16-bit ADC codes (`Int16List`) — the typical high-speed format.
  Stream<Int16List> readRawI16Stream(
    String physicalChannel, {
    required double rateHz,
    int samplesPerChunk = 1000,
    int? totalSamples,
    double min = -10,
    double max = 10,
    int terminalConfig = DaqmxVal.cfgDefault,
  }) =>
      readStream(physicalChannel,
              rateHz: rateHz,
              samplesPerChunk: samplesPerChunk,
              totalSamples: totalSamples,
              format: DaqSampleFormat.rawI16,
              min: min,
              max: max,
              terminalConfig: terminalConfig)
          .cast<Int16List>();

  /// Raw signed 32-bit ADC codes (`Int32List`) — for 24-/32-bit devices and counters.
  Stream<Int32List> readRawI32Stream(
    String physicalChannel, {
    required double rateHz,
    int samplesPerChunk = 1000,
    int? totalSamples,
    double min = -10,
    double max = 10,
    int terminalConfig = DaqmxVal.cfgDefault,
  }) =>
      readStream(physicalChannel,
              rateHz: rateHz,
              samplesPerChunk: samplesPerChunk,
              totalSamples: totalSamples,
              format: DaqSampleFormat.rawI32,
              min: min,
              max: max,
              terminalConfig: terminalConfig)
          .cast<Int32List>();
}
