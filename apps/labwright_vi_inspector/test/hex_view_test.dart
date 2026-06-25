import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('an undecoded non-heap block shows raw hex + its catalog identity', (tester) async {
    // TRec has no decoder -> the honest raw-hex note, not a parsed panel.
    final raw = DecodedSection(
      section: ViSection(tag: 'TRec', index: 0, dataOffset: 0, bytes: Uint8List.fromList(List.filled(40, 0x41))),
      bytes: Uint8List.fromList(List.filled(40, 0x41)),
      wasCompressed: false,
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: raw))));
    await tester.pump();
    expect(find.textContaining('raw hex'), findsOneWidget);
  });

  DecodedSection _raw(String tag, List<int> bytes) => DecodedSection(
        section: ViSection(tag: tag, index: 0, dataOffset: 0, bytes: Uint8List.fromList(bytes)),
        bytes: Uint8List.fromList(bytes),
        wasCompressed: false,
      );

  testWidgets('a vers block is annotated per-byte: version-word span + undecoded tail', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // vers: binary version word 08 50 80 02 -> "8.5" + a Pascal version string.
    final vers = _raw('vers', [0x08, 0x50, 0x80, 0x02, 0x03, ...'8.5'.codeUnits]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: vers))));
    await tester.pump();
    // the first 4 bytes are a clickable "Version word" field showing the version;
    expect(find.textContaining('Version word'), findsOneWidget);
    expect(find.textContaining('8.5'), findsWidgets); // decoded version in the preview
    // ...and the remaining (string) bytes are honestly marked undecoded — total coverage.
    expect(find.textContaining('Undecoded'), findsWidgets);
  });

  testWidgets('an LVSR block is annotated per byte (version word + hashes + undecoded gaps)', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final lvsr = _raw('LVSR', [for (var i = 0; i < 160; i++) 0]..[0] = 0x08..[1] = 0x50..[2] = 0x80);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: lvsr))));
    await tester.pump();
    expect(find.textContaining('Version word'), findsOneWidget);
    expect(find.textContaining('BD password hash'), findsOneWidget);
    expect(find.textContaining('Secondary hash'), findsOneWidget);
    // the flag/id bytes between known fields are honestly marked, not hidden
    expect(find.textContaining('Undecoded'), findsWidgets);
  });

  testWidgets('an id-table block is annotated per byte (count + each entry)', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // NUID = [u32 count=2][u32 id0][u32 id1] — every byte should be a field.
    final nuid = _raw('NUID', [0, 0, 0, 2, 0, 0, 0, 0x11, 0, 0, 0, 0x22]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: nuid))));
    await tester.pump();
    expect(find.textContaining('Entry count'), findsOneWidget);
    expect(find.textContaining('id[0]'), findsOneWidget);
    expect(find.textContaining('id[1]'), findsOneWidget);
    // fully framed: no "Undecoded" gap for this exact [count][entries] layout
    expect(find.textContaining('Undecoded'), findsNothing);
  });

  testWidgets('the header reports per-block byte coverage: 100% for a fully-framed id table', (tester) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // NUID fully covered by [count][entries] spans → 100% framed in the header.
    final nuid = _raw('NUID', [0, 0, 0, 2, 0, 0, 0, 0x11, 0, 0, 0, 0x22]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: nuid))));
    await tester.pump();
    expect(find.textContaining('100% framed'), findsOneWidget);
  });

  testWidgets('the header reports a partial % for a block with undecoded gaps (LVSR)', (tester) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // LVSR: only the version word + two 16-byte hash slots are named; the flag/id
    // bytes are honestly Undecoded → coverage is below 100% and never claims 100.
    final lvsr = _raw('LVSR', [for (var i = 0; i < 160; i++) 0]..[0] = 0x08..[1] = 0x50);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: lvsr))));
    await tester.pump();
    expect(find.textContaining('% framed'), findsOneWidget);
    expect(find.textContaining('100% framed'), findsNothing);
  });

  testWidgets('FPSE/BDSE section-marker blocks are framed as a u32 (100%)', (tester) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // Corpus: predominantly a single u32 value (e.g. 0x77).
    final fpse = _raw('FPSE', [0, 0, 0, 0x77]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: fpse))));
    await tester.pump();
    expect(find.textContaining('FPSE marker'), findsOneWidget);
    expect(find.textContaining('100% framed'), findsOneWidget);
    expect(find.textContaining('Undecoded'), findsNothing);
  });

  testWidgets('a MUID block is framed as a single u32 (100%)', (tester) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final muid = _raw('MUID', [0, 0, 0x0b, 0x6c]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: muid))));
    await tester.pump();
    expect(find.textContaining('MUID (u32)'), findsOneWidget);
    expect(find.textContaining('100% framed'), findsOneWidget);
  });

  testWidgets('a TITL block is annotated as a Pascal string (len + ASCII title)', (tester) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // [u8 len=11]["Batch Tests"] — len byte matches the text length exactly.
    final titl = _raw('TITL', [11, ...'Batch Tests'.codeUnits]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: titl))));
    await tester.pump();
    expect(find.textContaining('Title length'), findsOneWidget);
    expect(find.textContaining('Title (ASCII)'), findsOneWidget);
    expect(find.textContaining('Batch Tests'), findsWidgets);
    // [len][text] covers every byte → 100% framed, nothing left Undecoded.
    expect(find.textContaining('100% framed'), findsOneWidget);
    expect(find.textContaining('Undecoded'), findsNothing);
  });

  testWidgets('a decoded HLPP block shows its recovered help path', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hlpp = _raw('HLPP', [
      ...'PTH0'.codeUnits, // magic
      0, 0, 0, 0x0c, // inner len
      0, 0, // type
      0, 1, // count
      3, ...'doc'.codeUnits, // one component
    ]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: hlpp))));
    await tester.pump();
    expect(find.text('doc'), findsOneWidget);
  });

  testWidgets('a CONP block resolves its index against the sibling VCTP type pool', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // sibling VCTP with one type (#0 boolean); CONP -> 1-based index 1.
    final vctp = _raw('VCTP', [0, 0, 0, 1, 0, 4, 0, 0x21]);
    final conp = _raw('CONP', [0, 1]); // u16 index = 1
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: BlockHexView(section: conp, siblings: [vctp])),
    ));
    await tester.pump();
    expect(find.textContaining('VCTP type index'), findsOneWidget);
    expect(find.textContaining('boolean'), findsWidgets); // resolved conpane type
  });

  testWidgets('a VCTP block lists the recovered type pool', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // VCTP = [u32 count][ (u16 descLen)(flags)(code) ... ]; two scalar types:
    // a dbl (code 0x0a) and a boolean (code 0x21), each a 4-byte descriptor.
    final vctp = _raw('VCTP', [
      0, 0, 0, 2, // count = 2
      0, 4, 0, 0x0a, // #0 dbl
      0, 4, 0, 0x21, // #1 boolean
    ]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: vctp))));
    await tester.pump();
    expect(find.text('2 types'), findsOneWidget);
    expect(find.textContaining('dbl'), findsWidgets);
    expect(find.textContaining('boolean'), findsWidgets);
  });

  testWidgets('an ICON block renders a 32x32 legacy-icon preview', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // ICON = 128 B = 32x32 @ 1bpp. A non-trivial pattern so it's a real bitmap.
    final bytes = List<int>.generate(128, (i) => i.isEven ? 0xA5 : 0x5A);
    final icon = _raw('ICON', bytes);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: icon))));
    await tester.pump();
    expect(find.textContaining('32×32 @ 1bpp'), findsOneWidget);
    // the preview CustomPaint is present (there may be others, e.g. the hex dump).
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('copy menu puts the block bytes on the clipboard as hex', (tester) async {
    final log = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') log.add(call);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    final bdpw = DecodedSection(
      section: ViSection(tag: 'BDPW', index: 0, dataOffset: 0, bytes: Uint8List.fromList([0xd4, 0x1d, 0x8c, 0xd9])),
      bytes: Uint8List.fromList([0xd4, 0x1d, 0x8c, 0xd9]),
      wasCompressed: false,
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BlockHexView(section: bdpw))));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.copy));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy BDPW as hex'));
    await tester.pump();

    expect(log, hasLength(1));
    expect((log.single.arguments as Map)['text'], 'd41d8cd9');
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
