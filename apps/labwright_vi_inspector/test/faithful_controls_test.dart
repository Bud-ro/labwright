import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/faithful_controls.dart';
import 'package:labwright_videcode/labwright_videcode.dart';

ViHeapObject _obj({String? help, double? min, double? max}) =>
    ViHeapObject(oid: 1, kind: 0x50, offset: 0)
      ..helpText = help
      ..controlMin = min
      ..controlMax = max;

void main() {
  group('controlTooltip', () {
    test('help only', () => expect(controlTooltip(_obj(help: 'hover me')), 'hover me'));
    test('range only', () => expect(controlTooltip(_obj(min: -5, max: 10)), 'range: -5 … 10'));
    test('help + range joined', () =>
        expect(controlTooltip(_obj(help: 'doc', min: 0, max: 1)), 'doc\nrange: 0 … 1'));
    test('neither -> null', () => expect(controlTooltip(_obj()), isNull));
    test('NaN/blank suppressed', () {
      expect(controlTooltip(_obj(min: 0, max: double.nan)), isNull); // untrustworthy range, no help
      expect(controlTooltip(_obj(help: '   ')), isNull); // whitespace-only help
    });
  });

  testWidgets('faithful control with a decoded range is wrapped in a range Tooltip', (tester) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctl = ViHeapObject(oid: 2, kind: 0x50, offset: 0) // a numeric control
      ..absBounds = const HeapRect(top: 10, left: 10, bottom: 40, right: 120)
      ..controlMin = -1
      ..controlMax = 1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FaithfulLayer(objects: [ctl], origin: Offset.zero, size: const Size(200, 200)),
      ),
    ));
    await tester.pump();
    expect(find.byTooltip('range: -1 … 1'), findsOneWidget); // tooltip exists without hovering
  });
}
