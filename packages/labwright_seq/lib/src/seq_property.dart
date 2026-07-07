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
    this.xmlTag,
    this.valueAttributes = const {},
    this.elemProto,
    this.extData = const [],
    this.numericFormat,
  });

  /// The property name: the `name=` attribute when present (array elements and
  /// `_NAME_IN_ATTRIBUTE_` placeholders), otherwise the XML element tag.
  final String name;

  /// The literal XML element tag this property was read from, when XML-sourced —
  /// needed to write the file back, because the tag is NOT derivable from [name]
  /// when a `name=` attribute exists (the corpus holds both
  /// `<_NAME_IN_ATTRIBUTE_ name='X'>` and `<FCParameter name='X'>` /
  /// `<Sequence name='MainSequence'>` forms). null for synthesized properties
  /// (INI/binary readers, hand-built trees) and for scalar array elements
  /// (which serialize as bare `<value>` wrappers, no tag).
  final String? xmlTag;

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

  /// Every XML attribute on the property's own `<value>` element, in document
  /// order. Corpus-observed keys: `lbound`/`ubound` (array bounds, verbatim —
  /// see [arrayLBound]/[arrayUBound]) and `representation` (numeric storage
  /// hint, `Int64`/`UInt64`, on scalar AND array values — 748 occurrences).
  /// Empty when the property has no `<value>` or it carries no attributes.
  final Map<String, String> valueAttributes;

  /// The declared array LOW bound(s), verbatim from the `<value lbound=…>`
  /// attribute — `'[0]'`, or a multi-dimensional chain like
  /// `'[0][0]…[0]'` (16-D observed in the corpus). null when not an array
  /// (or the file omitted it).
  String? get arrayLBound => valueAttributes['lbound'];

  /// The declared array HIGH bound(s), verbatim from `<value ubound=…>` —
  /// `'[]'` (unbounded/empty), `'[4]'`, or a multi-dimensional chain. null
  /// when not an array (or the file omitted it).
  String? get arrayUBound => valueAttributes['ubound'];

  /// The array's element PROTOTYPE — the `<elemproto>` child of an array
  /// `<value>` (its single wrapped property tree), describing the type each
  /// unstored element instantiates. Corpus: 1649 occurrences across all 36
  /// XML files, always attribute-less with exactly one child, always FIRST
  /// among the array value's children. null when absent (or non-array).
  final SeqProperty? elemProto;

  /// The `<extdata …/>` children of the property element, each an ordered
  /// attribute map, in document order. Code-module parameter marshalling
  /// metadata (corpus: 584 occurrences, always self-closed, keysets of 4 or 8
  /// attrs such as `controllername`/`exclude`/`packingoption`). They sit
  /// AFTER `<value>` and BEFORE `<subprops>` in every corpus occurrence.
  /// Empty when the property has none.
  final List<Map<String, String>> extData;

  /// The `<numericfmt>` child's text, verbatim — the property's display
  /// format string (corpus: 132 occurrences, `%#x` and `%i`, always AFTER
  /// `<value>`). null when absent.
  final String? numericFormat;

  bool get isArray => array != null;
  bool get isLeaf => array == null && subProps.isEmpty;

  /// Resolves a `%`-directive attribute under EITHER of its two spellings:
  /// the literal key ([key], e.g. `%FLG` — INI- and binary-sourced trees) or
  /// the XML-serializable `x-` rename the cross-flavor converter applies
  /// (`x-FLG` — `%` is not a legal XML attribute-name character, so converted
  /// models carry the directive renamed; see `ConvKey.directiveAttrPrefix`).
  /// The typed directive getters below all read through this, so they work
  /// identically on native and converted models.
  String? directiveAttribute(String key) => attributes[key] ?? attributes['x-${key.substring(1)}'];

  /// Whether this property is an explicit **instance override** — i.e. the file
  /// marked it as set on this object rather than inherited from its base type.
  /// False for properties that simply take their type's default. Two encodings
  /// carry this: the legacy INI `%INSTOVRD` directive (flags bitmask kept
  /// verbatim), and the binary decoder's `%BINOVERRIDES` marker (its children
  /// are an override subset). Only presence is interpreted so far.
  bool get isInstanceOverride => directiveAttribute('%INSTOVRD') != null || directiveAttribute('%BINOVERRIDES') != null;

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

  int? _intAttr(String key) => int.tryParse(directiveAttribute(key)?.trim() ?? '');

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
  /// bounds are kept verbatim instead ([arrayLBound]/[arrayUBound]); binary
  /// bounds are TODO — not yet surfaced here.
  List<int>? get highIndices => _boundsAttr('%HI');

  /// The declared array LOW bounds, from the legacy INI `%LO: <member> = [1]`
  /// directive — mirrors [highIndices]. null when the source recorded no low
  /// bound; each dimension then defaults to 0. Nonzero low bounds are real
  /// (corpus: `%LO: ColumnList = [1]` paired with `%HI: ColumnList = [2]` —
  /// a 2-element array indexed 1..2).
  List<int>? get lowIndices => _boundsAttr('%LO');

  List<int>? _boundsAttr(String key) {
    final raw = directiveAttribute(key);
    if (raw == null) return null;
    final bounds = [
      for (final m in RegExp(r'\[(-?\d+)\]').allMatches(raw)) int.parse(m.group(1)!),
    ];
    return bounds.isEmpty ? null : bounds;
  }

  /// The array's declared ELEMENT prototype type name (`%EPTYPE`) — the
  /// type each default-valued element instantiates. null when absent.
  String? get elementTypeName => directiveAttribute('%EPTYPE');

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
  SeqProperty? elemProto;
  var valueAttrs = const <String, String>{};
  final valueEl = childElement(e, 'value');
  if (valueEl != null) {
    valueAttrs = {
      for (final attribute in valueEl.attributes) attribute.name.qualified: attribute.value,
    };
    final isArray = valueAttrs.containsKey('lbound') || valueAttrs.containsKey('ubound');
    if (isArray) {
      // The element prototype: `<elemproto>` wraps exactly one property tree
      // (corpus: 1649/1649 attribute-less with one child; a childless wrapper,
      // unobserved, reads defensively as absent).
      final protoEl = childElement(valueEl, 'elemproto');
      final protoChild = protoEl?.childElements.firstOrNull;
      if (protoChild != null) elemProto = buildProperty(protoChild);
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
    xmlTag: tag,
    valueAttributes: valueAttrs,
    elemProto: elemProto,
    extData: [
      for (final ext in childElementsNamed(e, 'extdata'))
        {for (final attribute in ext.attributes) attribute.name.qualified: attribute.value},
    ],
    numericFormat: childElement(e, 'numericfmt')?.innerText,
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
    xmlTag: child.xmlTag,
    valueAttributes: child.valueAttributes,
    elemProto: child.elemProto,
    extData: child.extData,
    numericFormat: child.numericFormat,
  );
}
