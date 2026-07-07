/// The exit code a lingering suite process uses to ask its `labwright run`
/// supervisor for a FRESH process — the viewer's "Hot restart". A restart is
/// the honest fix for edited test bodies: registered bodies are captured
/// closures, and a VM hot reload cannot re-map an already-captured closure to
/// its edited source; only fresh registration picks the new code up.
/// Deliberately away from dartdev's own 254/255 and sysexits' 64..78.
library;

const int restartExitCode = 249;
