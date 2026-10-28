import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

class _Classes implements LvClassIndex {
  _Classes(this.byName);

  final Map<String, LvClassData> byName;

  @override
  LvClassData? classOf(List<String> qualifiedName) => byName[lvQualifiedNameKey(qualifiedName)];

  @override
  Iterable<List<String>> childrenOf(List<String> qualifiedName) => [
    for (final MapEntry(:key, :value) in byName.entries)
      if (value.parent != null && lvQualifiedNameKey(value.parent!) == lvQualifiedNameKey(qualifiedName))
        key.split(':'),
  ];
}

LvClassData _interface(List<String> parent, {Set<String> members = const {}}) =>
    LvClassData(privateData: null, parent: parent, members: members, isInterface: true);

void main() {
  test('a class whose parent links form a cycle is refused by name rather than recursed into', () {
    final classes = _classes({
      'a.lvclass': _interface(['B.lvclass']),
      'b.lvclass': _interface(['A.lvclass']),
    });
    final mapped = lvClassObjectType(['A.lvclass'], classes, LvDeclarations());
    expect(mapped.isMapped, isFalse);
    expect(mapped.note, contains('form a cycle'));
  });

  test('qualified names compare without regard to case', () {
    final classes = _classes({
      'lib.lvlib:child.lvclass': _interface(['LIB.lvlib', 'Parent.lvclass']),
      'lib.lvlib:parent.lvclass': _interface(const [], members: {'run.vi'}),
    });
    expect(lvQualifiedNameKey(['Lib.lvlib', 'Child.lvclass']), lvQualifiedNameKey(['LIB.LVLIB', 'child.lvclass']));
    expect(lvClassDescendsFrom(['Lib.lvlib', 'Child.lvclass'], ['lib.lvlib', 'PARENT.lvclass'], classes), isTrue);
    expect(lvDispatchDefiner(['Lib.lvlib', 'Child.lvclass'], 'Run.vi', classes), ['LIB.lvlib', 'Parent.lvclass']);
    expect(lvOverridersOf(['lib.lvlib', 'parent.lvclass'], 'Run.vi', classes), isEmpty);
  });

  test('an interface declares no fields and extends the root object', () {
    final declarations = LvDeclarations();
    final mapped = lvClassObjectType(['I.lvclass'], _classes({'i.lvclass': _interface(const [])}), declarations);
    final declaration = mapped.declarations.single;
    expect(declaration.fields, isEmpty);
    expect((declaration.parent?.name, declaration.isClassObject), ('LabViewObject', true));
  });
}

_Classes _classes(Map<String, LvClassData> byName) => _Classes(byName);
