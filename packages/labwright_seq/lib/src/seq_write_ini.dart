library;

import 'dart:convert';
import 'dart:typed_data';

import 'seq_ini.dart';

Uint8List writeIniSeq(IniSeqFile file) {
  final nl = file.lineTerminator;
  final sb = StringBuffer('[__Header__]')..write(nl);
  file.headerFields.forEach((key, value) => _writeEntry(sb, key, value, nl));
  for (final section in file.sections) {
    sb
      ..write(nl)
      ..write(_sectionHeader(section))
      ..write(nl);
    for (final entry in section.entries) {
      _writeEntry(sb, entry.key, entry.rawValue, nl);
    }
  }
  sb.write(nl);
  return latin1.encode(sb.toString());
}

String _sectionHeader(IniSection section) {
  if (section.isExtData) return '[EXTDATA, ${section.path}, ${section.extDataKind}]';
  return section.isDef ? '[DEF, ${section.path}]' : '[${section.path}]';
}

const int _continuationInnerLimit = 120;

void _writeEntry(StringBuffer sb, String key, String value, String nl) {
  if (value.length - 2 > _continuationInnerLimit && value.startsWith('"') && value.endsWith('"')) {
    final inner = value.substring(1, value.length - 1);
    var number = 0;
    for (var start = 0; start < inner.length; start += _continuationInnerLimit) {
      number++;
      final end = start + _continuationInnerLimit;
      sb
        ..write(key)
        ..write(' Line')
        ..write(number.toString().padLeft(4, '0'))
        ..write(' = "')
        ..write(inner.substring(start, end > inner.length ? inner.length : end))
        ..write('"')
        ..write(nl);
    }
    return;
  }
  sb
    ..write(key)
    ..write(' = ')
    ..write(value)
    ..write(nl);
}

String escapeIniQuoted(String text) {
  final escaped = text
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n')
      .replaceAll('\t', r'\t')
      .replaceAll('\r', r'\r');
  return '"$escaped"';
}
