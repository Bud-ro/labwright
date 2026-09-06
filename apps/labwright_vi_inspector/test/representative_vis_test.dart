import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';
import 'package:labwright_vi_inspector/src/representative_vis.dart';
import 'package:labwright_vi_inspector/src/vi_demo.dart';
import 'package:labwright_vi_inspector/src/vi_screen.dart';

import 'util.dart';

void main() {
  group('RepresentativeVi.rawUrl', () {
    test('percent-encodes spaces and pins repo/commit', () {
      final vi = kRepresentativeVis.firstWhere(
        (v) => v.name == 'OriginalTest.vi',
      );
      final url = vi.rawUrl;
      expect(url.scheme, 'https');
      expect(url.host, 'raw.githubusercontent.com');
      expect(url.toString(), contains('%20'));
      expect(url.toString(), contains('tuftsBaxter/ROS-for-LabVIEW-Software'));
      expect(url.pathSegments.last, 'OriginalTest.vi');
    });

    test('every curated VI has a well-formed pinned URL and dep paths', () {
      expect(kRepresentativeVis, isNotEmpty);
      for (final vi in kRepresentativeVis) {
        expect(vi.rawUrl.host, 'raw.githubusercontent.com');
        expect(vi.rawUrl.pathSegments, isNotEmpty);
        expect(vi.commit.length, 40, reason: '${vi.name} needs a full SHA');
        for (final dep in vi.dependencies) {
          expect(
            dep.toLowerCase(),
            endsWith('.vi'),
            reason: '$dep in ${vi.name}',
          );
          expect(vi.rawUrlOf(dep).pathSegments.last, dep.split('/').last);
        }
      }
    });
  });

  test(
    'fetchRepresentativeVi writes the closure into a temp project dir',
    () async {
      final vi = kRepresentativeVis.firstWhere(
        (v) => v.name == 'USBDrDAQExampleStreaming.vi',
      );
      final urls = <Uri>[];
      final fetched = await fetchRepresentativeVi(
        vi,
        fetch: (url) async {
          urls.add(url);
          return Uint8List.fromList([1, 2, 3]);
        },
      );
      addTearDown(() => fetched.projectDir.deleteSync(recursive: true));
      expect(urls.length, 1 + vi.dependencies.length);
      expect(fetched.fetchedDeps, vi.dependencies.length);
      expect(fetched.failedDeps, 0);
      expect(fetched.mainPath, startsWith(fetched.projectDir.path));
      expect(fetched.bytes, [1, 2, 3]);
    },
  );

  test('a failing dependency is tolerated (icon-only cost)', () async {
    final vi = kRepresentativeVis.firstWhere(
      (v) => v.name == 'USBDrDAQExampleStreaming.vi',
    );
    var calls = 0;
    final fetched = await fetchRepresentativeVi(
      vi,
      fetch: (url) async {
        calls++;
        if (url.pathSegments.last == 'USBDrDAQClose.vi') {
          throw Exception('boom');
        }
        return Uint8List.fromList([0]);
      },
    );
    addTearDown(() => fetched.projectDir.deleteSync(recursive: true));
    expect(calls, 1 + vi.dependencies.length);
    expect(fetched.failedDeps, 1);
    expect(fetched.fetchedDeps, vi.dependencies.length - 1);
  });

  testWidgets('the Examples menu fetches and loads a representative VI', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final urls = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ViInspectorScreen(
          fetchBytes: (url) async {
            urls.add(url);
            return demoViBytes();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('examples')));
    await tester.pumpAndSettle();
    expect(find.text('3DBaxter.vi'), findsOneWidget);

    await tester.tap(find.text('3DBaxter.vi'));
    await tester.pumpAndSettle();

    expect(urls, hasLength(1));
    expect(urls.single.pathSegments.last, '3DBaxter.vi');
    expect(find.text('Block Diagram'), findsOneWidget);

    expect(find.byKey(const Key('examples')), findsOneWidget);
  });

  testWidgets('a snippet-PNG example loads its embedded VI + Oracle tab', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final snippetPng = (await tester.runAsync(() async {
      final rgba = Uint8List(60 * 60 * 4)..fillRange(0, 60 * 60 * 4, 0xff);
      final png = await imageToPng(await imageFromRgba(rgba, 60, 60));
      return spliceNiVi(png, demoViBytes());
    }))!;

    await tester.pumpWidget(
      MaterialApp(
        home: ViInspectorScreen(fetchBytes: (url) async => snippetPng),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('examples')));
    await tester.pumpAndSettle();
    expect(find.text('crc8.png (VI snippet)'), findsOneWidget);

    await tester.tap(find.text('crc8.png (VI snippet)'));
    await tester.pumpAndSettle();
    expect(find.text('demo.vi'), findsWidgets);
    expect(find.text('Oracle'), findsOneWidget);
  });
}
