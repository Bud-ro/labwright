/// The **declaration writer**: an [LvTypeDecl] as Dart source.
///
/// A lowered library spells nominal types — a named cluster's class, a named
/// enum's `enum` — and this is where those declarations are written, so that
/// nothing the emitter produces refers to a name the file does not carry.
///
/// Two shapes, and the file format decides both:
///
/// - a **cluster** becomes a class of `final` fields with a `const` constructor
///   taking every one by name. A cluster is a value with a fixed member list;
///   nothing about it changes after construction, and the descriptor states no
///   default for any member, so there is no unnamed or optional form to write.
/// - an **enum** becomes a Dart `enum`. The descriptor's interior is
///   `[u16 count]` then `count × [u8 len][chars]` — item labels in order and no
///   value word anywhere — so an item's value is its ordinal, which is exactly
///   a Dart enum's `index`. A class of named integer constants would carry the
///   same information and lose the exhaustiveness a `switch` over an enum gets.
///
/// The one declaration that cannot be written is an enum whose item labels did
/// not decode ([LvTypeDecl.undeclarable]): a Dart `enum` must have a member.
library;

import 'naming.dart';
import 'type_map.dart';

/// [decl] as Dart source — a class for a cluster, an `enum` for an enum.
///
/// The declaration is complete: every field is typed and every enum member
/// named, so a file carrying it compiles. Callers must have refused already on
/// [LvTypeDecl.undeclarable].
String lvDeclarationSource(LvTypeDecl decl) => decl.isEnum ? _enumSource(decl) : _classSource(decl);

/// Every declaration reachable from [roots], each one before anything that
/// names it, with duplicates removed — the order a file writes them in.
List<LvTypeDecl> lvDeclarationClosure(Iterable<LvTypeDecl> roots) {
  final seen = <LvTypeDecl>{};
  final ordered = <LvTypeDecl>[];
  void visit(LvTypeDecl decl) {
    if (!seen.add(decl)) return;
    for (final dependency in decl.dependencies) {
      visit(dependency);
    }
    ordered.add(decl);
  }

  for (final root in roots) {
    visit(root);
  }
  return ordered;
}

String _classSource(LvTypeDecl decl) {
  final names = LvNaming.declarationFields([for (final field in decl.fields) field.label]);
  final out = StringBuffer()
    ..writeln('/// The LabVIEW cluster ${_doc(decl.label)}.')
    ..writeln('class ${decl.name} {')
    ..writeln(
      'const ${decl.name}('
      '${names.isEmpty ? '' : '{${[for (final name in names) 'required this.$name'].join(', ')}}'});',
    );
  for (var index = 0; index < decl.fields.length; index++) {
    final label = decl.fields[index].label;
    out.writeln();
    if (label == null) {
      out.writeln('/// Member ${index + 1}; the descriptor carries no name for it.');
    } else if (label != names[index]) {
      out.writeln('/// ${_doc(label)}');
    }
    out.writeln('final ${decl.fields[index].type.dartType} ${names[index]};');
  }
  out.writeln('}');
  return out.toString();
}

String _enumSource(LvTypeDecl decl) {
  final names = LvNaming.declarationItems(decl.items);
  final out = StringBuffer()
    ..writeln('/// The LabVIEW enum ${_doc(decl.label)}. A member\'s `index` is the')
    ..writeln('/// value the wire carries: the descriptor states the item labels in order')
    ..writeln('/// and no value of its own for any of them.')
    ..writeln('enum ${decl.name} {');
  for (var index = 0; index < names.length; index++) {
    if (decl.items[index] != names[index]) out.writeln('/// ${_doc(decl.items[index])}');
    out.writeln('${names[index]}${index == names.length - 1 ? '' : ','}');
  }
  out.writeln('}');
  return out.toString();
}

/// [label] as one line of doc-comment text, quoted — or a stated absence.
///
/// A LabVIEW name is free text: it may hold newlines, backticks or bytes
/// outside printable ASCII, none of which a `///` line can carry as they are.
String _doc(String? label) {
  if (label == null) return 'with no name of its own';
  final collapsed = label.replaceAll(RegExp(r'\s+'), ' ').trim();
  final text = String.fromCharCodes([
    for (final code in collapsed.codeUnits)
      if (code >= 0x20 && code < 0x7f && code != 0x60) code,
  ]);
  return text.isEmpty ? 'whose name is not printable text' : '`$text`';
}
