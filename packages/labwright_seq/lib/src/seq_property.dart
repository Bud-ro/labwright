import 'package:xml/xml.dart';

/// `%` is not a legal XML attribute-name character, so directive attributes serialize as `x-` + rest.
const directiveXmlPrefix = 'x-';

const knownDirectiveKeys = <String>{
  '%FLG',
  '%INSTFLG',
  '%INSTOVRD',
  '%BINOVERRIDES',
  '%HI',
  '%LO',
  '%EPTYPE',
  '%COMMENT',
};

enum SeqValueClass {
  number('Num'),

  boolean('Bool', alias: 'Boolean'),

  string('Str'),

  expression('ExprValue'),

  path('PathValue'),

  reference('Ref'),

  object('Obj'),

  step('Step'),

  sequence('Sequence'),

  numbers('Nums'),

  strings('Strs'),

  booleans('Bools'),

  objects('Objs'),

  containers('Containers'),

  other('')
  ;

  const SeqValueClass(this.wire, {this.alias});

  final String wire;

  final String? alias;

  bool get isArray => const {numbers, strings, booleans, objects, containers}.contains(this);

  bool get isText => const {string, expression, path}.contains(this);

  static final Map<String, SeqValueClass> _byWire = {
    for (final cls in values)
      if (cls != other) ...{
        cls.wire: cls,
        if (cls.alias case final alias?) alias: cls,
      },
  };

  static SeqValueClass from(String token) => _byWire[token] ?? other;

  static SeqValueClass? of(String? token) => token == null ? null : from(token);
}

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
    this.xmlComment,
  });

  final String name;

  final String? xmlTag;

  final String? className;

  SeqValueClass? get valueClass => SeqValueClass.of(className);

  final String? typeName;

  final Map<String, String> attributes;

  final String? scalar;

  final List<SeqProperty>? array;

  final List<SeqProperty> subProps;

  final Map<String, String> valueAttributes;

  String? get arrayLBound => valueAttributes['lbound'];

  String? get arrayUBound => valueAttributes['ubound'];

  final SeqProperty? elemProto;

  final List<Map<String, String>> extData;

  final String? numericFormat;

  final String? xmlComment;

  bool get isArray => array != null;
  bool get isLeaf => array == null && subProps.isEmpty;

  String? directiveAttribute(String key) {
    final literal = attributes[key];
    if (literal != null) return literal;
    if (!knownDirectiveKeys.contains(key)) return null;
    return attributes['$directiveXmlPrefix${key.substring(1)}'];
  }

  bool get isInstanceOverride => directiveAttribute('%INSTOVRD') != null || directiveAttribute('%BINOVERRIDES') != null;

  int? get propertyFlags => _intAttr('%FLG');

  int? _intAttr(String key) => int.tryParse(directiveAttribute(key)?.trim() ?? '');

  int? get instanceOverrideFlags => _intAttr('%INSTOVRD');

  List<int>? get highIndices => _boundsAttr('%HI');

  List<int>? get lowIndices => _boundsAttr('%LO');

  List<int>? _boundsAttr(String key) {
    final raw = directiveAttribute(key);
    if (raw == null) return null;
    final bounds = [
      for (final m in RegExp(r'\[(-?\d+)\]').allMatches(raw)) int.parse(m.group(1)!),
    ];
    return bounds.isEmpty ? null : bounds;
  }

  String? get elementTypeName => directiveAttribute('%EPTYPE');

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

  SeqProperty copyWith({
    String? name,
    String? xmlTag,
    String? className,
    String? typeName,
    Map<String, String>? attributes,
    String? scalar,
    List<SeqProperty>? array,
    List<SeqProperty>? subProps,
    Map<String, String>? valueAttributes,
    SeqProperty? elemProto,
    List<Map<String, String>>? extData,
    String? numericFormat,
    String? xmlComment,
  }) => SeqProperty(
    name: name ?? this.name,
    xmlTag: xmlTag ?? this.xmlTag,
    className: className ?? this.className,
    typeName: typeName ?? this.typeName,
    attributes: attributes ?? this.attributes,
    scalar: scalar ?? this.scalar,
    array: array ?? this.array,
    subProps: subProps ?? this.subProps,
    valueAttributes: valueAttributes ?? this.valueAttributes,
    elemProto: elemProto ?? this.elemProto,
    extData: extData ?? this.extData,
    numericFormat: numericFormat ?? this.numericFormat,
    xmlComment: xmlComment ?? this.xmlComment,
  );

  SeqProperty? prop(String name) => subProps.where((p) => p.name == name).firstOrNull;

  SeqProperty? at(List<String> names) => names.fold<SeqProperty?>(this, (cur, n) => cur?.prop(n));

  @override
  String toString() {
    final elements = array;
    final shape = elements != null
        ? '[${elements.length}]'
        : scalar != null
        ? 'scalar'
        : '{${subProps.length}}';
    return 'SeqProperty($name, class=$className${typeName != null ? ', type=$typeName' : ''}, $shape)';
  }
}

XmlElement? childElement(XmlElement e, String name) => childElementsNamed(e, name).firstOrNull;

Iterable<XmlElement> childElementsNamed(XmlElement e, String name) =>
    e.childElements.where((c) => c.name.local == name);

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
    xmlComment: childElement(e, 'comment')?.innerText,
  );
}

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
    xmlComment: child.xmlComment,
  );
}
