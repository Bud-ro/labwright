import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'heap_spec.dart';
import 'vi_spec.dart';

/// Dart source declaring [spec] as a top-level `ViSpec` named [identifier], which builds the
/// same bytes when run.
String emitViSpecDart(ViSpec spec, {required String identifier}) {
  final out = StringBuffer()
    ..writeln("import 'dart:typed_data';")
    ..writeln()
    ..writeln(
      "import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';",
    )
    ..writeln("import 'package:labwright_vi_text/labwright_vi_text.dart';")
    ..writeln()
    ..writeln('Uint8List _h(String hex) => Uint8List.fromList([')
    ..writeln(
      '  for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),',
    )
    ..writeln(']);')
    ..writeln()
    ..writeln('final ViSpec $identifier = ViSpec(${_string(spec.name)}, [');
  for (final section in spec.sections) {
    _section(out, section, 1);
  }
  out.writeln(
    ']${spec.fileType == 'LVIN' ? '' : ', fileType: ${_string(spec.fileType)}'});',
  );
  return out.toString();
}

void _section(StringBuffer out, SectionSpec section, int depth) {
  final pad = '  ' * depth;
  final extra = [
    if (section.index != 0) 'index: ${section.index}',
    if (section.compressed !=
        (section is HeapSection || section is TypePoolSection))
      'compressed: ${section.compressed}',
  ];
  final tail = extra.isEmpty ? '' : ', ${extra.join(', ')}';
  switch (section) {
    case HeapSection(:final tag, :final records):
      out.writeln('$pad${'HeapSection'}(${_string(tag)}, [');
      for (final record in records) {
        _record(out, record, depth + 1);
      }
      out.writeln('$pad]$tail),');
    case TypePoolSection(:final descriptors, :final topLevel):
      out.writeln('${pad}TypePoolSection([');
      for (final descriptor in descriptors) {
        out.writeln('$pad  _h(${_bytes(descriptor)}),');
      }
      out.writeln('$pad], topLevel: ${_ints(topLevel)}$tail),');
    case TypedSection():
      out.writeln('$pad${_spell(section, extra)},');
    case RawSection(:final tag, :final bytes):
      out.writeln(
        '${pad}RawSection(${_string(tag)}, _h(${_bytes(bytes)})$tail),',
      );
  }
}

void _record(StringBuffer out, HeapSpec record, int depth) {
  final pad = '  ' * depth;
  switch (record) {
    case ObjectSpec():
      final args = [
        if (record.objectClass == HeapObjectClass.unknown ||
            record.objectClass.code != record.kind)
          'kind: ${_hex(record.kind)}',
        if (record.lead != 0x10) 'lead: ${_hex(record.lead)}',
        if (record.tag != 0x19) 'tag: ${_hex(record.tag)}',
        if (record.wide) 'wide: true',
        if (record.close != (0x08, 0x19)) 'close: ${_close(record.close)}',
      ];
      out.writeln(
        '${pad}ObjectSpec(HeapObjectClass.${record.objectClass.name}, ${record.oid}${_named(args)}, children: [',
      );
      for (final child in record.children) {
        _record(out, child, depth + 1);
      }
      out.writeln('$pad]),');
    case GroupSpec():
      final args = [
        if (record.close != (0x08, 0x19)) 'close: ${_close(record.close)}',
      ];
      out.writeln(
        '${pad}GroupSpec(_h(${_bytes(record.open)})${_named(args)}, children: [',
      );
      for (final child in record.children) {
        _record(out, child, depth + 1);
      }
      out.writeln('$pad]),');
    case AttrSpec(:final rawId, :final value, :final width):
      final attribute = HeapAttribute.fromRaw(rawId);
      final id = attribute.raw == rawId
          ? 'HeapAttribute.${attribute.name}.raw'
          : _hex(rawId);
      out.writeln(
        '${pad}AttrSpec($id, ${_hex(value)}, width: HeapAttrWidth.${width.name}),',
      );
    case RefSpec(:final rawId, :final oid, :final wide):
      final kind = HeapRefKind.fromRaw(rawId);
      final id = kind.raw == rawId
          ? 'HeapRefKind.${kind.name}.raw'
          : _hex(rawId);
      out.writeln('${pad}RefSpec($id, $oid${wide ? ', wide: true' : ''}),');
    case C4Spec(:final opcode, :final payload):
      final kind = HeapOpcode.fromByte(opcode);
      if (kind == HeapOpcode.bounds && payload.length == 8) {
        final r = HeapRect.fromPayload(payload)!;
        out.writeln(
          '${pad}C4Spec.bounds(${r.top}, ${r.left}, ${r.bottom}, ${r.right}),',
        );
      } else if (kind == HeapOpcode.caption && _isText(payload)) {
        out.writeln(
          '${pad}C4Spec.caption(${_string(String.fromCharCodes(payload))}),',
        );
      } else {
        final op = kind.byte == opcode
            ? 'HeapOpcode.${kind.name}.byte'
            : _hex(opcode);
        out.writeln('${pad}C4Spec($op, _h(${_bytes(payload)})),');
      }
    case WireSpec(:final oid, :final endpoints, :final route, :final table):
      final args = [
        if (route != null)
          'route: [${route.map(_leg).join(', ')}]'
        else
          'table: ${_table(table)}',
        'state: ${record.state}',
        'kind: ${_hex(record.kind)}',
        if (record.flags case final flags?) 'flags: ${_hex(flags)}',
      ];
      out.writeln('${pad}WireSpec($oid, ${_ints(endpoints)}${_named(args)}),');
    case WireTableSpec(:final table):
      out.writeln(
        '${pad}WireTableSpec(${table.pointCount}${_named(_tableArgs(table))}),',
      );
    case RawSpec(:final bytes):
      out.writeln('${pad}RawSpec(_h(${_bytes(bytes)})),');
  }
}

List<String> _tableArgs(WireTable table) => [
  if (table.header case final header?) 'header: ${_ints(header)}',
  if (table.modes.isNotEmpty) 'modes: ${_ints(table.modes)}',
  if (table.lengths.isNotEmpty) 'lengths: ${_ints(table.lengths)}',
];

String _table(WireTable table) =>
    'WireTable(${table.pointCount}${_named(_tableArgs(table))})';

String _leg(WireLeg leg) =>
    'WireLeg.${leg.direction.name}(${leg.length ?? ''})';

String _spell(Spelled value, [List<String> extra = const []]) {
  final args = [
    for (final (name, argument) in value.arguments)
      if (argument != null) '$name: ${_value(argument)}',
    ...extra,
  ];
  return '${value.constructor}(${args.join(', ')})';
}

String _value(Object argument) => switch (argument) {
  int() || bool() => '$argument',
  double() => '$argument',
  String() => _string(argument),
  Uint8List() => '_h(${_bytes(argument)})',
  Enum() => '${_enumType(argument)}.${argument.name}',
  HeapRect(:final top, :final left, :final bottom, :final right) =>
    'HeapRect(top: $top, left: $left, bottom: $bottom, right: $right)',
  Spelled() => _spell(argument),
  List<Object>() => '[${argument.map(_value).join(', ')}]',
  _ => throw ArgumentError.value(argument, 'argument', 'has no spelling'),
};

String _enumType(Enum value) => switch (value) {
  LegacyIconDepth() => 'LegacyIconDepth',
  _ => throw ArgumentError.value(value, 'value', 'is not a spelled enum'),
};

String _named(List<String> args) => args.isEmpty ? '' : ', ${args.join(', ')}';

String _close((int, int)? close) =>
    close == null ? 'null' : '(${_hex(close.$1)}, ${_hex(close.$2)})';

String _hex(int value) => '0x${value.toRadixString(16)}';

String _ints(List<int> values) => '[${values.join(', ')}]';

String _bytes(Uint8List bytes) =>
    "'${[for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join()}'";

bool _isText(Uint8List bytes) => bytes.every((b) => b >= 0x20 && b < 0x7f);

String _string(String text) {
  final out = StringBuffer("'");
  for (final unit in text.codeUnits) {
    out.write(switch (unit) {
      0x27 => r"\'",
      0x5c => r'\\',
      0x24 => r'\$',
      0x0a => r'\n',
      0x0d => r'\r',
      0x09 => r'\t',
      < 0x20 || >= 0x7f => '\\u{${unit.toRadixString(16)}}',
      _ => String.fromCharCode(unit),
    });
  }
  return (out..write("'")).toString();
}
