# labwright_nidaqmx

A **pure-Dart FFI wrapper** over NI's own **NI-DAQmx** driver. This is the
*trusted* DAQ backend: where NI supports the platform, it calls NI-DAQmx directly
instead of reverse-engineering the device protocol.

It is designed to be **interchangeable** with the clean-room `qdaq` backend behind
the `labwright_daq` HAL — pick the backend per platform/need:

| Platform | Recommended backend | Why |
|----------|---------------------|-----|
| Windows  | `labwright_nidaqmx` (this) | NI-DAQmx fully supported; trusted, no RE |
| Linux    | `labwright_nidaqmx` (this) | NI-DAQmx supported via NI Linux Device Drivers¹ |
| macOS    | `qdaq` (clean-room)  | **NI ships no DAQmx for macOS** — only the dead NI-DAQmx *Base* (≤ macOS 10.14) |
| CI / dev | `qdaq` (sim)         | No hardware/driver needed |

¹ NI flags incompatibility with default IOMMU settings on Linux kernel 6.8+; see NI's
compatibility docs.

This synergy is intentional: `qdaq` was built **DAQmx-conforming** (same `DAQmx*`
symbols and `DAQmx_Val_*` constants), so this wrapper reuses the exact binding shape,
just pointed at `nicaiu.dll` (Windows) / `libnidaqmx.so` (Linux).

## Status — foundation, validated to compile/analyze; NOT yet run against a runtime

What's here and analyze-clean:

- `loadNidaqmx()` — platform-aware loader (`nicaiu.dll` / `libnidaqmx.so`); throws
  `NidaqmxUnavailable` on macOS or when the runtime is absent.
- `NidaqmxBindings` — hand-written `dart:ffi` bindings to the public NI-DAQmx C API
  (task lifecycle, AI/AO voltage channels, sample-clock timing, scalar + buffered
  reads, scalar write, `GetExtendedErrorInfo`, `GetSysDevNames`).
- `Nidaqmx` facade — `open()`, `deviceNames()`, `readVoltage()`, `writeVoltage()`,
  `errorInfo()`, with a checked-call wrapper that raises `NidaqmxException` carrying
  NI's extended error text (same 0/<0/>0 status convention as `qdaq`).

**Honesty:** these calls have NOT been exercised against a live NI-DAQmx runtime
yet — this environment is WSL2 (NI-DAQmx's kernel modules don't build there) with no
NI runtime installed. The signatures are transcribed from NI's published C reference
and the wrapper compiles + `dart analyze` is clean, but **end-to-end behavior is
unverified until run on a Windows/Linux box with NI-DAQmx installed.** Validate with:

```dart
final ni = Nidaqmx.open();
print(ni.deviceNames());                 // e.g. [cDAQ1, cDAQ1Mod1]
print(ni.readVoltage('cDAQ1Mod1/ai0'));  // one AI sample
```

## Next steps

- `NidaqmxDaq implements DaqDevice` — the HAL adapter (analogIn/analogOut, then
  digital/counter/streaming) so callers swap backends transparently. Deferred until
  it can be validated against a real runtime (shipping an untested HAL adapter would
  overclaim).
- A backend selector in `labwright_daq` (or the app) choosing nidaqmx vs qdaq vs sim
  by platform/availability.
- Buffered/continuous acquisition via `DAQmxReadAnalogF64` (binding already present).

## Clean-room note

This package **wraps** NI's driver through its **public C API** — normal interop,
the supported way to use NI-DAQmx. It does not reimplement or copy NI code; the
clean-room rule applies to `qdaq`, which is a separate, independent implementation.
