import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:labwright_vi_inspector/src/hex_view.dart';
import 'package:labwright_viparse/labwright_viparse.dart';

DecodedSection _section(List<int> records) {
  final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
  return DecodedSection(
    // BDHb is a real C4 record-heap tag — the heap record-walk is gated on the
    // block tag now, so the heap-path tests must use a genuine heap tag.
    section: ViSection(tag: 'BDHb', index: 0, dataOffset: 0, bytes: body),
    bytes: body,
    wasCompressed: true,
  );
}

void main() {
  testWidgets('hex view parses heap records with names and typed displays', (tester) async {
    final records = <int>[
      // object: 0x50 numeric control, oid 1
      0x10, 0x19, 0x02, 0xfe, 0x00, 0x50, 0xfd, 0x00, 0x01,
      0xc4, 0x2d, 0x08, 0x00, 0x0a, 0x00, 0x14, 0x00, 0x1e, 0x00, 0x28, // bounds (10,20,30,40)
      0xc4, 0x22, 0x02, 0x48, 0x69, // caption "Hi"
      0x84, 0x28, 0xff, 0x12, 0x34, 0x56, // background colour #123456
      0x08, 0x19, // group close
    ];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: _section(records)))));
    await tester.pump();

    // record panel shows real names from the catalogs
    expect(find.textContaining('Numeric control'), findsOneWidget);
    expect(find.textContaining('bounds'), findsWidgets);
    expect(find.textContaining('backgroundColor'), findsOneWidget);

    // selecting the caption record reveals its decoded string in the detail panel
    await tester.tap(find.textContaining('caption').first);
    await tester.pump();
    expect(find.text('Hi'), findsOneWidget);
  });

  testWidgets('hex view labels the heap content-length header (no unexplained leading bytes)', (tester) async {
    final records = <int>[0x08, 0x19]; // a minimal group-close record stream
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: _section(records)))));
    await tester.pump();

    // the 4-byte u32 length prefix is now annotated (previously unexplained)
    expect(find.textContaining('Heap content length'), findsOneWidget);
    // the size shows INLINE in the row (a preview, like a colour swatch) — no click needed
    expect(find.text('2 B'), findsOneWidget);
    await tester.tap(find.textContaining('Heap content length').first);
    await tester.pump();
    // detail explains it is the record-stream size (here == records.length == 2)
    expect(find.textContaining('= 2 bytes'), findsOneWidget);
  });

  testWidgets('hex view accounts for an unframed tail when the walk stops (no silent bytes)', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 08 19 frames (group close), then 0x9f is an un-framable lead → the walk
    // stops and the remaining bytes must be explicitly accounted, not left blank.
    final records = <int>[0x08, 0x19, 0x9f, 0x27];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: _section(records)))));
    await tester.pump();

    expect(find.textContaining('Unframed tail'), findsOneWidget);
    expect(find.text('2 B'), findsWidgets); // the 2 remaining bytes accounted inline
    await tester.tap(find.textContaining('Unframed tail').first);
    await tester.pump();
    expect(find.textContaining('not yet decoded'), findsOneWidget); // honest framing
  });

  testWidgets('hex view shows the group close tag in the title', (tester) async {
    final records = <int>[0x08, 0x2a]; // a group-close record, tag 0x2a
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: _section(records)))));
    await tester.pump();

    expect(find.textContaining('Group close · tag 0x2a'), findsOneWidget);
    await tester.tap(find.textContaining('Group close · tag 0x2a').first);
    await tester.pump();
    // detail explains the matching-open tag pairing
    expect(find.textContaining('same tag'), findsOneWidget);
  });

  testWidgets('hex view surfaces the newest decoded forms (property name, help text, control min)', (tester) async {
    final records = <int>[
      0x10, 0x19, 0x02, 0xfe, 0x00, 0x50, 0xfd, 0x00, 0x01, // object header
      0xc6, 0x31, 0x05, 0x53, 0x63, 0x61, 0x6c, 0x65, // C6 31 "Scale" (property name)
      0xc6, 0x6c, 0xff, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x06, 0x52, 0x6f, 0x62, 0x6f, 0x74, 0x21, // C6 6C FF "Robot!"
      0xc5, 0x20, 0x08, 0xbf, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // C5 20 08 f64 = -1.0 (control min)
      0x08, 0x19,
    ];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: _section(records)))));
    await tester.pump();

    // the property-name record is named and its string is shown
    expect(find.textContaining('propertyName'), findsOneWidget);
    await tester.tap(find.textContaining('propertyName').first);
    await tester.pump();
    expect(find.text('Scale'), findsOneWidget);

    // the help-text blob string is shown
    await tester.tap(find.textContaining('helpDescription').first);
    await tester.pump();
    expect(find.text('Robot!'), findsOneWidget);

    // the C5 20 08 f64 control-min is surfaced as a numeric-control parameter
    await tester.tap(find.textContaining('foregroundColorOrControlMin').first);
    await tester.pump();
    expect(find.textContaining('Numeric-control parameter'), findsOneWidget);
  });

  testWidgets('non-heap section shows raw hex + its catalog identity, no crash', (tester) async {
    final raw = DecodedSection(
      section: ViSection(tag: 'LVSR', index: 0, dataOffset: 0, bytes: Uint8List.fromList(List.filled(40, 0x41))),
      bytes: Uint8List.fromList(List.filled(40, 0x41)),
      wasCompressed: false,
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: raw))));
    await tester.pump();
    expect(find.textContaining('raw hex'), findsOneWidget);
    expect(find.textContaining('LabVIEW save record'), findsOneWidget); // catalog name
  });

  testWidgets('a compressed NON-heap block (VCTP) is not mis-walked as a heap', (tester) async {
    // Regression: VCTP/TM80/VICD are compressed (or short look-alikes) but are NOT
    // C4 heaps. The old heuristic read their first u32 as a "heap content length"
    // and dumped the rest as a fat "unframed tail". Gating on the tag fixes it.
    // Craft bytes the old heuristic WOULD have flagged: b[4] == 0xc4.
    final body = Uint8List.fromList([0x00, 0x00, 0x00, 0xee, 0xc4, 0x01, 0x02, 0x03, 0x04, 0x05]);
    final vctp = DecodedSection(
      section: ViSection(tag: 'VCTP', index: 0, dataOffset: 0, bytes: body),
      bytes: body,
      wasCompressed: true,
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: vctp))));
    await tester.pump();
    expect(find.textContaining('Heap content length'), findsNothing);
    expect(find.textContaining('Unframed tail'), findsNothing);
    expect(find.textContaining('VI type pool'), findsOneWidget); // named honestly instead
  });
}
