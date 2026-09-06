import 'dart:convert';
import 'dart:typed_data';

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
