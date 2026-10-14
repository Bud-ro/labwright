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
    ..writeln('Uint8List _b(List<int> bytes) => Uint8List.fromList(bytes);')
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
        out.writeln('$pad  _b(${_bytes(descriptor)}),');
      }
      out.writeln('$pad], topLevel: ${_ints(topLevel)}$tail),');
    case RawSection(:final tag, :final bytes):
      out.writeln(
        '${pad}RawSection(${_string(tag)}, _b(${_bytes(bytes)})$tail),',
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
        '${pad}GroupSpec(_b(${_bytes(record.open)})${_named(args)}, children: [',
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
        out.writeln('${pad}C4Spec($op, _b(${_bytes(payload)})),');
      }
    case RawSpec(:final bytes):
      out.writeln('${pad}RawSpec(_b(${_bytes(bytes)})),');
  }
}

String _named(List<String> args) => args.isEmpty ? '' : ', ${args.join(', ')}';

String _close((int, int)? close) =>
    close == null ? 'null' : '(${_hex(close.$1)}, ${_hex(close.$2)})';

String _hex(int value) => '0x${value.toRadixString(16)}';

String _ints(List<int> values) => '[${values.join(', ')}]';

String _bytes(Uint8List bytes) =>
    '[${[for (final b in bytes) _hex(b)].join(', ')}]';

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
