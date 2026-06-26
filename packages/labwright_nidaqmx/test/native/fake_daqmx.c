// A tiny stand-in for NI's DAQmx shared library, built only for tests. It exports
// the exact symbols labwright_nidaqmx's FFI bindings look up, with the real C ABI, so
// loading it via `Daqmx.local(libraryPath: <this>.so)` exercises the genuine FFI
// marshalling path end-to-end — wrong widths/signs/pointers would actually surface.
// It returns distinguishable magic/echo values and captures the last call's arguments
// behind `fake_last_*` getters so tests can assert what crossed the boundary. The goal
// is to be ~90% of a real DLL: same surface, deterministic data, no hardware.
//
// Build (done by the test harness):  cc -shared -fPIC -o fake_daqmx.so fake_daqmx.c
//
// Conventions mirrored from DAQmx: int32 status (0 ok, <0 error), TaskHandle = void*,
// bool32 = int32, float64 = double. A physical-channel name containing "fail" makes
// channel creation return a negative status (to drive the error path).

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef void* TaskHandle;

// Per-task state, allocated by CreateTask and freed by ClearTask. Read functions cast
// the handle back to this, so a value read out proves the create/config/read chain
// marshalled correctly.
typedef struct {
  double min, max;
  int32_t termCfg, units;
  double rate;
  int32_t sampleMode;
  uint64_t sampsPerChan;
  int64_t counter; // running sample index for streaming continuity
  char chan[256];
} FakeTask;

// Snapshot of the most recent calls, exposed via getters below.
static double g_ai_min, g_ai_max;
static int32_t g_ai_term, g_ai_units;
static char g_last_chan[256];
static double g_write_value, g_write_timeout;
static int32_t g_write_autostart;
static double g_rate;
static int32_t g_sample_mode;
static const double kMagicScalar = 4.2; // distinguishable scalar-read magic

static const char* kDevNames = "FakeDev1, FakeDev1Mod1";
static const char* kErrText = "FAKE-DAQmx: simulated extended error info";

// --- getters the tests read directly (not part of DAQmx) ---
double fake_last_ai_min(void) { return g_ai_min; }
double fake_last_ai_max(void) { return g_ai_max; }
int32_t fake_last_ai_term(void) { return g_ai_term; }
int32_t fake_last_ai_units(void) { return g_ai_units; }
const char* fake_last_chan(void) { return g_last_chan; }
double fake_last_write_value(void) { return g_write_value; }
double fake_last_write_timeout(void) { return g_write_timeout; }
int32_t fake_last_write_autostart(void) { return g_write_autostart; }
double fake_last_rate(void) { return g_rate; }
int32_t fake_last_sample_mode(void) { return g_sample_mode; }

// --- DAQmx surface ---
int32_t DAQmxCreateTask(const char* name, TaskHandle* taskOut) {
  (void)name;
  FakeTask* t = (FakeTask*)calloc(1, sizeof(FakeTask));
  *taskOut = (TaskHandle)t;
  return 0;
}

int32_t DAQmxCreateAIVoltageChan(TaskHandle task, const char* phys, const char* assigned,
                                 int32_t termCfg, double min, double max, int32_t units,
                                 const char* customScale) {
  (void)assigned; (void)customScale;
  FakeTask* t = (FakeTask*)task;
  if (t) { t->min = min; t->max = max; t->termCfg = termCfg; t->units = units;
           strncpy(t->chan, phys ? phys : "", sizeof(t->chan) - 1); }
  g_ai_min = min; g_ai_max = max; g_ai_term = termCfg; g_ai_units = units;
  strncpy(g_last_chan, phys ? phys : "", sizeof(g_last_chan) - 1);
  if (phys && strstr(phys, "fail")) return -200279; // exercise the error path
  return 0;
}

int32_t DAQmxCreateAOVoltageChan(TaskHandle task, const char* phys, const char* assigned,
                                 double min, double max, int32_t units, const char* customScale) {
  (void)assigned; (void)customScale;
  FakeTask* t = (FakeTask*)task;
  if (t) { t->min = min; t->max = max; t->units = units;
           strncpy(t->chan, phys ? phys : "", sizeof(t->chan) - 1); }
  g_ai_min = min; g_ai_max = max; g_ai_units = units;
  strncpy(g_last_chan, phys ? phys : "", sizeof(g_last_chan) - 1);
  if (phys && strstr(phys, "fail")) return -200279;
  return 0;
}

int32_t DAQmxCfgSampClkTiming(TaskHandle task, const char* src, double rate, int32_t edge,
                              int32_t sampleMode, uint64_t sampsPerChan) {
  (void)src; (void)edge;
  FakeTask* t = (FakeTask*)task;
  if (t) { t->rate = rate; t->sampleMode = sampleMode; t->sampsPerChan = sampsPerChan; }
  g_rate = rate; g_sample_mode = sampleMode;
  return 0;
}

int32_t DAQmxStartTask(TaskHandle task) { (void)task; return 0; }
int32_t DAQmxStopTask(TaskHandle task) { (void)task; return 0; }

int32_t DAQmxClearTask(TaskHandle task) {
  free((FakeTask*)task);
  return 0;
}

int32_t DAQmxReadAnalogScalarF64(TaskHandle task, double timeout, double* value, int32_t* reserved) {
  (void)task; (void)timeout; (void)reserved;
  if (value) *value = kMagicScalar;
  return 0;
}

// Fills readArray with a continuous ramp (sample N = task counter + i) so tests can
// assert chunk size, ordering, and continuity across reads.
int32_t DAQmxReadAnalogF64(TaskHandle task, int32_t numSampsPerChan, double timeout,
                           int32_t fillMode, double* readArray, uint32_t arraySizeInSamps,
                           int32_t* sampsPerChanRead, int32_t* reserved) {
  (void)timeout; (void)fillMode; (void)reserved;
  FakeTask* t = (FakeTask*)task;
  int32_t n = numSampsPerChan;
  if ((uint32_t)n > arraySizeInSamps) n = (int32_t)arraySizeInSamps;
  for (int32_t i = 0; i < n; i++) {
    readArray[i] = (double)((t ? t->counter : 0) + i);
  }
  if (t) t->counter += n;
  if (sampsPerChanRead) *sampsPerChanRead = n;
  return 0;
}

// Binary (raw ADC-code) block reads — the practical high-speed formats. Each fills a
// continuous ramp in the native element type so tests can assert width, count, and
// cross-chunk continuity. Same shape as ReadAnalogF64, differing only in element type.
#define FAKE_READ_BINARY(NAME, CTYPE)                                                       \
  int32_t NAME(TaskHandle task, int32_t numSampsPerChan, double timeout, int32_t fillMode,  \
               CTYPE* readArray, uint32_t arraySizeInSamps, int32_t* sampsPerChanRead,      \
               int32_t* reserved) {                                                         \
    (void)timeout; (void)fillMode; (void)reserved;                                          \
    FakeTask* t = (FakeTask*)task;                                                          \
    int32_t n = numSampsPerChan;                                                            \
    if ((uint32_t)n > arraySizeInSamps) n = (int32_t)arraySizeInSamps;                      \
    for (int32_t i = 0; i < n; i++) readArray[i] = (CTYPE)((t ? t->counter : 0) + i);       \
    if (t) t->counter += n;                                                                 \
    if (sampsPerChanRead) *sampsPerChanRead = n;                                            \
    return 0;                                                                               \
  }
FAKE_READ_BINARY(DAQmxReadBinaryI16, int16_t)
FAKE_READ_BINARY(DAQmxReadBinaryI32, int32_t)
FAKE_READ_BINARY(DAQmxReadBinaryU16, uint16_t)
FAKE_READ_BINARY(DAQmxReadBinaryU32, uint32_t)

int32_t DAQmxWriteAnalogScalarF64(TaskHandle task, int32_t autoStart, double timeout,
                                  double value, int32_t* reserved) {
  (void)task; (void)reserved;
  g_write_autostart = autoStart; g_write_timeout = timeout; g_write_value = value;
  return 0;
}

// NI convention: bufferSize 0 (or NULL buffer) returns the required length, so the
// Dart side can probe-then-allocate.
int32_t DAQmxGetSysDevNames(char* data, uint32_t bufferSize) {
  uint32_t need = (uint32_t)strlen(kDevNames) + 1;
  if (!data || bufferSize == 0) return (int32_t)need;
  strncpy(data, kDevNames, bufferSize - 1);
  data[bufferSize - 1] = 0;
  return 0;
}

int32_t DAQmxGetExtendedErrorInfo(char* data, uint32_t bufferSize) {
  if (!data || bufferSize == 0) return (int32_t)(strlen(kErrText) + 1);
  strncpy(data, kErrText, bufferSize - 1);
  data[bufferSize - 1] = 0;
  return 0;
}
