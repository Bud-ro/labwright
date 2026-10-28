@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:isolate';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'snippets.dart';

/// The corpus against [kLvPrimSignatures]: every node of a catalogued primitive, whether its
/// holder count has a signature, whether each wired holder's direction agrees with the
/// signature, and whether each terminal whose signature names a type label carries that label
/// when it carries any.
const Map<String, int> kCorpusPrimSignatures = {
  'nodes': 45991,
  'nodes.noSignature': 41,
  'nodes.withSignature': 45950,
  'ops.absent': 13,
  'terminals.dirAgree': 127356,
  'terminals.dirDisagree': 3,
  'terminals.labelAgree': 37589,
  'terminals.labelOther': 6,
  'terminals.unlabelled': 118634,
  'terminals.unwired': 28870,
};

/// Every disagreement, by primitive, child index and the terminal the signature names there:
/// three Generate User Event nodes whose user event terminal is wired as a source, the one
/// File Dialog node drawn from a revision with its string inputs in another order, one Search
/// and Replace String node whose result terminal carries a wire label, and the TDMS Open nodes
/// whose terminal directions contradict their labels.
const Map<String, int> kCorpusPrimSignatureExceptions = {
  'dirDisagree|Generate User Event|0|user event': 3,
  'labelOther|File Dialog|4|pattern label|button label': 1,
  'labelOther|File Dialog|5|button label|pattern label': 1,
  'labelOther|File Dialog|6|pattern (all files)|default name': 1,
  'labelOther|File Dialog|7|prompt|pattern (all files)': 1,
  'labelOther|File Dialog|9|default name|select mode (2:new or exist...)': 1,
  'labelOther|Search and Replace String|4|result string|string': 1,
  'noSignature|TDMS Open|8': 41,
};

/// The primitives no corpus node draws, whose terminal order is therefore not decoded.
const Set<PrimOp> kLvPrimsAbsentFromCorpus = {
  PrimOp.mantissaAndExponent,
  PrimOp.dateTimeToSeconds,
  PrimOp.secondsToDateTime,
  PrimOp.rotateLeftWithCarry,
  PrimOp.udpOpen,
  PrimOp.udpRead,
  PrimOp.udpWrite,
  PrimOp.udpClose,
  PrimOp.visaClear,
  PrimOp.tdmsRead,
  PrimOp.tdmsListContents,
  PrimOp.fixedPointToIntegerCast,
  PrimOp.getFilePosition,
};

Map<String, int> probeChunk(List<String> paths) {
  final tally = <String, int>{};
  void bump(String key, [int by = 1]) => tally[key] = (tally[key] ?? 0) + by;
  for (final path in paths) {
    LvViUnit? unit;
    try {
      unit = LvViUnit.fromSections(
        decodeSections(File(path).readAsBytesSync()),
        fileName: path.split(Platform.pathSeparator).last,
        path: path,
      );
    } catch (_) {
      continue;
    }
    if (unit == null) continue;
    final diagram = unit.diagram;
    final wired = <int>{};
    for (final wire in diagram.wires) {
      wired.addAll(wire.endpointOids);
    }
    for (final node in diagram.objects) {
      if (node.category != BdObjectKind.node) continue;
      final id = node.primitive?.primResId;
      final op = id == null ? null : PrimOp.fromId(id);
      if (op == null) continue;
      bump('nodes');
      final holders = [
        for (final holder in diagram.childrenOf(node))
          if (holder.objectClass == BdObjectClass.terminalHolder) holder,
      ];
      final signature = LvPrimSignature.of(op, holders.length);
      if (signature == null) {
        bump('nodes.noSignature');
        bump('noSignature|${op.opName}|${holders.length}');
        continue;
      }
      bump('nodes.withSignature');
      for (var i = 0; i < holders.length; i++) {
        final holder = holders[i];
        final spec = signature.terminals[i];
        if (!wired.contains(holder.oid)) {
          bump('terminals.unwired');
        } else {
          final sink = lvEndpointIsSink(holder);
          if (sink == spec.isInput) {
            bump('terminals.dirAgree');
          } else {
            bump('terminals.dirDisagree');
            bump('dirDisagree|${op.opName}|$i|${spec.name}');
          }
        }
        final label = diagram.childrenOf(holder).firstOrNull?.typeName;
        if (spec.labels.isEmpty) {
          bump('terminals.unlabelled');
        } else if (label == null || spec.labels.contains(label)) {
          bump('terminals.labelAgree');
        } else {
          bump('terminals.labelOther');
          bump('labelOther|${op.opName}|$i|${spec.labels.first}|$label');
        }
      }
    }
  }
  return tally;
}

void main() {
  test('every catalogued primitive has a signature or is absent from the corpus', () {
    final signed = kLvPrimSignatures.keys.toSet();
    expect(PrimOp.values.toSet().difference(signed), kLvPrimsAbsentFromCorpus);
    expect(signed.intersection(kLvPrimsAbsentFromCorpus), isEmpty);
    for (final signatures in kLvPrimSignatures.values) {
      for (final signature in signatures) {
        final names = signature.terminals.map((terminal) => terminal.name).toSet();
        expect(names, hasLength(signature.length), reason: '${signature.op.opName} repeats a terminal name');
      }
    }
  });

  test(
    'the signatures agree with every wired terminal direction and fixed type label in the corpus',
    () async {
      final paths = corpusViPaths();
      final workers = (Platform.numberOfProcessors - 2).clamp(1, 16);
      final chunks = List.generate(workers, (_) => <String>[]);
      for (var i = 0; i < paths.length; i++) {
        chunks[i % workers].add(paths[i]);
      }
      final results = await Future.wait(chunks.map((chunk) => Isolate.run(() => probeChunk(chunk))));
      final tally = <String, int>{};
      for (final result in results) {
        result.forEach((key, value) => tally[key] = (tally[key] ?? 0) + value);
      }
      final absent = <PrimOp>{...kLvPrimsAbsentFromCorpus};
      for (final key in tally.keys) {
        if (!key.contains('|')) continue;
        final op = key.split('|')[1];
        absent.removeWhere((candidate) => candidate.opName == op);
      }
      tally['ops.absent'] = absent.length;
      final summary = {
        for (final entry in tally.entries)
          if (!entry.key.contains('|')) entry.key: entry.value,
      };
      final detail = [
        for (final key in tally.keys.toList()..sort())
          if (key.contains('|')) '  $key: ${tally[key]}',
      ];
      printOnFailure(
        'measured:\n${[for (final key in summary.keys.toList()..sort()) "  '$key': ${summary[key]},"].join('\n')}\n${detail.join('\n')}',
      );
      expect(summary, kCorpusPrimSignatures);
      expect({
        for (final entry in tally.entries)
          if (entry.key.contains('|')) entry.key: entry.value,
      }, kCorpusPrimSignatureExceptions);
    },
  );
}
