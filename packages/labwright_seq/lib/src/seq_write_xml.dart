library;

import 'dart:convert';
import 'dart:typed_data';

import 'seq_file.dart';
import 'seq_format.dart';
import 'seq_property.dart';

Uint8List writeSeqFileXml(SeqFile file) {
  if (file.header.format != SeqFormat.xml) {
    throw ArgumentError(
      'writeSeqFileXml writes XML-flavor SeqFiles only; this model came from '
      '${file.header.format} (the binary/INI decoders synthesize partial trees '
      'that cannot honestly serialize as a TestStand XML file)',
    );
  }
  final sb = StringBuffer('\uFEFF<?xml version="1.0" encoding="UTF-8"?>\n<teststandfileheader');
  _writeRootAttributes(sb, file);
  sb.write('>\n');
  final entries = file.typelistEntries ?? [for (final type in file.types) SeqTypelistEntry(root: type)];
  if (file.typelistEntries != null || file.types.isNotEmpty) {
    sb.write('\t<typelist>\n');
    for (final entry in entries) {
      final protected = entry.protectedData;
      if (protected != null) {
        sb
          ..write('\t\t<protected>')
          ..write(_escapeText(protected))
          ..write('</protected>\n');
        continue;
      }
      sb.write('\t\t<typedef');
      _writeAttributes(sb, entry.attributes);
      final root = entry.root;
      if (root == null) {
        sb.write('/>\n');
      } else {
        sb.write('>\n');
        _writeProperty(sb, root, 3);
        sb.write('\t\t</typedef>\n');
      }
    }
    sb.write('\t</typelist>\n');
  }
  _writeProperty(sb, file.data, 1);
  sb.write('</teststandfileheader>\n');
  var text = sb.toString();
  if (file.newline != '\n') {
    text = text.replaceAll('\r\n', '\n').replaceAll('\n', file.newline);
  }
  return utf8.encode(text);
}

void _writeRootAttributes(StringBuffer sb, SeqFile file) {
  final attrs =
      file.rootAttributes ??
      {
        if (file.header.fileType != null) 'type': file.header.fileType!,
        if (file.header.fileVersion != null) 'fileversion': file.header.fileVersion!,
        if (file.header.productName != null) 'productname': file.header.productName!,
      };
  attrs.forEach((name, value) {
    final doubleQuoted = name == 'xmlns' || name.startsWith('xmlns:');
    final quote = doubleQuoted ? '"' : "'";
    sb
      ..write(' ')
      ..write(name)
      ..write('=')
      ..write(quote)
      ..write(_escapeAttribute(value, doubleQuoted: doubleQuoted))
      ..write(quote);
  });
}

void _writeProperty(StringBuffer sb, SeqProperty p, int depth) {
  final indent = _tabs(depth);
  final tag = p.xmlTag ?? p.name;
  sb
    ..write(indent)
    ..write('<')
    ..write(tag);
  _writeAttributes(sb, p.attributes);
  final hasValue = p.array != null || p.scalar != null;
  if (!hasValue && p.xmlComment == null && p.numericFormat == null && p.extData.isEmpty && p.subProps.isEmpty) {
    sb.write('/>\n');
    return;
  }
  sb.write('>\n');
  if (p.xmlComment case final comment?) {
    sb
      ..write(indent)
      ..write('\t<comment>')
      ..write(_escapeText(comment))
      ..write('</comment>\n');
  }
  if (hasValue) _writeValue(sb, p, depth + 1);
  if (p.numericFormat case final format?) {
    sb
      ..write(indent)
      ..write('\t<numericfmt>')
      ..write(_escapeText(format))
      ..write('</numericfmt>\n');
  }
  for (final ext in p.extData) {
    sb
      ..write(indent)
      ..write('\t<extdata');
    _writeAttributes(sb, ext);
    sb.write('/>\n');
  }
  if (p.subProps.isNotEmpty) {
    sb
      ..write(indent)
      ..write('\t<subprops>\n');
    for (final child in p.subProps) {
      _writeProperty(sb, child, depth + 2);
    }
    sb
      ..write(indent)
      ..write('\t</subprops>\n');
  }
  sb
    ..write(indent)
    ..write('</')
    ..write(tag)
    ..write('>\n');
}

void _writeValue(StringBuffer sb, SeqProperty p, int depth) {
  final indent = _tabs(depth);
  sb
    ..write(indent)
    ..write('<value');
  _writeAttributes(sb, p.valueAttributes);
  final array = p.array;
  if (array == null) {
    final text = p.scalar!;
    if (text.isEmpty) {
      sb.write('/>\n');
    } else {
      sb
        ..write('>')
        ..write(_escapeText(text))
        ..write('</value>\n');
    }
    return;
  }
  if (p.elemProto == null && array.isEmpty) {
    sb.write('/>\n');
    return;
  }
  sb.write('>\n');
  final proto = p.elemProto;
  if (proto != null) {
    sb
      ..write(indent)
      ..write('\t<elemproto>\n');
    _writeProperty(sb, proto, depth + 2);
    sb
      ..write(indent)
      ..write('\t</elemproto>\n');
  }
  for (final element in array) {
    _writeArrayElement(sb, element, depth + 1);
  }
  sb
    ..write(indent)
    ..write('</value>\n');
}

void _writeArrayElement(StringBuffer sb, SeqProperty element, int depth) {
  final indent = _tabs(depth);
  if (element.xmlTag == null) {
    sb
      ..write(indent)
      ..write('<value');
    _writeAttributes(sb, element.attributes);
    final text = element.scalar ?? '';
    if (text.isEmpty) {
      sb.write('/>\n');
    } else {
      sb
        ..write('>')
        ..write(_escapeText(text))
        ..write('</value>\n');
    }
  } else {
    sb
      ..write(indent)
      ..write('<value>\n');
    _writeProperty(sb, element, depth + 1);
    sb
      ..write(indent)
      ..write('</value>\n');
  }
}

void _writeAttributes(StringBuffer sb, Map<String, String> attrs) {
  attrs.forEach((name, value) {
    sb
      ..write(' ')
      ..write(name)
      ..write("='")
      ..write(_escapeAttribute(value))
      ..write("'");
  });
}

final List<String> _tabCache = [for (var i = 0; i < 32; i++) '\t' * i];

String _tabs(int depth) => depth < _tabCache.length ? _tabCache[depth] : '\t' * depth;

String _escapeText(String text) {
  if (!text.contains('&') && !text.contains('<') && !text.contains('>')) return text;
  return text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

String _escapeAttribute(String value, {bool doubleQuoted = false}) {
  final quote = doubleQuoted ? '"' : "'";
  if (!value.contains('&') && !value.contains('<') && !value.contains('>') && !value.contains(quote)) {
    return value;
  }
  return _escapeText(value).replaceAll(quote, doubleQuoted ? '&quot;' : '&apos;');
}
