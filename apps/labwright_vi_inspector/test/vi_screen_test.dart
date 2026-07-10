import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/vi_demo.dart';
import 'package:labwright_vi_inspector/src/vi_screen.dart';

import 'util.dart';

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: home));
}

ViSummary _summary(List<String> blocks, String name) => ViSummary(
  fileType: 'LVIN',
  creator: 'LBVW',
  formatVersion: 3,
  blocks: blocks,
  name: name,
);

void main() {
  testWidgets('starts empty, loads the demo VI, and shows its details', (
    tester,
  ) async {
    await _pump(tester, const ViInspectorScreen());
    expect(
      find.textContaining('Drag a .vi or a VI-snippet .png'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('demo')));
    await tester.pump();
    expect(find.text('demo.vi'), findsWidgets);
    expect(find.text('Block diagram (logic)'), findsOneWidget);
    expect(find.text('BDHb'), findsOneWidget);
    // The loaded VI's path is copyable from the header.
    expect(find.byKey(const Key('copy-path')), findsOneWidget);
  });

  testWidgets('the Coverage tab surfaces writer fidelity for the demo VI', (
    tester,
  ) async {
    await _pump(tester, const ViInspectorScreen());
    await tester.tap(find.byKey(const Key('demo')));
    await tester.pump();
    await tester.tap(find.text('Coverage'));
    await tester.pumpAndSettle();
    expect(find.text('Writer fidelity'), findsOneWidget);
    expect(find.text('Content model'), findsOneWidget);
    expect(find.text('Round-trip'), findsOneWidget);
  });

  testWidgets('shows decoded version/title and a searchable string list', (
    tester,
  ) async {
    await _pump(
      tester,
      ViInspectorScreen(
        initial: _summary(const ['BDHb', 'vers'], 'My VI.vi'),
        initialSource: 'test',
        initialVersion: const ViVersionInfo(
          version: '10.0',
          title: 'My Example',
        ),
        initialStrings: const ['Conversion time', 'error out', 'Range Volts'],
        initialComponents: const [
          BlockComponent(
            tag: 'BDEx',
            sectionCount: 1,
            rawBytes: 5000,
            decompressedBytes: 78000,
            compressed: true,
          ),
          BlockComponent(
            tag: 'FPHb',
            sectionCount: 1,
            rawBytes: 1200,
            decompressedBytes: 1200,
            compressed: false,
          ),
        ],
      ),
    );
    expect(find.text('LabVIEW version'), findsOneWidget);
    expect(find.text('10.0'), findsOneWidget);
    expect(find.text('My Example'), findsOneWidget);
    expect(find.textContaining('Embedded strings (3)'), findsOneWidget);
    expect(find.text('Conversion time'), findsOneWidget);
    expect(find.text('Components (by decompressed size)'), findsOneWidget);
    expect(find.text('BDEx'), findsOneWidget);
    expect(find.textContaining('76.2 KB'), findsWidgets);
    expect(find.text('Block inventory (by category)'), findsOneWidget);
    expect(find.text('recordHeap'), findsOneWidget);
    expect(find.textContaining('Front-panel heap'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('string-search')), 'error');
    await tester.pump();
    expect(find.text('error out'), findsOneWidget);
    expect(find.text('Conversion time'), findsNothing);
  });

  testWidgets('surfaces owning library (LIBN) and embedded sub-VIs (VINS)', (
    tester,
  ) async {
    await _pump(
      tester,
      ViInspectorScreen(
        initial: _summary(const ['LIBN', 'VINS'], 'Library Member.vi'),
        initialSource: 'test',
        initialLibraryNames: const ['MQTT Server.lvlib'],
        initialEmbeddedVis: [
          ViEmbeddedVi(name: 'abc12345-0000.vi', sizeBytes: 10170),
          ViEmbeddedVi(name: 'UMLEditor Main .vi', sizeBytes: 25638),
          ViEmbeddedVi(name: null, sizeBytes: 1234),
        ],
      ),
    );
    expect(find.text('Owning library'), findsOneWidget);
    expect(find.text('MQTT Server.lvlib'), findsOneWidget);
    expect(find.text('Embedded VIs (3)'), findsOneWidget);
    expect(find.textContaining('abc12345-0000.vi'), findsOneWidget);
    expect(find.textContaining('UMLEditor Main .vi'), findsOneWidget);
  });

  testWidgets('tapping an embedded sub-VI opens it in the inspector', (
    tester,
  ) async {
    final nested = demoViBytes(name: 'NestedDemo.vi');
    await _pump(
      tester,
      ViInspectorScreen(
        initial: _summary(const ['VINS'], 'Outer.vi'),
        initialSource: 'test',
        initialEmbeddedVis: [
          ViEmbeddedVi(
            name: 'inner.vi',
            sizeBytes: nested.length,
            bytes: nested,
          ),
        ],
      ),
    );
    expect(find.text('Embedded VIs (1)'), findsOneWidget);
    expect(find.text('inner.vi'), findsOneWidget);

    await tester.tap(find.text('inner.vi'));
    await tester.pump();
    // Opening the embedded sub-VI loads it (its own name shows in the header).
    expect(find.text('NestedDemo.vi'), findsWidgets);
  });

  testWidgets('dropping a VI-snippet PNG loads its embedded VI + Oracle tab', (
    tester,
  ) async {
    await _pump(tester, const ViInspectorScreen());
    // A synthetic snippet: a real PNG with the demo VI spliced in as niVI.
    // Sync IO only: a real dart:io future awaited outside runAsync never
    // completes under the widget test's fake event loop.
    final dir = Directory.systemTemp.createTempSync('snippet_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final snippetPath = '${dir.path}/demo_snippet.png';
    final plainPath = '${dir.path}/plain.png';
    await tester.runAsync(() async {
      final rgba = Uint8List(60 * 60 * 4)..fillRange(0, 60 * 60 * 4, 0xff);
      final png = await imageToPng(await imageFromRgba(rgba, 60, 60));
      File(snippetPath).writeAsBytesSync(spliceNiVi(png, demoViBytes()));
      File(plainPath).writeAsBytesSync(png);
    });

    void drop(String path) =>
        tester.widget<DropTarget>(find.byType(DropTarget)).onDragDone!(
          DropDoneDetails(
            files: [DropItemFile(path)],
            localPosition: Offset.zero,
            globalPosition: Offset.zero,
          ),
        );

    drop(snippetPath);
    await tester.pump();
    // The embedded demo VI loads; the snippet reference adds the Oracle tab.
    expect(find.text('demo.vi'), findsWidgets);
    expect(find.text('Oracle'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('copy-path')))
          .tooltip!
          .contains('snippet:'),
      isTrue,
    );

    // A PNG without an embedded VI is a clean error, not a crash.
    drop(plainPath);
    await tester.pump();
    expect(find.textContaining('no embedded VI'), findsOneWidget);
  });
}
