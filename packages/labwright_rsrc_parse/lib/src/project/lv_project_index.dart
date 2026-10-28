import 'dart:io';

import '../blocks/LIvi_LIbd_LIfp_LIds_link_info.dart';
import 'lv_library_file.dart';

/// The directories an interactive scan of a project tree visits at most, so a scan rooted too
/// high never walks a whole disk.
const int kLvProjectScanDirectoryBudget = 4000;

/// The files of the directories under [root], in depth-first order, stepping over directories
/// that cannot be listed; with [directoryBudget], visiting at most that many directories, and
/// with [skipHidden], none whose name starts with a dot.
Iterable<File> lvWalkProjectFiles(Directory root, {int? directoryBudget, bool skipHidden = false}) sync* {
  final stack = <Directory>[root];
  var visited = 0;
  while (stack.isNotEmpty && (directoryBudget == null || visited < directoryBudget)) {
    final List<FileSystemEntity> entries;
    try {
      entries = stack.removeLast().listSync(followLinks: false);
    } on FileSystemException {
      continue;
    }
    visited++;
    for (final entity in entries) {
      if (entity is Directory) {
        final name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
        if (!skipHidden || !name.startsWith('.')) stack.add(entity);
      } else if (entity is File) {
        yield entity;
      }
    }
  }
}

/// Every library, class and XControl file under a root, and each member's file by its
/// library-qualified name; resolves a VI's link entries to files.
class LvProjectIndex {
  LvProjectIndex._(this.root, this.libraries, this._byQualifiedName, this._qualifiedNameOfLibrary);

  final Directory root;

  /// Every library file under [root] by its absolute path.
  final Map<String, LvLibraryFile> libraries;

  final Map<String, String> _byQualifiedName;

  final Map<String, List<String>> _qualifiedNameOfLibrary;

  /// The library-qualified name of the library file at [libraryPath], outermost owner first;
  /// null for a path the scan did not index.
  List<String>? qualifiedNameOf(String libraryPath) => _qualifiedNameOfLibrary[libraryPath];

  /// Reads every `.lvlib`, `.lvclass` and `.xctl` under [root] that [lvWalkProjectFiles]
  /// reaches, within [directoryBudget] and past hidden directories when asked.
  factory LvProjectIndex.scan(Directory root, {int? directoryBudget, bool skipHidden = false}) {
    final libraries = <String, LvLibraryFile>{};
    for (final entity in lvWalkProjectFiles(root, directoryBudget: directoryBudget, skipHidden: skipHidden)) {
      final kind = LvLibraryKind.ofPath(entity.path);
      if (kind == null || kind == LvLibraryKind.project) continue;
      final String text;
      try {
        text = entity.readAsStringSync();
      } on FileSystemException {
        continue;
      }
      libraries[entity.path] = LvLibraryFile.parse(text, fileName: entity.uri.pathSegments.last);
    }
    final owner = <String, String>{};
    for (final MapEntry(key: path, value: library) in libraries.entries) {
      for (final item in library.items) {
        if (item.url case final url? when _ownsLibrary(item.type)) owner[resolveLibraryUrl(path, url)] = path;
      }
    }
    List<String> qualifiedNameOf(String path) {
      final names = <String>[];
      for (String? at = path; at != null; at = owner[at]) {
        if (names.length > 16) {
          break;
        }
        names.insert(0, libraries[at]!.fileName);
      }
      return names;
    }

    final byQualifiedName = <String, String>{};
    final qualifiedNames = <String, List<String>>{};
    for (final MapEntry(key: path, value: library) in libraries.entries) {
      final prefix = qualifiedNameOf(path);
      qualifiedNames[path] = prefix;
      byQualifiedName[prefix.join(':')] = path;
      for (final item in library.items) {
        if (item.url == null || item.isFolder) continue;
        byQualifiedName[[...prefix, item.name].join(':')] = resolveLibraryUrl(path, item.url!);
      }
    }
    return LvProjectIndex._(root, libraries, byQualifiedName, qualifiedNames);
  }

  /// The file a library-qualified name denotes, such as [`MB Master.lvlib`, `Read Coils.vi`].
  String? fileOf(List<String> qualifiedName) => _byQualifiedName[qualifiedName.join(':')];

  /// The file a link entry of the VI at [viPath] denotes: its path record resolved from the
  /// VI's directory when that file exists and is not a library file (a class method's link
  /// records its class), else its qualified name through the libraries.
  String? fileOfLink(ViLinkEntryFramed entry, {required String viPath}) {
    final path = entry.path;
    if (path != null && path.pathType == 1) {
      final candidate = resolveViPath(viPath, path.components);
      if (File(candidate).existsSync()) {
        if (LvLibraryKind.ofPath(candidate) == null) return candidate;
        if (_memberOf(candidate, entry.qualifiedName) case final member?) return member;
      }
    }
    if (entry.qualifiedName.isNotEmpty) return fileOf(entry.qualifiedName);
    return null;
  }
}

extension on LvProjectIndex {
  /// The file of the member [qualifiedName] ends with, in the library file at [libraryPath].
  String? _memberOf(String libraryPath, List<String> qualifiedName) {
    final library = libraries[libraryPath];
    final name = qualifiedName.lastOrNull?.toLowerCase();
    if (library == null || name == null) return null;
    for (final item in library.items) {
      if (!item.isFolder && item.url != null && item.name.toLowerCase() == name) {
        return resolveLibraryUrl(libraryPath, item.url!);
      }
    }
    return null;
  }
}

bool _ownsLibrary(String itemType) => itemType == 'LVClass' || itemType == 'Library' || itemType == 'XControl';

/// A library item's URL resolved as LabVIEW does: relative to the library file taken as a
/// directory, so `../X.vi` is the file's sibling.
String resolveLibraryUrl(String libraryPath, String url) =>
    Uri.directory(libraryPath).resolveUri(Uri(pathSegments: url.split('/'))).toFilePath();

/// A path record's components resolved from the VI at [viPath]: a leading empty component
/// starts at the VI's file, and each further empty component climbs a directory.
String resolveViPath(String viPath, List<String> components) =>
    Uri.directory(
          viPath,
        )
        .resolveUri(Uri(pathSegments: [for (final component in components) component.isEmpty ? '..' : component]))
        .toFilePath();
