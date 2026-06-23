import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/vi_screen.dart';
import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:labwright_viparse/labwright_viparse.dart';

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

  testWidgets('shows decoded version/title and a searchable string list', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: ViInspectorScreen(
        initial: ViSummary(
          fileType: 'LVIN',
          creator: 'LBVW',
          formatVersion: 3,
          blocks: const ['BDHb', 'vers'],
          name: 'My VI.vi',
        ),
        initialSource: 'test',
        initialVersion: const ViVersionInfo(version: '10.0', title: 'My Example'),
        initialStrings: const ['Conversion time', 'error out', 'Range Volts'],
        initialComponents: const [
          BlockComponent(tag: 'BDEx', sectionCount: 1, rawBytes: 5000, decompressedBytes: 78000, compressed: true),
          BlockComponent(tag: 'FPHb', sectionCount: 1, rawBytes: 1200, decompressedBytes: 1200, compressed: false),
        ],
      ),
    ));

    expect(find.text('LabVIEW version'), findsOneWidget);
    expect(find.text('10.0'), findsOneWidget);
    expect(find.text('My Example'), findsOneWidget);
    expect(find.textContaining('Embedded strings (3)'), findsOneWidget);
    expect(find.text('Conversion time'), findsOneWidget);
    expect(find.text('Components (by decompressed size)'), findsOneWidget);
    expect(find.text('BDEx'), findsOneWidget); // only in components (not in inventory blocks)
    expect(find.textContaining('76.2 KB'), findsOneWidget); // 78000 bytes formatted

    // Filtering the string list.
    await tester.enterText(find.byKey(const Key('string-search')), 'error');
    await tester.pump();
    expect(find.text('error out'), findsOneWidget);
    expect(find.text('Conversion time'), findsNothing);
  });

  testWidgets('a non-existent path shows a clean error, not a crash', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ViInspectorScreen()));

    await tester.enterText(find.byKey(const Key('path')), '/no/such/file.vi');
    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();

    expect(find.textContaining('No such file'), findsOneWidget);
  });
}
