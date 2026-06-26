/// Documented `DAQmx_Val_*` integer constants from the public NI-DAQmx C API
/// reference. These are the SAME values the clean-room `qdaq` mirrors — by design,
/// since qdaq conforms to the NI-DAQmx C interface — so a backend swap is just a
/// different library behind identical constants.
///
/// Transcribed from NI's published C header / reference (interface values, not NI
/// implementation): binding to a documented public API is normal interop.
library;

/// The subset of `DAQmx_Val_*` constants this wrapper uses today.
abstract final class DaqmxVal {
  // Terminal configuration (AI).
  static const int cfgDefault = -1; // DAQmx_Val_Cfg_Default
  static const int rse = 10083; // DAQmx_Val_RSE
  static const int nrse = 10078; // DAQmx_Val_NRSE
  static const int diff = 10106; // DAQmx_Val_Diff
  static const int pseudoDiff = 12529; // DAQmx_Val_PseudoDiff

  // Units.
  static const int volts = 10348; // DAQmx_Val_Volts

  // Sample-clock active edge.
  static const int rising = 10280; // DAQmx_Val_Rising
  static const int falling = 10171; // DAQmx_Val_Falling

  // Sample mode.
  static const int finiteSamps = 10178; // DAQmx_Val_FiniteSamps
  static const int contSamps = 10123; // DAQmx_Val_ContSamps

  // Read fill mode (passed as the bool32 fillMode arg of DAQmxReadAnalogF64).
  static const int groupByChannel = 0; // DAQmx_Val_GroupByChannel
  static const int groupByScanNumber = 1; // DAQmx_Val_GroupByScanNumber

  /// `bool32` truthy values.
  static const int boolTrue = 1;
  static const int boolFalse = 0;
}
