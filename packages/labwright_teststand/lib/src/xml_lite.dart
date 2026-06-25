/// A small, owned, total XML reader for the TestStand XML `.seq` subset.
///
/// Clean-room (no third-party XML dependency): TestStand XML is regular,
/// machine-generated output — elements, attributes (single- or double-quoted),
/// self-closing tags, a UTF-8 BOM, an `<?xml?>` prolog, and entity-escaped text
/// in leaf `<value>` nodes. There is **no** CDATA / comment / DOCTYPE / mixed
/// content in the corpus (verified across all sample files), so this reader
/// supports exactly that subset and **throws** on anything outside it rather
/// than silently mis-reading — honesty over a lossy guess.
library;

/// One element node. [text] is the concatenated character data directly inside
/// the element (only leaf `<value>` nodes carry it in TestStand files).
class XmlLiteElement {
  XmlLiteElement(this.name);

  final String name;

  /// Attributes in document order (insertion-ordered map), values entity-decoded.
  final Map<String, String> attributes = {};
  final List<XmlLiteElement> children = [];
  String? text;

  /// First direct child element named [name], or null.
  XmlLiteElement? child(String name) {
    for (final c in children) {
      if (c.name == name) return c;
    }
    return null;
  }

  /// All direct child elements named [name].
  Iterable<XmlLiteElement> childrenNamed(String name) =>
      children.where((c) => c.name == name);

  @override
  String toString() => '<$name ${attributes.length} attrs, ${children.length} children>';
}

/// Parses [xml] (a decoded string; strip the BOM first via [stripBom]) into its
/// single root element. Throws [FormatException] with an offset on malformed or
/// unsupported input.
XmlLiteElement parseXml(String xml) => _XmlReader(xml).parseDocument();

/// Removes a leading UTF-8 BOM (`U+FEFF`) if present.
String stripBom(String s) => s.isNotEmpty && s.codeUnitAt(0) == 0xFEFF ? s.substring(1) : s;

class _XmlReader {
  _XmlReader(this.s);
  final String s;
  int i = 0;

  Never _err(String msg) => throw FormatException('$msg at offset $i', s, i);

  XmlLiteElement parseDocument() {
    _skipMisc();
    if (i >= s.length || s.codeUnitAt(i) != _lt) _err('expected root element');
    final root = _parseElement();
    _skipMisc();
    if (i < s.length) _err('unexpected trailing content');
    return root;
  }

  /// Skips whitespace, the `<?xml?>` prolog, and rejects unsupported constructs.
  void _skipMisc() {
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (_isWs(c)) {
        i++;
      } else if (c == _lt && _peek(1) == _question) {
        // <?...?> processing instruction (the prolog).
        final end = s.indexOf('?>', i);
        if (end < 0) _err('unterminated processing instruction');
        i = end + 2;
      } else if (c == _lt && _peek(1) == _bang) {
        // <!-- comment -->, <![CDATA[…]]>, <!DOCTYPE…> — not in the TestStand subset.
        _err('unsupported XML construct (comment/CDATA/DOCTYPE)');
      } else {
        return;
      }
    }
  }

  XmlLiteElement _parseElement() {
    if (s.codeUnitAt(i) != _lt) _err('expected "<"');
    i++;
    final name = _readName();
    final el = XmlLiteElement(name);
    // Attributes.
    while (true) {
      _skipWs();
      final c = s.codeUnitAt(i);
      if (c == _gt) {
        i++;
        break; // open tag; parse content below
      }
      if (c == _slash) {
        if (_peek(1) != _gt) _err('expected "/>"');
        i += 2;
        return el; // self-closing
      }
      final aName = _readName();
      _skipWs();
      if (s.codeUnitAt(i) != _eq) _err('expected "=" in attribute');
      i++;
      _skipWs();
      el.attributes[aName] = _readQuoted();
    }
    // Content: text and child elements until </name>.
    final textBuf = StringBuffer();
    while (true) {
      if (i >= s.length) _err('unterminated element <$name>');
      final c = s.codeUnitAt(i);
      if (c == _lt) {
        if (_peek(1) == _slash) {
          // closing tag
          i += 2;
          final close = _readName();
          if (close != name) _err('mismatched </$close> for <$name>');
          _skipWs();
          if (s.codeUnitAt(i) != _gt) _err('expected ">" in closing tag');
          i++;
          break;
        } else if (_peek(1) == _bang) {
          _err('unsupported XML construct in content');
        } else {
          el.children.add(_parseElement());
        }
      } else {
        textBuf.writeCharCode(c);
        i++;
      }
    }
    if (textBuf.isNotEmpty) {
      final t = _decodeEntities(textBuf.toString());
      if (t.trim().isNotEmpty || el.children.isEmpty) el.text = t;
    }
    return el;
  }

  String _readName() {
    final start = i;
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (_isWs(c) || c == _gt || c == _slash || c == _eq) break;
      i++;
    }
    if (i == start) _err('expected a name');
    return s.substring(start, i);
  }

  String _readQuoted() {
    final q = s.codeUnitAt(i);
    if (q != _dquote && q != _squote) _err('expected quoted attribute value');
    i++;
    final start = i;
    while (i < s.length && s.codeUnitAt(i) != q) {
      i++;
    }
    if (i >= s.length) _err('unterminated attribute value');
    final raw = s.substring(start, i);
    i++; // closing quote
    return _decodeEntities(raw);
  }

  int _peek(int ahead) => (i + ahead) < s.length ? s.codeUnitAt(i + ahead) : -1;
  void _skipWs() {
    while (i < s.length && _isWs(s.codeUnitAt(i))) {
      i++;
    }
  }
}

bool _isWs(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

const _lt = 0x3C, _gt = 0x3E, _slash = 0x2F, _eq = 0x3D;
const _question = 0x3F, _bang = 0x21, _dquote = 0x22, _squote = 0x27, _amp = 0x26;

/// Decodes the five predefined XML entities plus numeric character references.
/// Returns the input unchanged when it holds no `&`.
String _decodeEntities(String s) {
  if (!s.contains('&')) return s;
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s.codeUnitAt(i);
    if (c != _amp) {
      out.writeCharCode(c);
      i++;
      continue;
    }
    final semi = s.indexOf(';', i + 1);
    if (semi < 0) {
      out.writeCharCode(c);
      i++;
      continue;
    }
    final ent = s.substring(i + 1, semi);
    final decoded = _entity(ent);
    if (decoded == null) {
      out.writeCharCode(c); // not a recognized entity — keep the '&' literally
      i++;
    } else {
      out.write(decoded);
      i = semi + 1;
    }
  }
  return out.toString();
}

String? _entity(String ent) {
  switch (ent) {
    case 'lt':
      return '<';
    case 'gt':
      return '>';
    case 'amp':
      return '&';
    case 'quot':
      return '"';
    case 'apos':
      return "'";
  }
  if (ent.startsWith('#x') || ent.startsWith('#X')) {
    final code = int.tryParse(ent.substring(2), radix: 16);
    return code == null ? null : String.fromCharCode(code);
  }
  if (ent.startsWith('#')) {
    final code = int.tryParse(ent.substring(1));
    return code == null ? null : String.fromCharCode(code);
  }
  return null;
}
