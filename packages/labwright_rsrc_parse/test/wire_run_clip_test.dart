import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'wire_style_oracle.dart';

/// Unit coverage for [clipRunOutOfRects] — the geometry the wire-style oracle
/// uses to keep constant-shell pixels out of sampled wire runs. Exercised in
/// bulk by the corpus census; this pins its 0/1/2 sub-run edge cases directly.
///
/// Convention: a horizontal run cut by rect `[left..right]` drops the closed
/// band `[left-1 .. right+1]` (the 1-unit border margin), and each surviving
/// sub-run must span at least 2 units (hi - lo >= 1) or it is dropped.
void main() {
  ({bool horizontal, int axisPos, int lo, int hi}) r(WireRun run) =>
      (horizontal: run.horizontal, axisPos: run.axisPos, lo: run.lo, hi: run.hi);

  HeapRect rect(int top, int left, int bottom, int right) =>
      HeapRect(top: top, left: left, bottom: bottom, right: right);

  test('no rect / out-of-band rect: run passes through unchanged', () {
    final run = WireRun(1, true, 50, 10, 90);
    expect(clipRunOutOfRects(run, const []).map(r), [r(run)]);
    // Rect on the same axis span but a different row (perpendicular miss).
    expect(clipRunOutOfRects(run, [rect(0, 40, 10, 60)]).map(r), [r(run)]);
    // Rect in-band but entirely left of the run.
    expect(clipRunOutOfRects(run, [rect(40, -20, 60, 0)]).map(r), [r(run)]);
  });

  test('rect at a run end: one trimmed sub-run', () {
    // Shell [8..24] at the left end of a run [10..90] cuts [7..25] -> [26..90].
    final out = clipRunOutOfRects(WireRun(1, true, 50, 10, 90), [rect(42, 8, 58, 24)]);
    expect(out.map(r), [(horizontal: true, axisPos: 50, lo: 26, hi: 90)]);
  });

  test('rect crossing mid-run: two sub-runs', () {
    // Shell [40..50] mid-run cuts [39..51] -> [10..38] and [52..90].
    final out = clipRunOutOfRects(WireRun(1, true, 50, 10, 90), [rect(42, 40, 58, 50)]);
    expect(out.map(r), [
      (horizontal: true, axisPos: 50, lo: 10, hi: 38),
      (horizontal: true, axisPos: 50, lo: 52, hi: 90),
    ]);
  });

  test('rect swallowing the run: zero sub-runs', () {
    // Shell [0..100] covers the whole run [10..90].
    expect(clipRunOutOfRects(WireRun(1, true, 50, 10, 90), [rect(42, 0, 58, 100)]), isEmpty);
  });

  test('sub-run shorter than 2 units is dropped', () {
    // The cut band is [left-1 .. right+1]. Shell left=13 cuts [12..] and
    // leaves [10..11] — length 1 (hi - lo == 1) survives; shell left=12 cuts
    // [11..] and leaves [10..10] which is dropped.
    expect(clipRunOutOfRects(WireRun(1, true, 50, 10, 90), [rect(42, 13, 58, 90)]).map(r), [
      (horizontal: true, axisPos: 50, lo: 10, hi: 11),
    ]);
    expect(clipRunOutOfRects(WireRun(1, true, 50, 10, 90), [rect(42, 12, 58, 90)]), isEmpty);
  });

  test('vertical run is cut on the column axis', () {
    // Vertical run at x=50 spanning y [10..90]; shell rows [40..50] at x [42..58].
    final out = clipRunOutOfRects(WireRun(1, false, 50, 10, 90), [rect(40, 42, 50, 58)]);
    expect(out.map(r), [
      (horizontal: false, axisPos: 50, lo: 10, hi: 38),
      (horizontal: false, axisPos: 50, lo: 52, hi: 90),
    ]);
  });

  test('two rects cut independently', () {
    // Two mid-run shells [30..36] and [60..66] -> three sub-runs.
    final out = clipRunOutOfRects(WireRun(1, true, 50, 10, 90), [
      rect(42, 30, 58, 36),
      rect(42, 60, 58, 66),
    ]);
    expect(out.map(r), [
      (horizontal: true, axisPos: 50, lo: 10, hi: 28),
      (horizontal: true, axisPos: 50, lo: 38, hi: 58),
      (horizontal: true, axisPos: 50, lo: 68, hi: 90),
    ]);
  });
}
