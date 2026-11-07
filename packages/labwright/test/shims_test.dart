import 'package:labwright/labwright.dart' as lw;
import 'package:labwright/shims.dart' as ts;
import 'package:test/test.dart';

void main() {
  test('eval, cond and notExported always throw, naming what they were given', () {
    for (final (Function fn, expr) in [
      (ts.eval, 'RunState.Foo'),
      (ts.cond, 'Locals.X > 1'),
      (ts.notExported, 'python call: x.py'),
    ]) {
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
  test('checkLimits: the low limit alone for one-sided comparisons, both for ranges', () {
    expect(ts.checkLimits(5, 0, 5, 'EQ'), ts.statusPassed);
    expect(ts.checkLimits(6, 0, 5, 'GT'), ts.statusPassed);
    expect(ts.checkLimits(5, 0, 5, 'GT'), ts.statusFailed);
    expect(ts.checkLimits(10, 10, 0, 'GELE'), ts.statusPassed);
    expect(ts.checkLimits(10, 10, 0, 'GELT'), ts.statusFailed);
    expect(ts.checkLimits(11, 10, 0, 'LTGT'), ts.statusPassed);
    expect(ts.checkLimits(-1, 1, 0, 'LOG'), ts.statusPassed);
    expect(() => ts.checkLimits(1, 2, 0, 'EQT'), throwsUnimplementedError);
  });
  test('checkStrLimit compares with or without case', () {
    expect(ts.checkStrLimit('Abc', 'aBC', 'IgnoreCase'), ts.statusPassed);
    expect(ts.checkStrLimit('Abc', 'aBC', 'CaseSensitive'), ts.statusFailed);
    expect(() => ts.checkStrLimit('a', 'a', 'IgnoreCase', 3), throwsUnimplementedError);
  });
  test('a sequence run fails once a failed status is recorded', () {
    final run = ts.SequenceRun()..record('Done');
    expect(run.status, ts.statusPassed);
    run.record(ts.statusFailed);
    expect((run.status, run.failed), (ts.statusFailed, true));
  });
  test('terminate raises the termination a caller unwinds through', () {
    expect(ts.terminate, throwsA(isA<ts.SequenceTermination>()));
  });
  test('sweep values: steps up to the stop, points with both ends, parallel rows', () {
    expect(ts.sweepSteps(-10, 5, 5), [-10, -5, 0, 5]);
    expect(ts.sweepSteps(0, 1, 0.4), [0, 0.4, 0.8]);
    expect(ts.sweepPoints(1000, 6000, 3), [1000, 3500, 6000]);
    final log = ts.sweepPoints(200, 50000, 100, logarithmic: true);
    expect(log.first, 200);
    expect(log.last, closeTo(50000, 1e-6));
    expect(log[1] / log[0], closeTo(1.0573569305267, 1e-9));
    expect(
      ts.parallel([
        [1, 2],
        ['a', 'b'],
      ]).toList(),
      [
        [1, 'a'],
        [2, 'b'],
      ],
    );
    expect(
      () => ts.parallel([
        [1],
        [1, 2],
      ]).toList(),
      throwsArgumentError,
    );
  });
  test('a step loop counts passed and failed iterations', () {
    final loop = ts.StepLoop()
      ..count(ts.statusPassed)
      ..count(ts.statusFailed)
      ..count('Done');
    expect((loop.numIterations, loop.numPassed, loop.numFailed), (3, 1, 1));
  });
  test('without an installed host every step operation raises, naming it', () {
    expect(
      () => ts.stepHost.runStepType('NI_Measurement', ts.StepPhase.post, null, null),
      throwsA(isA<ts.StepHostUnavailable>().having((e) => e.operation, 'operation', 'NI_Measurement post')),
    );
    expect(
      () => ts.stepHost.messagePopup(title: 't', message: 'm', buttons: const []),
      throwsA(isA<ts.StepHostUnavailable>()),
    );
  });
  test('copy is deep for lists and property objects; a Ref carries a written value back', () {
    final dynamic original = ts.PropObj({
      'List': [1, 2],
      'Inner': ts.PropObj({'X': 1}),
    });
    final dynamic copied = ts.copy(original);
    copied.List[0] = 9;
    copied.Inner.X = 9;
    expect((original.List[0], original.Inner.X, copied.Inner.Name), (1, 1, 'Inner'));
    final ref = ts.Ref<int>(1)..value = 2;
    expect(ref.value, 2);
  });
  test('async calls are awaited by step and at the end; an error surfaces when awaited', () async {
    final calls = ts.AsyncCalls()
      ..start('a', Future<Object?>.value('Passed'), waitAtEnd: true)
      ..start('b', Future<Object?>.error(StateError('boom')), waitAtEnd: false);
    expect(await calls.wait('a'), 'Passed');
    await calls.waitAtEnd();
    await expectLater(calls.wait('b'), throwsStateError);
    expect(() => calls.wait('c'), throwsStateError);
  });
}
