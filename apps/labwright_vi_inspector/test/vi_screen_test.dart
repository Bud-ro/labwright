import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/vi_screen.dart';

void main() {
  testWidgets('starts empty, loads the demo VI, and shows its details', (tester) async {
    // Tall viewport so the whole (lazy) ListView builds for the assertions.
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: ViInspectorScreen()));

    expect(find.textContaining('Drag a .vi here'), findsOneWidget);

    await tester.tap(find.byKey(const Key('demo')));
    await tester.pump();

    expect(find.text('demo.vi'), findsOneWidget);
    expect(find.text('Block diagram (logic)'), findsOneWidget); // capability chip
    expect(find.text('BDHb'), findsOneWidget); // inventory chip
    expect(find.textContaining('Read-only viewer'), findsOneWidget); // honesty card
  });

  testWidgets('a non-existent path shows a clean error, not a crash', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ViInspectorScreen()));

    await tester.enterText(find.byKey(const Key('path')), '/no/such/file.vi');
    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();

    expect(find.textContaining('No such file'), findsOneWidget);
  });
}
