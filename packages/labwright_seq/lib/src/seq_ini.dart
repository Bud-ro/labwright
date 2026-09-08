import 'dart:convert';
import 'dart:typed_data';

import 'seq_file.dart';
import 'seq_format.dart';
import 'seq_property.dart';

class IniEntry {
  const IniEntry(this.key, this.rawValue);

  final String key;

  final String rawValue;

  bool get isDirective => key.startsWith('%');

  @override
  String toString() => 'IniEntry($key = $rawValue)';
}

class IniSection {
  IniSection({
    required this.isDef,
    required this.path,
    required this.entries,
    this.extDataKind,
  }) : members = _selectEntries(entries, directives: false),
       directives = _selectEntries(entries, directives: true);

  final bool isDef;

  final String path;

  final String? extDataKind;

  bool get isExtData => extDataKind != null;

  final List<IniEntry> entries;

  final Map<String, String> members;

  final Map<String, String> directives;

  String? get name => unquoteIni(directives['%NAME']);

  @override
  String toString() =>
      'IniSection(${isDef ? 'DEF ' : ''}$path, ${members.length} members, '
      '${directives.length} directives)';

  static Map<String, String> _selectEntries(List<IniEntry> entries, {required bool directives}) => {
    for (final e in entries)
      if (e.isDirective == directives) e.key: e.rawValue,
  };
}

class IniSeqFile {
  IniSeqFile({
    required this.header,
    required this.headerFields,
    required this.sections,
    this.lineTerminator = '\n',
  });

  final SeqFileHeader header;

  final Map<String, String> headerFields;

  final String lineTerminator;

  final List<IniSection> sections;

  Iterable<IniSection> get extDataSections => sections.where((s) => s.isExtData);
}

IniSeqFile parseIniSeqBytes(Uint8List bytes) => parseIniSeq(latin1.decode(bytes, allowInvalid: true));

IniSeqFile parseIniSeq(String text) {
  final headerEntries = <IniEntry>[];
  final rawSections = <_RawSection>[];

  bool inHeader = false;
  _RawSection? current;

  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trimRight();
    if (line.isEmpty) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      final inner = line.substring(1, line.length - 1).trim();
      if (inner == '__Header__') {
        inHeader = true;
        current = null;
        continue;
      }
      inHeader = false;
      final isDef = inner.startsWith('DEF,');
      var path = isDef ? inner.substring('DEF,'.length).trim() : inner;
      String? extDataKind;
      if (!isDef && inner.startsWith('EXTDATA,')) {
        final rest = inner.substring('EXTDATA,'.length);
        final kindComma = rest.lastIndexOf(',');
        if (kindComma >= 0) {
          path = rest.substring(0, kindComma).trim();
          extDataKind = rest.substring(kindComma + 1).trim();
        }
      }
      current = _RawSection(isDef: isDef, path: path, extDataKind: extDataKind);
      rawSections.add(current);
      continue;
    }
    final eq = line.indexOf(' = ');
    if (eq < 0) continue;
    final key = line.substring(0, eq).trim();
    final value = line.substring(eq + ' = '.length);
    if (inHeader) {
      headerEntries.add(IniEntry(key, value));
    } else if (current != null) {
      current.entries.add(IniEntry(key, value));
    }
  }
  final headerFields = <String, String>{
    for (final e in _reassembleEntryList(headerEntries)) e.key: e.rawValue,
  };
  return IniSeqFile(
    header: _headerFrom(headerFields),
    headerFields: headerFields,
    sections: [
      for (final raw in rawSections)
        IniSection(
          isDef: raw.isDef,
          path: raw.path,
          entries: _reassembleEntryList(raw.entries),
          extDataKind: raw.extDataKind,
        ),
    ],
    lineTerminator: text.contains('\r\n') ? '\r\n' : '\n',
  );
}

class _RawSection {
  _RawSection({required this.isDef, required this.path, required this.extDataKind});

  final bool isDef;
  final String path;
  final String? extDataKind;
  final List<IniEntry> entries = [];
}

final _continuationKey = RegExp(r'^(.+) Line(\d+)$');

List<IniEntry> _reassembleEntryList(List<IniEntry> entries) {
  Map<String, List<(int, String)>>? groups;
  for (final entry in entries) {
    final match = _continuationKey.firstMatch(entry.key);
    if (match == null) continue;
    (groups ??= {}).putIfAbsent(match.group(1)!, () => []).add((int.parse(match.group(2)!), entry.rawValue));
  }
  if (groups == null) return entries;
  final rebuilt = <IniEntry>[];
  final joined = <String>{};
  for (final entry in entries) {
    final match = _continuationKey.firstMatch(entry.key);
    if (match == null) {
      rebuilt.add(entry);
      continue;
    }
    final base = match.group(1)!;
    if (joined.add(base)) {
      final frags = groups[base]!..sort((a, b) => a.$1.compareTo(b.$1));
      rebuilt.add(IniEntry(base, _joinFragments(frags.map((f) => f.$2))));
    }
  }
  return rebuilt;
}

String _joinFragments(Iterable<String> fragments) {
  final buf = StringBuffer();
  var anyQuoted = false;
  for (final fragment in fragments) {
    final trimmed = fragment.trim();
    if (_isQuoted(trimmed)) {
      anyQuoted = true;
      buf.write(trimmed.substring(1, trimmed.length - 1));
    } else {
      buf.write(fragment);
    }
  }
  return anyQuoted ? '"$buf"' : buf.toString();
}

SeqFileHeader parseIniHeader(String text) => parseIniSeq(text).header;

SeqFileHeader iniHeaderFromFields(Map<String, String> fields) => _headerFrom(fields);

SeqFileHeader _headerFrom(Map<String, String> h) => SeqFileHeader(
  format: SeqFormat.ini,
  fileType: unquoteIni(h['Type']),
  productName: unquoteIni(h['ProductName']),
  fileVersion: h['Version'],
);

SeqProperty? iniDataTree(IniSeqFile doc) {
  final builder = _IniBuilder(doc);
  final rootPath = builder.dataRootPath();
  return rootPath == null ? null : builder.build(rootPath, 'Data', 'SequenceFileData');
}

List<SeqProperty> iniTypes(IniSeqFile doc) {
  final builder = _IniBuilder(doc);
  final typeList = doc.sections.where((s) => !s.isDef && !s.isExtData && s.path == '%TYPES').firstOrNull;
  if (typeList == null) return const [];
  return [
    for (final typeName in typeList.members.keys)
      if (builder.hasPath(typeName)) builder.build(typeName, typeName, builder.rootAliasClass(typeName)),
  ];
}

class _IniPathNode {
  IniSection? def;

  IniSection? values;

  final Set<String> members = {};

  final Set<int> _elements = {};

  late final List<int> elementIndices = _elements.toList()..sort();

  bool get hasSection => def != null || values != null;
}

class _IniBuilder {
  _IniBuilder(IniSeqFile doc) {
    for (final section in doc.sections) {
      if (section.isExtData) continue;
      final node = _nodeAt(section.path);
      if (section.isDef) {
        node.def = section;
      } else {
        node.values = section;
      }
    }
    _indexPaths();
  }

  final Map<String, _IniPathNode> _nodes = {};

  _IniPathNode _nodeAt(String path) => _nodes[path] ??= _IniPathNode();

  void _indexPaths() {
    for (final path in _nodes.keys.toList()) {
      final pathLength = path.length;
      var i = 0;
      while (i < pathLength && path[i] != '.' && path[i] != '[') {
        i++;
      }
      while (i < pathLength) {
        final anc = path.substring(0, i);
        if (path[i] == '.') {
          var j = i + 1;
          while (j < pathLength && path[j] != '.' && path[j] != '[') {
            j++;
          }
          if (j > i + 1) {
            _nodeAt(anc).members.add(path.substring(i + 1, j));
          }
          i = j;
        } else {
          var j = i + 1;
          while (j < pathLength && path[j] != ']') {
            j++;
          }
          if (j < pathLength) {
            final idx = int.tryParse(path.substring(i + 1, j));
            if (idx != null) _nodeAt(anc)._elements.add(idx);
            i = j + 1;
          } else {
            i = pathLength;
          }
        }
      }
    }
  }

  IniSection? _def(String path) => _nodes[path]?.def;

  IniSection? _values(String path) => _nodes[path]?.values;

  bool hasPath(String path) => _nodes[path]?.hasSection ?? false;

  static const _rootAliases = ['%OBJROOT', '%OBJECTS'];

  String? dataRootPath() {
    for (final alias in _rootAliases) {
      final root = _def(alias);
      if (root == null) continue;
      for (final member in root.members.entries) {
        if (member.value == 'SequenceFileData') return member.key;
      }
    }
    return null;
  }

  String? rootAliasClass(String name) {
    for (final alias in _rootAliases) {
      final declared = _def(alias)?.members[name];
      if (declared != null) return unquoteIni(declared);
    }
    return null;
  }

  List<int> _elementIndices(String childPath) => _nodes[childPath]?.elementIndices ?? const <int>[];

  bool _isContainer(String childPath) => _nodes.containsKey(childPath);

  Iterable<String> _discoveredChildren(String path) => _nodes[path]?.members ?? const <String>{};

  final Map<String, SeqProperty> _inheritCache = {};

  static String _inheritKey(String typePath, Set<String> visiting) =>
      visiting.isEmpty ? typePath : '$typePath|${(visiting.toList()..sort()).join('|')}';

  (String?, String?) _memberType(String? raw) {
    final text = unquoteIni(raw);
    if (text == null) return (null, null);
    if (text.startsWith('TYPE, ')) return (null, text.substring('TYPE, '.length).trim());
    return (text, null);
  }

  static const instOverrideAttr = '%INSTOVRD';

  static const flagsAttr = '%FLG';

  static const highIndexAttr = '%HI';

  static const lowIndexAttr = '%LO';

  static const instFlagsAttr = '%INSTFLG';

  static const elementTypeAttr = '%EPTYPE';

  static const commentAttr = '%COMMENT';

  static const numericFormatAttr = '%NUMFMT';

  /// `%NAME` on a non-element section is the enum value's label, not the node name.
  static const enumValueAttr = '%NAME';

  SeqProperty build(
    String path,
    String displayName,
    String? declaredType, [
    String? declaredTypeName,
    Set<String>? visiting,
    Map<String, String> ownAttributes = const {},
    String? ownScalar,
  ]) {
    visiting ??= <String>{};
    final def = _def(path);
    final val = _values(path);
    final isElement = displayName.startsWith('[');
    final nameOverride = val?.name ?? def?.name;
    final name = isElement ? (nameOverride ?? displayName) : displayName;
    Map<String, String> memberAttrs(String memberName) {
      final ovr = val?.directives['$instOverrideAttr: $memberName'];
      final flg = val?.directives['$flagsAttr: $memberName'] ?? def?.directives['$flagsAttr: $memberName'];
      final instFlg = val?.directives['$instFlagsAttr: $memberName'] ?? def?.directives['$instFlagsAttr: $memberName'];
      final hi = val?.directives['$highIndexAttr: $memberName'] ?? def?.directives['$highIndexAttr: $memberName'];
      final lo = val?.directives['$lowIndexAttr: $memberName'] ?? def?.directives['$lowIndexAttr: $memberName'];
      return {
        if (ovr != null) instOverrideAttr: ovr,
        if (flg != null) flagsAttr: flg,
        if (instFlg != null) instFlagsAttr: instFlg,
        if (hi != null) highIndexAttr: hi,
        if (lo != null) lowIndexAttr: lo,
      };
    }

    String? typeRoot;
    var inheritGuard = false;
    var typeDefMembers = const <String, String>{};
    if (declaredTypeName != null && declaredTypeName != path) {
      final typeDef = _def(declaredTypeName);
      if (typeDef != null) {
        typeRoot = declaredTypeName;
        inheritGuard = visiting.add(declaredTypeName);
        if (inheritGuard) typeDefMembers = typeDef.members;
      }
    }
    String? memberTypeOf(String memberName) => def?.members[memberName] ?? typeDefMembers[memberName];

    final memberOrder = <String>{
      ...?def?.members.keys,
      ...?val?.members.keys,
      ..._discoveredChildren(path),
      ...typeDefMembers.keys,
    };

    final subs = <SeqProperty>[];
    for (final memberName in memberOrder) {
      final (className, typeName) = _memberType(memberTypeOf(memberName));
      final instPath = '$path.$memberName';
      final typePath = typeRoot == null ? null : '$typeRoot.$memberName';
      String? memberScalar() =>
          unquoteIni(val?.members[memberName]) ??
          (typeRoot == null ? null : unquoteIni(_values(typeRoot)?.members[memberName]));
      final elems = _elementIndices(instPath);
      if (elems.isNotEmpty) {
        final arrDef = _def(instPath);
        final arr = [
          for (final item in elems)
            build(
              '$instPath[$item]',
              '[$item]',
              arrDef?.directives['%[$item]'],
              unquoteIni(arrDef?.directives['%TYPE: %[$item]']),
              visiting,
            ),
        ];
        subs.add(SeqProperty(name: memberName, className: className, array: arr, attributes: memberAttrs(memberName)));
      } else if (_isContainer(instPath)) {
        subs.add(build(instPath, memberName, className, typeName, visiting, memberAttrs(memberName), memberScalar()));
      } else if (typePath != null && _isContainer(typePath)) {
        final scalar = memberScalar();
        final attrs = memberAttrs(memberName);
        subs.add(
          scalar == null && attrs.isEmpty
              ? _inheritCache[_inheritKey(typePath, visiting)] ??= build(
                  typePath,
                  memberName,
                  className,
                  typeName,
                  visiting,
                )
              : build(typePath, memberName, className, typeName, visiting, attrs, scalar),
        );
      } else {
        subs.add(
          SeqProperty(
            name: memberName,
            className: className,
            typeName: typeName,
            scalar: memberScalar(),
            attributes: memberAttrs(memberName),
          ),
        );
      }
    }
    if (inheritGuard) visiting.remove(typeRoot);

    final bareOvr = val?.directives[instOverrideAttr] ?? def?.directives[instOverrideAttr];
    final bareFlg = val?.directives[flagsAttr] ?? def?.directives[flagsAttr];
    final bareInstFlg = val?.directives[instFlagsAttr] ?? def?.directives[instFlagsAttr];
    final comment = unquoteIni(val?.directives[commentAttr] ?? def?.directives[commentAttr]);
    final numericFormat = unquoteIni(val?.directives[numericFormatAttr] ?? def?.directives[numericFormatAttr]);
    final elementType = unquoteIni(val?.directives[elementTypeAttr] ?? def?.directives[elementTypeAttr]);
    final attrs = <String, String>{
      ...ownAttributes,
      if (bareOvr != null) instOverrideAttr: bareOvr,
      if (bareFlg != null) flagsAttr: bareFlg,
      if (bareInstFlg != null) instFlagsAttr: bareInstFlg,
      if (comment != null && comment.isNotEmpty) commentAttr: comment,
      if (numericFormat != null) numericFormatAttr: numericFormat,
      if (elementType != null && elementType.isNotEmpty) elementTypeAttr: elementType,
      if (!isElement && nameOverride != null && nameOverride != name) enumValueAttr: nameOverride,
    };

    return SeqProperty(
      name: name,
      className: declaredType,
      typeName: declaredTypeName,
      attributes: attrs,
      scalar: ownScalar,
      subProps: subs,
    );
  }
}

SeqFile parseIniSeqFile(Uint8List bytes) {
  final doc = parseIniSeqBytes(bytes);
  final data = iniDataTree(doc);
  if (data == null) {
    throw const FormatException(
      'INI .seq has no reconstructable %OBJROOT data root (not yet decoded)',
    );
  }
  return SeqFile(header: doc.header, types: iniTypes(doc), data: data);
}

String? unquoteIni(String? raw) => raw == null ? null : unquoteIniText(raw);

String unquoteIniText(String raw) {
  final trimmed = raw.trim();
  return _isQuoted(trimmed) ? _unescapeIni(trimmed.substring(1, trimmed.length - 1)) : trimmed;
}

bool _isQuoted(String text) => text.length >= 2 && text.startsWith('"') && text.endsWith('"');

String _unescapeIni(String text) {
  if (!text.contains(r'\')) return text;
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (text[i] == r'\' && i + 1 < text.length) {
      final decoded = switch (text[i + 1]) {
        r'\' => r'\',
        '"' => '"',
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        _ => null,
      };
      if (decoded != null) {
        buffer.write(decoded);
        i++;
        continue;
      }
    }
    buffer.write(text[i]);
  }
  return buffer.toString();
}
