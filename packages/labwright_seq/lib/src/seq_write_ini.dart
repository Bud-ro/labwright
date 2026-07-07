/// Byte-exact writer for the legacy INI flavor of TestStand `.seq` files:
/// [writeIniSeq] serializes a parsed [IniSeqFile] back to the on-disk INI
/// encoding, and [escapeIniQuoted] builds quoted raw values from logical text.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'seq_ini.dart';

/// Serializes a parsed [IniSeqFile] back to TestStand's legacy INI `.seq`
/// encoding, **byte-exactly**: for every INI `.seq` in the corpus,
/// `writeIniSeq(parseIniSeqBytes(bytes))` reproduces the original bytes
/// (validated by the corpus round-trip gate in `test/seq_write_ini_test.dart`).
///
/// The serialization constants below are corpus-verified over all 58 INI files
/// (uniform, no exceptions):
/// - single-byte text (Latin-1; the reader decodes the same way, so every byte
///   survives the model round-trip);
/// - the file's line terminator is uniform per file and replayed from
///   [IniSeqFile.lineTerminator] (57 LF files, one CRLF file, none mixed);
/// - line 1 is exactly `[__Header__]`, followed by the header entries;
/// - every section header is preceded by exactly ONE blank line, and the file
///   ends with the last entry line plus one blank line;
/// - section headers are `[path]`, `[DEF, path]` (single space after the
///   comma), or `[EXTDATA, path, KIND]` (single space after each comma);
/// - entry lines are `key = value` with single spaces around `=`, no leading
///   or trailing whitespace anywhere, and no empty sections;
/// - entries are written in [IniSection.entries] document order (members and
///   `%`-directives interleave freely — 7184 corpus sections interleave them);
/// - values are written verbatim from [IniEntry.rawValue] (quoted-vs-bare and
///   the C-style escapes are the parser's untouched raw text), EXCEPT that a
///   quoted value whose inner escaped text exceeds 120 characters is re-split
///   into `KEY LineNNNN` continuation fragments (see [_writeEntry]) — the
///   exact inverse of the reader's reassembly.
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

/// The exact `[...]` header line for [section]: `[DEF, path]` / `[path]` /
/// `[EXTDATA, path, KIND]`, with the corpus's single space after each comma
/// (uniform across all 36,339 DEF and 1,829 EXTDATA headers; no corpus path
/// contains a comma, so the reconstruction is unambiguous).
String _sectionHeader(IniSection section) {
  if (section.isExtData) return '[EXTDATA, ${section.path}, ${section.extDataKind}]';
  return section.isDef ? '[DEF, ${section.path}]' : '[${section.path}]';
}

/// The inner (escaped) length above which NI splits a quoted value across
/// `KEY LineNNNN` continuation lines. Corpus-exact threshold: no unsplit
/// quoted value has an inner longer than 120, every split group totals ≥ 121,
/// and every non-final fragment inner is exactly 120.
const int _continuationInnerLimit = 120;

/// Writes one `key = value` line — or, for a quoted value whose inner escaped
/// text exceeds [_continuationInnerLimit], the `KEY Line0001…` continuation
/// lines the reader rejoined: consecutive 120-character chunks of the raw
/// escaped inner text (escape-blind — a `\"`/`\\` pair may straddle a chunk
/// boundary, exactly as NI splits), each separately quoted, numbered from
/// 0001 with 4-digit zero padding; the final chunk carries the 1–120-char
/// remainder (an exact multiple of 120 ends with a full chunk, never an empty
/// one). Bare values never split (the corpus's longest is 23 chars).
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

/// Escapes [text] into a quoted INI raw value — the inverse of the reader's
/// unescaping, for building [IniEntry] values from logical text. Exactly the
/// five escapes the corpus uses inside quoted values (`\\` `\"` `\n` `\t`
/// `\r`; no other escape target survives continuation rejoining corpus-wide),
/// backslash first so no other escape is double-processed.
String escapeIniQuoted(String text) {
  final escaped = text
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n')
      .replaceAll('\t', r'\t')
      .replaceAll('\r', r'\r');
  return '"$escaped"';
}
