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
/// leaves it when its identity *and* its operand roles are decoded (see
/// `kLvMappedPrimOps`), or when a published test vector decides what it
/// computes (see `kLvProvenPrimResIds`) — never on a reading nothing checks.
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
/// `MD5` is the largest diagram here and it **lowers**: every constant,
/// structure, wire and node of it reads, and the code it lowers to reproduces
/// RFC 1321's published digests (`md5_behaviour_test.dart`). [kMd5Blockers] is
/// the node-level guard that keeps it that way.
const Map<String, String> kSnippetLoweringOutcomes = {
  'ClassChildren': 'wireType',
  'ClassesInMemory': 'subViCall',
  'Config_Dump': 'wireType',
  'Config_Dump2': 'wireType',
  'Config_Escape': 'structure',
  'Config_Load': 'wireType',
  'Config_Load2': 'foreignCall',
  'Excel_Cell_to_RowCol': 'primitive',
  'Excel_Cell_to_Value': 'wireType',
  'Excel_Read_XLSX': 'wireType',
  'Excel_Variant_Elements': 'wireType',
  'Export Palette Image WMF': 'wireType',
  'FileReadOnly': 'wireType',
  'GenerateTree': 'wireType',
  'GetCurrentDirectory': 'wireType',
  'IconHeader': 'wireType',
  'MD5': 'lowered',
  'PNG CRC32': 'lowered',
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
  'example': 'primitive',
  'fg': 'structure',
  'large': 'wireType',
  'missing_terminal': 'wireDirection',
  'sub_vi_missing': 'wireDirection',
  'vi_lib_dependency': 'subViCall',
};

/// The heap class of an **In Place Element Structure** frame
/// ([HeapObjectClass.bdInPlaceStructure]).
const int kLvInPlaceElementClass = 0x14d;

/// The In Place Element Structure's **border node** classes — the nodes drawn
/// on its frame that name the element each access reaches.
///
/// Only [kLvDataValueRefBorderClass] is identified. The other three carry the
/// family's poser reference and sit inside the structure like it does, but
/// which element access each performs is not recovered, so the parser labels
/// them by family alone ([ClassConfidence.kindOnly]).
const Set<int> kLvInPlaceElementBorderClasses = {kLvDataValueRefBorderClass, 0x150, 0x14f, 0x152};

/// The one In Place Element border node whose access IS decoded: the pair that
/// reads and writes a **data value reference** ([HeapObjectClass.bdNode153]).
const int kLvDataValueRefBorderClass = 0x153;

/// How far the **In Place Element Structure** is from lowering, and what stands
/// in the way — the measurement that sizes it as a coverage lever.
///
/// The structure is common: `ipe.vis` VIs carry `ipe.structures` of them, and
/// the `ipe.border.*` counters are the border nodes inside. Containing one is
/// not the same as being blocked by one, though, and the gap between the two is
/// the whole point of this census. A lowering refuses at the FIRST thing it
/// cannot read, so the VIs the structure actually gates are `ipe.blocked` —
/// every other VI carrying one is already refused by something reached earlier,
/// and modelling the structure would not move it.
///
/// `ipe.blocked` is 27 against `ipe.vis`'s 705, so 96.2% of the VIs that carry
/// an In Place Element Structure are held up elsewhere — 482 of them by one
/// cause, a cluster wire whose member types no endpoint resolves
/// (`clus.why.noneNoCluster`, the corpus's largest single blocker).
///
/// The 27 split by whether the structure's own contents are decoded, and they
/// split against it: `ipe.blocked.undecodedAccess` (22) carry a border node
/// from [kLvInPlaceElementBorderClasses] whose element access is not recovered,
/// leaving `ipe.blocked.identifiedOnly` (5) whose border nodes are all the
/// data-value-reference pair.
///
/// 27 is a **lower** bound on the lever, not a ceiling. Attribution follows the
/// order the lowering does its work, not the order the diagram draws: whole
/// diagram wire typing runs before any structure is reached, so every VI a wire
/// blocks is counted against the wire even where the structure would have
/// blocked it too. Widening any earlier reading moves VIs into this count:
/// `exceptions.structure` is 113 with `Wait (ms)` lowered and 111 without it.
const Map<String, int> kCorpusInPlaceElement = {
  'ipe.vis': 705,
  'ipe.structures': 904,
  'ipe.border.0x14f': 108,
  'ipe.border.0x150': 406,
  'ipe.border.0x152': 98,
  'ipe.border.0x153': 1466,
  'ipe.blocked': 27,
  'ipe.blocked.identifiedOnly': 5,
  'ipe.blocked.undecodedAccess': 22,
};

/// The **primitive review list**: every operation the snippet corpus uses that
/// has no lowering rule and appears at least [kReviewListFloor] times, with its
/// occurrence count. An entry keyed by class code is a node whose class is its
/// identity but whose operation this reader has not named; one keyed by a bare
/// `primResID` is a node whose id [PrimOp] does not name.
const Map<String, int> kSnippetPrimReviewList = {
  'Match Pattern (primResID 1535)': 134,
  'node class 0x93': 18,
  'node class 0x105': 16,
  'node class 0xa9': 15,
  'node class 0x150': 12,
  'node class 0x6a': 12,
  'Search 1D Array (primResID 1901)': 11,
  'primResID 1171 (name not decoded)': 11,
  'primResID 8051 (name not decoded)': 11,
  'primResID 1534 (name not decoded)': 11,
};

/// Everything `MD5.vi` refuses on, one entry per blocking node. It is
/// **empty**: every node of the corpus's largest tracked diagram lowers, and
/// the result is checked against RFC 1321's published digests in
/// `md5_behaviour_test.dart`.
///
/// Kept as a pin because it is the finest-grained regression guard the diagram
/// affords: a rule that stops reading one node repopulates this map with that
/// node alone, naming it, where the outcome pin above only says `primitive`.
const Map<String, int> kMd5Blockers = <String, int>{};

/// How the snippet corpus's **cluster wires** resolve. A cluster wire's member
/// types are not in its signal word, so they come from the data-space type an
/// endpoint of the wire resolves ([lvClusterOfEndpoint]) — which is the only
/// route there is, and covers a minority of wires. Pinned so the coverage
/// cannot fall silently.
const ({int signals, int resolved, int disagreeing, int unresolved}) kSnippetClusterWires = (
  signals: 729,
  resolved: 489,
  disagreeing: 32,
  unresolved: 208,
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
/// checks on it. Direction agrees on all 1 345 resolved terminals. Type agrees
/// on 615 of 620. The five exceptions are read as LabVIEW type relations rather
/// than as binding contradictions, and the kinds seen among them are an integer
/// wire reaching a callee `Variant` terminal, which accepts a value of any wire
/// type, and a wire whose caller-side descriptor NAMES a cluster the callee's
/// descriptor spells with the same members in the same order under no name —
/// the name-only difference `clus.paneNameOnly` sizes.
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
/// adds a shape the bare-cluster reading disagrees with. The `clus.pane*`
/// counters size the CALLEE side as a second source: `clus.pane.none` is the
/// unresolved wires it would newly decide, `clus.paneAgrees` against
/// `clus.paneDisagrees` is how it reproduces the endpoint route where both
/// speak, and `clus.epTypeIdx` — absent from the pin, so zero — is the
/// structural reason the caller-side walk stops.
///
/// The `clus.kid*` counters score the endpoint's own node-terminal **parts**
/// the same way, and the `clus.none*` counters partition the wires that
/// resolve nothing by cause — see [lvClusterOfEndpoint], which owns both
/// readings' evidence.
///
/// The `clusType.*` counters re-score all three on the **Dart type** each
/// reading maps to instead of on the descriptor's own spelling — the identity
/// a generated library has, and so the identity the lowering compares by. It
/// is a different question and a different answer: `clusType.one` (91 829)
/// exceeds `clus.one` (90 614) because two ends that spell one type under two
/// control LABELS are one Dart type, and the part route reproduces the
/// endpoint route on 68 112 of 70 051 wires (97.2%) where `clus.kidAgrees`
/// scores it at 44 977 of 68 982 (65.2%). `clusType.kidWouldDecide` (38 236) is
/// what the part route would newly type — the largest single lever on the
/// corpus — and `clusType.kidDisagrees` (1 939) is why it is measured and not
/// read: two decoded readings of one wire that name different Dart types, with
/// nothing decoded saying which is the wire's. `clusType.kidLabelOnly` (1 874)
/// and `clusType.kidShapeDiffers` (65) split those by kind: all but 65 agree on
/// every member's own type code and differ in a LABEL — the descriptor's name
/// or a member's — which is what a nominal class is named from.
///
/// The `clusType.pane*` counters do the same to the callee's connector pane,
/// and are why it is not the second side that would gate the part route. It
/// resolves one Dart type on 6 300 wires and agrees with the endpoint route on
/// 5 777 of them (`clusType.paneAgrees`, 91.7%) where the spelling scores it at
/// 2 626 of 6 277 (41.8%) — a large lift that still leaves 523 contradictions,
/// of which 518 (`clusType.paneLabelOnly`) are a label difference and 5
/// (`clusType.paneShapeDiffers`) a member-code one. A cluster crosses a
/// connector pane on its member types, so the two files' labels need not match
/// and the callee's terminal is not a reading of the caller's wire's NAME.
///
/// Where it agrees it is also not independent. `clusType.paneAtCall*` and
/// `clusType.paneOffCall*` read the SAME part route at two places on one wire:
/// at the call node's own terminal, the endpoint the pane is read through, it
/// contradicts the pane on 39 of 12 252 (0.32%), and at any other endpoint of
/// the same wire on 372 of 4 677 (7.95%) — the caller-side rate the endpoint
/// route also scores. A route that tracks one endpoint's stored descriptor
/// twenty-five times more closely than it tracks itself elsewhere on the same
/// wire is that descriptor's copy, not a second witness. Nor does what it says
/// there favour the part route: strip the labels and the off-call part route
/// still differs from the pane in a member's own type code on 40 of 4 677 wires
/// (`clusType.paneOffCallShapeDiffers`, 0.86%) where the endpoint route differs
/// on 5 of 6 300 (0.08%). `clusType.kidChecked` (5 645) against
/// `clusType.kidUnchecked` (32 591) is the reach either way: the pane sees
/// 14.8% of what the part route would newly type.
///
/// The `clus.why.*` counters partition every one of the 133 106 cluster wires
/// by what stands between it and a Dart type, `clus.why.typed` (89 559) being
/// the ones that have one. The rest, largest first: 40 683 whose endpoints
/// resolve no cluster descriptor though the VI does type objects and the wire's
/// endpoints do carry a data-space index (`noneNoCluster`); 1 809 + 281 + 4
/// whose cluster holds a member of a type on the review list (`member.0x54`
/// waveform, `member.0x33` picture, `member.0xd` extended float); 391 in a VI
/// where nothing types at all; 176 spelling an enum whose item labels did not
/// decode; 157 whose ends resolve two different Dart types; 46 reaching no
/// index at all.
///
/// The `foreign.*` counters size the corpus's Call Library Function nodes
/// ([kLvCallLibraryClass]), refused as `exceptions.foreignCall`;
/// [kCorpusForeignCalls] counts the distinct libraries and entry points.
///
/// The `pane.0x<class>.equal` / `.differs` counters compare a subVI call node's
/// holder count with its named callee's connector-pane width, over every node
/// in the corpus. They are what identified `0x124` (30 equal, 0 differing) and
/// what bounds that evidence: `0x32` differs on 975 of 1 012 and `0x103` on all
/// 13, so passing the check is not a condition of membership.
///
/// The `wt.*` counters attribute the `wireType` refusal of every VI whose own
/// dataflow build raises one: `wt.<family>` is the family of the wire the
/// refusal names, `wt.sole.<family>` the VIs carrying no untyped wire of any
/// other family, and `wt.cause.*` the `clus.why.*` sub-cause for a cluster
/// wire. `wt.noSignalWord` — absent from the pin, so zero — would be a refusal
/// naming a signal that carries no type word.
///
/// The `decl.*` counters are the generated-declaration census: what a lowering
/// must declare for the nominal types its cluster wires carry, one registry per
/// VI. 3 129 of the 7 508 VIs need a declaration at all, and they need 10 437 —
/// 8 583 cluster classes and 1 854 enums. The shape questions each have a
/// number: `decl.suffixed` (724) is how often a class name is not the plain
/// [lvClassName] of its own LabVIEW name because a structurally different type
/// in the same VI already held it, which is what makes structural identity
/// rather than the name the thing a declaration is keyed by;
/// `decl.unnamedMember` (1 213) and `decl.displacedMember` (1 594) are the
/// members the naming policy has to name or move; `decl.anonymous` (3) is the
/// enums with no name of their own; and `decl.noItems` (61) is the one shape
/// that cannot be declared — an enum whose item labels did not decode, which is
/// refused ([LvRefusalKind.typeDeclaration]) rather than half-written.
///
/// The `ref.*` and `flag<n>.*` counters are the refnum-wire census. A refnum
/// wire's array-depth base is the reference class's, not the type code's, so
/// `ref.scalar` is the share the depth-1 law ([kSignalMinScalarDepth]) decides
/// and `ref.undecided` the rest. The `flag<n>.array` / `flag<n>.scalar` pairs
/// are measured over the codes whose base IS pinned, and are what rules the
/// flag nibble out as the missing base: every observed flag value carries both
/// array and non-array wires, so the nibble does not encode array-ness.
///
/// The `ref.part.*` / `ref.ep.*` pairs score the two data-space descriptor
/// routes as a source for that dimensionality ([_refnumDims]), and separate
/// them sharply. Against the depth-1 law — an oracle neither derives from —
/// the part route agrees on all 26 796 wires where both speak, with
/// `ref.part.contradicts` absent from the pin and so zero, while the endpoint
/// route contradicts it on 1 335 of 15 381 (8.7%), every one of them claiming
/// an array where the word has no room for a dimension: the auto-indexing
/// boundary, where the typed endpoint sits on the array side of the tunnel the
/// wire crosses. `ref.part.split` is likewise absent, so across the 59 228
/// refnum wires whose parts speak the two ends never state different
/// dimensionalities. The route would decide 32 432 of the 37 891 undecided
/// wires (`ref.part.decides`), and the depth base it implies (`ref.part.base*`)
/// lands on the per-reference-class bases the descriptor's own discriminator
/// measures (see [kRefnumSubtypeNote]).
///
/// That test alone is **one-sided**: every one of those 26 796 wires is scalar,
/// so it catches a route that invents an array and cannot catch one that misses
/// a real one. The `ref.pane.*` counters are the second side. A call node's
/// holders are its pane terminals in pane order, so a refnum wire ending on one
/// can be read against the CALLEE's own terminal for that pane — a different
/// route (a terminal's own descriptor rather than a part's) in a different
/// file. It answers on both rows of the undecided wires (`ref.pane.dims0`
/// 4 661, `ref.pane.dims1` 177) and reproduces the part route on 4 827 of 4 838
/// (`ref.pane.vsAgrees`), the 11 disagreements splitting 10 `vsInvented` to 1
/// `vsMissed`. Its own calibration is `ref.pane.lawAgrees`: on the word's
/// ground-truth row it agrees 1 869 times with `ref.pane.lawContradicts` absent
/// from the pin and so zero — unlike the caller-side endpoint walk, which is
/// wrong 8.7% of the time on that same row and is not read.
///
/// The disagreements are not spread. `ref.pane.contraCell.*` breaks them out by
/// signal-word cell: plain refnum at depth 4 holds 10 of the 11, dissenting on
/// 10 of the 101 wires the pane tests there, while every other cell agrees
/// 4 736 of 4 737. That cell is [kLvRefnumContradictedCells] and its 1 494
/// wires (`ref.part.contradictedCell`) keep the word's refusal; the other
/// 30 938 (`ref.part.read`) are what the lowering types.
///
/// Two other candidate oracles were measured and refuted. **Auto-indexing
/// tunnels** ([kLvTunnelIndexerCode]) would give a boundary whose two sides
/// differ by exactly one dimension, but the corpus does not carry it: of the
/// 4 190 loop tunnels whose refnum-coded OUTER wire the part route types, NOT
/// ONE inner side resolves a type (4 141 are a refnum-coded wire whose parts
/// state nothing, 15 a wire of another code, 34 no wire at all) — a structure
/// border terminal carries no typed part, only a node terminal does.
/// **LabVIEW's own wire stroke** ([ViSignalTypeRenderStyle]) draws
/// dimensionality directly, but the shipped catalogue is a pure function of the
/// same 12 bits [ViSignalType.arrayDims] reads, so it can only restate them:
/// `render.lawSilent.styleSpeaks` is the wires where a stroke is catalogued and
/// the depth base is not, and it covers 5 292 of 38 439 — of which
/// `render.refUndecided.styleSpeaks` shows only 5 028 of the 37 891 refnum
/// wires (13.3%), every one of them the single depth-2 plain-refnum cell, whose
/// one catalogued stroke is shared by the 3 969 wires the part route calls
/// one-dimensional AND the 651 it calls scalar. A stroke constant across a cell
/// cannot separate readings inside it.
///
/// The `idx.*` counters are the Index Array terminal census
/// ([LvArrayTerminalRole]): `idx.regular` is the nodes reading as
/// `[array] ([output] [index]×rank)+`, `idx.rank1Index` the index terminals in
/// a rank-1 group (the shape that lowers), and `idx.groupFirstIndex` /
/// `idx.groupLastIndex` the delimiters of the higher-rank groups that are
/// refused for want of a decoded dimension order.
const Map<String, int> kCorpusLoweringSweep = {
  'call': 2357,
  'call.calleeMissing': 385,
  'call.noPaneMap': 1019,
  'call.paneMatched': 856,
  'call.paneWidthMismatch': 15,
  'call.unnamed': 82,
  'clus': 133106,
  'clus.kid.many': 228,
  'clus.kid.none': 21496,
  'clus.kid.one': 68982,
  'clus.kidAgrees': 44977,
  'clus.kidDisagrees': 24005,
  'clus.kidNameOnly': 23636,
  'clus.many': 1372,
  'clus.none': 41120,
  'clus.noneNoIndex': 46,
  'clus.noneUntyped': 391,
  'clus.one': 90614,
  'clus.pane.many': 17,
  'clus.pane.none': 4215,
  'clus.pane.one': 6327,
  'clus.paneAgrees': 2654,
  'clus.paneDisagrees': 3673,
  'clus.paneNameOnly': 3630,
  'clus.typedefContradicts': 6,
  'clus.viaTypedef': 18105,
  'clus.why.member.0x33': 281,
  'clus.why.member.0x54': 1809,
  'clus.why.member.0xd': 4,
  'clus.why.noneNoCluster': 40683,
  'clus.why.noneNoIndex': 46,
  'clus.why.noneUntyped': 391,
  'clus.why.typed': 89559,
  'clus.why.typesDisagree': 157,
  'clus.why.undeclarable': 176,
  'clusType.kidAgrees': 68112,
  'clusType.kidChecked': 5647,
  'clusType.kidDisagrees': 1939,
  'clusType.kidLabelOnly': 1874,
  'clusType.kidShapeDiffers': 65,
  'clusType.kidUnchecked': 32589,
  'clusType.kidWouldDecide': 38236,
  'clusType.kidWouldNotMap': 541,
  'clusType.many': 157,
  'clusType.none': 41120,
  'clusType.one': 91829,
  'clusType.pane.many': 4,
  'clusType.pane.none': 5949,
  'clusType.pane.one': 6350,
  'clusType.paneAgrees': 5827,
  'clusType.paneAtCallAgrees': 12263,
  'clusType.paneAtCallDisagrees': 39,
  'clusType.paneDisagrees': 523,
  'clusType.paneLabelOnly': 518,
  'clusType.paneOffCallAgrees': 4293,
  'clusType.paneOffCallDisagrees': 370,
  'clusType.paneOffCallLabelOnly': 329,
  'clusType.paneOffCallShapeDiffers': 40,
  'clusType.paneShapeDiffers': 5,
  'clusType.paneWouldDecide': 5918,
  'clusType.paneWouldNotMap': 31,
  'cond': 2267,
  'cond.dcoBit0': 382,
  'cond.dcoBit12': 140,
  'cond.glyph192': 1892,
  'cond.glyphNone': 375,
  'decl': 10437,
  'decl.anonymous': 3,
  'decl.cluster': 8583,
  'decl.displacedMember': 1594,
  'decl.enum': 1854,
  'decl.noItems': 61,
  'decl.suffixed': 724,
  'decl.unnamedMember': 1213,
  'decl.vi': 3129,
  'exceptions.caseSelector': 3,
  'exceptions.constantValue': 129,
  'exceptions.foreignCall': 37,
  'exceptions.lowered': 228,
  'exceptions.primitive': 519,
  'exceptions.structure': 111,
  'exceptions.subViCall': 302,
  'exceptions.tunnelCoercion': 6,
  'exceptions.typeDeclaration': 18,
  'exceptions.unboundValue': 7,
  'exceptions.unwiredTerminal': 232,
  'exceptions.wireDirection': 107,
  'exceptions.wireType': 5809,
  'flag0.array': 24628,
  'flag0.scalar': 148921,
  'flag12.array': 907,
  'flag12.scalar': 6556,
  'flag4.array': 4715,
  'flag4.scalar': 57772,
  'flag8.array': 9246,
  'flag8.scalar': 108263,
  'foreign.noLibrary': 55,
  'foreign.node': 865,
  'foreign.vi': 408,
  'idx': 3479,
  'idx.groupFirstIndex': 110,
  'idx.groupLastIndex': 94,
  'idx.irregular': 1,
  'idx.rank1Index': 2198,
  'idx.regular': 3478,
  'ipe.blocked': 27,
  'ipe.blocked.identifiedOnly': 5,
  'ipe.blocked.undecodedAccess': 22,
  'ipe.border.0x14f': 108,
  'ipe.border.0x150': 406,
  'ipe.border.0x152': 98,
  'ipe.border.0x153': 1466,
  'ipe.structures': 904,
  'ipe.vis': 705,
  'modes.differ': 43,
  'modes.same': 185,
  'pane.0x103.differs': 13,
  'pane.0x104.equal': 879,
  'pane.0x124.equal': 30,
  'pane.0x31.differs': 100,
  'pane.0x31.equal': 7529,
  'pane.0x32.differs': 975,
  'pane.0x32.equal': 37,
  'ref': 66473,
  'ref.ep.agrees': 14046,
  'ref.ep.contradicts': 1335,
  'ref.ep.split': 19,
  'ref.pane.contraCell.70_d2.agrees': 90,
  'ref.pane.contraCell.70_d3.agrees': 4086,
  'ref.pane.contraCell.70_d3.contradicts': 1,
  'ref.pane.contraCell.70_d4.agrees': 91,
  'ref.pane.contraCell.70_d4.contradicts': 10,
  'ref.pane.contraCell.71_d4.agrees': 66,
  'ref.pane.contraCell.71_d5.agrees': 548,
  'ref.pane.contraCell.71_d6.agrees': 1,
  'ref.pane.dims0': 4716,
  'ref.pane.dims1': 177,
  'ref.pane.lawAgrees': 1869,
  'ref.pane.vsAgrees': 4882,
  'ref.pane.vsContradicts': 11,
  'ref.pane.vsInvented': 10,
  'ref.pane.vsMissed': 1,
  'ref.part.agrees': 26796,
  'ref.part.base1': 3969,
  'ref.part.base2': 662,
  'ref.part.base3': 22461,
  'ref.part.base4': 1161,
  'ref.part.base5': 4161,
  'ref.part.base6': 18,
  'ref.part.contradictedCell': 1494,
  'ref.part.decides': 32432,
  'ref.part.dims0': 26831,
  'ref.part.dims1': 5601,
  'ref.part.read': 30938,
  'ref.part.silent': 5459,
  'ref.scalar': 28582,
  'ref.undecided': 37891,
  'render.lawSilent.styleMute': 33147,
  'render.lawSilent.styleSpeaks': 5292,
  'render.refUndecided.styleMute': 32863,
  'render.refUndecided.styleSpeaks': 5028,
  'term.calleeUntyped': 856,
  'term.dirAgree': 1497,
  'term.resolved': 1497,
  'term.typeAgree': 635,
  'term.typeDisagree': 6,
  'term.unresolved': 96,
  'term.wired': 1593,
  'threaded.caseSelector': 3,
  'threaded.constantValue': 129,
  'threaded.foreignCall': 37,
  'threaded.lowered': 228,
  'threaded.primitive': 519,
  'threaded.structure': 111,
  'threaded.subViCall': 302,
  'threaded.tunnelCoercion': 6,
  'threaded.typeDeclaration': 18,
  'threaded.unboundValue': 7,
  'threaded.unwiredTerminal': 232,
  'threaded.wireDirection': 107,
  'threaded.wireType': 5809,
  'vi': 7508,
  'wt.cause.member.0x33': 14,
  'wt.cause.member.0x54': 67,
  'wt.cause.noneNoCluster': 4197,
  'wt.cause.noneUntyped': 25,
  'wt.cause.typesDisagree': 60,
  'wt.cluster': 4363,
  'wt.code0x0': 4,
  'wt.code0x33': 46,
  'wt.code0x37': 22,
  'wt.code0x54': 81,
  'wt.code0x74': 1,
  'wt.code0xb': 4,
  'wt.code0xc': 3,
  'wt.code0xff': 70,
  'wt.refnum': 1154,
  'wt.sole.cluster': 1901,
  'wt.sole.code0x33': 4,
  'wt.sole.code0x37': 5,
  'wt.sole.code0x54': 29,
  'wt.sole.code0xb': 1,
  'wt.sole.code0xff': 8,
  'wt.sole.refnum': 666,
};

/// The **corpus** primitive review list: every operation the whole `.vi` corpus
/// uses that has no lowering rule and that at least [kCorpusReviewListFloor]
/// VIs carry, ranked by the VIs it blocks.
///
/// `vis` is how many of the 7 508 VIs hold at least one node of the identity;
/// `nodes` is the node instances; `sole` is the VIs whose only unmapped
/// identity it is — the VIs a lowering rule for it would leave with no
/// primitive blocker at all. One identity appearing 2 437 times over 378 VIs
/// (`0xd6`, 25 sole) is worth less than one appearing 406 times over 157, of
/// which 28 carry nothing else (`0x150`).
///
/// **`sole` ranks primitive blockers only, so it is an upper bound on what a
/// rule buys and never a count of VIs that would start lowering.** `0x153`
/// heads the column with 337 and none of them would: of the 556 VIs holding
/// one, 550 refuse [LvRefusalKind.wireType], 5 [LvRefusalKind.structure] and 1
/// [LvRefusalKind.wireDirection] — every refusal the whole-VI lowering raises
/// ahead of any primitive.
///
/// The snippet review list ([kSnippetPrimReviewList]) is scored over 45
/// diagrams and ranks differently: `Match Pattern` heads it and is fourth here,
/// where `0x63` — a quarter of every unmapped node in the corpus — appears
/// there 83 times.
///
/// The list is identity-level, exactly as the snippet one is: a node whose
/// identity HAS a rule is not counted here however often its own operands fail
/// to resolve. `exceptions.primitive` in [kCorpusLoweringSweep] is what sizes
/// those. Nodes that are not operations are off the list entirely: the subVI
/// call classes ([kSubViCallNodeCodes], which `0x124` joined) and the Call
/// Library Function node ([kLvCallLibraryClass]), which [kCorpusForeignCalls]
/// sizes instead.
const Map<String, ({int vis, int nodes, int sole})> kCorpusPrimReviewList = {
  'node class 0x34': (vis: 805, nodes: 1659, sole: 103),
  'Close Reference (primResID 8011)': (vis: 759, nodes: 3068, sole: 44),
  'node class 0x93': (vis: 690, nodes: 1566, sole: 134),
  'Match Pattern (primResID 1535)': (vis: 680, nodes: 1800, sole: 86),
  'node class 0xa9': (vis: 678, nodes: 2619, sole: 64),
  'Search 1D Array (primResID 1901)': (vis: 591, nodes: 1338, sole: 37),
  'node class 0x153': (vis: 556, nodes: 1466, sole: 339),
  'Build Path (primResID 1419)': (vis: 439, nodes: 1215, sole: 28),
  'node class 0xd6': (vis: 378, nodes: 2437, sole: 25),
  'Strip Path (primResID 1420)': (vis: 370, nodes: 865, sole: 3),
  'To More Specific Class (primResID 8016)': (vis: 344, nodes: 825, sole: 45),
  'node class 0xbd': (vis: 332, nodes: 645, sole: 12),
  'node class 0xb6': (vis: 264, nodes: 533, sole: 21),
  'Variant To Data (primResID 8003)': (vis: 263, nodes: 506, sole: 14),
  'Open VI Reference (primResID 8010)': (vis: 251, nodes: 447, sole: 8),
  'node class 0x14a': (vis: 221, nodes: 380, sole: 0),
  'node class 0x170': (vis: 221, nodes: 380, sole: 0),
  'node class 0xeb': (vis: 199, nodes: 226, sole: 6),
  'Unregister For Events (primResID 2076)': (vis: 181, nodes: 203, sole: 0),
  'Call Chain (primResID 1999)': (vis: 174, nodes: 175, sole: 73),
  'Search and Replace String (primResID 3914)': (vis: 157, nodes: 243, sole: 12),
  'node class 0x150': (vis: 157, nodes: 406, sole: 28),
  'Get Variant Attribute (primResID 8205)': (vis: 153, nodes: 307, sole: 29),
  'Enqueue Element (primResID 9111)': (vis: 152, nodes: 369, sole: 3),
  'primResID 9113 (name not decoded)': (vis: 152, nodes: 187, sole: 2),
};

/// The distinct libraries and entry points the corpus's Call Library Function
/// nodes name; [kCorpusLoweringSweep]'s `foreign.*` counts the nodes.
///
/// `entryPoints` is a LOWER bound: the symbol field stores at most 31
/// characters (84 nodes are at the limit), so two longer names sharing a
/// prefix collide here.
const ({int libraries, int entryPoints}) kCorpusForeignCalls = (libraries: 52, entryPoints: 481);

/// The VI count at which a [kCorpusPrimReviewList] entry is pinned
/// individually; the tail below it is pinned only by [kCorpusPrimTotals].
const int kCorpusReviewListFloor = 150;

/// The corpus review list's shape: distinct unmapped identities, the node
/// instances they account for, and the VIs carrying at least one.
const ({int identities, int nodes, int vis}) kCorpusPrimTotals = (identities: 219, nodes: 33998, vis: 15330);

/// The occurrence count at which a review-list entry is pinned individually;
/// the tail below it is pinned only by [kReviewListTotals].
const int kReviewListFloor = 10;

/// The review list's shape: how many distinct unmapped identities the snippet
/// corpus holds, and how many node instances they account for.
const ({int identities, int nodes}) kReviewListTotals = (identities: 87, nodes: 470);

/// How many VIs lower, and how many DISTINCT Dart sources they emit — the
/// input to the analyze sweep below. Copies of one VI appear all over the
/// corpus and lower to the same text, so the analyzer sees each source once.
const ({int vis, int sources}) kEmittedSources = (vis: 228, sources: 78);

/// Lowers every VI in [paths], resolving subVI calls against [index] (a
/// `file name → path` map over the whole corpus), and tallies both the
/// connector-pane binding of every call node and the per-mode outcome.
///
/// `sources` collects the distinct [LvErrorMode.exceptions] lowerings, which
/// the analyze sweep runs the analyzer over.
({Map<String, int> tally, Set<String> sources, Map<String, int> prims, Set<String> foreign}) sweepLoweringChunk(
  (List<String>, Map<String, String>) input,
) {
  final (paths, index) = input;
  final tally = <String, int>{};
  final emitted = <String>{};
  // The unmapped-primitive census, keyed `<column>|<identity>`: `nodes` is
  // node instances, `vis` the VIs holding at least one, and `sole` the VIs
  // whose ONLY unmapped identity it is.
  final prims = <String, int>{};
  // The distinct library paths and entry points the foreign calls name.
  final foreign = <String>{};
  void bump(String key) => tally[key] = (tally[key] ?? 0) + 1;
  final units = <String, LvViUnit?>{};
  // The dataflows of ONE entry VI and the callees it reaches, all typed through
  // that VI's own declaration registry — the scope a generated library has. A
  // nominal class name is unique within a registry and means nothing across
  // two, so comparing a caller's wire type with its callee's terminal type
  // (`term.type*`) is only a statement about the pane binding when both were
  // named by the same registry.
  var builds = <String, ({LvDataflow? dataflow, LvRefusal? refusal})>{};
  var registry = LvDeclarations();
  // The entry VI's own wires that do not type, filled by the censuses below:
  // per refusing cluster wire the sub-cause, and the set of wire FAMILIES the
  // VI carries an untyped wire of. Together they attribute the VI's
  // `wireType` refusal — which family it names, and whether that family is
  // the whole distance to a typed diagram.
  var clusterWireCause = <int, String>{};
  var untypedFamilies = <String>{};
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

  // A callee's connector-pane width alone, off its `CPMp` block — the pane
  // census needs no diagram, so it does not pay for one.
  final paneWidths = <String, int?>{};
  int? paneWidth(String name) => paneWidths.putIfAbsent(name.toLowerCase(), () {
    final path = index[name.toLowerCase()];
    if (path == null) return null;
    try {
      return lvConnectorPaneMap(decodeSections(File(path).readAsBytesSync())).length;
    } catch (_) {
      return null;
    }
  });

  ({LvDataflow? dataflow, LvRefusal? refusal}) buildOf(LvViUnit unit) => builds.putIfAbsent(
    unit.fileName,
    () => buildLvDataflow(unit.diagram, pool: unit.pool, declarations: registry),
  );

  LvDataflow? flowOf(LvViUnit unit) => buildOf(unit).dataflow;

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

  // The **In Place Element Structure** census (see [kCorpusInPlaceElement]):
  // how far the structure is from a lowering, measured as the VIs it is the
  // binding constraint on rather than as the VIs that contain one.
  void censusInPlaceElement(ViDiagram diagram, LvRefusal? refusal) {
    var structures = 0;
    final border = <int>[];
    for (final object in diagram.objects) {
      if (object.kind == kLvInPlaceElementClass) structures++;
      if (kLvInPlaceElementBorderClasses.contains(object.kind)) border.add(object.kind);
    }
    if (structures == 0) return;
    bump('ipe.vis');
    for (var i = 0; i < structures; i++) {
      bump('ipe.structures');
    }
    for (final code in border) {
      bump('ipe.border.0x${code.toRadixString(16)}');
    }
    final blocked =
        refusal != null &&
        refusal.kind == LvRefusalKind.structure &&
        diagram.byId[refusal.oid]?.kind == kLvInPlaceElementClass;
    if (!blocked) return;
    bump('ipe.blocked');
    bump(
      border.every((code) => code == kLvDataValueRefBorderClass)
          ? 'ipe.blocked.identifiedOnly'
          : 'ipe.blocked.undecodedAccess',
    );
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

  /// Per endpoint oid in [endpoints], the callee and pane index it is a pane
  /// terminal of. A call node's holders are its pane terminals in pane order,
  /// so a wire ending on one can be read against the callee VI's own terminal
  /// for that pane. Built only for the call nodes [endpoints] actually reaches,
  /// so the census does not load a callee it has no question for.
  Map<int, (LvViUnit, int)> paneTerminalsOf(ViDiagram diagram, Set<int> endpoints) {
    final paneOf = <int, (LvViUnit, int)>{};
    for (final node in diagram.objects) {
      if (!kSubViCallNodeCodes.contains(node.kind)) continue;
      final name = node.label?.trim();
      if (name == null) continue;
      final lower = name.toLowerCase();
      if (!lower.endsWith('.vi') && !lower.endsWith('.vim')) continue;
      final ports = [
        for (final holder in diagram.children(node.oid))
          if (holder.kind == kLvHolderCode) holder.oid,
      ];
      if (!ports.any(endpoints.contains)) continue;
      final callee = resolve(name);
      if (callee == null || ports.length != callee.paneMap.length || callee.paneMap.isEmpty) continue;
      for (var pane = 0; pane < ports.length; pane++) {
        paneOf[ports[pane]] = (callee, pane);
      }
    }
    return paneOf;
  }

  // The cluster-wire census: where a cluster wire's member shape comes from.
  // `clus.viaTypedef` is the wires only the typedef unwrap ([lvClusterBase])
  // resolves, and `clus.typedefContradicts` the wires where it adds a shape
  // the bare-cluster reading disagrees with — the two numbers that say whether
  // looking through a typedef is worth what it costs.
  //
  // The `clus.pane*` / `clusType.pane*` counters measure the CALLEE side as a
  // second source: a call node's holders are its pane terminals in pane order,
  // so a cluster wire ending on one can be read against the callee VI's own
  // terminal for that pane. `clus.epTypeIdx` is the structural reason the
  // caller-side walk stops where it does.
  //
  // The `clus.kid*` counters measure the endpoint's own **part** objects — the
  // node-terminal parts a bounds-less `0x15` endpoint DCO parents, which do
  // carry a data-space index where the endpoint itself does not. They score it
  // exactly as the pane side is scored, and refuse it for the same reason (see
  // [lvClusterOfEndpoint]). The `clus.none*` counters partition the wires that
  // resolve nothing by cause, so the size of each blocker is a measured number.
  void censusClusterWires(ViDiagram diagram, List<ViType> pool) {
    final clusterEndpoints = <int>{
      for (final wire in diagram.wires)
        if (kLvWireClusterCodes.contains(wire.signalType?.typeCode)) ...wire.endpointOids,
    };
    if (clusterEndpoints.isEmpty) return;
    final paneOf = paneTerminalsOf(diagram, clusterEndpoints);
    // Whether the VI's data-space type indices resolve at all: a VI carrying
    // no `VCTP` pool, or a `DTHP` too short to declare the heap's index base,
    // has no object with a resolved type, so no route can reach one.
    final anyTyped = diagram.objects.any((object) => object.resolvedType != null);
    final childrenByOid = diagram.childrenByOid;
    // What each descriptor becomes in Dart, allocated against one registry per
    // VI — the scope a generated library has, so two readings hold one
    // [LvTypeMapping.dartType] exactly when they are one type in that library.
    // Memoized because a pool descriptor is shared by every object that names
    // it, and the census asks about it once per wire end.
    final registry = LvDeclarations();
    final mappingOf = <ViType, LvTypeMapping>{};
    LvTypeMapping typeOf(ViType type, List<ViType> owner) =>
        mappingOf.putIfAbsent(type, () => mapLvType(type, owner, 0, registry));
    for (final wire in diagram.wires) {
      final signal = wire.signalType;
      if (signal == null || !kLvWireClusterCodes.contains(signal.typeCode)) continue;
      bump('clus');
      final array = (signal.arrayDims ?? 0) > 0;
      final shapes = <String>{}, bare = <String>{}, viaPane = <String>{}, viaKid = <String>{};
      final ownTypes = <String?>{}, kidTypes = <String?>{}, paneTypes = <String?>{};
      // The part route's answer split by WHERE the part sits: on the call
      // node's own terminal, which is the same endpoint the pane is read
      // through, or on another endpoint of the same wire.
      final kidAtCall = <String?>{}, kidOffCall = <String?>{}, kidOffCallShape = <String>{};
      LvTypeMapping? ownMapping;
      for (final endpoint in wire.endpointOids) {
        final type = lvClusterOfEndpoint(diagram, endpoint, array: array);
        if (type == null) continue;
        final shape = lvClusterShape(type, pool);
        shapes.add(shape);
        if (type.kind == ViDataType.cluster) bare.add(shape);
        final mapping = typeOf(type, pool);
        ownMapping ??= mapping;
        ownTypes.add(mapping.dartType);
      }
      // The endpoint's own node-terminal PARTS: the objects a bounds-less
      // endpoint DCO parents, which carry the data-space index the endpoint
      // itself never does.
      for (final endpoint in wire.endpointOids) {
        for (final part in childrenByOid[endpoint] ?? const <ViHeapObject>[]) {
          final type = array ? part.resolvedElementType : part.resolvedType;
          if (lvClusterBase(type) == null) continue;
          final shape = lvClusterShape(type!, pool);
          viaKid.add(shape);
          final mapped = typeOf(type, pool).dartType;
          kidTypes.add(mapped);
          if (paneOf.containsKey(endpoint)) {
            kidAtCall.add(mapped);
          } else {
            kidOffCall.add(mapped);
            kidOffCallShape.add(shape);
          }
        }
      }
      for (final endpoint in wire.endpointOids) {
        if (paneOf[endpoint] case (final callee, final pane)) {
          final terminal = callee.paneTerminal(pane);
          if (terminal == null) continue;
          final type = lvClusterOfEndpoint(callee.diagram, terminal.oid, array: array);
          if (type == null) continue;
          viaPane.add(lvClusterShape(type, callee.pool));
          // Named through the CALLER's registry, so two readings hold one
          // [LvTypeMapping.dartType] exactly when they are one type in one
          // generated library.
          paneTypes.add(typeOf(type, callee.pool).dartType);
        }
      }
      final own = switch (shapes.length) {
        0 => 'none',
        1 => 'one',
        _ => 'many',
      };
      bump('clus.$own');
      if (shapes.length == 1 && bare.isEmpty) bump('clus.viaTypedef');
      if (bare.length == 1 && shapes.length > 1) bump('clus.typedefContradicts');
      if (viaPane.length == 1) bump('clus.pane.$own');
      if (shapes.length == 1 && viaPane.length == 1) {
        final agrees = shapes.single == viaPane.single;
        bump(agrees ? 'clus.paneAgrees' : 'clus.paneDisagrees');
        if (!agrees && shapes.single.split('|').last == viaPane.single.split('|').last) {
          bump('clus.paneNameOnly');
        }
      }
      if (viaKid.length == 1) bump('clus.kid.$own');
      if (shapes.length == 1 && viaKid.length == 1) {
        final agrees = shapes.single == viaKid.single;
        bump(agrees ? 'clus.kidAgrees' : 'clus.kidDisagrees');
        // A disagreement that is the descriptor NAME alone: the two readings
        // spell identical members under different typedefs.
        if (!agrees && shapes.single.split('|').last == viaKid.single.split('|').last) {
          bump('clus.kidNameOnly');
        }
      }
      // The same two routes, scored on the DART TYPE each reading maps to
      // rather than on the descriptor's own spelling — the identity a
      // generated library has, and the one the lowering compares by.
      final ownCount = switch (ownTypes.length) {
        0 => 'none',
        1 => 'one',
        _ => 'many',
      };
      bump('clusType.$ownCount');
      if (ownTypes.length == 1 && kidTypes.length == 1) {
        final agrees = ownTypes.single == kidTypes.single;
        bump(agrees ? 'clusType.kidAgrees' : 'clusType.kidDisagrees');
        if (!agrees && shapes.length == 1 && viaKid.length == 1) {
          bump(
            _clusterMemberCodes(shapes.single) == _clusterMemberCodes(viaKid.single)
                ? 'clusType.kidLabelOnly'
                : 'clusType.kidShapeDiffers',
          );
        }
      }
      if (ownTypes.isEmpty && kidTypes.length == 1) {
        if (kidTypes.single == null) {
          bump('clusType.kidWouldNotMap');
        } else {
          bump('clusType.kidWouldDecide');
          // Whether the pane reaches that wire at all, and so whether anything
          // decoded can check the type the part route would give it.
          bump(paneTypes.length == 1 ? 'clusType.kidChecked' : 'clusType.kidUnchecked');
        }
      }
      // The CALLEE's pane terminal, scored the same way. Its calibration is
      // against the reading the lowering already trusts, and its independence
      // is the two counters below it.
      if (paneTypes.length == 1) bump('clusType.pane.$ownCount');
      if (ownTypes.length == 1 && paneTypes.length == 1) {
        final agrees = ownTypes.single == paneTypes.single;
        bump(agrees ? 'clusType.paneAgrees' : 'clusType.paneDisagrees');
        if (!agrees && shapes.length == 1 && viaPane.length == 1) {
          bump(
            _clusterMemberCodes(shapes.single) == _clusterMemberCodes(viaPane.single)
                ? 'clusType.paneLabelOnly'
                : 'clusType.paneShapeDiffers',
          );
        }
      }
      if (ownTypes.isEmpty && paneTypes.length == 1) {
        bump(paneTypes.single == null ? 'clusType.paneWouldNotMap' : 'clusType.paneWouldDecide');
      }
      // Is the pane a second reading, or the caller's own cached copy of the
      // callee's terminal type? The same part route, read at the call node's
      // terminal and read anywhere else on the same wire.
      if (paneTypes.length == 1 && kidAtCall.length == 1) {
        bump(kidAtCall.single == paneTypes.single ? 'clusType.paneAtCallAgrees' : 'clusType.paneAtCallDisagrees');
      }
      if (paneTypes.length == 1 && kidOffCall.length == 1) {
        final agrees = kidOffCall.single == paneTypes.single;
        bump(agrees ? 'clusType.paneOffCallAgrees' : 'clusType.paneOffCallDisagrees');
        if (!agrees && kidOffCallShape.length == 1 && viaPane.length == 1) {
          bump(
            _clusterMemberCodes(kidOffCallShape.single) == _clusterMemberCodes(viaPane.single)
                ? 'clusType.paneOffCallLabelOnly'
                : 'clusType.paneOffCallShapeDiffers',
          );
        }
      }
      // Why this wire does not type — one cause per wire, the causes and
      // `clus.why.typed` partitioning `clus`.
      String causeOfWire() {
        if (ownTypes.isEmpty) {
          if (!anyTyped) return 'noneUntyped';
          final anyIndex = wire.endpointOids.any(
            (endpoint) => [
              if (diagram.byId[endpoint] case final object?) object,
              ...?childrenByOid[endpoint],
            ].any((object) => object.typeDescIdx != null),
          );
          return anyIndex ? 'noneNoCluster' : 'noneNoIndex';
        }
        if (ownTypes.length > 1) return 'typesDisagree';
        final mapping = ownMapping!;
        if (mapping.dartType == null) {
          final code = mapping.unmappedCode;
          return code == null ? 'descriptor' : 'member.0x${code.toRadixString(16)}';
        }
        if (lvDeclarationClosure(mapping.declarations).any((declaration) => declaration.undeclarable != null)) {
          return 'undeclarable';
        }
        return 'typed';
      }

      final cause = causeOfWire();
      bump('clus.why.$cause');
      if (cause != 'typed') {
        clusterWireCause[wire.signalOid] = cause;
        untypedFamilies.add('cluster');
      }
      if (shapes.isNotEmpty) continue;
      if (cause == 'noneUntyped') bump('clus.noneUntyped');
      if (cause == 'noneNoIndex') bump('clus.noneNoIndex');
      for (final endpoint in wire.endpointOids) {
        if (diagram.byId[endpoint]?.typeDescIdx != null) bump('clus.epTypeIdx');
      }
    }
  }

  // The generated-declaration census: what a lowering has to declare so that
  // the nominal types its cluster wires carry exist. One registry per VI, the
  // scope a generated library has, over exactly the wires that resolve a single
  // member shape — so it is independent of where a VI's lowering refuses.
  //
  // `decl.suffixed` is the collision rate the structural identity buys: a
  // declaration whose class name is not the plain [lvClassName] of its own
  // LabVIEW name, because a structurally different type in the same VI already
  // took it. `decl.noItems` is the one shape that cannot be declared at all.
  void censusDeclarations(ViDiagram diagram, List<ViType> pool) {
    final registry = LvDeclarations();
    for (final wire in diagram.wires) {
      final signal = wire.signalType;
      if (signal == null || !kLvWireClusterCodes.contains(signal.typeCode)) continue;
      if (mapLvWireType(signal).isMapped) continue;
      final array = (signal.arrayDims ?? 0) > 0;
      final resolved = <ViType>[
        for (final endpoint in wire.endpointOids)
          if (lvClusterOfEndpoint(diagram, endpoint, array: array) case final cluster?) cluster,
      ];
      if (resolved.isEmpty) continue;
      if ({for (final cluster in resolved) lvClusterShape(cluster, pool)}.length != 1) continue;
      lvClusterWireType(signal, resolved.first, pool, registry);
    }
    final declarations = registry.all.toList();
    if (declarations.isEmpty) return;
    bump('decl.vi');
    for (final declaration in declarations) {
      bump('decl');
      bump(declaration.isEnum ? 'decl.enum' : 'decl.cluster');
      final preferred = declaration.label == null ? LvRuntimeType.anonymousEnum : lvClassName(declaration.label!);
      if (declaration.name != preferred) bump('decl.suffixed');
      if (declaration.label == null) bump('decl.anonymous');
      if (declaration.undeclarable != null) bump('decl.noItems');
      if (declaration.fields.any((field) => field.label == null)) bump('decl.unnamedMember');
      // A member the naming policy had to move: its identifier is not the one
      // it would take on its own, because an earlier member, or a name every
      // Dart class inherits, already held it.
      final labels = [for (final field in declaration.fields) field.label];
      final named = LvNaming.declarationFields(labels);
      for (var index = 0; index < labels.length; index++) {
        if (named[index] != LvNaming.declarationFields([labels[index]]).single) bump('decl.displacedMember');
      }
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
  //
  // Three readings of a refnum wire's dimensionality are scored here, each
  // against the others and against the word where the word decides — the
  // evidence [lvRefnumWireDims] rests on:
  //
  // * `ref.part.*` — the endpoint's node-terminal PARTS, in the wire's own VI.
  //   This is the route the lowering reads.
  // * `ref.ep.*` — the endpoint DCO itself, one parent up. Measured and NOT
  //   read: on the word's ground-truth row it invents an array 1 335 times.
  // * `ref.pane.*` — the CALLEE's connector-pane terminal where the wire ends
  //   on a subVI call: a different route (a terminal's own descriptor, not a
  //   part's) in a different file, and the only one of the three that answers
  //   on both the scalar and the array row of the undecided wires. `ref.pane.law*`
  //   is its calibration against the depth-1 law, `ref.pane.vs*` its verdict on
  //   the part route, and `ref.pane.contraCell*` where the two disagree
  //   ([kLvRefnumContradictedCells]).
  void censusRefnumWires(ViDiagram diagram) {
    final childrenByOid = diagram.childrenByOid;
    final refnumEndpoints = <int>{
      for (final wire in diagram.wires)
        if (kLvWireRefnumCodes.contains(wire.signalType?.typeCode)) ...wire.endpointOids,
    };
    final paneOf = refnumEndpoints.isEmpty ? const <int, (LvViUnit, int)>{} : paneTerminalsOf(diagram, refnumEndpoints);
    for (final wire in diagram.wires) {
      final signal = wire.signalType;
      if (signal == null) continue;
      final dims = signal.arrayDims;
      if (kLvWireRefnumCodes.contains(signal.typeCode)) {
        bump('ref');
        bump(dims == null ? 'ref.undecided' : 'ref.scalar');
        // The three descriptor routes as a source for the dimensionality the
        // word's missing base withholds, each scored against the other's
        // answer and against the word where the word decides.
        final viaEndpoint = <int>{}, viaPart = <int>{}, viaPane = <int>{};
        for (final endpoint in wire.endpointOids) {
          var walker = diagram.byId[endpoint];
          for (var depth = 0; walker != null && depth < 2; depth++) {
            if (_refnumDims(walker) case final answer?) {
              viaEndpoint.add(answer);
              break;
            }
            final parent = walker.parentOid;
            walker = parent == null ? null : diagram.byId[parent];
          }
          for (final part in childrenByOid[endpoint] ?? const <ViHeapObject>[]) {
            if (_refnumDims(part) case final answer?) viaPart.add(answer);
          }
          if (paneOf[endpoint] case (final callee, final pane)) {
            final terminal = callee.paneTerminal(pane);
            if (terminal == null) continue;
            var calleeWalker = callee.diagram.byId[terminal.oid];
            for (var depth = 0; calleeWalker != null && depth < 2; depth++) {
              if (_refnumDims(calleeWalker) case final answer?) {
                viaPane.add(answer);
                break;
              }
              final parent = calleeWalker.parentOid;
              calleeWalker = parent == null ? null : callee.diagram.byId[parent];
            }
          }
        }
        if (viaPart.length > 1) bump('ref.part.split');
        if (viaEndpoint.length > 1) bump('ref.ep.split');
        if (viaPane.length > 1) bump('ref.pane.split');
        if (dims != null) {
          if (viaPart.length == 1) bump(viaPart.single == dims ? 'ref.part.agrees' : 'ref.part.contradicts');
          if (viaEndpoint.length == 1) bump(viaEndpoint.single == dims ? 'ref.ep.agrees' : 'ref.ep.contradicts');
          // The pane route's calibration: on the row the word decides, does the
          // callee's terminal ever invent an array the word says is not there?
          if (viaPane.length == 1) bump(viaPane.single == dims ? 'ref.pane.lawAgrees' : 'ref.pane.lawContradicts');
        } else {
          if (viaPart.length == 1 && viaPane.length == 1) {
            final agrees = viaPart.single == viaPane.single;
            bump(agrees ? 'ref.pane.vsAgrees' : 'ref.pane.vsContradicts');
            // Both error directions, kept apart: the pane declining an array
            // the part route reads, and the pane reading one the part route
            // declines. A one-sided oracle can only ever fill one of these.
            if (!agrees) bump('ref.pane.vs${viaPart.single > viaPane.single ? 'Invented' : 'Missed'}');
            bump(
              'ref.pane.contraCell.${signal.typeCode.toRadixString(16)}_d${signal.depth}'
              '.${agrees ? 'agrees' : 'contradicts'}',
            );
          }
          // The array row of the undecided wires, which only the pane route
          // reaches: how many wires it calls one-dimensional at all.
          if (viaPane.length == 1) bump('ref.pane.dims${viaPane.single}');
          if (viaPart.length == 1) {
            bump('ref.part.decides');
            bump('ref.part.dims${viaPart.single}');
            bump('ref.part.base${signal.depth - viaPart.single}');
            if (kLvRefnumContradictedCells.contains((signal.typeCode, signal.depth))) {
              bump('ref.part.contradictedCell');
            } else {
              bump('ref.part.read');
            }
          } else if (viaPart.isEmpty) {
            bump('ref.part.silent');
          }
          bump('render.refUndecided.${signal.renderStyle == null ? 'styleMute' : 'styleSpeaks'}');
        }
      } else if (dims != null) {
        bump('flag${signal.flags}.${dims > 0 ? 'array' : 'scalar'}');
      }
      // Whether the wire's MEASURED render stroke ([ViSignalTypeRenderStyle])
      // says anything where the word's array-depth base does not — the whole
      // question of whether LabVIEW's own drawing can supply the missing
      // dimensionality. It is a pure function of the same 12 bits
      // ([ViSignalType.arrayDims] reads), so it can only ever restate them.
      if (dims == null) {
        bump('render.lawSilent.${signal.renderStyle == null ? 'styleMute' : 'styleSpeaks'}');
      }
      // The non-cluster half of the untyped-family set the refusal
      // attribution below reads; the cluster half is filled by the cluster
      // census, which needs an endpoint walk to decide it.
      if (!kLvWireClusterCodes.contains(signal.typeCode) && !mapLvWireType(signal).isMapped) {
        untypedFamilies.add(_wireFamilyName(signal.typeCode));
      }
    }
  }

  /// Which wire family this VI's OWN `wireType` refusal names, and — for a
  /// cluster wire — which sub-cause of [censusClusterWires]. `wt.sole.*` is the
  /// VIs carrying no untyped wire of any other family, so the named family is
  /// the whole distance to a typed diagram.
  ///
  /// Read off the VI's own dataflow build rather than off its library
  /// emission: heap oids repeat across VIs, so a refusal raised in a CALLEE's
  /// diagram cannot be identified against this one's signals.
  void censusWireTypeRefusal(ViDiagram diagram, LvRefusal refusal) {
    final wire = diagram.wires.where((wire) => wire.signalOid == refusal.oid).firstOrNull;
    final signal = wire?.signalType;
    if (signal == null) return bump('wt.noSignalWord');
    final family = _wireFamilyName(signal.typeCode);
    bump('wt.$family');
    if (untypedFamilies.length == 1) bump('wt.sole.$family');
    if (clusterWireCause[wire!.signalOid] case final cause?) bump('wt.cause.$cause');
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

  // The unmapped-primitive census of one diagram: which operations it uses
  // that [lvPrimHasRule] does not admit, how many nodes each accounts for, and
  // whether it is the only one the VI carries — the ranking key, since mapping
  // one identity clears a VI's primitive blockers only when nothing else is
  // left. Identity-level exactly as the snippet review list is, so a node whose
  // identity has a rule but whose own operands do not resolve is not counted
  // here; `exceptions.primitive` is what sizes those.
  void censusPrimitives(ViDiagram diagram) {
    final here = <String, int>{};
    for (final object in diagram.objects) {
      if (object.category != ViObjectKind.node) continue;
      if (kSubViCallNodeCodes.contains(object.kind)) continue;
      if (object.kind == kLvCallLibraryClass) continue;
      final op = object.primResId == null ? null : PrimOp.fromId(object.primResId!);
      if (lvPrimHasRule(op: op, classCode: object.kind, primResId: object.primResId)) continue;
      final key = _reviewKey(op, object);
      here[key] = (here[key] ?? 0) + 1;
    }
    for (final entry in here.entries) {
      prims['nodes|${entry.key}'] = (prims['nodes|${entry.key}'] ?? 0) + entry.value;
      prims['vis|${entry.key}'] = (prims['vis|${entry.key}'] ?? 0) + 1;
    }
    if (here.length == 1) {
      prims['sole|${here.keys.single}'] = (prims['sole|${here.keys.single}'] ?? 0) + 1;
    }
  }

  // Per subVI call class, whether a node's holder count equals its named
  // callee's connector-pane width — over every node in the corpus, not only
  // the calls an entry VI reaches. See [kCorpusLoweringSweep]'s `pane.*`.
  void censusCallPaneWidths(ViDiagram diagram) {
    for (final node in diagram.objects) {
      if (!kSubViCallNodeCodes.contains(node.kind)) continue;
      final name = node.label?.trim().toLowerCase();
      if (name == null || !(name.endsWith('.vi') || name.endsWith('.vim'))) continue;
      final width = paneWidth(name);
      if (width == null || width == 0) continue;
      final holders = diagram.children(node.oid).where((kid) => kid.kind == kLvHolderCode).length;
      final tag = 'pane.0x${node.kind.toRadixString(16)}';
      bump(holders == width ? '$tag.equal' : '$tag.differs');
    }
  }

  // The **foreign-call census**: what the Call Library Function nodes name.
  void censusForeignCalls(ViDiagram diagram) {
    var here = 0;
    for (final object in diagram.objects) {
      if (object.kind != kLvCallLibraryClass) continue;
      here++;
      bump('foreign.node');
      final library = object.foreignLibraryPath;
      final entry = object.foreignEntryPoint;
      if (library == null) bump('foreign.noLibrary');
      if (entry == null) bump('foreign.noEntryPoint');
      if (library != null) foreign.add('lib|$library');
      if (entry != null) foreign.add('entry|$entry');
    }
    if (here > 0) bump('foreign.vi');
  }

  for (final path in paths) {
    final unit = load(path, path.split(Platform.pathSeparator).last);
    if (unit == null) continue;
    bump('vi');
    censusPrimitives(unit.diagram);
    censusCallPaneWidths(unit.diagram);
    censusForeignCalls(unit.diagram);
    builds = <String, ({LvDataflow? dataflow, LvRefusal? refusal})>{};
    registry = LvDeclarations();
    clusterWireCause = <int, String>{};
    untypedFamilies = <String>{};
    censusConditionals(unit.diagram);
    censusClusterWires(unit.diagram, unit.pool);
    censusDeclarations(unit.diagram, unit.pool);
    censusIndexArrays(unit.diagram);
    censusRefnumWires(unit.diagram);
    final built = buildOf(unit);
    censusInPlaceElement(unit.diagram, built.refusal);
    if (built.dataflow case final flow?) walk(flow, flow.root);
    if (built.refusal case final refusal? when refusal.kind == LvRefusalKind.wireType) {
      censusWireTypeRefusal(unit.diagram, refusal);
    }
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
  return (tally: tally, sources: emitted, prims: prims, foreign: foreign);
}

/// The whole-corpus sweep, run once however many tests read it: it decodes
/// every VI in the corpus, so paying for it twice would double this file's
/// runtime.
Future<({Map<String, int> tally, Set<String> sources, Map<String, int> prims, Set<String> foreign})> corpusSweep(
  Directory corpus,
) => _corpusSweep ??= _runCorpusSweep(corpus);

Future<({Map<String, int> tally, Set<String> sources, Map<String, int> prims, Set<String> foreign})>? _corpusSweep;

Future<({Map<String, int> tally, Set<String> sources, Map<String, int> prims, Set<String> foreign})> _runCorpusSweep(
  Directory corpus,
) async {
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
  final prims = <String, int>{};
  final foreign = <String>{};
  for (final result in results) {
    result.tally.forEach((key, value) => tally[key] = (tally[key] ?? 0) + value);
    result.prims.forEach((key, value) => prims[key] = (prims[key] ?? 0) + value);
    sources.addAll(result.sources);
    foreign.addAll(result.foreign);
  }
  return (tally: tally, sources: sources, prims: prims, foreign: foreign);
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
            final twoWay = type != null && (type.isErrorCluster || type.carrier == LvCarrier.boolean);
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
      expect(measured, {...kCorpusLoweringSweep, ...kCorpusInPlaceElement});
      // The two independent checks on the pane binding: neither is used to
      // derive it, so a disagreement would mean the contract is wrong.
      // Direction admits none; the four type exceptions are attributed in
      // [kCorpusLoweringSweep]'s doc and pinned exactly by the map above.
      expect(measured['term.dirDisagree'], isNull, reason: 'the pane binding contradicts the caller\'s own direction');
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
        final analyzed = Process.runSync(_kDart, [
          'analyze',
          '--fatal-infos',
          '${scratch.path}/lib',
        ], workingDirectory: scratch.path);
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

  test(
    'the corpus primitive review list is exactly what the whole corpus holds',
    () async {
      final prims = (await corpusSweep(corpus!)).prims;
      final identities = <String>{for (final key in prims.keys) key.split('|').skip(1).join('|')};
      final measured = <String, ({int vis, int nodes, int sole})>{
        for (final identity in identities)
          identity: (
            vis: prims['vis|$identity'] ?? 0,
            nodes: prims['nodes|$identity'] ?? 0,
            sole: prims['sole|$identity'] ?? 0,
          ),
      };
      final ranked = identities.toList()
        ..sort((a, b) {
          final byVis = measured[b]!.vis.compareTo(measured[a]!.vis);
          return byVis != 0 ? byVis : a.compareTo(b);
        });
      final frequent = <String, ({int vis, int nodes, int sole})>{
        for (final identity in ranked)
          if (measured[identity]!.vis >= kCorpusReviewListFloor) identity: measured[identity]!,
      };
      printOnFailure(
        'measured:\n${[
          for (final identity in ranked) "  '$identity': (vis: ${measured[identity]!.vis}, "
                'nodes: ${measured[identity]!.nodes}, sole: ${measured[identity]!.sole}),',
        ].join('\n')}',
      );
      expect(frequent, kCorpusPrimReviewList);
      expect(
        (
          identities: identities.length,
          nodes: measured.values.fold(0, (sum, entry) => sum + entry.nodes),
          vis: measured.values.fold(0, (sum, entry) => sum + entry.vis),
        ),
        kCorpusPrimTotals,
        reason: 'the corpus review list moved; re-pin it against the measured corpus',
      );
    },
    tags: 'corpus',
    skip: corpus == null ? 'corpus not fetched' : null,
  );

  test(
    'every Call Library Function node names the library and entry point it calls',
    () async {
      final swept = await corpusSweep(corpus!);
      final measured = (
        libraries: swept.foreign.where((entry) => entry.startsWith('lib|')).length,
        entryPoints: swept.foreign.where((entry) => entry.startsWith('entry|')).length,
      );
      printOnFailure('measured: $measured');
      expect(measured, kCorpusForeignCalls);
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
        if (lvPrimHasRule(op: op, classCode: object.kind, primResId: object.primResId)) continue;
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
        LvPrimTerminal(
          port: port,
          type: edge.type,
          roleFlags: node.portRoleFlags[port] ?? 0,
          expression: 'x',
          memberName: node.portMemberName[port],
        ),
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
      nodeFlags: node.nodeFlags,
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

/// A [lvClusterShape] spelling with every LABEL dropped: the member type codes
/// alone, in order.
///
/// It separates the two things a cluster descriptor states. The codes are what
/// the wire CARRIES; the labels — the descriptor's own name and its members' —
/// are what a generated class is NAMED from. Two readings of one wire that
/// share this string and differ in the full spelling differ only in naming.
String _clusterMemberCodes(String shape) =>
    shape.split('|').last.split(',').map((member) => member.split(':').first).join(',');

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

/// The array dimensionality [object]'s resolved data-space descriptor states
/// for a REFNUM value — 0 for a bare reference, the array's own dimension count
/// for an array of them — or null when the descriptor is not a refnum shape.
///
/// It is what a refnum wire's dimensionality would come from if it came from a
/// descriptor rather than from the signal word, whose depth base rides the
/// reference class ([kSignalMinScalarDepth]). Typedef wrappers are transparent,
/// exactly as [lvClusterBase] makes them for a cluster.
int? _refnumDims(ViHeapObject object) {
  ViType? unwrap(ViType? type) {
    for (var depth = 0; type != null && depth < kLvTypedefDepth; depth++) {
      if (type.kind != ViDataType.typeDef) return type;
      type = type.typedefBase;
    }
    return null;
  }

  final own = unwrap(object.resolvedType);
  if (own == null) return null;
  if (own.kind == ViDataType.refnum) return 0;
  if (own.kind != ViDataType.array) return null;
  return unwrap(object.resolvedElementType)?.kind == ViDataType.refnum ? (own.dimCount ?? 1) : null;
}

/// A signal word's element type [code] as a family name — the two multi-code
/// families by name ([kLvWireClusterCodes], [kLvWireRefnumCodes]) and every
/// other code by its own number, which is how the refusal census groups the
/// wires a VI cannot type.
String _wireFamilyName(int code) {
  if (kLvWireClusterCodes.contains(code)) return 'cluster';
  if (kLvWireRefnumCodes.contains(code)) return 'refnum';
  return 'code0x${code.toRadixString(16)}';
}

String _reviewKey(PrimOp? op, ViHeapObject object) {
  if (op != null) return '${op.opName} (primResID ${op.id})';
  if (object.primResId case final id?) return 'primResID $id (name not decoded)';
  return 'node class 0x${object.kind.toRadixString(16)}';
}
