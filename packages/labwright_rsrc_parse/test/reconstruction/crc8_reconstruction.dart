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
  rotate.output('value') >> rotated;
  poly >> bitXor['y'];
  final bitOut = bitCase.tunnel(BdType.u8, direction: BdTunnelDirection.output);
  rotated.inner(bitCase.whenFalse) >> bitOut.inner(bitCase.whenFalse);
  rotated.inner(bitCase.whenTrue) >> bitXor['x'];
  bitXor['x .xor. y?'] >> bitOut.inner(bitCase.whenTrue);
  bitOut >> crc.right;
  rotate['msb carry out'] >> bitCase.selector;
  carry >> rotate['carry'];
  crc.left >> rotate.input('value');
  replace['output array'] >> table.right;
  toU8['unsigned 8bit integer'] >> crc.left;
  crc.right >> replace['new element'];
  eight >> bitLoop.count;
  table.left >> replace['array'];
  tableLoop.iteration >> toU8['number'];
  tableLoop.iteration >> replace['index'];

  final disable = vi.add(BdDisable());
  final reverseLoop = disable.disabled.add(BdLoop.forLoop());
  final reversed = reverseLoop.tunnel(BdType.u8.array, direction: BdTunnelDirection.output, indexing: true);
  final count = disable.disabled.add(BdConstant.i32(256));
  final toU8a = reverseLoop.add(BdPrimitive(PrimOp.toUnsignedByteInteger));
  final toNumber = reverseLoop.add(BdPrimitive(PrimOp.booleanArrayToNumber));
  final reverse = reverseLoop.add(BdPrimitive(PrimOp.reverse1dArray));
  final toBits = reverseLoop.add(BdPrimitive(PrimOp.numberToBooleanArray));
  final toU8b = reverseLoop.add(BdPrimitive(PrimOp.toUnsignedByteInteger));
  toU8a['unsigned 8bit integer'] >> reversed;
  toNumber['number'] >> toU8a['number'];
  reverse['reversed array'] >> toNumber['Boolean array'];
  toBits['Boolean array'] >> reverse['array'];
  toU8b['unsigned 8bit integer'] >> toBits['number'];
  reverseLoop.iteration >> toU8b['number'];
  count >> reverseLoop.count;

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
  table.right >> index['array'];
  reflectInput >> reflectCase.selector;
  lut >> lookup['array'];
  final byteOut = reflectCase.tunnel(BdType.u8, direction: BdTunnelDirection.output);
  byteIn.inner(reflectCase.whenFalse) >> byteOut.inner(reflectCase.whenFalse);
  toI32r['32bit integer'] >> lookup['index'];
  lookup['element'] >> byteOut.inner(reflectCase.whenTrue);
  byteIn.inner(reflectCase.whenTrue) >> toI32r['number'];
  byteOut >> mix['x'];
  toI32['32bit integer'] >> index['index'];
  index['element'] >> running.right;
  vi.connect(mix['x .xor. y?'], toI32['number'], type: BdType.u8);
  running.left >> mix['y'];
  input >> byteIn;

  final outCase = vi.add(BdCase());
  final crcIn = outCase.tunnel(BdType.u8, direction: BdTunnelDirection.input);
  final crcOutT = outCase.tunnel(BdType.u8, direction: BdTunnelDirection.output);
  final toI32o = outCase.whenTrue.add(BdPrimitive(PrimOp.toLongInteger));
  final lookupOut = outCase.whenTrue.add(BdIndexArray());
  crcIn.inner(outCase.whenFalse) >> crcOutT.inner(outCase.whenFalse);
  toI32o['32bit integer'] >> lookupOut['index'];
  lookupOut['element'] >> crcOutT.inner(outCase.whenTrue);
  crcIn.inner(outCase.whenTrue) >> toI32o['number'];
  lut >> lookupOut['array'];

  xor['x .xor. y?'] >> crcIn;
  toBytes['unsigned byte array'] >> input;
  reflectOutput >> outCase.selector;
  xorOut >> xor['y'];
  bytes >> tableLoop.count;
  zeros >> table.left;
  running.right >> xor['x'];
  crcOutT >> crcOut;
  dataIn >> toBytes['string'];
  init >> running.left;
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
