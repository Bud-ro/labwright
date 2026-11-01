import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';

Uint8List binarySeq() {
  const pool = [
    'SequenceFileData',
    'Data',
    r'My Computer\Lib\Read.vi',
    'Locals.x == 1',
    'ID#:abc123XYZ',
    '"6105A"',
  ];
  final words = [0, 0, 0, 0, 1, 0, 0, binaryNullIndex, pool.length];
  final region = ByteData(4 * words.length);
  for (final (i, word) in words.indexed) {
    region.setUint32(4 * i, word, Endian.little);
  }
  final body = Uint8List.fromList([
    ...Uint8List.sublistView(region),
    for (final text in pool) ...[...ascii.encode(text), 0],
  ]);
  final header = Tof1Header.blank()
    ..fileType = 'SequenceFile'
    ..productName = 'TestStand'
    ..fileVersion = 962
    ..recordRegionLength = 4 * (words.length - 1)
    ..inflatedLength = body.length;
  return Uint8List.fromList([...header.serialize(), ...zlib.encode(body)]);
}

Uint8List seqXml({
  String steps = '',
  String extra = '',
  String ubound = '[1]',
}) => Uint8List.fromList([
  0xef,
  0xbb,
  0xbf,
  ...utf8.encode(
    "<?xml version='1.0'?>\n"
    "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
    "<typelist/><Data classname='Obj'><subprops>"
    "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
    "<Sequence name='MainSequence' classname='Obj'><subprops>"
    "<Main classname='Objs'><value lbound='[0]' ubound='$ubound'>$steps</value></Main>"
    "</subprops></Sequence></value></value></Seq>$extra</subprops></Data>"
    "</teststandfileheader>",
  ),
]);

String step(String typename, String name, [String subprops = '']) =>
    "<value><Step typename='$typename' name='$name'>"
    "${subprops.isEmpty ? '' : '<subprops>$subprops</subprops>'}"
    '</Step></value>';

String prop(String name, String v, [String? cls]) =>
    "<$name${cls == null ? '' : " classname='$cls'"}><value>$v</value></$name>";

String obj(String name, String body, {String cls = 'Obj'}) =>
    "<$name classname='$cls'><subprops>$body</subprops></$name>";

String objs(String name, List<String> values, {String cls = 'Objs'}) =>
    "<$name classname='$cls'><value lbound='[0]' ubound='[${values.length}]'>"
    '${values.map((v) => '<value>$v</value>').join()}</value></$name>';

String ts(String body) => obj('TS', body);

String sdata(String body, {String cls = 'Obj'}) =>
    ts(obj('SData', body, cls: cls));

String entry(String body) =>
    "<_NAME_IN_ATTRIBUTE_ name='' classname='Obj'><subprops>$body"
    '</subprops></_NAME_IN_ATTRIBUTE_>';
