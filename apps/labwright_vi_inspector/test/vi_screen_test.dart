import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';
import 'package:labwright_vi_inspector/src/types_view.dart';
import 'package:labwright_vi_inspector/src/vi_screen.dart';
import 'package:labwright_rsrc_parse/testing.dart';

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

  testWidgets('shows decoded version/title and the component summary', (
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
    expect(find.text('Components (by decompressed size)'), findsOneWidget);
    expect(find.text('BDEx'), findsOneWidget);
    expect(find.textContaining('76.2 KB'), findsWidgets);
    expect(find.text('Block inventory'), findsOneWidget);
    expect(find.textContaining('Front-panel heap'), findsOneWidget);
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
    final nested = minimalViBytes(name: 'NestedDemo.vi');
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
    expect(find.text('NestedDemo.vi'), findsWidgets);
  });

  testWidgets('dropping a VI-snippet PNG loads its embedded VI + Oracle tab', (
    tester,
  ) async {
    await _pump(tester, const ViInspectorScreen());
    final dir = Directory.systemTemp.createTempSync('snippet_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final snippetPath = '${dir.path}/demo_snippet.png';
    final plainPath = '${dir.path}/plain.png';
    await tester.runAsync(() async {
      final rgba = Uint8List(60 * 60 * 4)..fillRange(0, 60 * 60 * 4, 0xff);
      final png = await imageToPng(await imageFromRgba(rgba, 60, 60));
      File(snippetPath).writeAsBytesSync(spliceNiVi(png, minimalViBytes()));
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
    expect(find.text('demo.vi'), findsWidgets);
    expect(find.text('Oracle'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('copy-path')))
          .tooltip!
          .contains('snippet:'),
      isTrue,
    );

    drop(plainPath);
    await tester.pump();
    expect(find.textContaining('no embedded VI'), findsOneWidget);
  });

  testWidgets('dropping another VI gives every stateful tab fresh state', (
    tester,
  ) async {
    await _pump(tester, const ViInspectorScreen());
    final dir = Directory.systemTemp.createTempSync('snippet_reload');
    addTearDown(() => dir.deleteSync(recursive: true));
    final paths = <String>[];
    await tester.runAsync(() async {
      final rgba = Uint8List(60 * 60 * 4)..fillRange(0, 60 * 60 * 4, 0xff);
      final png = await imageToPng(await imageFromRgba(rgba, 60, 60));
      for (final name in ['first.vi', 'second.vi', 'third.vi']) {
        final path = '${dir.path}/$name.png';
        File(
          path,
        ).writeAsBytesSync(spliceNiVi(png, minimalViBytes(name: name)));
        paths.add(path);
      }
    });
    void drop(String path) =>
        tester.widget<DropTarget>(find.byType(DropTarget)).onDragDone!(
          DropDoneDetails(
            files: [DropItemFile(path)],
            localPosition: Offset.zero,
            globalPosition: Offset.zero,
          ),
        );

    drop(paths[0]);
    await tester.pump();
    for (final (tab, view) in [
      ('Front Panel', find.byType(ViDiagramView)),
      ('Block Diagram', find.byType(ViDiagramView)),
      ('Types', find.byType(ViTypesView)),
      ('Oracle', find.byType(BdOracleView)),
    ]) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      final before = tester.state(view);
      drop(paths[1]);
      await tester.pumpAndSettle();
      expect(
        identical(before, tester.state(view)),
        isFalse,
        reason: '$tab kept its state across a drop',
      );
      drop(paths[2]);
      await tester.pumpAndSettle();
    }
  });
}
