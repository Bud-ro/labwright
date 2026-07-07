import 'package:xml/xml.dart';

/// One node in a TestStand **PropertyObject** tree — the universal unit of a
/// `.seq` file. Sequences, steps, variables, parameters and types are all
/// property objects; this model captures any of them faithfully (every attribute
/// kept) without yet ascribing meaning, mirroring the VI reader's "every byte
/// accounted for" stance. A typed lens (`SeqFile`/`Sequence`/`Step`) sits on top.
class SeqProperty {
  SeqProperty({
    required this.name,
    this.className,
    this.typeName,
    this.attributes = const {},
    this.scalar,
    this.array,
    this.subProps = const [],
  });

  /// The property name: the `name=` attribute when present (array elements and
  /// `_NAME_IN_ATTRIBUTE_` placeholders), otherwise the XML element tag.
  final String name;

  /// The value-kind (`classname` attr): `Bool`, `Str`, `Number`, `Obj`, `Objs`,
  /// `ExprValue`, `Nums`, `ArrayDimensions`, … null if absent.
  final String? className;

  /// The TestStand type (`typename`/`xsi:type` attr), e.g. a step's `Statement`,
  /// `EditSubstep`, or a custom data type. null if untyped.
  final String? typeName;

  /// Every XML attribute on the element (qualified name → value), in document
  /// order — full visibility.
  final Map<String, String> attributes;

  /// Leaf scalar text (the `<value>` content), entity-decoded. null when the
  /// property is a container or an array.
  final String? scalar;

  /// Array elements (when the `<value>` carried `lbound`/`ubound`). null when not
  /// an array. Object arrays hold child objects; numeric/string arrays hold
  /// scalar elements (name == '').
  final List<SeqProperty>? array;

  /// Named child properties (from `<subprops>`); empty when there are none.
  final List<SeqProperty> subProps;

  bool get isArray => array != null;
  bool get isLeaf => array == null && subProps.isEmpty;

  /// Whether this property is an explicit **instance override** — i.e. the file
  /// marked it as set on this object rather than inherited from its base type.
  /// False for properties that simply take their type's default. Two encodings
  /// carry this: the legacy INI `%INSTOVRD` directive (flags bitmask kept
  /// verbatim), and the binary decoder's `%BINOVERRIDES` marker (its children
  /// are an override subset). Only presence is interpreted so far.
  bool get isInstanceOverride => attributes.containsKey('%INSTOVRD') || attributes.containsKey('%BINOVERRIDES');

  /// The property's type-level **PropertyFlags** bitmask, recovered verbatim from
  /// the legacy INI `%FLG: <member>` directive — null when the source recorded no
  /// flags for this property (e.g. XML-sourced trees, or inherited-only members).
  ///
  /// This mask is ~constant per property *name* across the corpus, so it encodes
  /// the property's fixed options (its type), not instance data — e.g. `SData`
  /// reads `0x200000`, `Status`/`ReportText`/`Result` read `0x400000`. Individual
  /// bit meanings are **not yet decoded**; the raw mask is exposed for analysis,
  /// never with fabricated semantics. Kept verbatim in [attributes] under `%FLG`.
  int? get propertyFlags => _intAttr('%FLG');

  int? _intAttr(String key) => int.tryParse(attributes[key]?.trim() ?? '');

  /// The bitmask on this property's **instance-override record** (`%INSTOVRD`),
  /// or null when the property is not an instance override. This is the base
  /// [propertyFlags] **plus** override-only bits: differential analysis over the
  /// corpus shows **bit16 (`0x10000`) is set only in override records** (14133 of
  /// 19859 member overrides) and in **0 of 58310** base type-level masks (`%FLG` +
  /// `%INSTFLG`) — so it is an override-set bit, not a type flag. (It skews to
  /// leaf *value* overrides — `StatusExpr`, `ResultAct`, `LoopWhile` — over
  /// container/metadata ones; the precise trigger is not yet fully decoded.)
  int? get instanceOverrideFlags => _intAttr('%INSTOVRD');

  /// The declared array bounds as high-indices, from the legacy INI
  /// `%HI: <member> = [63]` directive — `[63]` → `[63]` (64 elements when
  /// the low bound is 0), multi-dimensional bounds chain as `[31][63]` →
  /// `[31, 63]`. Every corpus-observed `%HI` bound is ≥ 0; a negative bound
  /// (unobserved) is treated defensively as an empty dimension by
  /// [declaredArrayLength]. null when the source recorded no high-index for
  /// this property. The text format stores default-valued elements ONLY
  /// this way (no members materialize), so a sized array with no [array]
  /// entries still has a real declared length: `declaredArrayLength`. XML
  /// (`lbound`/`ubound` on the value node) and binary bounds are TODO —
  /// not yet surfaced here.
  List<int>? get highIndices => _boundsAttr('%HI');

  /// The declared array LOW bounds, from the legacy INI `%LO: <member> = [1]`
  /// directive — mirrors [highIndices]. null when the source recorded no low
  /// bound; each dimension then defaults to 0. Nonzero low bounds are real
  /// (corpus: `%LO: ColumnList = [1]` paired with `%HI: ColumnList = [2]` —
  /// a 2-element array indexed 1..2).
  List<int>? get lowIndices => _boundsAttr('%LO');

  List<int>? _boundsAttr(String key) {
    final raw = attributes[key];
    if (raw == null) return null;
    final bounds = [
      for (final m in RegExp(r'\[(-?\d+)\]').allMatches(raw)) int.parse(m.group(1)!),
    ];
    return bounds.isEmpty ? null : bounds;
  }

  /// The array's declared ELEMENT prototype type name (`%EPTYPE`) — the
  /// type each default-valued element instantiates. null when absent.
  String? get elementTypeName => attributes['%EPTYPE'];

  /// The declared TOTAL element count from [highIndices] and [lowIndices]:
  /// per dimension `hi - lo + 1` (lo defaults to 0 when `%LO` is absent),
  /// dimensions multiply — a 1-D `[63]` is 64; `%LO = [1]` + `%HI = [2]` is
  /// 2 (indices 1..2, corpus-observed). A non-positive dimension length
  /// (unobserved in the corpus) reads defensively as an empty array. null
  /// when no bounds are declared.
  int? get declaredArrayLength {
    final his = highIndices;
    if (his == null) return null;
    final los = lowIndices;
    var count = 1;
    for (var dim = 0; dim < his.length; dim++) {
      final lo = (los != null && dim < los.length) ? los[dim] : 0;
      final length = his[dim] - lo + 1;
      if (length <= 0) return 0;
      count *= length;
    }
    return count;
  }

  SeqProperty? prop(String name) => subProps.where((p) => p.name == name).firstOrNull;

  SeqProperty? at(List<String> names) => names.fold<SeqProperty?>(this, (cur, n) => cur?.prop(n));

  @override
  String toString() =>
      'SeqProperty($name, class=$className${typeName != null ? ', type=$typeName' : ''}, '
      '${isArray
          ? '[${array!.length}]'
          : scalar != null
          ? 'scalar'
          : '{${subProps.length}}'})';
}

XmlElement? childElement(XmlElement e, String name) => childElementsNamed(e, name).firstOrNull;

Iterable<XmlElement> childElementsNamed(XmlElement e, String name) =>
    e.childElements.where((c) => c.name.local == name);

/// Builds a [SeqProperty] tree from a parsed XML element (total over the
/// TestStand XML shape).
SeqProperty buildProperty(XmlElement e) {
  final attrs = <String, String>{
    for (final attribute in e.attributes) attribute.name.qualified: attribute.value,
  };
  final tag = e.name.local;
  final name = attrs['name'] ?? (tag == '_NAME_IN_ATTRIBUTE_' ? '' : tag);

  final subpropsEl = childElement(e, 'subprops');
  final subProps = [
    if (subpropsEl != null)
      for (final child in subpropsEl.childElements) buildProperty(child),
  ];

  String? scalar;
  List<SeqProperty>? array;
  final valueEl = childElement(e, 'value');
  if (valueEl != null) {
    final isArray = valueEl.getAttribute('lbound') != null || valueEl.getAttribute('ubound') != null;
    if (isArray) {
      array = [
        for (final elementValue in childElementsNamed(valueEl, 'value')) _arrayElement(elementValue),
      ];
    } else {
      scalar = valueEl.innerText;
    }
  }

  return SeqProperty(
    name: name,
    className: attrs['classname'],
    typeName: attrs['typename'] ?? attrs['xsi:type'],
    attributes: attrs,
    scalar: scalar,
    array: array,
    subProps: subProps,
  );
}

/// Builds one array element from its `<value>` wrapper, RETAINING the
/// wrapper's own attributes on the element property. This matters for sparse
/// scalar arrays, where only non-default elements materialize and each carries
/// its true index as `arrayindex='[N]'` (corpus: arrays whose single stored
/// element is `arrayindex='[1]'` under `lbound='[0]' ubound='[2]'`) — dropping
/// it would silently misread the array as dense from 0. For object elements the
/// child element's own attributes are kept too; no corpus wrapper attribute
/// coexists with a child element, and on a (defensive) key clash the child's
/// value wins.
SeqProperty _arrayElement(XmlElement wrapper) {
  final wrapperAttrs = <String, String>{
    for (final attribute in wrapper.attributes) attribute.name.qualified: attribute.value,
  };
  if (wrapper.childElements.isEmpty) {
    return SeqProperty(name: '', scalar: wrapper.innerText, attributes: wrapperAttrs);
  }
  final child = buildProperty(wrapper.childElements.first);
  if (wrapperAttrs.isEmpty) return child;
  return SeqProperty(
    name: child.name,
    className: child.className,
    typeName: child.typeName,
    attributes: {...wrapperAttrs, ...child.attributes},
    scalar: child.scalar,
    array: child.array,
    subProps: child.subProps,
  );
}
