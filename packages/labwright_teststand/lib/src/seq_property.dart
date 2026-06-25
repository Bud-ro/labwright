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

  /// First sub-property named [name], or null.
  SeqProperty? prop(String name) {
    for (final p in subProps) {
      if (p.name == name) return p;
    }
    return null;
  }

  /// Follows a chain of sub-property names; null if any link is missing.
  SeqProperty? at(List<String> names) {
    SeqProperty? cur = this;
    for (final n in names) {
      cur = cur?.prop(n);
      if (cur == null) return null;
    }
    return cur;
  }

  @override
  String toString() =>
      'SeqProperty($name, class=$className${typeName != null ? ', type=$typeName' : ''}, '
      '${isArray ? '[${array!.length}]' : scalar != null ? 'scalar' : '{${subProps.length}}'})';
}

/// First direct child element of [e] whose local name is [name], or null.
XmlElement? childElement(XmlElement e, String name) {
  for (final c in e.childElements) {
    if (c.name.local == name) return c;
  }
  return null;
}

/// Direct child elements of [e] whose local name is [name].
Iterable<XmlElement> childElementsNamed(XmlElement e, String name) =>
    e.childElements.where((c) => c.name.local == name);

/// Builds a [SeqProperty] tree from a parsed XML element (total over the
/// TestStand XML shape).
SeqProperty buildProperty(XmlElement e) {
  final attrs = <String, String>{
    for (final a in e.attributes) a.name.qualified: a.value,
  };
  final tag = e.name.local;
  final name = tag == '_NAME_IN_ATTRIBUTE_'
      ? (attrs['name'] ?? '')
      : (attrs['name'] ?? tag);

  final subProps = <SeqProperty>[];
  final subpropsEl = childElement(e, 'subprops');
  if (subpropsEl != null) {
    for (final c in subpropsEl.childElements) {
      subProps.add(buildProperty(c));
    }
  }

  String? scalar;
  List<SeqProperty>? array;
  final valueEl = childElement(e, 'value');
  if (valueEl != null) {
    final isArray = valueEl.getAttribute('lbound') != null ||
        valueEl.getAttribute('ubound') != null;
    if (isArray) {
      array = [
        for (final w in childElementsNamed(valueEl, 'value'))
          w.childElements.isNotEmpty
              ? buildProperty(w.childElements.first)
              : SeqProperty(name: '', scalar: w.innerText),
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
