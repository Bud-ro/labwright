/// The lowering sweep: what each tracked VI snippet's block diagram does when
/// it is lowered, what stands in the way of the rest, and — over the whole
/// fetched `.vi` corpus — how subVI calls bind and what the two error modes
/// make of it.
///
/// Every half is pinned as data, so progress and regression are equally
/// visible: a VI that starts lowering, and a VI that stops, both fail here
/// until the pin is updated to the measured value.
///
/// [kSnippetLoweringOutcomes] is the per-VI outcome; [kSnippetPrimReviewList]
/// is the primitive review list — every operation the corpus uses that has no
/// lowering rule, with how often it appears; [kCorpusLoweringSweep] is the
/// whole-corpus tally. Nothing on the review list is guessed at: an entry
/// leaves it only when its identity *and* its operand roles are decoded (see
/// `kLvMappedPrimOps`).
library;

import 'dart:io';
import 'dart:isolate';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'snippets.dart';

/// Per snippet, the outcome of lowering its block diagram: `lowered`, or the
/// [LvRefusalKind] naming the decoded fact that is missing.
///
/// The refusals concentrate in three places, and each names real work:
/// `wireType` — cluster wires whose endpoints resolve no member shape (see
/// [kSnippetClusterWires]) and the wire codes with no pinned array-depth base;
/// `primitive` — the review list below; `wireDirection` — the 0.8% of corpus
/// signals whose endpoints do not resolve exactly one source.
///
/// `MD5` is the largest diagram here and refuses on `primitive`. Its every
/// constant, structure and wire decodes; what stands in the way is identity:
/// 20 of its nodes carry the primResIDs 1056, 1082, 1155, 1156, 1162, 1163
/// and 1181, and not one of those ids is labelled anywhere in the 7 524-VI
/// corpus, so none can be named from evidence. The rest of its refusals are
/// ordinary review-list entries.
const Map<String, String> kSnippetLoweringOutcomes = {
  'ClassChildren': 'wireType',
  'ClassesInMemory': 'subViCall',
  'Config_Dump': 'wireType',
  'Config_Dump2': 'wireType',
  'Config_Escape': 'caseSelector',
  'Config_Load': 'wireType',
  'Config_Load2': 'wireType',
  'Excel_Cell_to_RowCol': 'primitive',
  'Excel_Cell_to_Value': 'wireType',
  'Excel_Read_XLSX': 'wireType',
  'Excel_Variant_Elements': 'wireType',
  'Export Palette Image WMF': 'wireType',
  'FileReadOnly': 'wireType',
  'GenerateTree': 'wireType',
  'GetCurrentDirectory': 'wireType',
  'IconHeader': 'wireType',
  'MD5': 'primitive',
  'PNG CRC32': 'constantValue',
  'Page1': 'wireType',
  'Pages': 'wireType',
  'ProjectItems': 'wireType',
  'Read Library Version': 'wireType',
  'Read VI Blocks': 'wireType',
  'Resolve Library Path': 'wireType',
  'Resolve Path': 'primitive',
  'ReverseBitsVim': 'primitive',
  'Symbols1Bit': 'wireType',
  'Tokenize URL': 'constantValue',
  'VI Tree': 'lowered',
  'VISA_InterfaceType': 'wireType',
  'VISA_Open2': 'wireType',
  'VISA_Query': 'wireType',
  'WriteConsole': 'wireType',
  'basic': 'lowered',
  'broken_wires_only': 'wireDirection',
  'crc16': 'primitive',
  'crc32': 'primitive',
  'crc32_lookup_table': 'primitive',
  'crc8': 'lowered',
  'decorations_only': 'lowered',
  'example': 'wireType',
  'fg': 'structure',
  'large': 'wireType',
  'missing_terminal': 'wireDirection',
  'sub_vi_missing': 'wireDirection',
  'vi_lib_dependency': 'wireType',
};

/// The **primitive review list**: every operation the snippet corpus uses that
/// has no lowering rule and appears at least [kReviewListFloor] times, with its
/// occurrence count. An entry keyed by class code is a node whose class is its
/// identity but whose operation this reader has not named; one keyed by a bare
/// `primResID` is a node whose id [PrimOp] does not name.
const Map<String, int> kSnippetPrimReviewList = {
  'Match Pattern (primResID 1535)': 134,
  'node class 0x63': 83,
  'node class 0x3a': 39,
  'Type Cast (primResID 1166)': 34,
  'node class 0x3e': 31,
  'String Subset (primResID 1503)': 24,
  'Empty String/Path? (primResID 1112)': 23,
  'node class 0x93': 18,
  'Select (primResID 1516)': 16,
  'node class 0x105': 16,
  'node class 0xa9': 15,
  'Array Size (primResID 1809)': 15,
  'Subtract (primResID 1051)': 15,
  'node class 0x172': 14,
  'node class 0x150': 12,
  'node class 0x6a': 12,
  'Search 1D Array (primResID 1901)': 11,
  'primResID 1171 (name not decoded)': 11,
  'primResID 8051 (name not decoded)': 11,
  'primResID 1534 (name not decoded)': 11,
  'String Length (primResID 1502)': 10,
};

/// How the snippet corpus's **cluster wires** resolve. A cluster wire's member
/// types are not in its signal word, so they come from the data-space type an
/// endpoint of the wire resolves ([lvClusterOfEndpoint]) — which is the only
/// route there is, and covers a minority of wires. Pinned so the coverage
/// cannot fall silently.
const ({int signals, int resolved, int disagreeing, int unresolved}) kSnippetClusterWires = (
  signals: 729,
  resolved: 337,
  disagreeing: 13,
  unresolved: 379,
);

/// The snippets whose outcome differs under [LvErrorMode.threaded]. It is
/// **empty**: the two modes differ only where an error cluster reaches the
/// connector pane, and no tracked snippet lowers far enough for that to
/// matter. The corpus does show the difference — see the corpus sweep below,
/// which is where the mode is measured.
const Map<String, String> kSnippetThreadedDifferences = <String, String>{};

/// How the whole `.vi` corpus's **subVI calls** bind through the connector
/// pane, and what the two error modes make of the corpus as a whole.
///
/// Keys are the counter names [sweepLoweringChunk] tallies. The binding chain
/// is what proves the pane contract: `term.dirAgree` against `term.dirDisagree`
/// compares the caller's own wire direction with the callee control's, and
/// `term.typeAgree` against `term.typeDisagree` compares the two VIs' wire
/// types — neither is used to *derive* the binding, so both are independent
/// checks on it.
///
/// The `cond.*` counters are the While-loop conditional terminal census
/// ([LvTerminalRole.conditional]): one glyph selector on every drawn terminal
/// (`cond.glyph192` = `cond` minus `cond.glyphNone`), and two flag bits that
/// vary without changing anything LabVIEW draws. They size the refusal — a
/// second glyph value appearing here is the evidence that would settle the
/// polarity.
const Map<String, int> kCorpusLoweringSweep = {
  'call': 1290,
  'call.calleeMissing': 159,
  'call.noPaneMap': 567,
  'call.paneMatched': 545,
  'call.paneWidthMismatch': 6,
  'call.unnamed': 13,
  'cond': 2267,
  'cond.dcoBit0': 382,
  'cond.dcoBit12': 140,
  'cond.glyph192': 1892,
  'cond.glyphNone': 375,
  'exceptions.caseSelector': 60,
  'exceptions.constantValue': 66,
  'exceptions.lowered': 135,
  'exceptions.primitive': 167,
  'exceptions.structure': 53,
  'exceptions.subViCall': 57,
  'exceptions.tunnelIndexing': 1,
  'exceptions.unboundValue': 1,
  'exceptions.unwiredTerminal': 53,
  'exceptions.wireDirection': 66,
  'exceptions.wireType': 6849,
  'modes.same': 135,
  'term.calleeUntyped': 115,
  'term.dirAgree': 304,
  'term.resolved': 304,
  'term.typeAgree': 189,
  'term.unresolved': 33,
  'term.wired': 337,
  'threaded.caseSelector': 60,
  'threaded.constantValue': 66,
  'threaded.lowered': 135,
  'threaded.primitive': 167,
  'threaded.structure': 53,
  'threaded.subViCall': 57,
  'threaded.tunnelIndexing': 1,
  'threaded.unboundValue': 1,
  'threaded.unwiredTerminal': 53,
  'threaded.wireDirection': 66,
  'threaded.wireType': 6849,
  'vi': 7508,
};

/// The occurrence count at which a review-list entry is pinned individually;
/// the tail below it is pinned only by [kReviewListTotals].
const int kReviewListFloor = 10;

/// The review list's shape: how many distinct unmapped identities the snippet
/// corpus holds, and how many node instances they account for.
const ({int identities, int nodes}) kReviewListTotals = (identities: 122, nodes: 878);

/// Lowers every VI in [paths], resolving subVI calls against [index] (a
/// `file name → path` map over the whole corpus), and tallies both the
/// connector-pane binding of every call node and the per-mode outcome.
Map<String, int> sweepLoweringChunk((List<String>, Map<String, String>) input) {
  final (paths, index) = input;
  final tally = <String, int>{};
  void bump(String key) => tally[key] = (tally[key] ?? 0) + 1;
  final units = <String, LvViUnit?>{};
  final flows = <String, LvDataflow?>{};
  LvViUnit? load(String path, String fileName) => units.putIfAbsent(path, () {
    try {
      return LvViUnit.fromSections(decodeSections(File(path).readAsBytesSync()), fileName: fileName);
    } catch (_) {
      return null;
    }
  });
  LvViUnit? resolve(String name) {
    final path = index[name.toLowerCase()];
    return path == null ? null : load(path, name);
  }

  LvDataflow? flowOf(LvViUnit unit) =>
      flows.putIfAbsent(unit.fileName, () => buildLvDataflow(unit.diagram, pool: unit.pool).dataflow);

  void bindCall(LvDataflow flow, LvSubViUnit call) {
    bump('call');
    if (call.calleeName == null) return bump('call.unnamed');
    final callee = resolve(call.calleeName!);
    if (callee == null) return bump('call.calleeMissing');
    if (callee.paneMap.isEmpty) return bump('call.noPaneMap');
    if (callee.paneMap.length != call.panePorts.length) return bump('call.paneWidthMismatch');
    bump('call.paneMatched');
    final calleeFlow = flowOf(callee);
    for (var pane = 0; pane < call.panePorts.length; pane++) {
      final holder = call.panePorts[pane];
      final into = flow.into(holder), outOf = flow.outOf(holder);
      if (into == null && outOf == null) continue;
      bump('term.wired');
      final terminal = callee.paneTerminal(pane);
      if (terminal == null) {
        bump('term.unresolved');
        continue;
      }
      bump('term.resolved');
      bump((into != null) == !lvEndpointIsSink(terminal) ? 'term.dirAgree' : 'term.dirDisagree');
      final declared = calleeFlow == null
          ? null
          : (calleeFlow.into(terminal.oid) ?? calleeFlow.outOf(terminal.oid))?.type;
      if (declared == null) {
        bump('term.calleeUntyped');
        continue;
      }
      bump(declared.dartType == (into ?? outOf)!.type.dartType ? 'term.typeAgree' : 'term.typeDisagree');
    }
  }

  // The While-loop conditional terminal census (see LvTerminalRole.conditional):
  // what the file says about a terminal whose polarity decides the loop's exit
  // test. Counted here so the refusal is backed by a number that moves the
  // moment a second glyph or a discriminating flag appears in the corpus.
  void censusConditionals(ViDiagram diagram) {
    for (final object in diagram.objects) {
      if (object.kind != LvTerminalRole.conditional.code) continue;
      bump('cond');
      bump('cond.glyph${object.termBmp ?? 'None'}');
      final dcoFlags = diagram.terminalDco(object.oid)?.objFlags ?? 0;
      if (dcoFlags & 0x1 != 0) bump('cond.dcoBit0');
      if (dcoFlags & 0x1000 != 0) bump('cond.dcoBit12');
    }
  }

  void walk(LvDataflow flow, LvRegion region) {
    for (final unit in region.units) {
      if (unit is LvSubViUnit) bindCall(flow, unit);
      if (unit is LvStructUnit) {
        for (final frame in unit.frames) {
          walk(flow, frame);
        }
      }
    }
  }

  for (final path in paths) {
    final unit = load(path, path.split(Platform.pathSeparator).last);
    if (unit == null) continue;
    bump('vi');
    censusConditionals(unit.diagram);
    if (flowOf(unit) case final flow?) walk(flow, flow.root);
    final sources = <String?>[];
    for (final mode in LvErrorMode.values) {
      final result = emitLvLibrary(unit, functionName: 'lowered', errorMode: mode, resolveSubVi: resolve);
      bump('${mode.name}.${result.refusal?.kind.name ?? 'lowered'}');
      sources.add(result.source);
    }
    // The modes are only allowed to differ where an error cluster reaches the
    // connector pane, so this counts the VIs the choice actually changes.
    if (sources.every((source) => source != null)) {
      bump(sources.first == sources.last ? 'modes.same' : 'modes.differ');
    }
  }
  return tally;
}

void main() {
  final snippets = snippetFiles();

  test('every tracked snippet lowers, or refuses for its pinned reason', () {
    final measured = <String, String>{};
    for (final file in snippets) {
      final name = snippetName(file);
      final vi = snippetVi(name);
      final result = emitLvFunction(vi.diagram, functionName: 'lowered', sourceNote: name, pool: vi.pool);
      measured[name] = result.refusal?.kind.name ?? 'lowered';
      if (result.refusal == null) {
        expect(result.source, contains(' lowered('), reason: '$name emitted no function');
      }
    }
    expect(measured, kSnippetLoweringOutcomes);
    expect(
      measured.values.where((outcome) => outcome == 'lowered').length,
      kSnippetLoweringOutcomes.values.where((outcome) => outcome == 'lowered').length,
    );
  });

  test('the threaded error mode changes only the VIs that carry an error cluster', () {
    final measured = <String, String>{};
    for (final file in snippets) {
      final name = snippetName(file);
      final vi = snippetVi(name);
      final result = emitLvFunction(
        vi.diagram,
        functionName: 'lowered',
        sourceNote: name,
        pool: vi.pool,
        errorMode: LvErrorMode.threaded,
      );
      final outcome = result.refusal?.kind.name ?? 'lowered';
      if (outcome != kSnippetLoweringOutcomes[name]) measured[name] = outcome;
    }
    expect(measured, kSnippetThreadedDifferences);
  });

  test('cluster wires resolve their member shape through their endpoints', () {
    var signals = 0, resolved = 0, disagreeing = 0, unresolved = 0;
    for (final file in snippets) {
      final vi = snippetVi(snippetName(file));
      final measured = _clusterWires(vi.diagram, vi.pool);
      signals += measured.signals;
      resolved += measured.resolved;
      disagreeing += measured.disagreeing;
      unresolved += measured.unresolved;
    }
    expect(
      (signals: signals, resolved: resolved, disagreeing: disagreeing, unresolved: unresolved),
      kSnippetClusterWires,
    );
  });

  final corpus = corpusViDir();
  test(
    'subVI calls bind through the connector pane, and both error modes sweep the corpus',
    () async {
      final paths = corpusViPaths(corpus!);
      final index = <String, String>{};
      for (final path in paths) {
        index.putIfAbsent(path.split(Platform.pathSeparator).last.toLowerCase(), () => path);
      }
      final workers = (Platform.numberOfProcessors - 2).clamp(1, 16);
      final chunks = List.generate(workers, (_) => <String>[]);
      for (var i = 0; i < paths.length; i++) {
        chunks[i % workers].add(paths[i]);
      }
      final results = await Future.wait(chunks.map((chunk) => Isolate.run(() => sweepLoweringChunk((chunk, index)))));
      final measured = <String, int>{};
      for (final result in results) {
        result.forEach((key, value) => measured[key] = (measured[key] ?? 0) + value);
      }
      printOnFailure(
        'measured:\n${[for (final key in measured.keys.toList()..sort()) "  '$key': ${measured[key]},"].join('\n')}',
      );
      expect(measured, kCorpusLoweringSweep);
      // The two independent checks on the pane binding: neither is used to
      // derive it, so a disagreement would mean the contract is wrong.
      expect(measured['term.dirDisagree'], isNull, reason: 'the pane binding contradicts the caller\'s own direction');
      expect(measured['term.typeDisagree'], isNull, reason: 'the pane binding contradicts the two VIs\' wire types');
    },
    tags: 'corpus',
    skip: corpus == null ? 'corpus not fetched' : null,
  );

  test('the primitive review list is exactly what the snippet corpus holds', () {
    final counts = <String, int>{};
    for (final file in snippets) {
      for (final object in snippetDiagram(snippetName(file)).objects) {
        if (object.category != ViObjectKind.node) continue;
        if (kSubViCallNodeCodes.contains(object.kind)) continue;
        final op = object.primResId == null ? null : PrimOp.fromId(object.primResId!);
        if (lvPrimHasRule(op: op, classCode: object.kind)) continue;
        final key = _reviewKey(op, object);
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    final frequent = <String, int>{
      for (final entry in counts.entries)
        if (entry.value >= kReviewListFloor) entry.key: entry.value,
    };
    expect(frequent, kSnippetPrimReviewList);
    expect(
      (identities: counts.length, nodes: counts.values.fold(0, (sum, count) => sum + count)),
      kReviewListTotals,
      reason: 'the review list grew or shrank; re-pin it against the measured corpus',
    );
  });
}

/// Every cluster-coded signal in [diagram], bucketed by whether its endpoints
/// resolve one member shape, several, or none.
({int signals, int resolved, int disagreeing, int unresolved}) _clusterWires(ViDiagram diagram, List<ViType> pool) {
  var signals = 0, resolved = 0, disagreeing = 0, unresolved = 0;
  for (final wire in diagram.wires) {
    final signal = wire.signalType;
    if (signal == null || !kLvWireClusterCodes.contains(signal.typeCode)) continue;
    signals++;
    final array = (signal.arrayDims ?? 0) > 0;
    final shapes = {
      for (final endpoint in wire.endpointOids)
        if (lvClusterOfEndpoint(diagram, endpoint, array: array) case final cluster?)
          '${cluster.name ?? ''}|${clusterFields(cluster, pool).map((m) => '${m.code}:${m.name ?? ''}').join(',')}',
    };
    if (shapes.isEmpty) {
      unresolved++;
    } else if (shapes.length == 1) {
      resolved++;
    } else {
      disagreeing++;
    }
  }
  return (signals: signals, resolved: resolved, disagreeing: disagreeing, unresolved: unresolved);
}

String _reviewKey(PrimOp? op, ViHeapObject object) {
  if (op != null) return '${op.opName} (primResID ${op.id})';
  if (object.primResId case final id?) return 'primResID $id (name not decoded)';
  return 'node class 0x${object.kind.toRadixString(16)}';
}
