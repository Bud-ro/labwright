import 'package:labwright_seq/labwright_seq.dart';

class PropertyNode {
  PropertyNode({
    required this.name,
    this.className,
    this.typeName,
    this.value,
    this.attributes = const {},
    this.isArray = false,
    required this.children,
  });

  final String name;
  final String? className;
  final String? typeName;

  final String? value;

  final Map<String, String> attributes;

  final bool isArray;

  final List<PropertyNode> children;

  bool get isLeaf => children.isEmpty;

  bool get isInstanceOverride =>
      attributes.containsKey('%INSTOVRD') ||
      attributes.containsKey('%BINOVERRIDES');

  factory PropertyNode.of(SeqProperty p, {int? index}) {
    final children = <PropertyNode>[];
    final arr = p.array;
    if (arr != null) {
      for (var i = 0; i < arr.length; i++) {
        children.add(PropertyNode.of(arr[i], index: i));
      }
    }
    for (final sp in p.subProps) {
      children.add(PropertyNode.of(sp));
    }
    return PropertyNode(
      name: p.name.isEmpty && index != null ? '[$index]' : p.name,
      className: p.className,
      typeName: p.typeName,
      value: p.scalar,
      attributes: p.attributes,
      isArray: p.isArray,
      children: children,
    );
  }

  String get label => name.isEmpty ? '(unnamed)' : name;

  String get typeLabel => [
    if (className case final name?)
      isArray ? '$name[${children.length}]' : name
    else if (isArray)
      '[${children.length}]',
    if (typeName case final name?) name,
  ].join(' · ');
}

PropertyNode propertyTree(SeqFile file) => PropertyNode.of(file.data);

bool matchesQuery(PropertyNode node, String query) {
  if (query.isEmpty) return true;
  bool hit(String? s) => s != null && s.toLowerCase().contains(query);
  if (hit(node.name) ||
      hit(node.className) ||
      hit(node.typeName) ||
      hit(node.value)) {
    return true;
  }
  for (final entry in node.attributes.entries) {
    if (hit(entry.key) || hit(entry.value)) return true;
  }
  return false;
}

PropertyNode? filterTree(PropertyNode node, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return node;
  final keptChildren = <PropertyNode>[];
  for (final child in node.children) {
    final filtered = filterTree(child, needle);
    if (filtered != null) keptChildren.add(filtered);
  }
  final selfMatches = matchesQuery(node, needle);
  if (!selfMatches && keptChildren.isEmpty) return null;
  final children = keptChildren.isEmpty ? node.children : keptChildren;
  return PropertyNode(
    name: node.name,
    className: node.className,
    typeName: node.typeName,
    value: node.value,
    attributes: node.attributes,
    isArray: node.isArray,
    children: children,
  );
}
