import 'xml_lite.dart';

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

  /// Every XML attribute on the element, in document order — full visibility.
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

/// Builds a [SeqProperty] tree from a parsed XML element (total over the
/// TestStand XML shape).
SeqProperty buildProperty(XmlLiteElement e) {
  final name = e.name == '_NAME_IN_ATTRIBUTE_'
      ? (e.attributes['name'] ?? '')
      : (e.attributes['name'] ?? e.name);

  final subProps = <SeqProperty>[];
  final subpropsEl = e.child('subprops');
  if (subpropsEl != null) {
    for (final c in subpropsEl.children) {
      subProps.add(buildProperty(c));
    }
  }

  String? scalar;
  List<SeqProperty>? array;
  final valueEl = e.child('value');
  if (valueEl != null) {
    final isArray = valueEl.attributes.containsKey('lbound') ||
        valueEl.attributes.containsKey('ubound');
    if (isArray) {
      array = [
        for (final w in valueEl.childrenNamed('value'))
          w.children.isNotEmpty
              ? buildProperty(w.children.first)
              : SeqProperty(name: '', scalar: w.text),
      ];
    } else {
      scalar = valueEl.text;
    }
  }

  return SeqProperty(
    name: name,
    className: e.attributes['classname'],
    typeName: e.attributes['typename'] ?? e.attributes['xsi:type'],
    attributes: e.attributes,
    scalar: scalar,
    array: array,
    subProps: subProps,
  );
}
