@Tags(['corpus'])
library;

import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

// Per-VI tallies of decoded object colours: how many objects carry each colour
// attribute, and how many of those are BOUNDED (drawable).
// [0]=bg total, [1]=bg bounded, [2]=fg total, [3]=fg bounded,
// [4]=content total, [5]=content bounded, [6]=objects, [7]=in-range rgb,
// [8]=struct total, [9]=struct bounded, [10]=struct on a BD structure object,
// [11]=border total, [12]=struct+border in-range rgb,
// [13]=plot objects, [14]=plot objects that are bounded (drawable),
// [15]=plot colour entries, [16]=plot entries in range,
// [17]=plot objects that are a graphIndicator.
List<int> _tally(Uint8List bytes, String path) {
  final out = List<int>.filled(18, 0);
  final ViModel model;
  try {
    model = buildViModel(bytes);
  } catch (_) {
    return out;
  }
  bool inRange(int? rgb) => rgb != null && rgb >= 0 && rgb <= 0xffffff;
  for (final diagram in [
    ...model.frontPanelDiagrams,
    ...model.blockDiagrams,
  ]) {
    final isBd = diagram.sectionTag == 'BDHb';
    for (final object in diagram.objects) {
      out[6]++;
      final bounded = object.absBounds != null;
      for (final rgb in [object.bgRgb, object.fgRgb, object.contentRgb]) {
        if (inRange(rgb)) out[7]++;
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
      if (object.structRgb != null) {
        out[8]++;
        if (bounded) out[9]++;
        if (isBd && object.category == ViObjectKind.structure) out[10]++;
      }
      if (object.borderRgb != null) out[11]++;
      if (inRange(object.structRgb)) out[12]++;
      if (inRange(object.borderRgb)) out[12]++;
      if (object.plotColors.isNotEmpty) {
        out[13]++;
        if (bounded) out[14]++;
        out[15] += object.plotColors.length;
        out[16] += object.plotColors.where(inRange).length;
        if (object.objectClass == HeapObjectClass.graphIndicator) out[17]++;
      }
    }
  }
  return out;
}

void main() {
  final all = corpusVis();

  test('object colours decode and land on drawable objects', () async {
    final tallies = await corpusParallel(all, _tally);
    final sum = List<int>.filled(18, 0);
    for (final t in tallies) {
      for (var i = 0; i < 18; i++) {
        sum[i] += t[i];
      }
    }
    // ignore: avoid_print
    print(
      'object colours: bg ${sum[1]}/${sum[0]} bounded, '
      'fg ${sum[3]}/${sum[2]} bounded, '
      'content ${sum[5]}/${sum[4]} bounded, '
      'struct ${sum[10]}/${sum[8]} on a BD structure, '
      'border ${sum[11]}, '
      'plot ${sum[15]} colours over ${sum[13]} objects (${sum[14]} bounded), '
      'over ${sum[6]} objects',
    );
    expect(sum[0], greaterThan(0), reason: 'backgroundColor should decode');
    expect(sum[2], greaterThan(0), reason: 'fgColor should decode');
    expect(sum[4], greaterThan(0), reason: 'contentColor should decode');
    expect(sum[8], greaterThan(0), reason: 'structColor should decode');
    expect(sum[11], greaterThan(0), reason: 'borderColor should decode');
    expect(sum[15], greaterThan(0), reason: 'plotColor should decode');
    expect(sum[7], sum[0] + sum[2] + sum[4], reason: 'every confirmed rgb in 0..0xffffff');
    expect(sum[12], sum[8] + sum[11], reason: 'every struct/border rgb in 0..0xffffff');
    expect(sum[16], sum[15], reason: 'every plot rgb in 0..0xffffff');
    expect(sum[14], sum[13], reason: 'every plotColor carrier is drawable');
    expect(sum[17], sum[13], reason: 'every plotColor carrier is a graph');
    expect(sum[3] / sum[2], greaterThan(0.99), reason: 'fgColor is on the drawable object');
    expect(sum[5] / sum[4], greaterThan(0.99), reason: 'contentColor is on the drawable object');
    expect(sum[1] / sum[0], greaterThan(0.9), reason: 'backgroundColor is overwhelmingly on the drawable object');
    expect(sum[9] / sum[8], greaterThan(0.9), reason: 'structColor is on the drawable object');
    expect(sum[10] / sum[8], greaterThan(0.9), reason: 'structColor is on a BD structure object');
  });
}
