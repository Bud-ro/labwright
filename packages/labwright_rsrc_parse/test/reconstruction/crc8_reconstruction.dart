import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// The CRC-8 snippet of the corpus, placed and wired from the editing API: a byte-reversal
/// table, a lookup table built bit by bit, then the running CRC over the input bytes.
ViModel buildCrc8() {
  final vi = ViModel.empty(name: 'crc8.vi');
  final reflectInput = vi.control(BdType.boolean, 'Reflect Input? (F)');
  final poly = vi.control(BdType.u8, 'Poly (0x07)');
  final dataIn = vi.control(BdType.string, 'Data in');
  final init = vi.control(BdType.u8, 'Init (0x00)');
  final reflectOutput = vi.control(BdType.boolean, 'Reflect Output? (F)');
  final crcOut = vi.indicator(BdType.u8, 'CRC-8');
  final xorOut = vi.control(BdType.u8, 'Xor Out (0x00)');

  final bytes = vi.add(BdConstant.i32(256, label: 'bytes'));
  final lut = vi.add(
    BdConstant.array(BdType.u8, [
      for (var i = 0; i < 256; i++) _reverseBits(i),
    ], label: 'U8 Bits Reversed LUT'),
  );
  final zeros = vi.add(BdConstant.array(BdType.u8, List.filled(256, 0)));
  final xor = vi.add(BdPrimitive(PrimOp.exclusiveOr));
  final toBytes = vi.add(BdPrimitive(PrimOp.stringToByteArray));

  final tableLoop = vi.add(BdLoop.forLoop());
  final table = tableLoop.shiftRegister(BdType.u8.array);
  final replace = tableLoop.add(BdReplaceArraySubset());
  final toU8 = tableLoop.add(BdPrimitive(PrimOp.toUnsignedByteInteger));
  final bitLoop = tableLoop.add(BdLoop.forLoop());
  final eight = tableLoop.add(BdConstant.i32(8, label: '8-bits'));
  final crc = bitLoop.shiftRegister(BdType.u8);
  final bitCase = bitLoop.add(BdCase());
  final rotate = bitLoop.add(BdPrimitive(PrimOp.rotateLeftWithCarry));
  final carry = bitLoop.add(BdConstant.boolean(false, label: 'carry'));
  final rotated = bitCase.tunnel(BdType.u8, direction: BdTunnelDirection.input);
  final bitXor = bitCase.whenTrue.add(BdPrimitive(PrimOp.exclusiveOr));
  vi.connect([rotate.output('value'), rotated]);
  vi.connect([poly, bitXor.terminal('y')]);
  final bitOut = bitCase.tunnel(BdType.u8, direction: BdTunnelDirection.output);
  vi.connect([rotated.inner(bitCase.whenFalse), bitOut.inner(bitCase.whenFalse)]);
  vi.connect([rotated.inner(bitCase.whenTrue), bitXor.terminal('x')]);
  vi.connect([bitXor.terminal('x .xor. y?'), bitOut.inner(bitCase.whenTrue)]);
  vi.connect([bitOut, crc.right]);
  vi.connect([rotate.terminal('msb carry out'), bitCase.selector]);
  vi.connect([carry, rotate.terminal('carry')]);
  vi.connect([crc.left, rotate.input('value')]);
  vi.connect([replace.terminal('output array'), table.right]);
  vi.connect([toU8.terminal('unsigned 8bit integer'), crc.left]);
  vi.connect([crc.right, replace.terminal('new element')]);
  vi.connect([eight, bitLoop.count]);
  vi.connect([table.left, replace.terminal('array')]);
  vi.connect([tableLoop.iteration, toU8.terminal('number'), replace.terminal('index')]);

  final disable = vi.add(BdDisable());
  final reverseLoop = disable.disabled.add(BdLoop.forLoop());
  final reversed = reverseLoop.tunnel(BdType.u8.array, direction: BdTunnelDirection.output, indexing: true);
  final count = disable.disabled.add(BdConstant.i32(256));
  final toU8a = reverseLoop.add(BdPrimitive(PrimOp.toUnsignedByteInteger));
  final toNumber = reverseLoop.add(BdPrimitive(PrimOp.booleanArrayToNumber));
  final reverse = reverseLoop.add(BdPrimitive(PrimOp.reverse1dArray));
  final toBits = reverseLoop.add(BdPrimitive(PrimOp.numberToBooleanArray));
  final toU8b = reverseLoop.add(BdPrimitive(PrimOp.toUnsignedByteInteger));
  vi.connect([toU8a.terminal('unsigned 8bit integer'), reversed]);
  vi.connect([toNumber.terminal('number'), toU8a.terminal('number')]);
  vi.connect([reverse.terminal('reversed array'), toNumber.terminal('Boolean array')]);
  vi.connect([toBits.terminal('Boolean array'), reverse.terminal('array')]);
  vi.connect([toU8b.terminal('unsigned 8bit integer'), toBits.terminal('number')]);
  vi.connect([reverseLoop.iteration, toU8b.terminal('number')]);
  vi.connect([count, reverseLoop.count]);

  final byteLoop = vi.add(BdLoop.forLoop());
  final running = byteLoop.shiftRegister(BdType.u8);
  final input = byteLoop.tunnel(BdType.u8.array, direction: BdTunnelDirection.input, indexing: true);
  final reflectCase = byteLoop.add(BdCase());
  final toI32 = byteLoop.add(BdPrimitive(PrimOp.toLongInteger));
  final index = byteLoop.add(BdIndexArray());
  final mix = byteLoop.add(BdPrimitive(PrimOp.exclusiveOr));
  final byteIn = reflectCase.tunnel(BdType.u8, direction: BdTunnelDirection.input);
  final toI32r = reflectCase.whenTrue.add(BdPrimitive(PrimOp.toLongInteger));
  final lookup = reflectCase.whenTrue.add(BdIndexArray());
  vi.connect([table.right, index.terminal('array')]);
  vi.connect([reflectInput, reflectCase.selector]);
  vi.connect([lut, lookup.terminal('array')]);
  final byteOut = reflectCase.tunnel(BdType.u8, direction: BdTunnelDirection.output);
  vi.connect([byteIn.inner(reflectCase.whenFalse), byteOut.inner(reflectCase.whenFalse)]);
  vi.connect([toI32r.terminal('32bit integer'), lookup.terminal('index')]);
  vi.connect([lookup.terminal('element'), byteOut.inner(reflectCase.whenTrue)]);
  vi.connect([byteIn.inner(reflectCase.whenTrue), toI32r.terminal('number')]);
  vi.connect([byteOut, mix.terminal('x')]);
  vi.connect([toI32.terminal('32bit integer'), index.terminal('index')]);
  vi.connect([index.terminal('element'), running.right]);
  vi.connect([mix.terminal('x .xor. y?'), toI32.terminal('number')], type: BdType.u8);
  vi.connect([running.left, mix.terminal('y')]);
  vi.connect([input, byteIn]);

  final outCase = vi.add(BdCase());
  final crcIn = outCase.tunnel(BdType.u8, direction: BdTunnelDirection.input);
  final crcOutT = outCase.tunnel(BdType.u8, direction: BdTunnelDirection.output);
  final toI32o = outCase.whenTrue.add(BdPrimitive(PrimOp.toLongInteger));
  final lookupOut = outCase.whenTrue.add(BdIndexArray());
  vi.connect([crcIn.inner(outCase.whenFalse), crcOutT.inner(outCase.whenFalse)]);
  vi.connect([toI32o.terminal('32bit integer'), lookupOut.terminal('index')]);
  vi.connect([lookupOut.terminal('element'), crcOutT.inner(outCase.whenTrue)]);
  vi.connect([crcIn.inner(outCase.whenTrue), toI32o.terminal('number')]);
  vi.connect([lut, lookupOut.terminal('array')]);

  vi.connect([xor.terminal('x .xor. y?'), crcIn]);
  vi.connect([toBytes.terminal('unsigned byte array'), input]);
  vi.connect([reflectOutput, outCase.selector]);
  vi.connect([xorOut, xor.terminal('y')]);
  vi.connect([bytes, tableLoop.count]);
  vi.connect([zeros, table.left]);
  vi.connect([running.right, xor.terminal('x')]);
  vi.connect([crcOutT, crcOut]);
  vi.connect([dataIn, toBytes.terminal('string')]);
  vi.connect([init, running.left]);
  vi.write();
  return vi;
}

int _reverseBits(int byte) {
  var out = 0;
  for (var bit = 0; bit < 8; bit++) {
    out = (out << 1) | ((byte >> bit) & 1);
  }
  return out;
}
