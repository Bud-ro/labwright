import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'wire_style_oracle.dart';

void main() {
  ({bool horizontal, int axisPos, int lo, int hi}) r(WireRun run) =>
      (horizontal: run.horizontal, axisPos: run.axisPos, lo: run.lo, hi: run.hi);

  HeapRect rect(int top, int left, int bottom, int right) =>
      HeapRect(top: top, left: left, bottom: bottom, right: right);

  test('no rect / out-of-band rect: run passes through unchanged', () {
    final run = WireRun(1, true, 50, 10, 90);
    expect(clipRunOutOfRects(run, const []).map(r), [r(run)]);
    expect(clipRunOutOfRects(run, [rect(0, 40, 10, 60)]).map(r), [r(run)]);
    expect(clipRunOutOfRects(run, [rect(40, -20, 60, 0)]).map(r), [r(run)]);
  });

  test('rect at a run end: one trimmed sub-run', () {
    final out = clipRunOutOfRects(WireRun(1, true, 50, 10, 90), [rect(42, 8, 58, 24)]);
    expect(out.map(r), [(horizontal: true, axisPos: 50, lo: 26, hi: 90)]);
  });

  test('rect crossing mid-run: two sub-runs', () {
    final out = clipRunOutOfRects(WireRun(1, true, 50, 10, 90), [rect(42, 40, 58, 50)]);
    expect(out.map(r), [
      (horizontal: true, axisPos: 50, lo: 10, hi: 38),
      (horizontal: true, axisPos: 50, lo: 52, hi: 90),
    ]);
  });

  test('rect swallowing the run: zero sub-runs', () {
    expect(clipRunOutOfRects(WireRun(1, true, 50, 10, 90), [rect(42, 0, 58, 100)]), isEmpty);
  });

  test('sub-run shorter than 2 units is dropped', () {
    expect(clipRunOutOfRects(WireRun(1, true, 50, 10, 90), [rect(42, 13, 58, 90)]).map(r), [
      (horizontal: true, axisPos: 50, lo: 10, hi: 11),
    ]);
    expect(clipRunOutOfRects(WireRun(1, true, 50, 10, 90), [rect(42, 12, 58, 90)]), isEmpty);
  });

  test('vertical run is cut on the column axis', () {
    final out = clipRunOutOfRects(WireRun(1, false, 50, 10, 90), [rect(40, 42, 50, 58)]);
    expect(out.map(r), [
      (horizontal: false, axisPos: 50, lo: 10, hi: 38),
      (horizontal: false, axisPos: 50, lo: 52, hi: 90),
    ]);
  });

  test('two rects cut independently', () {
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
