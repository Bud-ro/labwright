/// Renders every block file's byte diagram from its layout classes and writes
/// `lib/src/generated/block_docs.dart`, the field names, types and doc comments the inspector
/// shows at run time. Run: `dart run tool/gen_block_docs.dart`; CI fails if the output differs.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/src/byte_layout.dart';

const _fenceOpen = '/// ```text';
const _fenceClose = '/// ```';
const _minOffsetWidth = 7;
const _minSizeWidth = 5;
const _minNameWidth = 8;
const _minTypeWidth = 6;
const _lineWidth = 110;

/// The last line of a `static const` declaration: a `;`, then at most a trailing comment.
final _declarationEnd = RegExp(r';(?: //.*)?\s*$');

/// A getter, operator or instance field declaration at class-member indent.
final _accessor = RegExp(
  r'^  (?:late )?(?:final )?[\w<>?,() ]+ (?:get \w+|operator \S+\()|^  (?:late )?final [\w<>?]+ \w+;',
);

void main() {
  final lib = Directory('${File.fromUri(Platform.script).parent.parent.path}/lib/src');
  final files = [
    ...Directory('${lib.path}/blocks').listSync().whereType<File>().where((f) => f.path.endsWith('.dart')),
    File('${lib.path}/pth0.dart'),
  ]..sort((a, b) => a.path.compareTo(b.path));
  final classes = <String, _LayoutClass>{};
  final byFile = <File, List<_LayoutClass>>{};
  for (final file in files) {
    final parsed = _parseClasses(file);
    byFile[file] = parsed;
    for (final c in parsed) {
      if (classes.containsKey(c.name)) throw StateError('${c.name} is declared twice');
      classes[c.name] = c;
    }
  }
  for (final c in classes.values) {
    c.resolve(classes);
  }
  final nested = {
    for (final c in classes.values)
      for (final field in c.fields)
        if (field.entryClass != null) field.entryClass!,
  };
  final tagsOf = _tagsByClass(File('${lib.path}/block_tag.dart'), classes);
  for (final MapEntry(key: file, value: parsed) in byFile.entries) {
    final top = [
      for (final c in parsed)
        if (!nested.contains(c.name)) c,
    ];
    if (top.isEmpty) continue;
    final lines = file.readAsLinesSync();
    final open = lines.lastIndexOf(_fenceOpen);
    final close = open < 0 ? -1 : lines.indexOf(_fenceClose, open + 1);
    if (open < 0 || close < 0) throw StateError('${file.path}: no ```text fence in the library doc comment');
    lines.replaceRange(open + 1, close, [
      for (final c in top) ...[
        if (top.length > 1) '/// ${(tagsOf[c.name]?.map((t) => t.$2) ?? [c.name]).join(' / ')}:',
        ..._render(c, classes),
      ],
    ]);
    file.writeAsStringSync('${lines.join('\n')}\n');
  }
  final docs = File('${lib.path}/generated/block_docs.dart')
    ..parent.createSync()
    ..writeAsStringSync(_docsSource(tagsOf, classes));
  final format = Process.runSync('dart', ['format', docs.path]);
  if (format.exitCode != 0) throw StateError('dart format failed: ${format.stderr}');
}

/// One `static const` field of a layout class: its identifier, doc comment and initializer.
final class _FieldDecl {
  _FieldDecl(this.name, this.doc, this.initializer);

  final String name;

  /// The field's trailing `//` comment, else the doc comment of the first documented getter,
  /// operator or instance field of the class that reads it, else that of the one sharing its
  /// name.
  String doc;

  final String initializer;

  /// The name as documented: the identifier without a leading underscore.
  String get shownName => name.startsWith('_') ? name.substring(1) : name;

  Field? _field;

  bool get resolved => _field != null;

  Field get field => _field!;

  set field(Field value) => _field = value;

  /// The class whose layout an [Entries] or [Struct] field repeats.
  String? entryClass;

  /// The identifier of the field holding the count of a counted run.
  String? countName;

  String get type {
    final base = switch (field) {
      Entries(:final length) => '$entryClass[${length ?? countName ?? ''}]',
      Struct() => entryClass!,
      final f => f.typeName.replaceFirst('[]', '[${countName ?? ''}]'),
    };
    return field.optional ? '$base?' : base;
  }
}

/// An `abstract final class` whose `static const` members are [Field]s and a `layout`.
final class _LayoutClass {
  _LayoutClass(this.name, this.decls, this.layoutNames);

  final String name;

  final List<_FieldDecl> decls;

  final List<String> layoutNames;

  late final ByteLayout layout;

  bool _resolved = false;

  List<_FieldDecl> get fields => [for (final n in layoutNames) decls.firstWhere((d) => d.name == n)];

  void resolve(Map<String, _LayoutClass> classes) {
    if (_resolved) return;
    _resolved = true;
    final byName = <String, Field>{};
    for (final decl in decls) {
      if (!decl.resolved) decl.field = _evaluate(decl, byName, classes);
      byName[decl.name] = decl.field;
    }
    layout = ByteLayout([for (final f in fields) f.field]);
  }
}

/// Parses every class declaring a `static const … = ByteLayout([...])`: its `static const`
/// fields, each documented by its trailing `//` comment or by the accessor that reads or is
/// named after it, and each layout's field list. A class with
/// several layouts yields one [_LayoutClass] per layout, named `Class.member` except for
/// `layout`, which keeps the class name.
List<_LayoutClass> _parseClasses(File file) {
  final lines = file.readAsLinesSync();
  final out = <_LayoutClass>[];
  final classOpen = RegExp(r'^(?:abstract |final |sealed |base )*class (\w+)\b[^{]*\{$');
  final layoutDecl = RegExp(r'^static const (\w+) = ByteLayout\(');
  var i = 0;
  while (i < lines.length) {
    final match = classOpen.firstMatch(lines[i]);
    if (match == null) {
      i++;
      continue;
    }
    final name = match.group(1)!;
    final body = lines.sublist(i + 1, lines.indexOf('}', i));
    i += body.length + 2;
    if (!body.any((line) => layoutDecl.hasMatch(line.trim()))) continue;
    final decls = <_FieldDecl>[];
    final layouts = <String, List<String>>{};
    final accessors = <(String doc, String text)>[];
    final doc = <String>[];
    for (var j = 0; j < body.length; j++) {
      final line = body[j].trim();
      if (line.startsWith('///')) {
        doc.add(line.substring(3).trim());
      } else if (line.startsWith('@')) {
        continue;
      } else if (_accessor.hasMatch(body[j])) {
        final text = StringBuffer(body[j]);
        while (j + 1 < body.length && (body[j + 1].startsWith('   ') || body[j + 1].startsWith('  }'))) {
          text.write(body[++j]);
        }
        if (doc.isNotEmpty) accessors.add((_docText(doc), text.toString()));
        doc.clear();
      } else if (line.startsWith('static const ')) {
        final buffer = StringBuffer(line);
        while (!_declarationEnd.hasMatch(body[j])) {
          j++;
          buffer.write(' ${body[j].trim()}');
        }
        final decl = RegExp(r'^static const (?:[\w<>?]+ )?(\w+) = (.*?);(?: // (.*))?$').firstMatch(buffer.toString());
        if (decl == null) throw StateError('${file.path}: cannot parse `$buffer`');
        final memberName = decl.group(1)!;
        final initializer = decl.group(2)!;
        final list = RegExp(r'^ByteLayout\(\[(.*?),?\]\)$').firstMatch(initializer);
        if (list != null) {
          layouts[memberName] = [
            for (final n in list.group(1)!.split(','))
              if (n.trim().isNotEmpty) n.trim(),
          ];
        } else if (RegExp(r'^[A-Z]\w*\(').hasMatch(initializer)) {
          decls.add(_FieldDecl(memberName, _docText(doc.isEmpty ? [?decl.group(3)] : doc), initializer));
        }
        doc.clear();
      } else if (line.isNotEmpty) {
        doc.clear();
      }
    }
    for (final decl in decls) {
      if (decl.doc.isNotEmpty) continue;
      final reads = RegExp('\\b${decl.name}\\b');
      final named = RegExp('\\b(?:get |operator |final [\\w<>?]+ )${decl.shownName}\\b');
      decl.doc =
          accessors.where((a) => reads.hasMatch(a.$2)).map((a) => a.$1).firstOrNull ??
          accessors.where((a) => named.hasMatch(a.$2)).map((a) => a.$1).firstOrNull ??
          '';
    }
    for (final MapEntry(key: member, value: names) in layouts.entries) {
      out.add(_LayoutClass(member == 'layout' ? name : '$name.$member', decls, names));
    }
  }
  return out;
}

/// Joins doc lines into one sentence run, spelling `[Name]` references as plain names.
String _docText(List<String> lines) =>
    lines.join(' ').replaceAllMapped(RegExp(r'\[([A-Za-z_][\w.]*)\]'), (m) => m.group(1)!);

/// Builds the [Field] a `static const` initializer denotes; [siblings] resolves `count:`
/// references and [classes] the `X.layout` of an [Entries] or [Struct].
Field _evaluate(_FieldDecl decl, Map<String, Field> siblings, Map<String, _LayoutClass> classes) {
  final call = RegExp(r'^(\w+)\((.*)\)$').firstMatch(decl.initializer);
  if (call == null) throw StateError('cannot parse `${decl.initializer}`');
  final ctor = call.group(1)!;
  final positional = <String>[];
  final named = <String, String>{};
  for (final arg in _splitArgs(call.group(2)!)) {
    final colon = arg.indexOf(':');
    if (colon < 0) {
      positional.add(arg);
    } else {
      named[arg.substring(0, colon).trim()] = arg.substring(colon + 1).trim();
    }
  }
  final offset = int.parse(positional[0]);
  final optional = named['optional'] == 'true';
  final endian = switch (named['endian']) {
    null || 'Endian.big' => Endian.big,
    'Endian.little' => Endian.little,
    final other => throw StateError('${decl.name}: unknown endian `$other`'),
  };
  Scalar? count;
  if (named case {'count': final name}) {
    decl.countName = name.startsWith('_') ? name.substring(1) : name;
    count = siblings[name] as Scalar? ?? (throw StateError('${decl.name}: count `$name` is not a scalar field'));
  }
  final size = named['size'] == null ? null : int.parse(named['size']!);
  final length = named['length'] == null ? null : int.parse(named['length']!);
  ByteLayout entryLayout() {
    final className = positional[1].replaceFirst(RegExp(r'\.layout$'), '');
    final entry = classes[className] ?? (throw StateError('${decl.name}: no layout class $className'));
    decl.entryClass = className;
    entry.resolve(classes);
    return entry.layout;
  }

  return switch (ctor) {
    'U8' => U8(offset, optional: optional),
    'U16' => U16(offset, endian: endian, optional: optional),
    'U32' => U32(offset, endian: endian, optional: optional),
    'I16' => I16(offset, endian: endian, optional: optional),
    'I32' => I32(offset, endian: endian, optional: optional),
    'F32' => F32(offset, endian: endian, optional: optional),
    'PackedWord' => PackedWord(offset, optional: optional),
    'FourCc' => FourCc(offset, optional: optional),
    'PStr' => PStr(offset, optional: optional),
    'Bytes' => Bytes(offset, size: size, count: count, optional: optional),
    'Unknown' => Unknown(offset, size: size, optional: optional),
    'U16List' => U16List(offset, endian: endian, length: length, count: count, optional: optional),
    'U32List' => U32List(offset, endian: endian, length: length, count: count, optional: optional),
    'PackedWordList' => PackedWordList(offset, length: length, count: count, optional: optional),
    'PStrList' => PStrList(offset, length: length, count: count, optional: optional),
    'Entries' => Entries(offset, entryLayout(), length: length, count: count, optional: optional),
    'Struct' => Struct(offset, entryLayout(), optional: optional),
    _ => throw StateError('${decl.name}: unknown field class $ctor'),
  };
}

List<String> _splitArgs(String text) {
  final out = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    switch (text[i]) {
      case '(' || '[':
        depth++;
      case ')' || ']':
        depth--;
      case ',' when depth == 0:
        out.add(text.substring(start, i).trim());
        start = i + 1;
    }
  }
  final last = text.substring(start).trim();
  if (last.isNotEmpty) out.add(last);
  return out;
}

/// The `BlockTag` members naming each layout class, in enum order, as (member, tag) pairs.
Map<String, List<(String, String)>> _tagsByClass(File blockTag, Map<String, _LayoutClass> classes) {
  final out = <String, List<(String, String)>>{};
  final row = RegExp(r"(\w+)\(\s*'([^']*)',\s*'[^']*',\s*(?:[\w.]+|null),\s*(\w+)\.(\w+),?\s*\)");
  for (final m in row.allMatches(blockTag.readAsStringSync())) {
    final className = m.group(4) == 'layout' ? m.group(3)! : '${m.group(3)}.${m.group(4)}';
    if (!classes.containsKey(className)) throw StateError('BlockTag.${m.group(1)} names no layout class $className');
    (out[className] ??= []).add((m.group(1)!, m.group(2)!));
  }
  return out;
}

List<String> _render(_LayoutClass c, Map<String, _LayoutClass> classes) {
  final rows = <(String offset, String size, String name, String type, String meaning)>[];
  var pos = const _Pos();
  for (final decl in c.fields) {
    final size = _sizeExpr(decl);
    rows.add((pos.render(decl.field), size, decl.shownName, decl.type, _meaning(decl)));
    if (decl.entryClass != null) {
      var at = const _Pos();
      for (final e in classes[decl.entryClass]!.fields) {
        final entrySize = _sizeExpr(e);
        rows.add(('  +${at.render(e.field)}', entrySize, e.shownName, e.type, _meaning(e)));
        at = at.after(entrySize);
      }
    }
    pos = pos.after(size);
  }
  final widths = _Widths(
    offset: rows.fold(_minOffsetWidth, (w, r) => r.$1.length > w ? r.$1.length : w),
    size: rows.fold(_minSizeWidth, (w, r) => r.$2.length > w ? r.$2.length : w),
    name: rows.fold(_minNameWidth, (w, r) => r.$3.length > w ? r.$3.length : w),
    type: rows.fold(_minTypeWidth, (w, r) => r.$4.length > w ? r.$4.length : w),
  );
  return [
    '${_head('offset', 'size', 'field', 'type', widths)}meaning',
    for (final r in rows) ..._wrapRow(r.$1, r.$2, r.$3, r.$4, r.$5, widths),
  ];
}

/// A byte position as a fixed part plus the count-sized runs before it, or unknowable once a
/// field of unknowable size precedes it.
final class _Pos {
  const _Pos([this.fixed = 0, this.terms = const [], this.known = true]);

  final int fixed;

  final List<String> terms;

  final bool known;

  /// The position of [field]: its declared offset while nothing symbolic precedes it.
  String render(Field field) {
    if (!known) return '…';
    if (terms.isEmpty) return '${field.offset}';
    return [if (fixed != 0) '$fixed', ...terms].join('+');
  }

  /// The position after a field of [size], as [_sizeExpr] spells it.
  _Pos after(String size) {
    if (!known || size == '…' || size == 'rest') return const _Pos(0, [], false);
    final n = int.tryParse(size);
    return n == null ? _Pos(fixed, [...terms, size]) : _Pos(fixed + n, terms);
  }
}

/// The size of a field as the diagram spells it: a number, `n·count` for a count-sized run,
/// `rest` to the end of the payload, `…` when only the data says.
String _sizeExpr(_FieldDecl decl) {
  final field = decl.field;
  if (field.size case final int size) return '$size';
  final count = decl.countName;
  return switch (field) {
    Bytes() when count != null => count,
    WordList(:final wordSize) when count != null => '$wordSize·$count',
    Entries(entry: ByteLayout(size: final int entrySize)) when count != null => '$entrySize·$count',
    Bytes() || Unknown() || WordList() || PStrList() || PackedWordList() || Entries() when count == null => 'rest',
    _ => '…',
  };
}

/// The column widths of one table, sized to its longest offset, size, field name and type.
final class _Widths {
  const _Widths({required this.offset, required this.size, required this.name, required this.type});

  final int offset;

  final int size;

  final int name;

  final int type;
}

String _meaning(_FieldDecl decl) => decl.doc.isEmpty && decl.field is Unknown ? 'not decoded' : decl.doc;

String _head(String offset, String size, String name, String type, _Widths widths) =>
    '/// ${offset.padRight(widths.offset)} ${size.padRight(widths.size)} ${name.padRight(widths.name)} ${type.padRight(widths.type)} ';

List<String> _wrapRow(String offset, String size, String name, String type, String meaning, _Widths widths) {
  final head = _head(offset, size, name, type, widths);
  final indent = head.length;
  final words = meaning.split(' ');
  final lines = <String>[];
  var line = StringBuffer(head);
  var lineHasWord = false;
  for (final word in words) {
    if (lineHasWord && line.length + 1 + word.length > _lineWidth) {
      lines.add(line.toString().trimRight());
      line = StringBuffer('///'.padRight(indent));
      lineHasWord = false;
    }
    if (lineHasWord) line.write(' ');
    line.write(word);
    lineHasWord = true;
  }
  lines.add(line.toString().trimRight());
  return lines;
}

String _docsSource(Map<String, List<(String, String)>> tagsOf, Map<String, _LayoutClass> classes) {
  final out = StringBuffer('''
// Generated by tool/gen_block_docs.dart from the layout classes' doc comments; do not edit.

import '../block_tag.dart';
import '../byte_layout.dart';

''');
  final tagRows = <String>[];
  for (final MapEntry(key: className, value: tags) in tagsOf.entries) {
    final camel = className.replaceAllMapped(RegExp(r'\.(\w)'), (m) => m.group(1)!.toUpperCase());
    final listName = '_${camel[0].toLowerCase()}${camel.substring(1)}';
    out.writeln('const $listName = <FieldDoc>[');
    for (final decl in classes[className]!.fields) {
      out.writeln('  ${_fieldDoc(decl, classes, '  ')},');
    }
    out.writeln('];\n');
    for (final (member, _) in tags) {
      tagRows.add('  BlockTag.$member: $listName,');
    }
  }
  out.writeln('/// The name, type and doc comment of each field of every layout a [BlockTag] has, in layout order.');
  out.writeln('const Map<BlockTag, List<FieldDoc>> blockFieldDocs = {');
  tagRows.forEach(out.writeln);
  out.writeln('};');
  return out.toString();
}

String _fieldDoc(_FieldDecl decl, Map<String, _LayoutClass> classes, String indent) {
  final head = "FieldDoc(${_quote(decl.shownName)}, ${_quote(decl.type)}, ${_quote(_meaning(decl))}";
  if (decl.entryClass == null) return '$head)';
  final entry = [for (final e in classes[decl.entryClass]!.fields) '$indent  ${_fieldDoc(e, classes, '$indent  ')},'];
  return '$head, [\n${entry.join('\n')}\n$indent])';
}

String _quote(String text) => "'${text.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$')}'";
