import 'graph.dart';
import 'heap.dart';
import 'ir.dart';

/// Schema version of the JSON IR emitted by [viModelToJson] / [viDiagramToJson].
///
/// This is the **stable, serializable export** of the read-only [ViModel] —
/// the "structured, versioned IR graph (JSON)" the migration plan (VI→IR→Dart)
/// consumes: a future translator reads this JSON rather than re-decoding bytes,
/// and a review UI renders it alongside generated Dart. Bump on any
/// shape-breaking change to the emitted maps.
/// v2 added `subViNames` (the LIbd subVI dependency list) to the top level.
const int viIrVersion = 2;

/// Serializes a recovered [ViDiagram] to a JSON-encodable map: its section tag
/// plus a **flat list of objects** carrying the positional nesting via
/// `parentOid`. Flat-with-parent (not a nested `children` tree) is deliberate —
/// it is lossless, avoids duplicating shared nodes, preserves the heap pre-order,
/// and the tree is trivially rebuilt from `parentOid`. Every drawable object
/// (one with absolute bounds) is represented.
///
/// Each node map omits null/empty fields to stay compact. Non-finite control
/// range sentinels (±infinity = "no bound") are dropped rather than emitted as
/// invalid JSON numbers. Deterministic: object order follows the diagram's
/// pre-order [ViDiagram.objects].
Map<String, Object?> viDiagramToJson(ViDiagram d) => {
      'sectionTag': d.sectionTag,
      'objects': [for (final o in d.objects) _objectToJson(o)],
    };

Map<String, Object?> _objectToJson(ViHeapObject o) {
  final cls = o.objectClass;
  final m = <String, Object?>{
    'oid': o.oid,
    'kindCode': o.kind,
    // the documented class catalog entry: human label + structural category +
    // how well-grounded the name is (clean-room honesty).
    'class': {
      'label': cls.label,
      'category': cls.category.name,
      'confidence': cls.confidence.name,
    },
    'objectKind': o.category.name,
    'typeKind': o.typeKind.name,
  };
  if (o.parentOid != null) m['parentOid'] = o.parentOid;
  if (o.label != null) m['label'] = o.label;
  if (o.bounds != null) m['bounds'] = _rectToJson(o.bounds!);
  if (o.absBounds != null) m['absBounds'] = _rectToJson(o.absBounds!);
  if (o.items.isNotEmpty) m['items'] = o.items;
  if (o.termCount != 0) m['termCount'] = o.termCount;
  final members = o.memberOids.toList();
  if (members.isNotEmpty) m['memberOids'] = members;
  if (o.controlMin != null && o.controlMin!.isFinite) m['controlMin'] = o.controlMin;
  if (o.controlMax != null && o.controlMax!.isFinite) m['controlMax'] = o.controlMax;
  if (o.helpText != null) m['helpText'] = o.helpText;
  return m;
}

Map<String, Object?> _rectToJson(HeapRect r) => {
      'top': r.top,
      'left': r.left,
      'bottom': r.bottom,
      'right': r.right,
    };

/// Serializes a whole [ViModel] to a JSON-encodable map — the top-level IR
/// artifact: schema version, VI identity (version/title/description), the
/// external symbols/library paths the VI calls (the Call-Library surface a
/// translator must bind), and the recovered block-diagram + front-panel object
/// trees ([viDiagramToJson]).
///
/// Honest limits carried from [ViModel]: there are **no dataflow wires/edges**
/// (LabVIEW stores wires as geometry with no recoverable endpoints), so the IR
/// is a typed, nested object graph — not yet a dataflow graph. Deterministic and
/// `jsonEncode`-safe (no non-finite numbers, no cycles).
Map<String, Object?> viModelToJson(ViModel m) => {
      'irVersion': viIrVersion,
      if (m.version != null) 'labviewVersion': m.version,
      if (m.title != null) 'title': m.title,
      if (m.description != null) 'description': m.description,
      if (m.symbolNames.isNotEmpty) 'symbolNames': m.symbolNames,
      if (m.paths.isNotEmpty) 'libraryPaths': m.paths,
      if (m.subViNames.isNotEmpty) 'subViNames': m.subViNames,
      'blockDiagrams': [for (final d in m.blockDiagrams) viDiagramToJson(d)],
      'frontPanelDiagrams': [for (final d in m.frontPanelDiagrams) viDiagramToJson(d)],
    };
