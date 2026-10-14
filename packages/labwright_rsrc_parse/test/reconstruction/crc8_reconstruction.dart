import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// The CRC-8 snippet of the corpus, placed and wired from the editing API: a byte-reversal
/// table, a lookup table built bit by bit, then the running CRC over the input bytes.
ViModel buildCrc8() {
  final vi = ViModel.empty(name: 'crc8.vi');
  final bd = vi.blockDiagram;
  final d = bd.diagram;

  final reflectInput = bd.control(BdType.boolean, 'Reflect Input? (F)');
  final poly = bd.control(BdType.u8, 'Poly (0x07)');
  final dataIn = bd.control(BdType.string, 'Data in');
  final init = bd.control(BdType.u8, 'Init (0x00)');
  final reflectOutput = bd.control(BdType.boolean, 'Reflect Output? (F)');
  final crcOut = bd.indicator(BdType.u8, 'CRC-8');
  final xorOut = bd.control(BdType.u8, 'Xor Out (0x00)');
  final bytes = d.add(BdConstant.create(bd, BdType.i32, 256, label: 'bytes'));
  final lut = d.add(
    BdConstant.create(bd, BdType.u8Array, [
      for (var i = 0; i < 256; i++) _reverseBits(i),
    ], label: 'U8 Bits Reversed LUT'),
  );
  final zeros = d.add(BdConstant.create(bd, BdType.u8Array, List.filled(256, 0)));

  final xor = d.add(BdPrimitive.create(bd, PrimOp.exclusiveOr));
  final toBytes = d.add(BdPrimitive.create(bd, PrimOp.stringToByteArray));

  final tableLoop = d.add(BdLoop.create(bd));
  final polyIn = tableLoop.tunnel(BdType.u8, output: false);
  final table = tableLoop.shiftRegister(BdType.u8Array);
  final replace = tableLoop.body.add(BdReplaceArraySubset.create(bd));
  final toU8 = tableLoop.body.add(BdPrimitive.create(bd, PrimOp.toUnsignedByteInteger));
  final bitLoop = tableLoop.body.add(BdLoop.create(bd));
  final eight = tableLoop.body.add(BdConstant.create(bd, BdType.i32, 8, label: '8-bits'));
  final crc = bitLoop.shiftRegister(BdType.u8);
  final polyInner = bitLoop.tunnel(BdType.u8, output: false);
  final bitCase = bitLoop.body.add(BdCase.create(bd));
  final rotate = bitLoop.body.add(BdPrimitive.create(bd, PrimOp.rotateLeftWithCarry));
  final carry = bitLoop.body.add(BdConstant.create(bd, BdType.boolean, false, label: 'carry'));
  final rotated = bitCase.tunnel(BdType.u8, output: false);
  final polyCase = bitCase.tunnel(BdType.u8, output: false);
  final bitOut = bitCase.tunnel(BdType.u8, output: true);
  final bitXor = bitCase.frames[1].add(BdPrimitive.create(bd, PrimOp.exclusiveOr));
  bd.connect(rotated.inner(bitCase.frames[0]), bitOut.inner(bitCase.frames[0]));
  bd.connect(bitXor.terminal('x .xor. y?'), bitOut.inner(bitCase.frames[1]));
  bd.connect(rotated.inner(bitCase.frames[1]), bitXor.terminal('x'));
  bd.connect(polyCase.inner(bitCase.frames[1]), bitXor.terminal('y'));
  bd.connect(bitOut.outer!, crc.right.innerPort);
  bd.connect(rotate.output('value'), rotated.outer!);
  bd.connect(rotate.terminal('msb carry out'), bitCase.selector.outer!);
  bd.connect(carry.out, rotate.terminal('carry'));
  bd.connect(crc.left.innerPort, rotate.input('value'));
  bd.connect(polyInner.innerPort, polyCase.outer!);
  bd.connect(replace.terminal('output array'), table.right.innerPort);
  bd.connect(toU8.terminal('unsigned 8bit integer'), crc.left.outer!);
  bd.connect(crc.right.outer!, replace.terminal('new element'));
  bd.connect(eight.out, bitLoop.count!.outer!);
  bd.connect(polyIn.innerPort, polyInner.outer!);
  bd.connect(table.left.innerPort, replace.terminal('array'));
  bd.connect(tableLoop.iteration.innerPort, toU8.terminal('number'));
  bd.connect(tableLoop.iteration.innerPort, replace.terminal('index'));

  final disable = d.add(BdDisable.create(bd));
  final reverseLoop = disable.disabled.add(BdLoop.create(bd));
  final reversed = reverseLoop.tunnel(BdType.u8Array, output: true, indexing: true);
  final count = disable.disabled.add(BdConstant.create(bd, BdType.i32, 256));
  final toU8a = reverseLoop.body.add(BdPrimitive.create(bd, PrimOp.toUnsignedByteInteger));
  final toNumber = reverseLoop.body.add(BdPrimitive.create(bd, PrimOp.booleanArrayToNumber));
  final reverse = reverseLoop.body.add(BdPrimitive.create(bd, PrimOp.reverse1dArray));
  final toBits = reverseLoop.body.add(BdPrimitive.create(bd, PrimOp.numberToBooleanArray));
  final toU8b = reverseLoop.body.add(BdPrimitive.create(bd, PrimOp.toUnsignedByteInteger));
  bd.connect(toU8a.terminal('unsigned 8bit integer'), reversed.innerPort);
  bd.connect(toNumber.terminal('number'), toU8a.terminal('number'));
  bd.connect(reverse.terminal('reversed array'), toNumber.terminal('Boolean array'));
  bd.connect(toBits.terminal('Boolean array'), reverse.terminal('array'));
  bd.connect(toU8b.terminal('unsigned 8bit integer'), toBits.terminal('number'));
  bd.connect(reverseLoop.iteration.innerPort, toU8b.terminal('number'));
  bd.connect(count.out, reverseLoop.count!.outer!);

  final byteLoop = d.add(BdLoop.create(bd));
  final running = byteLoop.shiftRegister(BdType.u8);
  final input = byteLoop.tunnel(BdType.u8Array, output: false, indexing: true);
  final tableIn = byteLoop.tunnel(BdType.u8Array, output: false);
  final reflectIn = byteLoop.tunnel(BdType.boolean, output: false);
  final lutIn = byteLoop.tunnel(BdType.u8Array, output: false);
  final reflectCase = byteLoop.body.add(BdCase.create(bd));
  final toI32 = byteLoop.body.add(BdPrimitive.create(bd, PrimOp.toLongInteger));
  final index = byteLoop.body.add(BdIndexArray.create(bd));
  final mix = byteLoop.body.add(BdPrimitive.create(bd, PrimOp.exclusiveOr));
  final byteIn = reflectCase.tunnel(BdType.u8, output: false);
  final lutCase = reflectCase.tunnel(BdType.u8Array, output: false);
  final byteOut = reflectCase.tunnel(BdType.u8, output: true);
  final toI32r = reflectCase.frames[1].add(BdPrimitive.create(bd, PrimOp.toLongInteger));
  final lookup = reflectCase.frames[1].add(BdIndexArray.create(bd));
  bd.connect(byteIn.inner(reflectCase.frames[0]), byteOut.inner(reflectCase.frames[0]));
  bd.connect(toI32r.terminal('32bit integer'), lookup.terminal('index'));
  bd.connect(lookup.terminal('element'), byteOut.inner(reflectCase.frames[1]));
  bd.connect(byteIn.inner(reflectCase.frames[1]), toI32r.terminal('number'));
  bd.connect(lutCase.inner(reflectCase.frames[1]), lookup.terminal('array'));
  bd.connect(byteOut.outer!, mix.terminal('x'));
  bd.connect(toI32.terminal('32bit integer'), index.terminal('index'));
  bd.connect(index.terminal('element'), running.right.innerPort);
  bd.connect(mix.terminal('x .xor. y?'), toI32.terminal('number'), type: BdType.u8);
  bd.connect(running.left.innerPort, mix.terminal('y'));
  bd.connect(input.innerPort, byteIn.outer!);
  bd.connect(tableIn.innerPort, index.terminal('array'));
  bd.connect(reflectIn.innerPort, reflectCase.selector.outer!);
  bd.connect(lutIn.innerPort, lutCase.outer!);

  final outCase = d.add(BdCase.create(bd));
  final crcIn = outCase.tunnel(BdType.u8, output: false);
  final crcOutT = outCase.tunnel(BdType.u8, output: true);
  final lutOut = outCase.tunnel(BdType.u8Array, output: false);
  final toI32o = outCase.frames[1].add(BdPrimitive.create(bd, PrimOp.toLongInteger));
  final lookupOut = outCase.frames[1].add(BdIndexArray.create(bd));
  bd.connect(crcIn.inner(outCase.frames[0]), crcOutT.inner(outCase.frames[0]));
  bd.connect(toI32o.terminal('32bit integer'), lookupOut.terminal('index'));
  bd.connect(lookupOut.terminal('element'), crcOutT.inner(outCase.frames[1]));
  bd.connect(crcIn.inner(outCase.frames[1]), toI32o.terminal('number'));
  bd.connect(lutOut.inner(outCase.frames[1]), lookupOut.terminal('array'));

  bd.connect(xor.terminal('x .xor. y?'), crcIn.outer!, type: BdType.u8);
  bd.connect(toBytes.terminal('unsigned byte array'), input.outer!);
  bd.connect(reflectOutput.terminal, outCase.selector.outer!);
  bd.connect(xorOut.terminal, xor.terminal('y'));
  bd.connect(bytes.out, tableLoop.count!.outer!);
  bd.connect(lut.out, lutOut.outer!);
  bd.connect(lut.out, lutIn.outer!);
  bd.connect(zeros.out, table.left.outer!);
  bd.connect(table.right.outer!, tableIn.outer!);
  bd.connect(running.right.outer!, xor.terminal('x'));
  bd.connect(crcOutT.outer!, crcOut.terminal);
  bd.connect(reflectInput.terminal, reflectIn.outer!);
  bd.connect(poly.terminal, polyIn.outer!);
  bd.connect(dataIn.terminal, toBytes.terminal('string'));
  bd.connect(init.terminal, running.left.outer!);

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
