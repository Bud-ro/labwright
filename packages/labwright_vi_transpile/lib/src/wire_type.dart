/// The **wire** half of the type model: what a decoded block-diagram signal
/// word ([ViSignalType]) carries, expressed in the same [LvTypeMapping] terms
/// the consolidated type pool resolves to.
///
/// A signal word is not a pool descriptor — it holds an element type code, an
/// array depth and a flag nibble, and nothing else. That is exactly enough to
/// type a dataflow edge, and it is per-wire rather than per-terminal, so it is
/// the authority on what flows: a tunnel whose two sides carry different
/// dimensionalities is visible here as two different [LvWireType]s.
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'numeric.dart';
import 'type_map.dart';

/// The Dart type of one dataflow edge.
class LvWireType {
  LvWireType._({required this.dims, required this.element, required this.value});

  /// The Dart representation of the edge's **element** — the scalar under any
  /// array wrapping, and the whole value itself when [dims] is 0.
  final LvTypeMapping element;

  /// The Dart representation of the whole edge value.
  final LvTypeMapping value;

  /// The array dimension count: 0 for a scalar edge, 1 for a 1-D array.
  final int dims;

  /// The element's numeric width model, or null when it is not a number.
  LvNumericKind? get numeric => element.numeric;

  /// Whether the whole edge value has a decided Dart representation.
  bool get isMapped => value.isMapped;

  /// The declarations the edge's Dart type names ([LvTypeMapping.declarations]).
  List<LvTypeDecl> get declarations => value.declarations;

  /// The Dart type source of the whole edge value, or null when unmapped.
  String? get dartType => value.dartType;

  /// [expression] renormalized to the element's LabVIEW width — the identity
  /// for a non-numeric or already-exact carrier.
  String wrap(String expression) => numeric?.wrap(expression) ?? expression;

  /// The Dart type of a 1-D array **over this edge's element**: the storage a
  /// value of this element type is collected into.
  String get elementListType => lvArrayDartType(element, 1);

  /// Whether the edge carries a bare LabVIEW **error cluster** — the wire an
  /// [LvErrorMode] decides the carrier of. An array of error clusters is
  /// ordinary data and is not one.
  bool get isErrorCluster => dims == 0 && value.dartType == LvRuntimeType.error;

  /// This edge's type with its array wrapping removed — the scalar an
  /// elementwise lowering operates on. Already scalar edges return themselves.
  LvWireType get scalar => dims == 0 ? this : LvWireType._(dims: 0, element: element, value: element);
}

/// The Dart type of a wire whose decoded signal word is [signal].
///
/// Total: a word whose element code has no decided representation, or whose
/// array depth base is not pinned ([ViSignalType.arrayDims] null), comes back
/// with an unmapped [LvWireType.value] carrying the reason — never a guess.
LvWireType mapLvWireType(ViSignalType signal) {
  final dims = signal.arrayDims;
  final element = _mapSignalElement(signal.typeCode);
  if (dims == null) {
    final why =
        'wire type code 0x${signal.typeCode.toRadixString(16)} has no pinned '
        'array-depth base, so the wire\'s dimensionality is not decoded';
    return LvWireType._(dims: 0, element: element, value: LvTypeMapping.unmapped(why));
  }
  if (dims == 0 || !element.isMapped) {
    return LvWireType._(dims: dims, element: element, value: element);
  }
  return LvWireType._(
    dims: dims,
    element: element,
    value: LvTypeMapping.mapped(lvArrayDartType(element, dims)),
  );
}

/// The Dart type of a **refnum** wire whose dimensionality comes from the data
/// space rather than from the signal word ([lvRefnumWireDims]).
///
/// The word carries the reference family and a depth, but not the base that
/// separates the two ([ViSignalType.arrayDims] is null above
/// [kSignalMinScalarDepth]); [dims] supplies it. The element is the same
/// [LvRuntimeType.refnum] a word-decided refnum wire carries, so the only thing
/// this adds is the array wrapping.
LvWireType lvRefnumWireType(ViSignalType signal, int dims) {
  final element = _mapSignalElement(signal.typeCode);
  if (dims == 0 || !element.isMapped) {
    return LvWireType._(dims: dims, element: element, value: element);
  }
  return LvWireType._(dims: dims, element: element, value: LvTypeMapping.mapped(lvArrayDartType(element, dims)));
}

/// The `(code, depth)` signal-word cells where the two decoded readings of a
/// refnum wire's dimensionality **contradict each other**, so neither is read.
///
/// The readings are the endpoint's node-terminal **parts** in the wire's own VI
/// ([lvRefnumWireDims]) and the **callee's connector-pane terminal** where the
/// wire ends on a subVI call — a different route (the terminal's own descriptor,
/// not a part's) in a different file. Corpus-wide they answer together on 4 838
/// of the 37 891 refnum wires the word does not decide and agree on 4 827
/// (99.77%), but the 11 disagreements are not spread: 10 of them sit in this one
/// cell, where the pane contradicts the part route on 10 of the 101 wires it
/// tests (9.9%) while the whole rest of the corpus agrees 4 736 of 4 737
/// (99.98%). A cell in which a corroborating route dissents at a tenth of its
/// samples is not decided by either reading, so its 1 494 wires keep the
/// word's own refusal.
///
/// TODO: revisit when a third reading of a plain-refnum depth-4 wire is decoded
/// — the two present ones split the cell between base 3 (part) and base 4
/// (pane) and nothing decoded says which the reference class carries.
const Set<(int, int)> kLvRefnumContradictedCells = {(TypeCode.refnum, 4)};

/// The **dimensionality** of a refnum wire whose signal word does not carry it,
/// read from the data-space type descriptors on the node-terminal **part**
/// objects its endpoints parent — or null when nothing decoded decides it.
///
/// A refnum wire's depth base rides the reference class rather than the type
/// code, so the word alone decides only the depth-1 wires
/// ([kSignalMinScalarDepth]): 28 582 of the corpus's 66 473 refnum-coded
/// signals. The parts carry the data-space index the endpoint DCO itself never
/// does, and their descriptor states the dimension count outright.
///
/// Null when the parts state nothing (5 459 wires), when two of them state
/// different counts, or when the wire's word sits in a
/// [kLvRefnumContradictedCells] cell. It decides 30 938 of the remaining
/// 37 891.
///
/// **Why the reading is read.** Two independent checks, each on a different
/// byte record:
///
/// * against the **signal word**, on the 26 796 depth-1 wires where the word
///   decides and a part also speaks, the part route reproduces the word's
///   answer 26 796 times and contradicts it **0** times. That check is
///   one-sided — every wire the word decides is scalar, so it catches an
///   invented array and cannot catch a missed one.
/// * against the **callee's connector pane**, which supplies the missing side:
///   it answers on both rows (4 661 scalar, 177 one-dimensional) and agrees on
///   4 827 of 4 838. It is itself calibrated on the word's ground-truth row —
///   1 869 depth-1 wires, 1 869 agreements, **0** contradictions — unlike the
///   caller-side endpoint walk, which on that same row invents an array on
///   1 335 of the 15 381 wires it answers (8.7%) and so is not read.
///
/// The residue is [kLvRefnumContradictedCells].
int? lvRefnumWireDims(ViDiagram diagram, ViWire wire) {
  final signal = wire.signalType;
  if (signal == null || !kLvWireRefnumCodes.contains(signal.typeCode)) return null;
  if (signal.arrayDims != null) return null;
  if (kLvRefnumContradictedCells.contains((signal.typeCode, signal.depth))) return null;
  int? answer;
  for (final endpoint in wire.endpointOids) {
    for (final part in diagram.childrenByOid[endpoint] ?? const <ViHeapObject>[]) {
      final dims = _refnumDimsOf(part);
      if (dims == null) continue;
      if (answer != null && answer != dims) return null;
      answer = dims;
    }
  }
  return answer;
}

/// The refnum dimensionality [object]'s resolved data-space type states: 0 for
/// a refnum descriptor, the dimension count for an array whose element is one,
/// and null for every other descriptor. Typedefs are looked through on both
/// halves, as [lvClusterBase] does for clusters.
int? _refnumDimsOf(ViHeapObject object) {
  final own = _throughTypedefs(object.resolvedType);
  if (own == null) return null;
  if (own.kind == ViDataType.refnum) return 0;
  if (own.kind != ViDataType.array) return null;
  return _throughTypedefs(object.resolvedElementType)?.kind == ViDataType.refnum ? (own.dimCount ?? 1) : null;
}

/// [type] with up to [kLvTypedefDepth] typedef wrappers removed, or null when
/// it is absent or the walk does not reach a non-typedef descriptor.
ViType? _throughTypedefs(ViType? type) {
  for (var depth = 0; type != null && depth < kLvTypedefDepth; depth++) {
    if (type.kind != ViDataType.typeDef) return type;
    type = type.typedefBase;
  }
  return null;
}

/// Element codes carried by a **runtime type** ([LvRuntimeType]) rather than
/// by a Dart core type. The runtime declares each of them, so a wire of one of
/// these is typed exactly as a numeric wire is.
///
/// The refnum codes are here too. A refnum wire's depth base rides its
/// reference class rather than its code, so only the ones the depth-1 law
/// decides ([kSignalMinScalarDepth]) carry a dimensionality; a deeper refnum
/// word reaches this map with [ViSignalType.arrayDims] null and is refused.
const Map<int, String> kLvWireRuntimeCarriers = {
  TypeCode.path: LvRuntimeType.path,
  TypeCode.variant: LvRuntimeType.variant,
  TypeCode.refnum: LvRuntimeType.refnum,
  ViSignalType.typedRefnumCode: LvRuntimeType.refnum,
};

/// The element codes of a **refnum** wire, in both the plain and the
/// inner-typed form ([ViSignalType.typedRefnumCode]).
const Set<int> kLvWireRefnumCodes = {TypeCode.refnum, ViSignalType.typedRefnumCode};

/// The element codes of a **cluster** wire, in both the plain and the
/// typedef/class form ([ViSignalType.clusterVariantCode]).
const Set<int> kLvWireClusterCodes = {TypeCode.cluster, ViSignalType.clusterVariantCode};

/// How many typedef wrappers [lvClusterBase] looks through. The pool decodes
/// a typedef's base inline and admits a typedef of a typedef, so the walk is
/// bounded rather than open-ended.
const int kLvTypedefDepth = 8;

/// The **cluster** [type] stands for: itself when it is one, and the base of a
/// typedef over one. Null for every other descriptor.
///
/// A typedef is transparent to its base — [mapLvType] already reads it that
/// way, giving the typedef's name to the cluster it wraps — so a typedef over
/// a cluster is a cluster descriptor for the purpose of typing a wire. It is
/// also the shape the `0x51` wire code names (the typedef'd / class-typed
/// cluster family), and looking through it resolves 9 381 of the corpus's
/// 133 106 cluster wires that the bare-cluster test alone leaves with no
/// member shape, while contradicting that test on 24.
ViType? lvClusterBase(ViType? type) {
  for (var depth = 0; type != null && depth < kLvTypedefDepth; depth++) {
    if (type.kind == ViDataType.cluster) return type;
    if (type.kind != ViDataType.typeDef) return null;
    type = type.typedefBase;
  }
  return null;
}

/// A cluster descriptor's **spelling**: its own name, and its members' type
/// codes and names. Two pool entries with the same spelling describe the same
/// LabVIEW cluster however many entries spell it.
///
/// It is a census identity, not the wire's. What decides whether two endpoints
/// of one wire carry the same value is the Dart type each maps to
/// ([mapLvType]) — the identity a generated library has — and the two answers
/// differ: the spelling counts a wire whose ends are an `error in` and an
/// `error out` control as two types where the mapping counts one. The lowering
/// compares by the mapping; the corpus sweep pins both, as `clus.*` against
/// `clusType.*`.
String lvClusterShape(ViType type, List<ViType> pool) {
  final members = clusterFields(lvClusterBase(type) ?? type, pool);
  return '${type.name ?? ''}|${members.map((member) => '${member.code}:${member.name ?? ''}').join(',')}';
}

/// The cluster descriptor the wire endpoint [oid] resolves in [diagram], or
/// null when neither it nor its owner carries one. A typedef over a cluster is
/// returned as itself ([lvClusterBase]), so the wire keeps the typedef's name.
///
/// [array] selects which half of an endpoint's resolved type to read: the
/// element descriptor of a resolved array for an array-of-cluster wire, and
/// the type itself for a scalar cluster wire. Reading the OTHER half instead
/// would resolve a further 586 wires, but it asserts that an endpoint
/// describing an array of clusters describes a scalar cluster wire's element
/// (and the converse) — which nothing decoded says — so it is not read. The
/// walk stops at the endpoint's owner: the corpus resolves nothing further up
/// (a 1-, 2- and 6-parent walk return identical counts over all 133 106
/// cluster-coded signals).
///
/// It stops there because the ancestors hold nothing. Across the endpoints of
/// the cluster wires no endpoint resolves, NOT ONE carries a type-descriptor
/// index of its own ([ViHeapObject.typeDescIdx]) — a wire endpoint is a holder
/// (`0x15`) or an interface terminal (`0x16`), and neither class stores one.
/// Every type such an endpoint has is inherited from a paired panel DCO
/// through its `dcoRef`, and most carry no `dcoRef` either.
///
/// **Where the data space does type a wire**, and why that route is not read:
/// the index lives one level DOWN, on the node-terminal **part** objects a
/// bounds-less `0x15` endpoint parents (`0x2d`, `0x33`, `0x30`, `0x62`, `0x8e`,
/// `0x13`, … — the same parts [ViDiagram.dcoChildTerminalAttach] reads geometry
/// from). Every one of them carries a [ViHeapObject.typeDescIdx]. The
/// **signal object itself carries no index at all** — a census of all 428 043
/// corpus signals finds exactly four record families on the `0x17` class (the
/// `14 19` endpoint refs 428 043, the wire-type word `0x9f` 428 029, the
/// `0x115` state word 427 610 and the `0x1e7` route table), plus objFlags and
/// a handful of cosmetic tags; no data-space index, generation or ordinal.
///
/// Scored on the DART TYPE the two routes map to — the identity that decides
/// whether a lowering can use one for the other — the part route reproduces
/// the endpoint route's answer on 68 112 of the 70 051 wires where both speak
/// (97.2%), and would newly type 38 236 of the 41 120 wires no endpoint
/// resolves. That is far better than the descriptor spelling scores it
/// (44 977 of 68 982, 65.2%, `clus.kidAgrees`), because most of what the
/// spelling counts as a conflict is one type under two control labels.
///
/// It is still not read, and 1 939 wires are the reason: two decoded readings
/// of one wire that map to DIFFERENT Dart types, with nothing decoded saying
/// which is the wire's. They are not a naming artefact — among them are wires
/// where one route reads a `point` of two `I16` and the other a `point` of two
/// `DBL`. Restricting the part route by descriptor kind does not separate them
/// either: a plain-cluster part against a plain-cluster endpoint agrees on
/// 54 555 of 54 997 (99.2%) and a typedef part against a typedef endpoint on
/// 13 553 of 14 983 (90.5%), so the typedef — the descriptor that carries an
/// owning-library path and so a file identity — is the WORSE of the two, not
/// the better. The route is measured ([kCorpusLoweringSweep]'s `clus.kid*` and
/// `clusType.kid*`) and not read.
///
/// The per-VI base the heap's indices carry is **decoded** from the `DTHP`
/// header (see `resolveDataSpaceTypes`), so the wires that resolve nothing are
/// no longer dominated by VIs that type nothing: of the 41 120 unresolved
/// cluster wires only 391 sit in a VI where no object resolves a type at all
/// (`clus.noneUntyped`) and 46 reach no index at all (`clus.noneNoIndex`).
/// What remains is wires whose endpoints hold no cluster descriptor of their
/// own — a walk question, not a base question.
ViType? lvClusterOfEndpoint(ViDiagram diagram, int oid, {required bool array}) {
  var object = diagram.byId[oid];
  for (var depth = 0; object != null && depth < 2; depth++) {
    final type = array ? object.resolvedElementType : object.resolvedType;
    if (lvClusterBase(type) != null) return type;
    final parent = object.parentOid;
    object = parent == null ? null : diagram.byId[parent];
  }
  return null;
}

/// The Dart type of a cluster wire whose element descriptor is [cluster],
/// resolved against the VI's type [pool].
///
/// The signal word says only *cluster*; the member types come from the
/// data-space type an endpoint of the wire resolves ([lvClusterOfEndpoint]).
/// Corpus, over 133 106 cluster-coded signals in 7 508 block diagrams: 91 829
/// resolve exactly one Dart type, 41 120 have no endpoint that resolves a
/// cluster descriptor at all, and 157 resolve two or more. The agreement where
/// two ends can be compared is the evidence the route is sound; a wire whose
/// ends disagree, and a wire no end resolves, are both refused rather than
/// picked between.
///
/// Two ends are compared by what they MAP TO, not by what they spell: of the
/// 1 372 wires whose ends resolve two different descriptor spellings
/// (`clus.many`), 1 353 differ by the descriptor's own name alone — the label
/// of the control each end is, `error in` against `error out` — and 1 216 of
/// those name the same Dart type. Only 19 differ in a member at all.
///
/// The **callee's connector pane** is not a second source. A call node's
/// holders are its pane terminals in pane order (the binding the subVI
/// contract already proves at 99.83%), so a cluster wire ending on one can be
/// read against the callee VI's own terminal for that pane — but measured over
/// the corpus that reading decides only 4 230 of the unresolved wires, and
/// where both it and the endpoint route resolve exactly one shape it
/// reproduces that shape 2 626 times against 3 651 disagreements — of which
/// 3 608 are the descriptor NAME alone (`clus.paneNameOnly`): caller and
/// callee spell the same members under different typedefs, and the name is
/// what the emitted Dart type is. Two readings that name a wire differently
/// more than half the time are not one route, so the pane side is measured
/// ([kCorpusLoweringSweep]'s `clus.pane*`) and not read.
///
/// The unresolved majority is the corpus's single largest lowering blocker.
/// Of the 6 063 VIs whose own dataflow build refuses on `wireType`, the wire
/// the refusal names is a cluster wire in 3 696, and 1 901 have no untyped wire
/// of any other family at all. Within those 3 696 the sub-cause is measured
/// (`wt.cause.*`): 3 549 name a wire whose endpoints resolve no cluster
/// descriptor, 57 + 14 a cluster holding a review-list member (waveform `0x54`,
/// picture `0x33`), 51 a wire whose ends resolve two different Dart types, and
/// 25 a VI whose data space types nothing.
///
/// Next is the refnum codes' array-depth base, which rides the reference class
/// rather than the code (named first in 1 154 VIs, the sole family in 666 — the
/// depth-1 law [kSignalMinScalarDepth] and [lvRefnumWireDims] between them
/// decide the rest of those wires), and then the element codes with no Dart
/// representation (the uncatalogued `0xff` 70, measureData `0x54` 81, packed
/// string `0x33` 46, tag `0x37` 22).
LvWireType lvClusterWireType(ViSignalType signal, ViType cluster, List<ViType> pool, [LvDeclarations? declarations]) {
  final element = mapLvType(cluster, pool, 0, declarations);
  final dims = signal.arrayDims ?? 0;
  if (dims == 0 || !element.isMapped) {
    return LvWireType._(dims: dims, element: element, value: element);
  }
  return LvWireType._(
    dims: dims,
    element: element,
    value: LvTypeMapping.mapped(lvArrayDartType(element, dims), declarations: element.declarations),
  );
}

/// The Dart representation of a signal word's element type [code].
///
/// The wire word carries only the flattened scalar family — enums, typedefs
/// and substrings ride their flattened code — so this resolves the leaf codes
/// directly rather than through a pool descriptor.
LvTypeMapping _mapSignalElement(int code) {
  if (LvNumericKind.ofCode(code) case final kind?) {
    return LvTypeMapping.mapped(kind.dartType, numeric: kind);
  }
  if (kLvWireClusterCodes.contains(code)) {
    return LvTypeMapping.unmapped(
      'a cluster wire\'s member types are not in the signal word, and no '
      'endpoint of this wire resolves a cluster descriptor to take them from',
      unmappedCode: code,
    );
  }
  if (kLvWireRuntimeCarriers[code] case final carrier?) {
    return LvTypeMapping.mapped(carrier, note: carrier == LvRuntimeType.refnum ? kRefnumSubtypeNote : null);
  }
  switch (code) {
    case TypeCode.boolean:
    case TypeCode.booleanU16:
      return const LvTypeMapping.mapped('bool');
    case TypeCode.string:
    case TypeCode.cString:
    case TypeCode.pascalString:
      return const LvTypeMapping.mapped('String', note: kStringEncodingNote);
    default:
      return LvTypeMapping.unmapped(
        'wire element type code 0x${code.toRadixString(16)} has no decided Dart '
        'representation',
        unmappedCode: code,
      );
  }
}
