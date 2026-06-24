import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:labwright_vi_inspector/src/hex_view.dart';
import 'package:labwright_viparse/labwright_viparse.dart';

DecodedSection _section(List<int> records) {
  final body = Uint8List.fromList([0, 0, 0, records.length, ...records]);
  return DecodedSection(
    section: ViSection(tag: 'BDEx', index: 0, dataOffset: 0, bytes: body),
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

  testWidgets('non-heap section shows raw bytes without crashing', (tester) async {
    final raw = DecodedSection(
      section: ViSection(tag: 'LVSR', index: 0, dataOffset: 0, bytes: Uint8List.fromList(List.filled(40, 0x41))),
      bytes: Uint8List.fromList(List.filled(40, 0x41)),
      wasCompressed: false,
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: raw))));
    await tester.pump();
    expect(find.textContaining('raw bytes'), findsOneWidget);
  });
}
