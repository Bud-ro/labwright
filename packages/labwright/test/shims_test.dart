import 'package:labwright/labwright.dart' as lw;
import 'package:labwright/shims.dart' as ts;
import 'package:test/test.dart';

void main() {
  test('eval and cond always throw, naming the expression', () {
    for (final (Function fn, expr) in [(ts.eval, 'RunState.Foo'), (ts.cond, 'Locals.X > 1')]) {
      expect(
        () => fn(expr),
        throwsA(isA<UnimplementedError>().having((e) => e.message, 'message', contains(expr))),
      );
    }
  });

  test('truthy: engine boolean coercion where pinned, loud elsewhere', () {
    expect(ts.truthy(true), isTrue);
    expect(ts.truthy(0), isFalse);
    expect(ts.truthy(-2.5), isTrue);
    expect(() => ts.truthy('yes'), throwsUnimplementedError);
  });

  test('string built-ins pin engine semantics: Len/Str/Left/Right/Mid/Find', () {
    // dart format off
    final rows = <(String, Object?, Object?)>[
      ('Len(str)', ts.len('abcd'), 4.0),
      ('Len(array)', ts.len([1, 2, 3]), 3.0),
      ('Str(3.0) drops .0', ts.str(3.0), '3'),
      ('Str(2.5)', ts.str(2.5), '2.5'),
      ('Left', ts.left('sequence', 3), 'seq'),
      ('Left clamps', ts.left('ab', 99), 'ab'),
      ('Right', ts.right('sequence', 4), 'ence'),
      ('Right clamps', ts.right('ab', 99), 'ab'),
      ('Mid', ts.mid('sequence', 3, 2), 'ue'),
      ('Find hit', ts.find('sequence', 'que'), 2.0),
      ('Find miss', ts.find('sequence', 'zzz'), -1.0),
    ];
    // dart format on
    for (final (name, got, want) in rows) {
      expect(got, want, reason: name);
    }
  });

  test('array built-ins: GetNumElements/SetNumElements grow with null, shrink', () {
    final list = <dynamic>[1, 2, 3];
    expect(ts.getNumElements(list), 3.0);
    ts.setNumElements(list, 5);
    expect(list, [1, 2, 3, null, null]);
    ts.setNumElements(list, 2);
    expect(list, [1, 2]);
  });

  test('iterate: lists, maps, PropObj sub-properties', () {
    expect(ts.iterate([1, 2]).toList(), [1, 2]);
    final dynamic bag = ts.PropObj({
      'A': 1.0,
      'B': ts.PropObj({'C': true}),
    });
    expect([for (final dynamic e in ts.iterate(bag)) e.Name], ['A', 'B']);
  });

  test('PropObj: case-insensitive member get/set via dynamic dispatch', () {
    final dynamic bag = ts.PropObj({
      'Menus': ts.PropObj({'MENU_RECIPE': false}),
    });
    expect(bag.Menus.MENU_RECIPE, isFalse);
    expect(bag.menus.menu_recipe, isFalse, reason: 'engine names ignore case');
    bag.Menus.MENU_RECIPE = true;
    expect(bag.Menus.MENU_RECIPE, isTrue);
    bag.NewMember = 7.0;
    expect(bag.newmember, 7.0, reason: 'writes create members');
  });

  test('PropObj: unset reads and unshimmed engine methods are loud', () {
    final dynamic bag = ts.PropObj();
    expect(() => bag.Missing, throwsStateError);
    expect(() => bag.SetValNumber('x', 0, 1.0), throwsUnimplementedError);
  });

  test('PropObj: engine-object surface (GetSubProperties/Name/Exists)', () {
    final dynamic bag = ts.PropObj({
      'A': 1.0,
      'Nested': ts.PropObj({'B': ''}),
    });
    expect(bag.AsPropertyObject, same(bag));
    final subs = bag.GetSubProperties('', 0) as List<Object?>;
    expect([for (final dynamic p in subs) p.Name], ['A', 'Nested']);
    expect(bag.Exists('a'), isTrue);
    expect(bag.Exists('zzz'), isFalse);
  });

  test('lw.rand: bounded draws; ts.rand mirrors for plain exports', () {
    for (var i = 0; i < 100; i++) {
      expect(lw.rand(2, 4), inInclusiveRange(2, 4));
      expect(ts.rand(), inInclusiveRange(0, 1));
    }
    expect(List.generate(8, (_) => lw.rand()).toSet().length, greaterThan(1));
  });
}
