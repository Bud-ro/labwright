/// Byte-exact writer for the XML flavor of TestStand `.seq` files:
/// [writeSeqFileXml] serializes a parsed [SeqFile] back to the on-disk XML
/// encoding.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'seq_file.dart';
import 'seq_format.dart';
import 'seq_property.dart';

/// Serializes an XML-flavor [SeqFile] back to TestStand's on-disk XML encoding,
/// **byte-exactly**: for every XML `.seq` in the corpus,
/// `writeSeqFileXml(parseSeqFile(bytes))` reproduces the original bytes
/// (validated by the corpus round-trip gate in `test/seq_write_xml_test.dart`).
///
/// The serialization constants below are corpus-verified over all 42 XML files
/// (uniform, no exceptions):
/// - UTF-8 with a BOM (`EF BB BF`);
/// - declaration exactly `<?xml version="1.0" encoding="UTF-8"?>` (the only
///   double-quoted line besides the root's `xmlns` attributes);
/// - element attributes single-quoted, EXCEPT the root's `xmlns`/`xmlns:*`
///   declarations which are double-quoted;
/// - the source file's line terminator throughout ([SeqFile.newline]: LF for
///   36 corpus files, CRLF for the 6 CRLF-terminated ones — each is uniform,
///   no corpus file mixes terminators); TAB indentation, one element per line;
/// - childless elements self-closed (`<value/>`, `<SData/>`, `<extdata …/>`);
/// - an empty `<subprops>` is never written (the corpus never contains one);
/// - text/attribute escaping is exactly `&amp;` `&lt;` `&gt;` (the corpus uses
///   no other entity, no numeric refs, and no `&`/`<`/`>`/quote characters in
///   attribute values — `&apos;`/`&quot;` are emitted defensively for
///   out-of-corpus values since attrs are quoted);
/// - literal LFs inside multiline `<value>` text stay literal;
/// - the file ends `</teststandfileheader>` plus a single LF.
///
/// Only XML-flavor models are writable: a [SeqFile] whose header format is
/// binary/INI was synthesized by a PARTIAL decoder (its tree is not the full
/// file content), so writing it would fabricate a file — [ArgumentError] is
/// thrown instead.
Uint8List writeSeqFileXml(SeqFile file) {
  if (file.header.format != SeqFormat.xml) {
    throw ArgumentError(
      'writeSeqFileXml writes XML-flavor SeqFiles only; this model came from '
      '${file.header.format} (the binary/INI decoders synthesize partial trees '
      'that cannot honestly serialize as a TestStand XML file)',
    );
  }
  // U+FEFF becomes the on-disk UTF-8 BOM (EF BB BF) when encoded below.
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
      if (entry.root == null) {
        // Unobserved in the corpus (every typedef wraps a root); an empty
        // wrapper self-closes like every other childless element.
        sb.write('/>\n');
      } else {
        sb.write('>\n');
        _writeProperty(sb, entry.root!, 3);
        sb.write('\t\t</typedef>\n');
      }
    }
    sb.write('\t</typelist>\n');
  }
  _writeProperty(sb, file.data, 1);
  sb.write('</teststandfileheader>\n');
  var text = sb.toString();
  if (file.newline != '\n') {
    // The writer builds with LF; a CRLF source expands every line break to
    // the file's terminator. Text content that already carries literal CRLFs
    // (multiline `<value>`/`<comment>` text is kept verbatim by the parser)
    // is normalized first so it cannot double-expand — exact because every
    // CRLF corpus file is uniformly CRLF (a bare LF inside a text node of a
    // CRLF file, unobserved in the corpus, would be widened; the byte-exact
    // round-trip gates would catch such a file loudly).
    text = text.replaceAll('\r\n', '\n').replaceAll('\n', file.newline);
  }
  return utf8.encode(text);
}

/// Root attributes, with the corpus's mixed quoting: single quotes everywhere
/// EXCEPT `xmlns`/`xmlns:*`, which TestStand writes double-quoted. Falls back
/// to the sniffed header trio for a hand-built model with no
/// [SeqFile.rootAttributes].
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

/// One property element at [depth] tabs: tag + attributes, then its children in
/// the corpus-invariant order `<comment>` → `<value>` → `<numericfmt>` →
/// `<extdata/>`* → `<subprops>` (verified over every co-occurrence in all 42
/// files; both corpus `<comment>` occurrences are the element's FIRST child,
/// before `<subprops>`, and never co-occur with the others); childless
/// elements self-close.
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
  if (p.xmlComment != null) {
    sb
      ..write(indent)
      ..write('\t<comment>')
      ..write(_escapeText(p.xmlComment!))
      ..write('</comment>\n');
  }
  if (hasValue) _writeValue(sb, p, depth + 1);
  if (p.numericFormat != null) {
    sb
      ..write(indent)
      ..write('\t<numericfmt>')
      ..write(_escapeText(p.numericFormat!))
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

/// The property's own `<value>` element: scalar text inline (literal LFs kept,
/// empty self-closes), or the array form — `lbound`/`ubound`/`representation`
/// re-emitted verbatim from [SeqProperty.valueAttributes], the `<elemproto>`
/// first, then one wrapped `<value>` per stored element.
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

/// One stored array element. A scalar element (no source tag) IS its `<value>`
/// wrapper: its attributes (e.g. the sparse-array `arrayindex`) go on the
/// wrapper and its text inline. An object element writes a bare wrapper around
/// the property element (corpus-verified: no wrapper attribute ever coexists
/// with a wrapped child element).
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

/// Single-quoted attributes in stored (document) order.
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

/// Indentation strings, cached per depth so no `'\t' * depth` string is
/// allocated per output line (corpus trees nest ~20 deep, so the writer
/// indents far more lines than it has distinct depths).
final List<String> _tabCache = [for (var i = 0; i < 32; i++) '\t' * i];

String _tabs(int depth) => depth < _tabCache.length ? _tabCache[depth] : '\t' * depth;

/// Text-content escaping, exactly the entity set TestStand emits (`&` `<` `>`;
/// corpus-verified: no other entity or numeric ref occurs, raw `>` never
/// appears in text). Fast path: most values contain none of the three.
String _escapeText(String text) {
  if (!text.contains('&') && !text.contains('<') && !text.contains('>')) return text;
  return text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

/// Attribute-value escaping: the same three entities plus the enclosing quote
/// (`&apos;` single- / `&quot;` double-quoted). No corpus attribute value
/// contains ANY of these characters, so this is defensive for out-of-corpus
/// models, not a corpus-observed encoding.
String _escapeAttribute(String value, {bool doubleQuoted = false}) {
  final quote = doubleQuoted ? '"' : "'";
  if (!value.contains('&') && !value.contains('<') && !value.contains('>') && !value.contains(quote)) {
    return value;
  }
  return _escapeText(value).replaceAll(quote, doubleQuoted ? '&quot;' : '&apos;');
}
