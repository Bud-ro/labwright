// Minimal end-to-end demo: enumerate devices, read one sample, stream to a TDMS file —
// over local FFI by default, or remote gRPC with `--grpc <host>`. Runs harmlessly with
// no NI software present (it reports that no DAQ is available and exits).
//
//   dart run example/main.dart                         # local FFI, channel cDAQ1Mod1/ai0
//   dart run example/main.dart --channel Dev1/ai0
//   dart run example/main.dart --grpc 192.168.1.50     # remote gRPC

import 'dart:io';

import 'package:labwright_nidaqmx/labwright_nidaqmx.dart';

Future<void> main(List<String> args) async {
  final host = _optionValue(args, '--grpc');
  final useGrpc = host != null;
  final channel = _optionValue(args, '--channel') ?? 'cDAQ1Mod1/ai0';

  try {
    final DaqmxApi daq = useGrpc ? Daqmx.remote(host: host) : Daqmx.local();
    try {
      print('Devices: ${await daq.deviceNames()}');
      print('$channel = ${await daq.readVoltage(channel)} V');

      print('Streaming 5000 samples @ 1 kHz to capture.tdms ...');
      final bytes = await recordStreamToTdms(
        daq.readVoltageStream(channel, rateHz: 1000, totalSamples: 5000),
        format: DaqSampleFormat.volts,
        group: 'AI',
        channel: channel,
        rateHz: 1000,
      );
      await File('capture.tdms').writeAsBytes(bytes);
      print('Wrote capture.tdms (${bytes.length} bytes).');
    } finally {
      await daq.close();
    }
  } on DaqmxUnavailable catch (e) {
    stderr.writeln('No DAQ available: $e');
    stderr.writeln('Install NI-DAQmx (Windows/Linux) or use --grpc <host>.');
  } on UnsupportedError catch (e) {
    stderr.writeln(e.message); // e.g. local DAQ on macOS -> use --grpc
  }
}

/// Returns the value following [flag] in [args], or null if the flag is absent.
String? _optionValue(List<String> args, String flag) {
  final i = args.indexOf(flag);
  return (i >= 0 && i + 1 < args.length) ? args[i + 1] : null;
}
