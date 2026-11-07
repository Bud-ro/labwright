@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:isolate';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'snippets.dart';

const Set<String> kCorpusPrimSignatureExceptions = {
  'dirDisagree|Generate User Event|0|user event',
  'labelOther|File Dialog|4|pattern label|button label',
  'labelOther|File Dialog|5|button label|pattern label',
  'labelOther|File Dialog|6|pattern (all files)|default name',
  'labelOther|File Dialog|7|prompt|pattern (all files)',
  'labelOther|File Dialog|9|default name|select mode (2:new or exist...)',
  'labelOther|Search and Replace String|4|result string|string',
  'noSignature|TDMS Open|8',
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

Set<String> probeChunk(List<String> paths) {
  final found = <String>{};
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
    final wired = {for (final wire in diagram.wires) ...wire.endpointOids};
    for (final node in diagram.objects) {
      if (node.category != BdObjectKind.node) continue;
      final id = node.primitive?.primResId;
      final op = id == null ? null : PrimOp.fromId(id);
      if (op == null) continue;
      found.add('op|${op.opName}');
      final holders = [
        for (final holder in diagram.childrenOf(node))
          if (holder.objectClass == BdObjectClass.terminalHolder) holder,
      ];
      final signature = LvPrimSignature.of(op, holders.length);
      if (signature == null) {
        found.add('noSignature|${op.opName}|${holders.length}');
        continue;
      }
      for (var i = 0; i < holders.length; i++) {
        final holder = holders[i];
        final spec = signature.terminals[i];
        if (wired.contains(holder.oid) && lvEndpointIsSink(holder) != spec.isInput) {
          found.add('dirDisagree|${op.opName}|$i|${spec.name}');
        }
        final label = diagram.childrenOf(holder).firstOrNull?.typeName;
        if (spec.labels.isNotEmpty && label != null && !spec.labels.contains(label)) {
          found.add('labelOther|${op.opName}|$i|${spec.labels.first}|$label');
        }
      }
    }
  }
  return found;
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
  test('the signatures agree with every wired terminal direction and fixed type label in the corpus', () async {
    final paths = corpusViPaths();
    final workers = (Platform.numberOfProcessors - 2).clamp(1, 16);
    final chunks = List.generate(workers, (_) => <String>[]);
    for (var i = 0; i < paths.length; i++) {
      chunks[i % workers].add(paths[i]);
    }
    final found = {
      for (final result in await Future.wait(chunks.map((c) => Isolate.run(() => probeChunk(c))))) ...result,
    };
    expect(found.where((key) => !key.startsWith('op|')).toSet(), kCorpusPrimSignatureExceptions);
    expect(kLvPrimsAbsentFromCorpus.where((op) => found.contains('op|${op.opName}')), isEmpty);
  });
}
