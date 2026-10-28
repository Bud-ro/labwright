import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// What a class file states about a LabVIEW class.
class LvClassData {
  const LvClassData({required this.privateData, required this.parent, required this.members});

  /// The private data control, as [buildViModel] reads it; null when the file carries none.
  final ViModel? privateData;

  /// The parent class's library-qualified name; empty for a class that descends from the root
  /// `LabVIEW Object`.
  final List<String> parent;

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

/// The item type a class file gives the item naming its parent class, `Lib.lvlib:Parent.lvclass`.
const String kLvParentClassItemType = 'Parent';

/// The classes of an [LvProjectIndex], read from their class files on demand.
class LvProjectClassIndex implements LvClassIndex {
  LvProjectClassIndex(this.index) {
    for (final MapEntry(key: path, value: library) in index.libraries.entries) {
      if (library.kind != LvLibraryKind.lvClass) continue;
      final own = index.qualifiedNameOf(path);
      if (own == null) continue;
      _pathOf[own.join(':')] = path;
      for (final item in library.items) {
        if (item.type == kLvParentClassItemType) {
          (_children[item.name.toLowerCase()] ??= []).add(own);
        }
      }
    }
  }

  final LvProjectIndex index;

  final Map<String, String> _pathOf = {};

  final Map<String, List<List<String>>> _children = {};

  final Map<String, LvClassData?> _data = {};

  @override
  LvClassData? classOf(List<String> qualifiedName) => _data.putIfAbsent(qualifiedName.join(':'), () {
    final path = _pathOf[qualifiedName.join(':')];
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
      parent: switch (library.items.where((item) => item.type == kLvParentClassItemType).firstOrNull) {
        final parent? => parent.name.split(':'),
        null => const [],
      },
      members: {
        for (final item in library.items)
          if (!item.isFolder && item.type == 'VI') item.name.toLowerCase(),
      },
    );
  });

  @override
  Iterable<List<String>> childrenOf(List<String> qualifiedName) =>
      _children[qualifiedName.join(':').toLowerCase()] ?? const [];
}

/// Whether [qualifiedName] names [ancestor] or a class descending from it, through [classes].
bool lvClassDescendsFrom(List<String> qualifiedName, List<String> ancestor, LvClassIndex? classes) {
  var at = qualifiedName;
  for (var depth = 0; depth < kLvClassDepth; depth++) {
    if (at.join(':') == ancestor.join(':')) return true;
    final parent = classes?.classOf(at)?.parent;
    if (parent == null || parent.isEmpty) return false;
    at = parent;
  }
  return false;
}

/// The deepest class hierarchy walked.
const int kLvClassDepth = 32;

/// The classes under [root] descending from [qualifiedName] that define a member named
/// [member], nearest first.
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
