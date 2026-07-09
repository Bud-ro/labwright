@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

// Per-VI tallies of decoded object colours: how many objects carry each
// confirmed colour attribute, and how many of those are BOUNDED (drawable).
// [0]=bg total, [1]=bg bounded, [2]=fg total, [3]=fg bounded,
// [4]=content total, [5]=content bounded, [6]=objects, [7]=in-range rgb.
List<int> _tally(Uint8List bytes, String path) {
  final out = List<int>.filled(8, 0);
  final ViModel model;
  try {
    model = buildViModel(bytes);
  } catch (_) {
    return out;
  }
  for (final object in [
    ...model.frontPanelDiagrams.expand((d) => d.objects),
    ...model.blockDiagrams.expand((d) => d.objects),
  ]) {
    out[6]++;
    final bounded = object.absBounds != null;
    for (final rgb in [object.bgRgb, object.fgRgb, object.contentRgb]) {
      if (rgb != null && rgb >= 0 && rgb <= 0xffffff) out[7]++;
    }
    if (object.bgRgb != null) {
      out[0]++;
      if (bounded) out[1]++;
    }
    if (object.fgRgb != null) {
      out[2]++;
      if (bounded) out[3]++;
    }
    if (object.contentRgb != null) {
      out[4]++;
      if (bounded) out[5]++;
    }
  }
  return out;
}

void main() {
  final all = corpusVis();
  if (all.isEmpty) {
    test('object colours (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }

  test('confirmed object colours decode and land on drawable objects', () async {
    final tallies = await corpusParallel(all, _tally);
    final sum = List<int>.filled(8, 0);
    for (final t in tallies) {
      for (var i = 0; i < 8; i++) {
        sum[i] += t[i];
      }
    }
    // ignore: avoid_print
    print(
      'object colours: bg ${sum[1]}/${sum[0]} bounded, '
      'fg ${sum[3]}/${sum[2]} bounded, '
      'content ${sum[5]}/${sum[4]} bounded, over ${sum[6]} objects',
    );
    expect(sum[0], greaterThan(0), reason: 'backgroundColor should decode');
    expect(sum[2], greaterThan(0), reason: 'fgColor should decode');
    expect(sum[4], greaterThan(0), reason: 'contentColor should decode');
    expect(sum[7], sum[0] + sum[2] + sum[4], reason: 'every captured rgb in 0..0xffffff');
    // Placement invariant (discovery: fg 1056287/1056287 = 100% bounded, content
    // 546130/546307 = 99.97%, bg 1287391/1348503 = 95.5%): the confirmed colours
    // land on the drawable object itself, so a renderer can colour an object by
    // its own colour with no part→owner propagation. A colour on an unbounded
    // object is simply not drawn (it has no rectangle).
    expect(sum[3] / sum[2], greaterThan(0.99), reason: 'fgColor is on the drawable object');
    expect(sum[5] / sum[4], greaterThan(0.99), reason: 'contentColor is on the drawable object');
    expect(sum[1] / sum[0], greaterThan(0.9), reason: 'backgroundColor is overwhelmingly on the drawable object');
  });
}
