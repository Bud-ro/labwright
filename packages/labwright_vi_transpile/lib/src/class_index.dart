import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'type_map.dart';

/// The key a library-qualified name is compared by: LabVIEW names are case-insensitive, so two
/// spellings that differ only in case name one library, class or member.
String lvQualifiedNameKey(List<String> qualifiedName) => qualifiedName.join(':').toLowerCase();

/// What a class file states about a LabVIEW class.
class LvClassData {
  const LvClassData({
    required this.privateData,
    required this.parent,
    required this.members,
    this.isInterface = false,
  });

  /// Whether the class is an interface, which holds no private data.
  final bool isInterface;

  /// The private data control, as [buildViModel] reads it; null when the file carries none.
  final ViModel? privateData;

  /// The parent class's library-qualified name, [LvLibraryFile.parentClass]; empty for a class
  /// that descends from the root `LabVIEW Object`, null when the file's parent link does not
  /// decode.
  final List<String>? parent;

  /// The file names of the class's own member VIs, lower-cased.
  final Set<String> members;
}

/// The LabVIEW classes a lowering may name: each by its library-qualified name (`Lib.lvlib`,
/// `X.lvclass`), and the children of each.
abstract class LvClassIndex {
  LvClassData? classOf(List<String> qualifiedName);

  /// The qualified names of the classes whose parent is [qualifiedName].
  Iterable<List<String>> childrenOf(List<String> qualifiedName);
}

/// The classes of an [LvProjectIndex], read from their class files on demand.
class LvProjectClassIndex implements LvClassIndex {
  LvProjectClassIndex(this.index) {
    for (final MapEntry(key: path, value: library) in index.libraries.entries) {
      if (library.kind != LvLibraryKind.lvClass) continue;
      final own = index.qualifiedNameOf(path);
      if (own == null) continue;
      _pathOf[lvQualifiedNameKey(own)] = path;
      if (library.parentClass case final parent? when parent.isNotEmpty) {
        (_children[lvQualifiedNameKey(parent)] ??= []).add(own);
      }
    }
  }

  final LvProjectIndex index;

  final Map<String, String> _pathOf = {};

  final Map<String, List<List<String>>> _children = {};

  final Map<String, LvClassData?> _data = {};

  @override
  LvClassData? classOf(List<String> qualifiedName) => _data.putIfAbsent(lvQualifiedNameKey(qualifiedName), () {
    final path = _pathOf[lvQualifiedNameKey(qualifiedName)];
    final library = path == null ? null : index.libraries[path];
    if (library == null) return null;
    final control = library.privateDataControl;
    ViModel? privateData;
    if (control != null) {
      try {
        privateData = buildViModel(control);
      } on ViFormatException {
        privateData = null;
      }
    }
    return LvClassData(
      privateData: privateData,
      parent: library.parentClass,
      isInterface: library.isInterface,
      members: {
        for (final item in library.items)
          if (!item.isFolder && item.type == 'VI') item.name.toLowerCase(),
      },
    );
  });

  @override
  Iterable<List<String>> childrenOf(List<String> qualifiedName) =>
      _children[lvQualifiedNameKey(qualifiedName)] ?? const [];
}

/// Whether [qualifiedName] names [ancestor] or a class descending from it, through [classes].
bool lvClassDescendsFrom(List<String> qualifiedName, List<String> ancestor, LvClassIndex? classes) {
  if (lvQualifiedNameKey(ancestor) == lvQualifiedNameKey(kLvRootClassName)) return true;
  var at = qualifiedName;
  for (var depth = 0; depth < kLvClassDepth; depth++) {
    if (lvQualifiedNameKey(at) == lvQualifiedNameKey(ancestor)) return true;
    final parent = classes?.classOf(at)?.parent;
    if (parent == null || parent.isEmpty) return false;
    at = parent;
  }
  return false;
}

/// The class whose member a dynamic-dispatch call to [member] on an object of [owner] reaches
/// when no descendant overrides it: [owner] or its nearest ancestor that defines [member]; null
/// when none [classes] holds does.
List<String>? lvDispatchDefiner(List<String> owner, String member, LvClassIndex classes) {
  final lower = member.toLowerCase();
  List<String>? at = owner;
  for (var depth = 0; at != null && at.isNotEmpty && depth < kLvClassDepth; depth++) {
    final data = classes.classOf(at);
    if (data == null) return null;
    if (data.members.contains(lower)) return at;
    at = data.parent;
  }
  return null;
}

/// The link a dynamic-dispatch call through [link] reaches statically: the member of the class
/// [lvDispatchDefiner] finds, its path record dropped so it resolves by qualified name.
ViLinkEntryFramed? lvDispatchLink(ViLinkEntryFramed link, LvClassIndex classes) {
  if (link.qualifiedName.length < 2) return null;
  final member = link.qualifiedName.last;
  final owner = link.qualifiedName.sublist(0, link.qualifiedName.length - 1);
  final definer = lvDispatchDefiner(owner, member, classes);
  if (definer == null) return null;
  if (lvQualifiedNameKey(definer) == lvQualifiedNameKey(owner)) return link;
  return ViLinkEntryFramed(link.offset, link.end, link.kind, qualifiedName: [...definer, member]);
}

/// The deepest class hierarchy walked.
const int kLvClassDepth = 32;

/// The classes descending from [qualifiedName] that define a member named [member]: the
/// overrides a dynamic-dispatch call to that member may reach.
List<List<String>> lvOverridersOf(List<String> qualifiedName, String member, LvClassIndex classes) {
  final lower = member.toLowerCase();
  final found = <List<String>>[];
  final pending = <List<String>>[...classes.childrenOf(qualifiedName)];
  var budget = 4096;
  while (pending.isNotEmpty && budget-- > 0) {
    final child = pending.removeLast();
    if (classes.classOf(child)?.members.contains(lower) ?? false) found.add(child);
    pending.addAll(classes.childrenOf(child));
  }
  return found;
}
