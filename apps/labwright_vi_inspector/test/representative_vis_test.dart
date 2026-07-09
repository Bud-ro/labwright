import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/representative_vis.dart';
import 'package:labwright_vi_inspector/src/vi_demo.dart';
import 'package:labwright_vi_inspector/src/vi_screen.dart';

void main() {
  group('RepresentativeVi.rawUrl', () {
    test('percent-encodes spaces and pins repo/commit', () {
      final vi = kRepresentativeVis.firstWhere(
        (v) => v.name == 'OriginalTest.vi',
      );
      final url = vi.rawUrl;
      expect(url.scheme, 'https');
      expect(url.host, 'raw.githubusercontent.com');
      expect(url.toString(), contains('%20')); // the path has spaces
      expect(url.toString(), contains('tuftsBaxter/ROS-for-LabVIEW-Software'));
      expect(url.pathSegments.last, 'OriginalTest.vi');
    });

    test('every curated VI has a well-formed pinned URL', () {
      expect(kRepresentativeVis, isNotEmpty);
      for (final vi in kRepresentativeVis) {
        expect(vi.rawUrl.host, 'raw.githubusercontent.com');
        expect(vi.rawUrl.pathSegments, isNotEmpty);
        expect(vi.commit.length, 40, reason: '${vi.name} needs a full SHA');
      }
    });
  });

  testWidgets('tapping a representative VI fetches and loads it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Uri? fetched;
    await tester.pumpWidget(
      MaterialApp(
        home: ViInspectorScreen(
          fetchBytes: (url) async {
            fetched = url;
            return demoViBytes();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The landing screen lists the curated VIs.
    expect(find.text('OriginalTest.vi'), findsOneWidget);

    await tester.tap(find.text('OriginalTest.vi'));
    await tester.pumpAndSettle();

    // The injected fetch was called with that VI's raw URL, and it loaded.
    expect(fetched, isNotNull);
    expect(fetched!.pathSegments.last, 'OriginalTest.vi');
    expect(find.text('Block Diagram'), findsOneWidget); // loaded → tabs shown
  });
}
