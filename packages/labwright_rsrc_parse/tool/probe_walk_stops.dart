import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'corpus_base.dart';

/// Where do incomplete heap walks stop? Aggregates, per stopped section: the
/// stopping lead byte, the un-walked byte mass, the section tag, and a hex
/// context sample — the itemization of the `1 - deliberatelyParsed` tail.
///
/// Run: `dart run tool/probe_walk_stops.dart [corpusRoot=<pkg>/corpus/vi]`

class _Agg {
  int sections = 0, stopped = 0;
  int bodyBytes = 0, unwalked = 0;
  final Map<int, int> stopLeadCount = {};
  final Map<int, int> stopLeadBytes = {};
  final Map<String, int> stopSection = {};
  final List<String> samples = [];

  void merge(_Agg o) {
    sections += o.sections;
    stopped += o.stopped;
    bodyBytes += o.bodyBytes;
    unwalked += o.unwalked;
    o.stopLeadCount.forEach((k, v) => stopLeadCount[k] = (stopLeadCount[k] ?? 0) + v);
    o.stopLeadBytes.forEach((k, v) => stopLeadBytes[k] = (stopLeadBytes[k] ?? 0) + v);
    o.stopSection.forEach((k, v) => stopSection[k] = (stopSection[k] ?? 0) + v);
    if (samples.length < 20) samples.addAll(o.samples.take(20 - samples.length));
  }
}

void _probeVi(Uint8List bytes, String path, _Agg agg) {
  final List<DecodedSection> secs;
  try {
    secs = decodeSections(bytes);
  } catch (_) {
    return;
  }
  for (final sec in secs) {
    if (!kHeapSectionTags.contains(sec.tag) || sec.bytes.length < 6) continue;
    final body = sec.bytes;
    final walk = walkHeapBody(body);
    agg.sections++;
    agg.bodyBytes += walk.bodyBytes;
    if (walk.complete) continue;
    agg.stopped++;
    final at = walk.stoppedAtOffset!;
    final lead = walk.stoppedLead!;
    final left = body.length - at;
    agg.unwalked += left;
    agg.stopLeadCount[lead] = (agg.stopLeadCount[lead] ?? 0) + 1;
    agg.stopLeadBytes[lead] = (agg.stopLeadBytes[lead] ?? 0) + left;
    agg.stopSection[sec.tag] = (agg.stopSection[sec.tag] ?? 0) + 1;
    if (agg.samples.length < 20) {
      final from = (at - 8).clamp(0, body.length);
      final to = (at + 24).clamp(0, body.length);
      final hex = [for (var i = from; i < to; i++) body[i].toRadixString(16).padLeft(2, '0')].join(' ');
      agg.samples.add('${path.split('/').last}/${sec.tag}@$at left=$left: …$hex');
    }
  }
}

Future<void> main(List<String> args) async {
  final root = args.isNotEmpty ? args[0] : '${corpusBaseDir().path}/vi';
  final files = listCorpusVis(Directory(root));
  stdout.writeln('corpus: ${files.length} VIs under $root');
  final workers = (Platform.numberOfProcessors - 2).clamp(1, 16);
  final chunks = List.generate(workers, (_) => <String>[]);
  for (var i = 0; i < files.length; i++) {
    chunks[i % workers].add(files[i].path);
  }
  final aggs = await Future.wait(
    chunks.map(
      (chunk) => Isolate.run(() {
        final agg = _Agg();
        for (final p in chunk) {
          _probeVi(File(p).readAsBytesSync(), p, agg);
        }
        return agg;
      }),
    ),
  );
  final agg = _Agg();
  for (final a in aggs) {
    agg.merge(a);
  }
  stdout.writeln(
    'sections=${agg.sections} stopped=${agg.stopped} '
    'unwalked=${agg.unwalked}/${agg.bodyBytes} (${(100 * agg.unwalked / agg.bodyBytes).toStringAsFixed(2)}%)',
  );
  final leads = agg.stopLeadBytes.entries.toList()..sort((a, b) => b.value - a.value);
  for (final e in leads.take(15)) {
    stdout.writeln(
      '  lead 0x${e.key.toRadixString(16).padLeft(2, '0')}: sections=${agg.stopLeadCount[e.key]} '
      'unwalkedBytes=${e.value}',
    );
  }
  stdout.writeln('  by section: ${agg.stopSection}');
  for (final s in agg.samples) {
    stdout.writeln('  $s');
  }
}
