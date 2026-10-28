import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'lv_flattened_text.dart';

/// The kinds of XML file LabVIEW keeps a library in, by extension.
enum LvLibraryKind {
  library('lvlib', 'Library'),
  lvClass('lvclass', 'LVClass'),
  xControl('xctl', 'XControl'),
  project('lvproj', 'Project');

  const LvLibraryKind(this.extension, this.rootElement);

  final String extension;

  /// The document's root element name.
  final String rootElement;

  static LvLibraryKind? ofPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return null;
    final extension = path.substring(dot + 1).toLowerCase();
    for (final kind in values) {
      if (kind.extension == extension) return kind;
    }
    return null;
  }
}

/// One `Item` of a library file: a member, a folder, or a dependency listing.
class LvLibraryItem {
  const LvLibraryItem({required this.name, required this.type, required this.url, required this.folders});

  final String name;

  /// The item's `Type` attribute: `VI`, `LVClass`, `Library`, `Folder`, `Class Private Data`, …
  final String type;

  /// The item's `URL` attribute, a path relative to the library file taken as a directory, or
  /// null for an item that is only a grouping.
  final String? url;

  /// The virtual folders above the item, outermost first; they are not part of its name.
  final List<String> folders;

  bool get isFolder => type == 'Folder';
}

/// A LabVIEW library, class, XControl or project file: an XML `Item` tree with `Property`
/// entries. The qualified name of a member is the owning files' names and then the member's,
/// `Lib.lvlib`, `Class.lvclass`, `Member.vi`; a virtual folder adds nothing to it.
class LvLibraryFile {
  LvLibraryFile._({required this.kind, required this.fileName, required this.items, required this.properties});

  final LvLibraryKind kind;

  /// The file's own name, such as `MB Master.lvlib`.
  final String fileName;

  final List<LvLibraryItem> items;

  /// The root's `Property` entries by name, such as `NI.Lib.Version`.
  final Map<String, String> properties;

  /// A class's private data control, the RSRC control file its
  /// `NI.LVClass.FlattenedPrivateDataCTL` property carries after a 33-byte header; null for a
  /// file that is not a class or a class without one.
  Uint8List? get privateDataControl {
    final text = properties['NI.LVClass.FlattenedPrivateDataCTL'];
    if (kind != LvLibraryKind.lvClass || text == null) return null;
    final bytes = lvFlattenedTextBytes(text);
    for (var i = 0; i + 4 <= bytes.length; i++) {
      if (bytes[i] == 0x52 && bytes[i + 1] == 0x53 && bytes[i + 2] == 0x52 && bytes[i + 3] == 0x43) {
        return Uint8List.sublistView(bytes, i);
      }
    }
    return null;
  }

  /// Whether the file is a LabVIEW interface: a class file whose `NI.LVClass.IsInterface`
  /// property is true, and which carries no private data control.
  bool get isInterface => kind == LvLibraryKind.lvClass && properties['NI.LVClass.IsInterface'] == 'true';

  /// The library-qualified name of a class's parent class (`Lib.lvlib`, `Parent.lvclass`): the
  /// name of the class file's `Parent` item, else the one its `NI.LVClass.ParentClassLinkInfo`
  /// property flattens ([LvParentClassLink]); empty for a file that names neither, which is a
  /// child of the root `LabVIEW Object`, and null for a link that does not decode.
  List<String>? get parentClass {
    if (kind != LvLibraryKind.lvClass) return const [];
    for (final item in items) {
      if (item.type == kLvParentClassItemType) return item.name.split(':');
    }
    final text = properties[LvParentClassLink.property];
    return text == null ? const [] : LvParentClassLink.qualifiedNameIn(lvFlattenedTextBytes(text));
  }

  /// Parses [xml] from the file named [fileName].
  factory LvLibraryFile.parse(String xml, {required String fileName}) {
    final kind = LvLibraryKind.ofPath(fileName);
    if (kind == null) throw FormatException('not a LabVIEW library file name: $fileName');
    final document = XmlDocument.parse(xml);
    final root = document.rootElement;
    if (root.name.local != kind.rootElement) {
      throw FormatException('a .${kind.extension} file holds a <${kind.rootElement}> root, not <${root.name.local}>');
    }
    final items = <LvLibraryItem>[];
    void walk(XmlElement element, List<String> folders) {
      for (final child in element.childElements) {
        if (child.name.local != 'Item') continue;
        final name = child.getAttribute('Name') ?? '';
        final type = child.getAttribute('Type') ?? '';
        final url = child.getAttribute('URL');
        items.add(LvLibraryItem(name: name, type: type, url: url, folders: folders));
        walk(child, type == 'Folder' ? [...folders, name] : folders);
      }
    }

    walk(root, const []);
    return LvLibraryFile._(
      kind: kind,
      fileName: fileName,
      items: items,
      properties: {
        for (final property in root.childElements)
          if (property.name.local == 'Property')
            if (property.getAttribute('Name') case final name?) name: property.innerText,
      },
    );
  }
}

/// The item type a class file gives the item naming its parent class, `Lib.lvlib:Parent.lvclass`.
const String kLvParentClassItemType = 'Parent';

/// The flattened link a class file keeps to its parent class in
/// `NI.LVClass.ParentClassLinkInfo`: a header, then at [nameOffset] the parent's qualified name
/// as a `u32` component count and that many Pascal strings, then an optional zero pad byte and
/// the parent's path record (`PTH0`).
// TODO: the header before the qualified name, and the words after the path record, are not decoded.
abstract final class LvParentClassLink {
  static const String property = 'NI.LVClass.ParentClassLinkInfo';

  static const int nameOffset = 33;

  /// The most components a qualified name is read with.
  static const int maxComponents = 16;

  /// The parent's qualified name in [bytes]; null when they do not hold one followed by a path
  /// record.
  static List<String>? qualifiedNameIn(Uint8List bytes) {
    if (bytes.length < nameOffset + 4) return null;
    final count = ByteData.sublistView(bytes).getUint32(nameOffset);
    if (count < 1 || count > maxComponents) return null;
    var at = nameOffset + 4;
    final names = <String>[];
    for (var i = 0; i < count; i++) {
      if (at >= bytes.length) return null;
      final length = bytes[at];
      if (length == 0 || at + 1 + length > bytes.length) return null;
      names.add(String.fromCharCodes(bytes, at + 1, at + 1 + length));
      at += 1 + length;
    }
    if (at < bytes.length && bytes[at] == 0) at++;
    if (at + 3 > bytes.length || bytes[at] != 0x50 || bytes[at + 1] != 0x54 || bytes[at + 2] != 0x48) return null;
    return names;
  }
}
