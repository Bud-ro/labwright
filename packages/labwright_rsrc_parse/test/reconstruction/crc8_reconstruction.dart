import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// The CRC-8 snippet of the corpus, placed and wired from the editing API: a byte-reversal
/// table, a lookup table built bit by bit, then the running CRC over the input bytes.
ViModel buildCrc8() {
  final vi = ViModel.empty(name: 'crc8.vi');
  final bd = vi.blockDiagram;
  final d = bd.diagram;

  final reflectInput = bd.control(
    BdType.boolean,
    'Reflect Input? (F)',
    at: (x: 118, y: 289),
    labelAt: const HeapRect(top: 0, left: -92, bottom: 17, right: 0),
  );
  final poly = bd.control(
    BdType.u8,
    'Poly (0x07)',
    at: (x: 118, y: 495),
    labelAt: const HeapRect(top: 0, left: -61, bottom: 17, right: 0),
  );
  final dataIn = bd.control(
    BdType.string,
    'Data in',
    at: (x: 118, y: 272),
    labelAt: const HeapRect(top: 0, left: -40, bottom: 17, right: 0),
  );
  final init = bd.control(
    BdType.u8,
    'Init (0x00)',
    at: (x: 118, y: 306),
    labelAt: const HeapRect(top: 0, left: -55, bottom: 17, right: 0),
  );
  final reflectOutput = bd.control(
    BdType.boolean,
    'Reflect Output? (F)',
    at: (x: 118, y: 356),
    labelAt: const HeapRect(top: 0, left: -102, bottom: 17, right: 0),
  );
  final crcOut = bd.indicator(
    BdType.u8,
    'CRC-8',
    at: (x: 963, y: 310),
    labelAt: const HeapRect(top: 0, left: 32, bottom: 17, right: 69),
  );
  final xorOut = bd.control(
    BdType.u8,
    'Xor Out (0x00)',
    at: (x: 118, y: 339),
    labelAt: const HeapRect(top: 0, left: -79, bottom: 17, right: 0),
  );
  final bytes = d.add(
    BdConstant.create(
      bd,
      BdType.i32,
      256,
      label: 'bytes',
      at: const HeapRect(top: 374, left: 94, bottom: 393, right: 150),
      labelAt: const HeapRect(top: 1, left: 0, bottom: 18, right: 31),
      showLabel: true,
      boxAt: const HeapRect(top: 0, left: 31, bottom: 19, right: 56),
    ),
  );
  final lut = d.add(
    BdConstant.create(
      bd,
      BdType.u8Array,
      [for (var i = 0; i < 256; i++) _reverseBits(i)],
      label: 'U8 Bits Reversed LUT',
      at: const HeapRect(top: 148, left: 429, bottom: 191, right: 541),
      labelAt: const HeapRect(top: 0, left: 0, bottom: 17, right: 112),
      showLabel: true,
      array: const BdArrayView(
        index: HeapRect(top: 20, left: 3, bottom: 37, right: 35),
        element: HeapRect(top: 21, left: 39, bottom: 40, right: 70),
        firstIndex: 255,
      ),
    ),
  );
  final zeros = d.add(
    BdConstant.create(
      bd,
      BdType.u8Array,
      List.filled(256, 0),
      at: const HeapRect(top: 397, left: 75, bottom: 422, right: 149),
      array: const BdArrayView(
        index: HeapRect(top: 2, left: 2, bottom: 19, right: 36),
        element: HeapRect(top: 3, left: 41, bottom: 22, right: 71),
        firstIndex: 255,
        format: '%02x',
        showRadix: true,
        elementLabel: true,
      ),
    ),
  );

  final xor = d.add(
    BdPrimitive.create(bd, PrimOp.exclusiveOr, at: const HeapRect(top: 302, left: 821, bottom: 334, right: 853)),
  );
  d.add(
    BdText.create(
      bd,
      'Embed the CRC-8 LUT if the\nPolynomial is a constant',
      at: const HeapRect(top: 424, left: 503, bottom: 456, right: 655),
    ),
  );
  final toBytes = d.add(
    BdPrimitive.create(bd, PrimOp.stringToByteArray, at: const HeapRect(top: 264, left: 465, bottom: 296, right: 497)),
  );

  final tableLoop = d.add(BdLoop.create(bd, at: const HeapRect(top: 375, left: 158, bottom: 543, right: 495)));
  tableLoop.iteration.termBounds = const HeapRect(top: 38, left: 23, bottom: 54, right: 39);
  final polyIn = tableLoop.tunnel(BdType.u8, output: false, top: 124);
  final table = tableLoop.shiftRegister(BdType.u8Array, top: 28);
  tableLoop.body.add(
    BdText.create(bd, 'Create CRC-8 LUT', at: const HeapRect(top: 7, left: 24, bottom: 24, right: 123)),
  );
  final replace = tableLoop.body.add(
    BdReplaceArraySubset.create(bd, at: const HeapRect(top: 26, left: 283, bottom: 59, right: 315)),
  );
  final toU8 = tableLoop.body.add(
    BdPrimitive.create(bd, PrimOp.toUnsignedByteInteger, at: const HeapRect(top: 96, left: 45, bottom: 128, right: 77)),
  );
  final bitLoop = tableLoop.body.add(
    BdLoop.create(bd, at: const HeapRect(top: 58, left: 105, bottom: 154, right: 272)),
  );
  final eight = tableLoop.body.add(
    BdConstant.create(
      bd,
      BdType.i32,
      8,
      label: '8-bits',
      at: const HeapRect(top: 57, left: 51, bottom: 76, right: 97),
      labelAt: const HeapRect(top: 1, left: 0, bottom: 18, right: 33),
      showLabel: true,
      boxAt: const HeapRect(top: 0, left: 33, bottom: 19, right: 46),
    ),
  );
  bitLoop.iteration.hideGlyph();
  tableLoop.body.add(BdText.subdiagramLabel(bd, null, at: const HeapRect(top: 1, left: 1, bottom: 18, right: 332)));
  final crc = bitLoop.shiftRegister(BdType.u8, top: 48);
  final polyInner = bitLoop.tunnel(BdType.u8, output: false, top: 66);
  final bitCase = bitLoop.body.add(
    BdCase.create(
      bd,
      at: const HeapRect(top: 25, left: 78, bottom: 79, right: 144),
      label: 'XOR?',
      labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 31),
    ),
  );
  bitCase.selector.termBounds = const HeapRect(top: 15, left: 0, bottom: 27, right: 8);
  final rotate = bitLoop.body.add(
    BdPrimitive.create(bd, PrimOp.rotateLeftWithCarry, at: const HeapRect(top: 34, left: 39, bottom: 66, right: 71)),
  );
  final carry = bitLoop.body.add(
    BdConstant.create(
      bd,
      BdType.boolean,
      false,
      label: 'carry',
      at: const HeapRect(top: 39, left: 21, bottom: 53, right: 37),
      labelAt: const HeapRect(top: -1, left: -30, bottom: 16, right: -1),
    ),
  );
  final rotated = bitCase.tunnel(BdType.u8, output: false, top: 25);
  final polyCase = bitCase.tunnel(BdType.u8, output: false, top: 33);
  final bitOut = bitCase.tunnel(BdType.u8, output: true, top: 25);
  final bitXor = bitCase.frames[1].add(
    BdPrimitive.create(bd, PrimOp.exclusiveOr, at: const HeapRect(top: 17, left: 12, bottom: 49, right: 44)),
  );
  bd.connect(rotated.inner(bitCase.frames[0]), bitOut.inner(bitCase.frames[0]));
  bd.connect(bitXor.terminal('x .xor. y?'), bitOut.inner(bitCase.frames[1]), bendX: 40);
  bd.connect(rotated.inner(bitCase.frames[1]), bitXor.terminal('x'));
  bd.connect(polyCase.inner(bitCase.frames[1]), bitXor.terminal('y'));
  bd.connect(bitOut.outer!, crc.right.innerPort);
  bd.connect(rotate.output('value'), rotated.outer!);
  bd.connect(rotate.terminal('msb carry out'), bitCase.selector.outer!);
  bd.connect(carry.out, rotate.terminal('carry'));
  bd.connect(crc.left.innerPort, rotate.input('value'));
  bd.connect(polyInner.innerPort, polyCase.outer!, bendX: 64);
  bd.connect(replace.terminal('output array'), table.right.innerPort);
  bd.connect(toU8.terminal('unsigned 8bit integer'), crc.left.outer!);
  bd.connect(crc.right.outer!, replace.terminal('new element'), bendX: 281);
  bd.connect(eight.out, bitLoop.count!.outer!);
  bd.connect(polyIn.innerPort, polyInner.outer!);
  bd.connect(table.left.innerPort, replace.terminal('array'));
  bd.connect(tableLoop.iteration.innerPort, toU8.terminal('number'));
  bd.connect(tableLoop.iteration.innerPort, replace.terminal('index'), bendX: 44);

  final disable = d.add(BdDisable.create(bd, at: const HeapRect(top: 163, left: 184, bottom: 256, right: 423)));
  final reverseLoop = disable.disabled.add(
    BdLoop.create(bd, at: const HeapRect(top: 18, left: 38, bottom: 84, right: 230)),
  );
  reverseLoop.count!.termBounds = const HeapRect(top: 17, left: 0, bottom: 33, right: 16);
  reverseLoop.iteration.termBounds = const HeapRect(top: 35, left: 10, bottom: 51, right: 26);
  final reversed = reverseLoop.tunnel(BdType.u8Array, output: true, indexing: true, top: 39);
  final count = disable.disabled.add(
    BdConstant.create(
      bd,
      BdType.i32,
      256,
      at: const HeapRect(top: 34, left: 5, bottom: 53, right: 30),
      labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 9),
    ),
  );
  final toU8a = reverseLoop.body.add(
    BdPrimitive.create(
      bd,
      PrimOp.toUnsignedByteInteger,
      at: const HeapRect(top: 27, left: 148, bottom: 59, right: 180),
    ),
  );
  final toNumber = reverseLoop.body.add(
    BdPrimitive.create(bd, PrimOp.booleanArrayToNumber, at: const HeapRect(top: 27, left: 120, bottom: 59, right: 152)),
  );
  final reverse = reverseLoop.body.add(
    BdPrimitive.create(bd, PrimOp.reverse1dArray, at: const HeapRect(top: 27, left: 88, bottom: 59, right: 120)),
  );
  final toBits = reverseLoop.body.add(
    BdPrimitive.create(bd, PrimOp.numberToBooleanArray, at: const HeapRect(top: 27, left: 55, bottom: 59, right: 87)),
  );
  final toU8b = reverseLoop.body.add(
    BdPrimitive.create(bd, PrimOp.toUnsignedByteInteger, at: const HeapRect(top: 27, left: 26, bottom: 59, right: 58)),
  );
  reverseLoop.body.add(
    BdText.subdiagramLabel(
      bd,
      'Create U8 Bits Reversed LUT',
      at: const HeapRect(top: 1, left: 1, bottom: 18, right: 187),
    ),
  );
  bd.connect(toU8a.terminal('unsigned 8bit integer'), reversed.innerPort);
  bd.connect(toNumber.terminal('number'), toU8a.terminal('number'));
  bd.connect(reverse.terminal('reversed array'), toNumber.terminal('Boolean array'));
  bd.connect(toBits.terminal('Boolean array'), reverse.terminal('array'));
  bd.connect(toU8b.terminal('unsigned 8bit integer'), toBits.terminal('number'));
  bd.connect(reverseLoop.iteration.innerPort, toU8b.terminal('number'));
  bd.connect(count.out, reverseLoop.count!.outer!);

  final byteLoop = d.add(BdLoop.create(bd, at: const HeapRect(top: 186, left: 520, bottom: 339, right: 813)));
  byteLoop.iteration.hideGlyph();
  final running = byteLoop.shiftRegister(BdType.u8, top: 122);
  final input = byteLoop.tunnel(BdType.u8Array, output: false, indexing: true, top: 90);
  final tableIn = byteLoop.tunnel(BdType.u8Array, output: false, top: 27);
  final reflectIn = byteLoop.tunnel(BdType.boolean, output: false, top: 107);
  final lutIn = byteLoop.tunnel(BdType.u8Array, output: false, top: 77);
  byteLoop.body.add(
    BdText.create(
      bd,
      'Uses Look Up Tables (LUTs)\nfor better performance on\nlarge data sets.',
      at: const HeapRect(top: 49, left: 130, bottom: 96, right: 278),
    ),
  );
  byteLoop.body.add(BdText.create(bd, 'Calculate CRC-8', at: const HeapRect(top: 7, left: 23, bottom: 24, right: 114)));
  final reflectCase = byteLoop.body.add(
    BdCase.create(
      bd,
      at: const HeapRect(top: 51, left: 22, bottom: 124, right: 111),
      label: 'Reflect Input?',
      labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 75),
    ),
  );
  reflectCase.selector.termBounds = const HeapRect(top: 54, left: 0, bottom: 66, right: 8);
  final toI32 = byteLoop.body.add(
    BdPrimitive.create(bd, PrimOp.toLongInteger, at: const HeapRect(top: 108, left: 169, bottom: 140, right: 201)),
  );
  final index = byteLoop.body.add(
    BdIndexArray.create(bd, at: const HeapRect(top: 102, left: 205, bottom: 129, right: 237)),
  );
  final mix = byteLoop.body.add(
    BdPrimitive.create(bd, PrimOp.exclusiveOr, at: const HeapRect(top: 108, left: 141, bottom: 140, right: 173)),
  );
  byteLoop.body.add(BdText.subdiagramLabel(bd, null, at: const HeapRect(top: 1, left: 1, bottom: 18, right: 288)));
  final byteIn = reflectCase.tunnel(BdType.u8, output: false, top: 39);
  final lutCase = reflectCase.tunnel(BdType.u8Array, output: false, top: 26);
  final byteOut = reflectCase.tunnel(BdType.u8, output: true, top: 39);
  final toI32r = reflectCase.frames[1].add(
    BdPrimitive.create(bd, PrimOp.toLongInteger, at: const HeapRect(top: 27, left: 10, bottom: 59, right: 42)),
  );
  final lookup = reflectCase.frames[1].add(
    BdIndexArray.create(bd, at: const HeapRect(top: 21, left: 43, bottom: 48, right: 75)),
  );
  bd.connect(byteIn.inner(reflectCase.frames[0]), byteOut.inner(reflectCase.frames[0]));
  bd.connect(toI32r.terminal('32bit integer'), lookup.terminal('index'));
  bd.connect(lookup.terminal('element'), byteOut.inner(reflectCase.frames[1]));
  bd.connect(byteIn.inner(reflectCase.frames[1]), toI32r.terminal('number'));
  bd.connect(lutCase.inner(reflectCase.frames[1]), lookup.terminal('array'));
  bd.connect(byteOut.outer!, mix.terminal('x'), bendX: 117);
  bd.connect(toI32.terminal('32bit integer'), index.terminal('index'));
  bd.connect(index.terminal('element'), running.right.innerPort, bendX: 242);
  bd.connect(mix.terminal('x .xor. y?'), toI32.terminal('number'), type: BdType.u8);
  bd.connect(running.left.innerPort, mix.terminal('y'));
  bd.connect(input.innerPort, byteIn.outer!);
  bd.connect(tableIn.innerPort, index.terminal('array'), bendX: 124);
  bd.connect(reflectIn.innerPort, reflectCase.selector.outer!);
  bd.connect(lutIn.innerPort, lutCase.outer!);

  final outCase = d.add(
    BdCase.create(
      bd,
      at: const HeapRect(top: 250, left: 857, bottom: 345, right: 957),
      label: 'Reflect Output?',
      labelAt: const HeapRect(top: -17, left: 0, bottom: 0, right: 85),
    ),
  );
  outCase.selector.termBounds = const HeapRect(top: 75, left: 0, bottom: 87, right: 8);
  outCase.frames[0].add(BdText.subdiagramLabel(bd, null, at: const HeapRect(top: 6, left: 6, bottom: 33, right: 94)));
  final crcIn = outCase.tunnel(BdType.u8, output: false, top: 64);
  final crcOutT = outCase.tunnel(BdType.u8, output: true, top: 64);
  final lutOut = outCase.tunnel(BdType.u8Array, output: false, top: 51);
  outCase.frames[1].add(
    BdText.create(bd, 'Reverse Bits', at: const HeapRect(top: 24, left: 13, bottom: 41, right: 80)),
  );
  final toI32o = outCase.frames[1].add(
    BdPrimitive.create(bd, PrimOp.toLongInteger, at: const HeapRect(top: 52, left: 12, bottom: 84, right: 44)),
  );
  final lookupOut = outCase.frames[1].add(
    BdIndexArray.create(bd, at: const HeapRect(top: 46, left: 47, bottom: 73, right: 79)),
  );
  outCase.frames[1].add(BdText.subdiagramLabel(bd, null, at: const HeapRect(top: 6, left: 6, bottom: 33, right: 94)));
  bd.connect(crcIn.inner(outCase.frames[0]), crcOutT.inner(outCase.frames[0]));
  bd.connect(toI32o.terminal('32bit integer'), lookupOut.terminal('index'));
  bd.connect(lookupOut.terminal('element'), crcOutT.inner(outCase.frames[1]));
  bd.connect(crcIn.inner(outCase.frames[1]), toI32o.terminal('number'));
  bd.connect(lutOut.inner(outCase.frames[1]), lookupOut.terminal('array'));

  bd.connect(lut.out, lutOut.outer!, turnX: 842);
  bd.connect(lut.out, lutIn.outer!, bendX: 512);
  bd.connect(reflectInput.terminal, reflectIn.outer!);
  bd.connect(table.right.outer!, tableIn.outer!, bendX: 507);
  bd.connect(zeros.out, table.left.outer!);
  bd.connect(xor.terminal('x .xor. y?'), crcIn.outer!, type: BdType.u8);
  bd.connect(running.right.outer!, xor.terminal('x'));
  bd.connect(toBytes.terminal('unsigned byte array'), input.outer!);
  bd.connect(bytes.out, tableLoop.count!.outer!);
  bd.connect(dataIn.terminal, toBytes.terminal('string'));
  bd.connect(reflectOutput.terminal, outCase.selector.outer!, bendX: 847);
  bd.connect(xorOut.terminal, xor.terminal('y'), bendX: 822);
  bd.connect(init.terminal, running.left.outer!);
  bd.connect(crcOutT.outer!, crcOut.terminal);
  bd.connect(poly.terminal, polyIn.outer!);

  bd.write();
  return vi;
}

int _reverseBits(int byte) {
  var out = 0;
  for (var bit = 0; bit < 8; bit++) {
    out = (out << 1) | ((byte >> bit) & 1);
  }
  return out;
}
