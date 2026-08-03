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

import 'dart:convert';
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
/// constant, structure and wire decodes, and so now does its arithmetic; what
/// stands in the way is listed node by node in [kMd5Blockers].
const Map<String, String> kSnippetLoweringOutcomes = {
  'ClassChildren': 'wireType',
  'ClassesInMemory': 'subViCall',
  'Config_Dump': 'wireType',
  'Config_Dump2': 'wireType',
  'Config_Escape': 'structure',
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
  'ReverseBitsVim': 'lowered',
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
  'crc32_lookup_table': 'lowered',
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
  'String Subset (primResID 1503)': 24,
  'node class 0x93': 18,
  'node class 0x105': 16,
  'node class 0xa9': 15,
  'node class 0x172': 14,
  'node class 0x150': 12,
  'node class 0x6a': 12,
  'Search 1D Array (primResID 1901)': 11,
  'primResID 1171 (name not decoded)': 11,
  'primResID 8051 (name not decoded)': 11,
  'primResID 1534 (name not decoded)': 11,
};

/// Everything `MD5.vi` still refuses on, one entry per blocking node — the
/// exact distance to the second behavioural milestone after `crc8`.
///
/// Its every wire types, its whole structure tree builds, its four Case
/// structures lower from their own per-frame range lists, and its arithmetic
/// — `Subtract`, `Quotient & Remainder`, the byte and word swaps, the 64-bit
/// conversions — lowers from the drawn operand order. So now do its
/// `Concatenate Strings`, `Build Array`, `Select` and `Logical Shift` nodes,
/// from the same order read at N operands, its two swap nodes wired to an
/// ARRAY, from the elementwise form, and all seven of its `Type Cast` nodes,
/// from the flat byte form, and its every constant now decodes. What
/// remains is 10 nodes in two groups.
///
/// Five carry a `primResID` no corpus VI labels and whose icon does not say
/// what it computes either (1181 ×4, 1082). Five are named operations whose
/// RULE is not decoded: `String Subset`'s handling of an offset or length
/// outside the string, `Compound Arithmetic`'s mode and per-operand inversion
/// (see [kLvMappedPrimClasses]), and `To Lower Case`'s case-mapping table. The
/// last is a `0x114` node whose corpus captions do not agree on a name.
const Map<String, int> kMd5Blockers = {
  'primResID 1181': 4,
  'String Subset (primResID 1503)': 2,
  'Compound Arithmetic (class 0x6c)': 2,
  'To Lower Case (primResID 1189)': 1,
  'primResID 1082': 1,
  'node class 0x114': 1,
};

/// How the snippet corpus's **cluster wires** resolve. A cluster wire's member
/// types are not in its signal word, so they come from the data-space type an
/// endpoint of the wire resolves ([lvClusterOfEndpoint]) — which is the only
/// route there is, and covers a minority of wires. Pinned so the coverage
/// cannot fall silently.
const ({int signals, int resolved, int disagreeing, int unresolved}) kSnippetClusterWires = (
  signals: 729,
  resolved: 338,
  disagreeing: 13,
  unresolved: 378,
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
///
/// The `clus.*` counters are the cluster-wire census: a cluster wire's member
/// types are not in its signal word, so `clus.one` is how often an endpoint
/// supplies them, `clus.none` how often none does, and `clus.many` how often
/// two ends disagree. `clus.viaTypedef` is the share only the typedef unwrap
/// ([lvClusterBase]) reaches, and `clus.typedefContradicts` the wires where it
/// adds a shape the bare-cluster reading disagrees with.
///
/// The `ref.*` and `flag<n>.*` counters are the refnum-wire census. A refnum
/// wire's array-depth base is the reference class's, not the type code's, so
/// `ref.scalar` is the share the depth-1 law ([kSignalMinScalarDepth]) decides
/// and `ref.undecided` the rest. The `flag<n>.array` / `flag<n>.scalar` pairs
/// are measured over the codes whose base IS pinned, and are what rules the
/// flag nibble out as the missing base: every observed flag value carries both
/// array and non-array wires, so the nibble does not encode array-ness.
///
/// The `idx.*` counters are the Index Array terminal census
/// ([LvArrayTerminalRole]): `idx.regular` is the nodes reading as
/// `[array] ([output] [index]×rank)+`, `idx.rank1Index` the index terminals in
/// a rank-1 group (the shape that lowers), and `idx.groupFirstIndex` /
/// `idx.groupLastIndex` the delimiters of the higher-rank groups that are
/// refused for want of a decoded dimension order.
const Map<String, int> kCorpusLoweringSweep = {
  'call': 1331,
  'call.calleeMissing': 173,
  'call.noPaneMap': 574,
  'call.paneMatched': 551,
  'call.paneWidthMismatch': 6,
  'call.unnamed': 27,
  'clus': 133106,
  'clus.many': 502,
  'clus.none': 88743,
  'clus.one': 43861,
  'clus.typedefContradicts': 24,
  'clus.viaTypedef': 9381,
  'cond': 2267,
  'cond.dcoBit0': 382,
  'cond.dcoBit12': 140,
  'cond.glyph192': 1892,
  'cond.glyphNone': 375,
  'exceptions.caseSelector': 2,
  'exceptions.constantValue': 77,
  'exceptions.lowered': 162,
  'exceptions.primitive': 178,
  'exceptions.structure': 61,
  'exceptions.subViCall': 76,
  'exceptions.tunnelIndexing': 1,
  'exceptions.unboundValue': 1,
  'exceptions.unwiredTerminal': 75,
  'exceptions.wireDirection': 68,
  'exceptions.wireType': 6807,
  'flag0.array': 24628,
  'flag0.scalar': 148921,
  'flag12.array': 907,
  'flag12.scalar': 6556,
  'flag4.array': 4715,
  'flag4.scalar': 57772,
  'flag8.array': 9246,
  'flag8.scalar': 108263,
  'idx': 3479,
  'idx.groupFirstIndex': 110,
  'idx.groupLastIndex': 94,
  'idx.irregular': 1,
  'idx.rank1Index': 2198,
  'idx.regular': 3478,
  'modes.same': 162,
  'ref': 66473,
  'ref.scalar': 28582,
  'ref.undecided': 37891,
  'term.calleeUntyped': 121,
  'term.dirAgree': 317,
  'term.resolved': 317,
  'term.typeAgree': 196,
  'term.unresolved': 33,
  'term.wired': 350,
  'threaded.caseSelector': 2,
  'threaded.constantValue': 77,
  'threaded.lowered': 162,
  'threaded.primitive': 178,
  'threaded.structure': 61,
  'threaded.subViCall': 76,
  'threaded.tunnelIndexing': 1,
  'threaded.unboundValue': 1,
  'threaded.unwiredTerminal': 75,
  'threaded.wireDirection': 68,
  'threaded.wireType': 6807,
  'vi': 7508,
};

/// The occurrence count at which a review-list entry is pinned individually;
/// the tail below it is pinned only by [kReviewListTotals].
const int kReviewListFloor = 10;

/// The review list's shape: how many distinct unmapped identities the snippet
/// corpus holds, and how many node instances they account for.
const ({int identities, int nodes}) kReviewListTotals = (identities: 99, nodes: 632);

/// How many VIs lower, and how many DISTINCT Dart sources they emit — the
/// input to the analyze sweep below. Copies of one VI appear all over the
/// corpus and lower to the same text, so the analyzer sees each source once.
const ({int vis, int sources}) kEmittedSources = (vis: 162, sources: 41);

/// Lowers every VI in [paths], resolving subVI calls against [index] (a
/// `file name → path` map over the whole corpus), and tallies both the
/// connector-pane binding of every call node and the per-mode outcome.
///
/// `sources` collects the distinct [LvErrorMode.exceptions] lowerings, which
/// the analyze sweep runs the analyzer over.
({Map<String, int> tally, Set<String> sources}) sweepLoweringChunk((List<String>, Map<String, String>) input) {
  final (paths, index) = input;
  final tally = <String, int>{};
  final emitted = <String>{};
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

  // The cluster-wire census: where a cluster wire's member shape comes from.
  // `clus.viaTypedef` is the wires only the typedef unwrap ([lvClusterBase])
  // resolves, and `clus.typedefContradicts` the wires where it adds a shape
  // the bare-cluster reading disagrees with — the two numbers that say whether
  // looking through a typedef is worth what it costs.
  void censusClusterWires(ViDiagram diagram, List<ViType> pool) {
    for (final wire in diagram.wires) {
      final signal = wire.signalType;
      if (signal == null || !kLvWireClusterCodes.contains(signal.typeCode)) continue;
      bump('clus');
      final array = (signal.arrayDims ?? 0) > 0;
      final shapes = <String>{}, bare = <String>{};
      for (final endpoint in wire.endpointOids) {
        final type = lvClusterOfEndpoint(diagram, endpoint, array: array);
        if (type == null) continue;
        final shape = lvClusterShape(type, pool);
        shapes.add(shape);
        if (type.kind == ViDataType.cluster) bare.add(shape);
      }
      bump(
        'clus.${switch (shapes.length) {
          0 => 'none',
          1 => 'one',
          _ => 'many',
        }}',
      );
      if (shapes.length == 1 && bare.isEmpty) bump('clus.viaTypedef');
      if (bare.length == 1 && shapes.length > 1) bump('clus.typedefContradicts');
    }
  }

  // The Index Array terminal census ([LvArrayTerminalRole]): the grammar's
  // regularity, and how much of the corpus the refused higher-rank groups
  // account for. `idx.dims<n>` is the dimensionality of the array wire, so
  // `idx.dims2` and above size exactly what a decoded dimension order would
  // unblock.
  void censusIndexArrays(ViDiagram diagram) {
    final childrenByOid = diagram.childrenByOid;
    for (final node in diagram.objects) {
      if (node.kind != kLvIndexArrayClass) continue;
      bump('idx');
      final roles = [
        for (final holder in childrenByOid[node.oid] ?? const <ViHeapObject>[])
          if (holder.kind == kLvHolderCode)
            (childrenByOid[holder.oid] ?? const <ViHeapObject>[]).firstOrNull?.objFlags ?? 0,
      ];
      bump(_indexArrayShape(roles) ? 'idx.regular' : 'idx.irregular');
      for (final role in roles) {
        if (role == LvArrayTerminalRole.singleIndex) bump('idx.rank1Index');
        if (role == LvArrayTerminalRole.groupFirst) bump('idx.groupFirstIndex');
        if (role == LvArrayTerminalRole.groupLast) bump('idx.groupLastIndex');
      }
    }
  }

  // The refnum-wire census, and the flag-nibble refutation behind it
  // ([kSignalMinScalarDepth]). `ref.scalar` is the share of refnum-coded wires
  // the depth-1 law decides and `ref.undecided` the rest, whose base is the
  // reference class's. The `flag<n>.*` pairs are why no other field of the word
  // supplies that base: every observed flag value carries both array and
  // non-array wires among the codes whose base IS pinned, so the nibble does
  // not encode array-ness.
  void censusRefnumWires(ViDiagram diagram) {
    for (final wire in diagram.wires) {
      final signal = wire.signalType;
      if (signal == null) continue;
      final dims = signal.arrayDims;
      if (kLvWireRefnumCodes.contains(signal.typeCode)) {
        bump('ref');
        bump(dims == null ? 'ref.undecided' : 'ref.scalar');
      } else if (dims != null) {
        bump('flag${signal.flags}.${dims > 0 ? 'array' : 'scalar'}');
      }
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
    censusClusterWires(unit.diagram, unit.pool);
    censusIndexArrays(unit.diagram);
    censusRefnumWires(unit.diagram);
    if (flowOf(unit) case final flow?) walk(flow, flow.root);
    final sources = <String?>[];
    for (final mode in LvErrorMode.values) {
      final result = emitLvLibrary(unit, functionName: 'lowered', errorMode: mode, resolveSubVi: resolve);
      bump('${mode.name}.${result.refusal?.kind.name ?? 'lowered'}');
      sources.add(result.source);
      if (mode == LvErrorMode.exceptions && result.source != null) emitted.add(result.source!);
    }
    // The modes are only allowed to differ where an error cluster reaches the
    // connector pane, so this counts the VIs the choice actually changes.
    if (sources.every((source) => source != null)) {
      bump(sources.first == sources.last ? 'modes.same' : 'modes.differ');
    }
  }
  return (tally: tally, sources: emitted);
}

/// The whole-corpus sweep, run once however many tests read it: it decodes
/// every VI in the corpus, so paying for it twice would double this file's
/// runtime.
Future<({Map<String, int> tally, Set<String> sources})> corpusSweep(Directory corpus) =>
    _corpusSweep ??= _runCorpusSweep(corpus);

Future<({Map<String, int> tally, Set<String> sources})>? _corpusSweep;

Future<({Map<String, int> tally, Set<String> sources})> _runCorpusSweep(Directory corpus) async {
  final paths = corpusViPaths(corpus);
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
  final tally = <String, int>{};
  final sources = <String>{};
  for (final result in results) {
    result.tally.forEach((key, value) => tally[key] = (tally[key] ?? 0) + value);
    sources.addAll(result.sources);
  }
  return (tally: tally, sources: sources);
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

  test('MD5 refuses on exactly the nodes it is pinned to refuse on', () {
    final vi = snippetVi('MD5');
    final flow = buildLvDataflow(vi.diagram, pool: vi.pool).dataflow!;
    final measured = <String, int>{};
    void bump(String key) => measured[key] = (measured[key] ?? 0) + 1;
    void walk(LvRegion region) {
      for (final node in region.units) {
        switch (node) {
          case LvStructUnit():
            final selector = node.terminals.where((t) => t.role == LvTerminalRole.selector).firstOrNull;
            final outer = selector?.outerPort;
            final type = outer == null ? null : flow.into(outer)?.type;
            // A Case lowers from its own per-frame range list, or — for a
            // boolean / error-cluster selector — from the displayed frame's
            // label and its complement. A structure with neither refuses.
            final twoWay = type != null && (type.isErrorCluster || type.dartType == 'bool');
            if (type != null && !twoWay && node.selectorRanges.isEmpty) {
              bump('caseSelector over ${type.dartType}');
            }
            for (final frame in node.frames) {
              walk(frame);
            }
          case LvPrimUnit():
            if (_loweringOf(node, flow) != null) continue;
            bump(_blockerKey(node));
          case LvConstUnit():
            final type = flow.outOf(node.port)?.type;
            if (type != null && !_constantHasValue(node, type)) bump('constantValue ${type.dartType}');
          case _:
            break;
        }
      }
    }

    walk(flow.root);
    printOnFailure(
      'measured:\n${[for (final key in measured.keys) "  '$key': ${measured[key]},"].join('\n')}',
    );
    expect(measured, kMd5Blockers);
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
      final measured = (await corpusSweep(corpus!)).tally;
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

  test(
    'every emitted library analyzes clean at the recommended lint set, and compiles',
    () async {
      final swept = await corpusSweep(corpus!);
      expect(
        (vis: swept.tally['exceptions.lowered'], sources: swept.sources.length),
        kEmittedSources,
        reason: 'the set of VIs that lower changed; re-pin it before reading the analyzer result',
      );
      final scratch = _scratchPackage(swept.sources);
      try {
        final analyzed = Process.runSync(_kDart, ['analyze', '${scratch.path}/lib'], workingDirectory: scratch.path);
        expect(analyzed.exitCode, 0, reason: 'the emitted code is not clean:\n${analyzed.stdout}${analyzed.stderr}');
        // Analysis covers the static errors; a kernel compile of one entry
        // importing all of them is the independent check that the emitted
        // libraries really do link against the runtime.
        final compiled = Process.runSync(_kDart, [
          'compile',
          'kernel',
          'bin/all.dart',
          '-o',
          '${scratch.path}/all.dill',
        ], workingDirectory: scratch.path);
        expect(
          compiled.exitCode,
          0,
          reason: 'the emitted code does not compile:\n${compiled.stdout}${compiled.stderr}',
        );
      } finally {
        scratch.deleteSync(recursive: true);
      }
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

/// The Dart executable running this test — the same SDK the emitted code is
/// analyzed and compiled with.
final String _kDart = Platform.resolvedExecutable;

/// The scratch package's name; it is throwaway, so nothing refers to it beyond
/// the entry point that imports its libraries.
const String _kScratchPackageName = 'lv_emitted';

/// A throwaway package holding one library per source in [sources], ready for
/// `dart analyze` and `dart compile`.
///
/// Package resolution is this repo's own `package_config.json` with every
/// relative `rootUri` made absolute, so the emitted code links against the
/// same `labwright_lv_runtime` the checked-in generated sources do without a
/// `pub get`. `bin/all.dart` imports every library under a prefix — the
/// emitted entry points all share a name, and a prefix keeps a batch compile
/// to one invocation.
Directory _scratchPackage(Set<String> sources) {
  final dir = Directory.systemTemp.createTempSync('lv_emitted_');
  for (final sub in const ['lib', 'bin', '.dart_tool']) {
    Directory('${dir.path}/$sub').createSync();
  }
  final names = <String>[];
  for (final source in sources) {
    final name = 'vi_${names.length.toString().padLeft(4, '0')}.dart';
    File('${dir.path}/lib/$name').writeAsStringSync(source);
    names.add(name);
  }
  File('${dir.path}/bin/all.dart').writeAsStringSync(
    '${[
      for (var i = 0; i < names.length; i++) "import 'package:$_kScratchPackageName/${names[i]}' as vi$i;",
    ].join('\n')}\n\nvoid main() {}\n',
  );

  final configUri = Isolate.packageConfigSync!;
  final config = jsonDecode(File.fromUri(configUri).readAsStringSync()) as Map<String, dynamic>;
  final packages = (config['packages']! as List<dynamic>).cast<Map<String, dynamic>>();
  for (final package in packages) {
    package['rootUri'] = configUri.resolve(package['rootUri']! as String).toString();
  }
  final runtime = packages.firstWhere((package) => package['name'] == kLvRuntimePackage);
  packages.add({
    'name': _kScratchPackageName,
    'rootUri': dir.uri.toString(),
    'packageUri': 'lib/',
    'languageVersion': runtime['languageVersion'],
  });
  File('${dir.path}/.dart_tool/package_config.json').writeAsStringSync(jsonEncode(config));
  File('${dir.path}/pubspec.yaml').writeAsStringSync(
    'name: $_kScratchPackageName\n'
    'environment:\n  sdk: ^${runtime['languageVersion']}.0\n'
    'dependencies:\n  $kLvRuntimePackage: any\n',
  );
  // Goal: emitted code is clean at the lint set a new Dart package gets.
  File('${dir.path}/analysis_options.yaml').writeAsStringSync('include: package:lints/recommended.yaml\n');
  return dir;
}

/// [node]'s lowering against the wires that reach it, or null when it has
/// none. The expressions are placeholders: only whether a lowering EXISTS is
/// asked here, never what it says.
List<String>? _loweringOf(LvPrimUnit node, LvDataflow flow) {
  List<LvPrimTerminal> terminals(List<int> ports, {required bool isInput}) => [
    for (final port in ports)
      if (isInput ? flow.into(port) : flow.outOf(port) case final edge?)
        LvPrimTerminal(port: port, type: edge.type, roleFlags: node.portRoleFlags[port] ?? 0, expression: 'x'),
  ];
  return lvPrimLowering(
    LvPrimCall(
      op: node.op,
      primResId: node.primResId,
      classCode: node.classCode,
      inputs: terminals(node.inputPorts, isInput: true),
      outputs: terminals(node.outputPorts, isInput: false),
      outputPorts: node.outputPorts,
      portDrawnTop: node.portDrawnTop,
      requireImport: (_) {},
      names: LvNaming(),
    ),
  );
}

/// How a refused node is named in [kMd5Blockers]: the operation, the named
/// class, or the bare `primResID` an unnamed one carries.
String _blockerKey(LvPrimUnit node) {
  if (node.op case final op?) return '${op.opName} (primResID ${op.id})';
  if (kLvNamedNodeClasses[node.classCode] case final named?) {
    return '${named.name} (class 0x${node.classCode.toRadixString(16)})';
  }
  if (node.primResId case final id?) return 'primResID $id';
  return 'node class 0x${node.classCode.toRadixString(16)}';
}

/// Whether the diagram constant [node] carries a decoded value of [type].
bool _constantHasValue(LvConstUnit node, LvWireType type) => type.dims == 0
    ? node.record.constBool != null || node.record.constText != null || node.record.constNumeric != null
    : node.record.constArray != null && node.record.constArrayDims != null;

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
        if (lvClusterOfEndpoint(diagram, endpoint, array: array) case final cluster?) lvClusterShape(cluster, pool),
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

/// Whether [roles] — one Index Array node's terminal role bits in heap order —
/// reads as `[array] ([output] [index]×rank)+` ([LvArrayTerminalRole]).
bool _indexArrayShape(List<int> roles) {
  if (roles.isEmpty || roles.first != LvArrayTerminalRole.array) return false;
  var at = 1;
  while (at < roles.length) {
    final head = roles[at];
    if (head != LvArrayTerminalRole.output && head != LvArrayTerminalRole.grownOutput) {
      return false;
    }
    at++;
    var rank = 0;
    var opensGroup = false;
    while (at < roles.length &&
        roles[at] != LvArrayTerminalRole.output &&
        roles[at] != LvArrayTerminalRole.grownOutput) {
      final role = roles[at++];
      if (rank++ == 0) opensGroup = role & LvArrayTerminalRole.groupFirst != 0;
      if (role & LvArrayTerminalRole.groupLast != 0) break;
    }
    if (rank == 0 || !opensGroup) return false;
  }
  return true;
}

String _reviewKey(PrimOp? op, ViHeapObject object) {
  if (op != null) return '${op.opName} (primResID ${op.id})';
  if (object.primResId case final id?) return 'primResID $id (name not decoded)';
  return 'node class 0x${object.kind.toRadixString(16)}';
}
