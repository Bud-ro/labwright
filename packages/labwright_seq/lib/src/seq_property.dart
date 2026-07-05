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
  bool get isInstanceOverride =>
      attributes.containsKey('%INSTOVRD') ||
      attributes.containsKey('%BINOVERRIDES');

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

  SeqProperty? prop(String name) =>
      subProps.where((p) => p.name == name).firstOrNull;

  SeqProperty? at(List<String> names) =>
      names.fold<SeqProperty?>(this, (cur, n) => cur?.prop(n));

  @override
  String toString() =>
      'SeqProperty($name, class=$className${typeName != null ? ', type=$typeName' : ''}, '
      '${isArray ? '[${array!.length}]' : scalar != null ? 'scalar' : '{${subProps.length}}'})';
}

XmlElement? childElement(XmlElement e, String name) =>
    childElementsNamed(e, name).firstOrNull;

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
    final isArray = valueEl.getAttribute('lbound') != null ||
        valueEl.getAttribute('ubound') != null;
    if (isArray) {
      array = [
        for (final elementValue in childElementsNamed(valueEl, 'value'))
          elementValue.childElements.isNotEmpty
              ? buildProperty(elementValue.childElements.first)
              : SeqProperty(name: '', scalar: elementValue.innerText),
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
