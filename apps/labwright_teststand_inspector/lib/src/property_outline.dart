import 'package:labwright_teststand/labwright_teststand.dart';

/// A Flutter-free view-model node over a [SeqProperty] tree — the data behind
/// the Properties tab. Kept widget-free so the shaping (label, value, which
/// attributes to surface, child ordering) is unit-testable.
///
/// The raw PropertyObject tree is the "every attribute kept" layer of the
/// reader, so this node deliberately preserves everything: className, typeName,
/// the full attributes map, the leaf scalar, and both subProps and array
/// children (array elements first, then named sub-properties).
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

  /// Property name; array elements arrive name-less, shown as `[i]` by [label].
  final String name;
  final String? className;
  final String? typeName;

  /// Leaf scalar text, or `null` for containers/arrays.
  final String? value;

  /// Every XML attribute kept on the source node.
  final Map<String, String> attributes;

  /// Whether this node was a PropertyObject array.
  final bool isArray;

  final List<PropertyNode> children;

  bool get isLeaf => children.isEmpty;

  /// Whether the source property was an explicit **instance override** — it
  /// carried a legacy `%INSTOVRD` marker, i.e. it overrides its base type rather
  /// than inheriting the default. See [SeqProperty.isInstanceOverride].
  bool get isInstanceOverride => attributes.containsKey('%INSTOVRD');

  /// Builds the node for [p]. Array elements are indexed for a readable label.
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

  /// Display label: the name, or `(unnamed)` when truly anonymous.
  String get label => name.isEmpty ? '(unnamed)' : name;

  /// A compact one-line type/kind annotation, e.g. `Obj` or `Obj · Statement`,
  /// or `Objs[3]` for an array. Empty when nothing is known.
  String get typeLabel {
    final parts = <String>[];
    if (className != null) {
      parts.add(isArray ? '$className[${children.length}]' : className!);
    } else if (isArray) {
      parts.add('[${children.length}]');
    }
    if (typeName != null) parts.add(typeName!);
    return parts.join(' · ');
  }
}

/// Root node for the whole file's PropertyObject tree.
PropertyNode propertyTree(SeqFile file) => PropertyNode.of(file.data);

/// True if [node] itself matches [query] (case-insensitive) — by name,
/// className, typeName, scalar value, or any attribute key/value. The query is
/// assumed already lower-cased by the caller.
bool matchesQuery(PropertyNode node, String query) {
  if (query.isEmpty) return true;
  bool hit(String? s) => s != null && s.toLowerCase().contains(query);
  if (hit(node.name) || hit(node.className) || hit(node.typeName) ||
      hit(node.value)) {
    return true;
  }
  for (final e in node.attributes.entries) {
    if (hit(e.key) || hit(e.value)) return true;
  }
  return false;
}

/// Returns a pruned copy of [node] keeping only nodes that match [query] or have
/// a descendant that matches — so matches stay reachable through their
/// ancestors. An empty/blank query returns [node] unchanged. Returns `null`
/// when neither [node] nor any descendant matches. Pure.
PropertyNode? filterTree(PropertyNode node, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return node;
  final keptChildren = <PropertyNode>[];
  for (final c in node.children) {
    final f = filterTree(c, q);
    if (f != null) keptChildren.add(f);
  }
  final selfMatches = matchesQuery(node, q);
  if (!selfMatches && keptChildren.isEmpty) return null;
  // If this node matches but no child does, keep its full subtree so the user
  // can still drill into the match; otherwise keep only the matching branches.
  final children =
      keptChildren.isEmpty ? node.children : keptChildren;
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
