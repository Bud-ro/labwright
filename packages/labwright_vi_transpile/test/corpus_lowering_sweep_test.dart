/// The lowering sweep over the tracked VI snippets: what each one's block
/// diagram does when it is lowered, and what stands in the way of the rest.
///
/// Both halves are pinned as data, so progress and regression are equally
/// visible: a VI that starts lowering, and a VI that stops, both fail here
/// until the pin is updated to the measured value.
///
/// [kSnippetLoweringOutcomes] is the per-VI outcome; [kSnippetPrimReviewList]
/// is the primitive review list — every operation the corpus uses that has no
/// lowering rule, with how often it appears. Nothing on that list is guessed
/// at: an entry leaves it only when its identity *and* its operand roles are
/// decoded (see `kLvMappedPrimOps`).
library;

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
/// `primitive` — the review list below; `wireDirection` — the 1.3% of corpus
/// signals whose endpoint flags do not resolve exactly one source.
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
  'basic': 'wireDirection',
  'broken_wires_only': 'wireDirection',
  'crc16': 'primitive',
  'crc32': 'primitive',
  'crc32_lookup_table': 'wireDirection',
  'crc8': 'lowered',
  'decorations_only': 'lowered',
  'example': 'wireType',
  'fg': 'wireDirection',
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

/// The occurrence count at which a review-list entry is pinned individually;
/// the tail below it is pinned only by [kReviewListTotals].
const int kReviewListFloor = 10;

/// The review list's shape: how many distinct unmapped identities the snippet
/// corpus holds, and how many node instances they account for.
const ({int identities, int nodes}) kReviewListTotals = (identities: 122, nodes: 878);

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
