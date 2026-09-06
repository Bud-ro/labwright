import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/hex_view.dart';

import 'util.dart';

DecodedSection raw(String tag, List<int> bytes) => DecodedSection(
  section: ViSection(
    tag: tag,
    index: 0,
    dataOffset: 0,
    bytes: Uint8List.fromList(bytes),
  ),
  bytes: Uint8List.fromList(bytes),
  wasCompressed: false,
);

class HexCase {
  const HexCase(
    this.name,
    this.sec, {
    this.one = const [],
    this.some = const [],
    this.never = const [],
    this.exact = const [],
    this.taps = const [],
  });
  final String name;
  final DecodedSection sec;
  final List<String> one, some, never, exact;
  final List<(String, String, bool)> taps;
}

void main() {
  final versBytes = [0x08, 0x50, 0x80, 0x02, 0x03, ...'8.5'.codeUnits];
  final nuidBytes = [0, 0, 0, 2, 0, 0, 0, 0x11, 0, 0, 0, 0x22];
  final cpsBytes = [
    0,
    0,
    0,
    2,
    4,
    ...'True'.codeUnits,
    5,
    ...'False'.codeUnits,
  ];

  final cases = <HexCase>[
    HexCase(
      'heap records get names and typed displays',
      heapSection([
        ...open(0x50, 1),
        ...bounds(10, 20, 30, 40),
        ...caption('Hi'),
        0x84,
        0x28,
        0xff,
        0x12,
        0x34,
        0x56,
        ...close(),
      ], compressed: true),
      one: ['Numeric control', 'backgroundColor'],
      some: ['bounds'],
      taps: [('caption', 'Hi', true)],
    ),
    HexCase(
      'the heap content-length header is labeled (no unexplained lead)',
      heapSection([0x08, 0x19], compressed: true),
      one: ['Heap content length'],
      exact: ['2 B'],
      taps: [('Heap content length', '= 2 bytes', false)],
    ),
    HexCase(
      'an unframed tail is accounted when the walk stops (no silent bytes)',
      heapSection([0x08, 0x19, 0x9f, 0x27], compressed: true),
      one: ['Unframed tail'],
      some: ['2 B'],
      taps: [('Unframed tail', 'not yet decoded', false)],
    ),
    HexCase(
      'the group close tag shows in the title',
      heapSection([0x08, 0x2a], compressed: true),
      one: ['Group close · tag 0x2a'],
      taps: [('Group close · tag 0x2a', 'same tag', false)],
    ),
    HexCase(
      'newest decoded forms: prop item name, const value, control min',
      heapSection([
        ...open(0x50, 1),
        0xc6,
        0x31,
        0x05,
        ...'Scale'.codeUnits,
        0xc6,
        0x6c,
        0xff,
        0x00,
        0x0a,
        0x00,
        0x00,
        0x00,
        0x06,
        ...'Robot!'.codeUnits,
        0xc6,
        0x20,
        0x08,
        0xbf,
        0xf0,
        0,
        0,
        0,
        0,
        0,
        0,
        ...close(),
      ], compressed: true),
      one: ['propItemName'],
      taps: [
        ('propItemName', 'Scale', true),
        ('constValue', 'Robot!', true),
        ('stdNumMin', 'Numeric-control parameter', false),
      ],
    ),
    HexCase(
      'an undecoded non-heap block shows raw hex + catalog identity',
      raw('TRec', List.filled(40, 0x41)),
      one: ['raw hex'],
    ),
    HexCase(
      'a vers block frames the version word, reports a partial %',
      raw('vers', versBytes),
      one: ['Version word', '% framed'],
      some: ['8.5', 'Undecoded'],
      never: ['100% framed'],
    ),
    HexCase(
      'an LVSR block frames every byte (version/config/per-VI/hashes)',
      raw(
        'LVSR',
        [for (var i = 0; i < 160; i++) 0]
          ..[0] = 0x08
          ..[1] = 0x50
          ..[2] = 0x80,
      ),
      one: [
        'Version word',
        'Per-VI value A',
        'Per-VI value B',
        'Per-VI value C',
        'BD password hash',
        'Secondary hash',
        '100% framed',
      ],
      some: ['Config/flags word'],
      never: ['Undecoded'],
    ),
    HexCase(
      'a NUID id table frames count + every entry (100%)',
      raw('NUID', nuidBytes),
      one: ['Entry count', 'id[0]', 'id[1]', '100% framed'],
      never: ['Undecoded'],
    ),
    HexCase(
      'an FPSE section marker is framed as a u32 (100%)',
      raw('FPSE', [0, 0, 0, 0x77]),
      one: ['FPSE marker', '100% framed'],
      never: ['Undecoded'],
    ),
    HexCase(
      'a BDSE section marker is framed as a u32 (100%)',
      raw('BDSE', [0, 0, 0, 0x2c]),
      one: ['BDSE marker', '100% framed'],
      never: ['Undecoded'],
    ),
    HexCase(
      'a MUID block is framed as a single u32 (100%)',
      raw('MUID', [0, 0, 0x0b, 0x6c]),
      one: ['MUID (u32)', '100% framed'],
    ),
    HexCase(
      'a TITL block is a Pascal string (len + ASCII title, 100%)',
      raw('TITL', [11, ...'Batch Tests'.codeUnits]),
      one: ['Title length', 'Title (ASCII)', '100% framed'],
      some: ['Batch Tests'],
      never: ['Undecoded'],
    ),
    HexCase(
      'FTAB per-font metric records are framed (12B metric + u32 gaps)',
      raw('FTAB', [
        0,
        1,
        0,
        2,
        0,
        3,
        0,
        2,
        0,
        0,
        0,
        40,
        ...List.filled(12, 0x0f),
        0,
        0,
        0,
        5,
        ...List.filled(12, 0x0f),
        3,
        ...'Foo'.codeUnits,
      ]),
      one: [
        'Header constant',
        'Font[0] metric record',
        'Font[1] metric record',
        'Font[0] u32 field',
        'Font names',
        '100% framed',
      ],
      never: ['Undecoded'],
    ),
    HexCase(
      'a CPSP string-label table is framed (count + Pascal entries, 100%)',
      raw('CPSP', cpsBytes),
      one: ['String count', '100% framed'],
      some: ['entry[0]', 'True', 'False'],
      never: ['Undecoded'],
    ),
    HexCase(
      'a CPST string-label table is framed the same way',
      raw('CPST', cpsBytes),
      one: ['String count', '100% framed'],
      some: ['entry[0]', 'True', 'False'],
      never: ['Undecoded'],
    ),
    HexCase(
      'an FPTD block is framed as a u16 type index (100%)',
      raw('FPTD', [0x01, 0x52]),
      one: ['Type index (u16)', '100% framed'],
    ),
    HexCase(
      'a decoded HLPP block shows its recovered help path',
      raw('HLPP', [
        ...'PTH0'.codeUnits,
        0,
        0,
        0,
        0x0c,
        0,
        0,
        0,
        1,
        3,
        ...'doc'.codeUnits,
      ]),
      exact: ['doc'],
    ),
    HexCase(
      'a VCTP block lists the recovered type pool',
      raw('VCTP', [0, 0, 0, 2, 0, 4, 0, 0x0a, 0, 4, 0, 0x21]),
      exact: ['2 types'],
      some: ['dbl', 'boolean'],
    ),
  ];

  for (final c in cases) {
    testWidgets('hex view: ${c.name}', (tester) async {
      await pumpBody(
        tester,
        BlockHexView(section: c.sec),
        view: const Size(1400, 2000),
      );
      for (final t in c.one) {
        expect(find.textContaining(t), findsOneWidget, reason: t);
      }
      for (final t in c.some) {
        expect(find.textContaining(t), findsWidgets, reason: t);
      }
      for (final t in c.never) {
        expect(find.textContaining(t), findsNothing, reason: t);
      }
      for (final t in c.exact) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      for (final (tap, then, isExact) in c.taps) {
        await tester.tap(find.textContaining(tap).first);
        await tester.pump();
        expect(
          isExact ? find.text(then) : find.textContaining(then),
          findsOneWidget,
          reason: '$tap → $then',
        );
      }
    });
  }

  testWidgets('an ICON block renders a 32x32 legacy-icon preview', (
    tester,
  ) async {
    final icon = raw('ICON', List.generate(128, (i) => i.isEven ? 0xA5 : 0x5A));
    await pumpBody(
      tester,
      BlockHexView(section: icon),
      view: const Size(1000, 1400),
    );
    expect(find.textContaining('32×32 @ 1bpp'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('a CONP block resolves its index against the sibling VCTP pool', (
    tester,
  ) async {
    final vctp = raw('VCTP', [0, 0, 0, 1, 0, 4, 0, 0x21]);
    final conp = raw('CONP', [0, 1]);
    await pumpBody(
      tester,
      BlockHexView(section: conp, siblings: [vctp]),
      view: const Size(1000, 1400),
    );
    expect(find.textContaining('VCTP type index'), findsOneWidget);
    expect(find.textContaining('boolean'), findsWidgets);
  });

  testWidgets(
    'a compressed NON-heap block (VCTP) is not mis-walked as a heap',
    (tester) async {
      final body = Uint8List.fromList([0, 0, 0, 0xee, 0xc4, 1, 2, 3, 4, 5]);
      final vctp = DecodedSection(
        section: ViSection(tag: 'VCTP', index: 0, dataOffset: 0, bytes: body),
        bytes: body,
        wasCompressed: true,
      );
      await pumpBody(tester, BlockHexView(section: vctp));
      expect(find.textContaining('Heap content length'), findsNothing);
      expect(find.textContaining('Unframed tail'), findsNothing);
      expect(find.textContaining('VI type pool'), findsOneWidget);
    },
  );

  testWidgets('copy menu puts the block bytes on the clipboard as hex', (
    tester,
  ) async {
    final log = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') log.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpBody(
      tester,
      BlockHexView(section: raw('BDPW', [0xd4, 0x1d, 0x8c, 0xd9])),
    );
    await tester.tap(find.byIcon(Icons.copy));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy BDPW as hex'));
    await tester.pump();
    expect(log, hasLength(1));
    expect((log.single.arguments as Map)['text'], 'd41d8cd9');
  });
}
