import 'dart:convert';
import 'dart:typed_data';

import 'seq_file.dart';
import 'seq_format.dart';
import 'seq_property.dart';

/// Serializes an XML-flavor [SeqFile] back to TestStand's on-disk XML encoding,
/// **byte-exactly**: for every XML `.seq` in the corpus,
/// `writeSeqFileXml(parseSeqFile(bytes))` reproduces the original bytes
/// (validated by the corpus round-trip gate in `test/seq_write_test.dart`).
///
/// The serialization constants below are corpus-verified over all 36 XML files
/// (uniform, no exceptions):
/// - UTF-8 with a BOM (`EF BB BF`);
/// - declaration exactly `<?xml version="1.0" encoding="UTF-8"?>` (the only
///   double-quoted line besides the root's `xmlns` attributes);
/// - element attributes single-quoted, EXCEPT the root's `xmlns`/`xmlns:*`
///   declarations which are double-quoted;
/// - LF line endings only; TAB indentation, one element per line;
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
  return utf8.encode(sb.toString());
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
/// the corpus-invariant order `<value>` → `<numericfmt>` → `<extdata/>`* →
/// `<subprops>` (verified over every co-occurrence in all 36 files); childless
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
  if (!hasValue && p.numericFormat == null && p.extData.isEmpty && p.subProps.isEmpty) {
    sb.write('/>\n');
    return;
  }
  sb.write('>\n');
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

/// Indentation strings, cached per depth (corpus trees nest ~20 deep; building
/// `'\t' * depth` per line was the writer's hottest allocation).
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

/// Deep structural equality over two [SeqFile] models — the model-level
/// round-trip gate (`parse(write(parse(f)))` must deep-equal `parse(f)`).
/// Deliberately ORDER-SENSITIVE on attribute maps: attribute order is document
/// order in this model and the writer re-emits it, so a reordering is a real
/// fidelity loss, not an equivalent file.
bool seqFileDeepEquals(SeqFile a, SeqFile b) {
  if (a.header.format != b.header.format ||
      a.header.fileType != b.header.fileType ||
      a.header.productName != b.header.productName ||
      a.header.fileVersion != b.header.fileVersion) {
    return false;
  }
  if (!_nullableOrderedMapEquals(a.rootAttributes, b.rootAttributes)) return false;
  final aDefs = a.typelistEntries;
  final bDefs = b.typelistEntries;
  if ((aDefs == null) != (bDefs == null)) return false;
  if (aDefs != null && bDefs != null) {
    if (aDefs.length != bDefs.length) return false;
    for (var i = 0; i < aDefs.length; i++) {
      if (aDefs[i].protectedData != bDefs[i].protectedData) return false;
      if (!_orderedMapEquals(aDefs[i].attributes, bDefs[i].attributes)) return false;
      if (!_nullablePropEquals(aDefs[i].root, bDefs[i].root)) return false;
    }
  }
  return seqPropertyDeepEquals(a.data, b.data);
}

/// Deep structural equality over two [SeqProperty] trees: every model field —
/// name, tag, class/type names, scalar, attribute maps (order-sensitive),
/// value attributes, element prototype, array elements, extdata, numeric
/// format, and sub-properties, recursively.
bool seqPropertyDeepEquals(SeqProperty a, SeqProperty b) {
  if (a.name != b.name ||
      a.className != b.className ||
      a.typeName != b.typeName ||
      a.xmlTag != b.xmlTag ||
      a.scalar != b.scalar ||
      a.numericFormat != b.numericFormat) {
    return false;
  }
  if (!_orderedMapEquals(a.attributes, b.attributes)) return false;
  if (!_orderedMapEquals(a.valueAttributes, b.valueAttributes)) return false;
  if (!_nullablePropEquals(a.elemProto, b.elemProto)) return false;
  if (a.extData.length != b.extData.length) return false;
  for (var i = 0; i < a.extData.length; i++) {
    if (!_orderedMapEquals(a.extData[i], b.extData[i])) return false;
  }
  final aArr = a.array;
  final bArr = b.array;
  if ((aArr == null) != (bArr == null)) return false;
  if (aArr != null && bArr != null) {
    if (aArr.length != bArr.length) return false;
    for (var i = 0; i < aArr.length; i++) {
      if (!seqPropertyDeepEquals(aArr[i], bArr[i])) return false;
    }
  }
  if (a.subProps.length != b.subProps.length) return false;
  for (var i = 0; i < a.subProps.length; i++) {
    if (!seqPropertyDeepEquals(a.subProps[i], b.subProps[i])) return false;
  }
  return true;
}

bool _nullablePropEquals(SeqProperty? a, SeqProperty? b) {
  if (a == null || b == null) return identical(a, b) || (a == null && b == null);
  return seqPropertyDeepEquals(a, b);
}

bool _nullableOrderedMapEquals(Map<String, String>? a, Map<String, String>? b) {
  if (a == null || b == null) return a == null && b == null;
  return _orderedMapEquals(a, b);
}

/// Order-sensitive map equality (insertion order == document order here).
bool _orderedMapEquals(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  final ai = a.entries.iterator;
  final bi = b.entries.iterator;
  while (ai.moveNext() && bi.moveNext()) {
    if (ai.current.key != bi.current.key || ai.current.value != bi.current.value) return false;
  }
  return true;
}
