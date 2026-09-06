import 'naming.dart';
import 'type_map.dart';

String lvDeclarationSource(LvTypeDecl decl) => decl.isEnum ? _enumSource(decl) : _classSource(decl);

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

String _doc(String? label) {
  if (label == null) return 'with no name of its own';
  final collapsed = label.replaceAll(RegExp(r'\s+'), ' ').trim();
  final text = String.fromCharCodes([
    for (final code in collapsed.codeUnits)
      if (code >= 0x20 && code < 0x7f && code != 0x60) code,
  ]);
  return text.isEmpty ? 'whose name is not printable text' : '`$text`';
}
