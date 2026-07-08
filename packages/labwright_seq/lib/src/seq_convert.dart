/// Cross-flavor conversion between the TestStand `.seq` encodings, with 100%
/// information retention: [iniToXmlSeqFile] / [xmlToIniSeqFile] convert between
/// the legacy INI model ([IniSeqFile]) and the XML-flavor model ([SeqFile]) in
/// both directions, and [binaryToXmlSeqFile] / [binaryToIniSeqFile] lift the
/// **partial** binary decode into the same bridge.
///
/// ## Retention model
///
/// Each direction is a *native conversion plus a reserved fidelity channel*:
///
/// - **INI → XML** produces a real XML-flavor model whose `Data` tree is the
///   fully decoded INI property tree (`iniDataTree` — inheritance-EXPANDED,
///   which is exactly the shape the XML flavor materializes natively), made
///   XML-serializable by [_xmlReady]. The INI *serialization state* — section
///   document order, which members a section spelled out vs. inherited from
///   its type, member/directive interleaving, and raw value quoting — has no
///   XML counterpart (the XML flavor stores an explicit tree with no
///   type-elision concept), so it is recorded losslessly as a reserved
///   property subtree ([ConvKey.iniChannel]) rather than dropped.
///   [xmlToIniSeqFile] inverts the channel, reproducing the original INI
///   **byte-exactly** (45/45 corpus INI files; gate:
///   `test/seq_convert_corpus_test.dart`).
/// - **XML → INI** emits real INI `[DEF, path]`/`[path]` sections for the
///   whole property tree (every node written explicitly — the INI flavor
///   accepts fully-materialized members), and records the XML-only facts —
///   element tags, verbatim ordered attribute maps, `<value>` attributes,
///   `<elemproto>` trees, `<extdata>` attribute maps — under reserved `%X*`
///   directives ([ConvKey]). `<numericfmt>` crosses **natively** as the INI
///   `%NUMFMT` directive (corpus: 530 native `%NUMFMT` lines, all bare
///   own-section, quoted — the same fact in both flavors). [iniToXmlSeqFile]
///   inverts this encoding, reproducing the original XML model deep-equal and
///   therefore (via the byte-exact XML writer) the original file byte-exactly
///   (42/42 corpus XML files).
///
/// Both conversions are deterministic pure functions of their input models, so
/// longer loops (`XML → INI → XML → INI → …`) are fixpoints after the first
/// hop (gated).
///
/// ## What crosses natively
///
/// - `%NUMFMT` ↔ `<numericfmt>` (verbatim format string, both directions);
/// - `%HI`/`%LO` declared array bounds → XML `<value lbound/ubound>` (the two
///   flavors use the same `[n]`/`[a][b]` bracket syntax; 4039 of 4052 corpus
///   INI arrays declare `%HI` equal to the stored element count, and the
///   nonzero-`%LO` arrays — `ColumnList`, indices 1..2 — carry their low bound
///   through verbatim);
/// - every retained INI directive attribute (`%FLG`, `%INSTFLG`, `%INSTOVRD`,
///   `%HI`, `%LO`, `%EPTYPE`, `%COMMENT`, `%NAME` enum labels) rides on the
///   XML property element under the [ConvKey.directiveAttrPrefix] rename
///   (`%FLG` → `x-FLG`), because `%` is not a legal XML attribute-name
///   character (`package:xml` rejects it). [SeqProperty.directiveAttribute]
///   reads both spellings, so the typed lenses (flags, bounds, comments) work
///   identically on converted models;
/// - header fields: the INI `[__Header__]` `Type`/`ProductName`/`Version` and
///   the XML root `type`/`productname`/`fileversion` share one value space
///   (`Version` stamps 127–1022 across both corpora) and map across directly.
///
/// ## What crosses as a reserved record (corpus-proven flavor-unique)
///
/// - INI `[EXTDATA, path, KIND]` sections (kinds `STRUCT`/`CLUST`/`DNSTRUCT`/
///   `BLVCLUSTER`, entries like `DataVersion = 1`) and XML `<extdata …/>`
///   elements (attribute keysets like `controllername`/`exclude`/
///   `packingoption`) are per-adapter metadata in visibly DIFFERENT encodings;
///   no corpus pair proves them interchangeable, so each crosses verbatim in
///   its own reserved form instead of being fabricated into the other;
/// - the INI section skeleton (order/explicitness/quoting) — see above;
/// - XML `xsi:type`, `xmlns` declarations, typedef wrapper attributes and
///   `<protected>` blobs — carried verbatim in the reserved INI directives;
/// - the INI typedef-metadata directives (`%LOCATION` / `%ROOT_TYPE` /
///   `%TIMESTAMP` / `%VERSION` / `%TYPELASTMOD` / `%MINPRODVER` / `%TYPE_FLG`
///   / `%ALWAYS_SAVE` / `%ATTRIBUTES` / bare `%EXTDATA`) cross losslessly
///   inside the channel. Their NAME correspondence to the XML typedef
///   attributes (`isroottypedef`/`timestamp`/`typeversion`/…) is suggestive
///   but unproven — the corpus has no INI↔XML twin of one file — so they are
///   not yet translated natively.
///   TODO: revisit if a cross-flavor INI twin ever lands in the corpus.
///
/// ## Binary hops
///
/// The binary `TOF1` reader yields an explicitly **partial** model (decoded
/// sequence/step/type surface only). [binaryToXmlSeqFile] converts exactly
/// that decoded surface, stamping the result with a
/// [ConvKey.partialDecodeAttr] root attribute so the output can never pass as
/// a complete file; there is deliberately NO binary writer, and
/// [xmlToIniSeqFile] refuses binary-flavor models directly (convert via
/// [binaryToXmlSeqFile], which keeps the partial marking). Loops through the
/// binary hop retain exactly the decoded surface (gated over all 297 corpus
/// binaries — every one currently inflates and converts; a body that does not
/// inflate refuses with [FormatException] at parse, never fabricating
/// output).
library;

import 'dart:convert';

import 'seq_file.dart';
import 'seq_format.dart';
import 'seq_ini.dart';
import 'seq_property.dart';
import 'seq_write_ini.dart';

/// The reserved names the cross-flavor converters write and read back. One
/// documented catalog (per the repo's magic-constant rule); everything here is
/// synthesized by THIS module — none of these keys occur in the corpus
/// (corpus-probed: INI directive heads are `%NAME %FLG %HI %LO %TYPE %EPTYPE
/// %INSTFLG %INSTOVRD %COMMENT %NUMFMT %EXTDATA %ATTRIBUTES %LOCATION
/// %ROOT_TYPE %TIMESTAMP %VERSION %TYPELASTMOD %MINPRODVER %TYPE_FLG
/// %ALWAYS_SAVE %[i]…`, and the 16 XML attribute names plus the 8 INI header
/// keys contain nothing starting `x-` or `%X`).
abstract final class ConvKey {
  // ---- XML side (must be legal XML names; `%` is not) ----

  /// Prefix replacing the `%` of a directive attribute when a property tree is
  /// serialized as XML (`%FLG` → `x-FLG`): `package:xml` rejects `%` in
  /// attribute names. The rename is bijective (`x-` + rest ↔ `%` + rest) and
  /// [SeqProperty.directiveAttribute] resolves both spellings. Aliased to the
  /// shared [directiveXmlPrefix] so the reader and writer agree on one constant.
  static const directiveAttrPrefix = directiveXmlPrefix;

  /// The reserved `Data` sub-property carrying an INI file's serialization
  /// state (header fields, line terminator, every section with its ordered
  /// verbatim entries). [xmlToIniSeqFile] rebuilds the exact [IniSeqFile]
  /// from it.
  static const iniChannel = 'x-ini-source';

  /// The [iniChannel] child holding the `[__Header__]` entries (one leaf per
  /// field, verbatim raw values, document order).
  static const iniChannelHeader = 'header';

  /// The [iniChannel] child holding the section list (one node per section,
  /// document order; entries as verbatim leaves).
  static const iniChannelSections = 'sections';

  /// Attribute on [iniChannel] recording a `\r\n` line terminator (value
  /// `crlf`); absent for `\n` (corpus: 44 LF INI files, one CRLF).
  static const iniEolAttr = 'eol';

  /// Value of [iniEolAttr] for a CRLF-terminated source file.
  static const iniEolCrlf = 'crlf';

  /// Attribute on a channel section node: `def` for a `[DEF, path]` section,
  /// `val` for a value section (an `[EXTDATA, …]` section is `val` plus
  /// [iniExtAttr]).
  static const iniKindAttr = 'kind';

  /// [iniKindAttr] value for a `[DEF, path]` section.
  static const iniKindDef = 'def';

  /// [iniKindAttr] value for a value section.
  static const iniKindVal = 'val';

  /// Attribute on a channel section node holding an `[EXTDATA, path, KIND]`
  /// section's kind token, verbatim.
  static const iniExtAttr = 'ext';

  /// Root attribute stamped by [binaryToXmlSeqFile]: the model came from the
  /// PARTIAL binary decoder and the output is the decoded surface only —
  /// never a complete file.
  static const partialDecodeAttr = 'x-partial-decode';

  /// [partialDecodeAttr] value for the binary `TOF1` decoder.
  static const partialDecodeBinary = 'binary';

  // ---- INI side (reserved `%X*` header keys / directives / paths) ----

  /// Header marker: this INI file was synthesized from an XML-flavor model by
  /// [xmlToIniSeqFile] and [iniToXmlSeqFile] must invert it rather than
  /// decode it as a native INI.
  static const hdrMarker = '%XSEQ';

  /// Header key holding the armored header trio (`t`/`p`/`v` →
  /// type/productname/fileversion; a key is absent when the field is null).
  static const hdrTrio = '%XHDR';

  /// Header key holding the armored ordered [SeqFile.rootAttributes] map;
  /// absent when the model carries none (null).
  static const hdrRootAttrs = '%XROOTA';

  /// Header key recording a `\r\n` XML line terminator ([SeqFile.newline];
  /// value [iniEolCrlf]); absent for `\n` — the mirror of [iniEolAttr] for
  /// the opposite direction (corpus: 36 LF XML files, 6 CRLF).
  static const hdrEol = '%XEOL';

  /// Header key marking the typelist shape: `1` = [SeqFile.typelistEntries]
  /// was non-null (rebuilt as-is, empty included), `2` = entries were
  /// synthesized from a bare [SeqFile.types] list (rebuilt with
  /// `typelistEntries` null); absent = no typelist at all.
  static const hdrTypelist = '%XTL';

  /// [hdrTypelist] value for a real (non-null) entry list.
  static const typelistReal = '1';

  /// [hdrTypelist] value for a list synthesized from bare roots.
  static const typelistFromTypes = '2';

  /// Section path listing the typelist entries in document order.
  static const typesPath = '%XTYPES';

  /// Scoped directive in [typesPath]: a typedef wrapper's armored ordered
  /// attribute map, keyed by the typedef's section path.
  static const typeAttrs = '%XT';

  /// Scoped directive in [typesPath]: a `<protected>` blob, armored, keyed by
  /// its position in the entry list.
  static const typeProtected = '%XP';

  /// The section path of the data root (`SequenceFileData`) — the same `SF`
  /// alias every corpus INI declares under `[DEF, %OBJROOT]`.
  static const dataPath = 'SF';

  /// The root-objects alias section path ([dataPath] is declared here).
  static const objRootPath = '%OBJROOT';

  /// Bare directive: the node's armored [SeqProperty.name] (always present on
  /// every emitted node — the anchor the rebuilder dereferences).
  static const nodeName = '%XNM';

  /// Bare directive: the node's armored [SeqProperty.xmlTag]; absent when the
  /// model's tag is null.
  static const nodeTag = '%XTAG';

  /// Bare directive: the node's armored ordered attribute map, verbatim
  /// (always present, `""` for an attribute-less node).
  static const nodeAttrs = '%XA';

  /// Bare directive: [SeqProperty.className] when it differs from the
  /// attribute-derived value (nullable-encoded); absent otherwise. Genuine
  /// XML parses never need it (the parser derives `className` from
  /// `classname`); it covers hand-built models.
  static const nodeClassName = '%XCN';

  /// Bare directive: [SeqProperty.typeName] when it differs from the
  /// attribute-derived value (nullable-encoded); absent otherwise.
  static const nodeTypeName = '%XTN';

  /// Bare directive: the armored ordered `<value>` attribute map
  /// ([SeqProperty.valueAttributes]); absent when empty.
  static const nodeValueAttrs = '%XV';

  /// Bare directive: the stored array length (bare integer); present exactly
  /// when [SeqProperty.array] is non-null (0 for an empty array — the
  /// null-vs-empty distinction is real: `<value ubound='[]'/>`).
  static const nodeArrayLength = '%XN';

  /// Scoped directive: stored array element `i` is a SCALAR element — the
  /// armored scalar text. An element without this directive is an object
  /// element with its own `path[i]` sections.
  static const nodeScalarElem = '%XE';

  /// Scoped directive: scalar element `i`'s armored attribute map (e.g. the
  /// sparse-array `arrayindex`); absent when the element has none.
  static const nodeScalarElemAttrs = '%XEA';

  /// Bare directive (value `1`): the array carries an `<elemproto>`; its tree
  /// is emitted under the [elemProtoSegment] child path.
  static const nodeElemProto = '%XEP';

  /// Reserved path segment for an `<elemproto>` subtree (`path.%EP`).
  static const elemProtoSegment = '%EP';

  /// Bare directive: the node's own armored scalar — used for parentless
  /// nodes (the data root, typedef roots, object array elements, elemproto
  /// roots) and for a scalar that cannot ride the parent section natively
  /// (non-Latin-1). A child scalar otherwise rides its parent's value section
  /// as a native quoted `seg = "…"` entry.
  static const nodeScalar = '%XSCA';

  /// The NATIVE numericfmt directive (`%NUMFMT = "%#x"` — 530 corpus lines,
  /// all bare own-section): `<numericfmt>` crosses under its real INI name.
  static const numericFmt = '%NUMFMT';

  /// Bare directive: armored fallback for a `<numericfmt>` whose text cannot
  /// be written as a native Latin-1 quoted value (none in the corpus;
  /// defensive).
  static const numericFmtArmored = '%XNFA';

  /// Bare directive: the node's armored `<comment>` element text
  /// ([SeqProperty.xmlComment]); absent when the property carries none.
  /// Reserved (armored) rather than folded into the native INI `%COMMENT`
  /// directive: no corpus twin proves the two encodings are the same fact.
  static const nodeComment = '%XCMT';

  /// Scoped directive: `<extdata>` element `j`'s armored ordered attribute
  /// map, keyed by position.
  static const nodeExtData = '%XX';
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Converts a parsed legacy INI `.seq` to an XML-flavor [SeqFile] with 100%
/// information retention.
///
/// For a native INI file the result is a writable XML model
/// ([writeSeqFileXml]-serializable, reparse-stable) whose `Data` tree is the
/// fully decoded INI property tree (inheritance-expanded — the shape the XML
/// flavor materializes natively), whose typelist is the decoded `[%TYPES]`
/// list, and whose header/root attributes carry the INI header trio. The INI
/// serialization state rides in the reserved [ConvKey.iniChannel] subtree so
/// that [xmlToIniSeqFile] reproduces the original file byte-exactly (45/45
/// corpus INI files — see `test/seq_convert_corpus_test.dart`).
///
/// For an INI produced by [xmlToIniSeqFile] (recognized by the
/// [ConvKey.hdrMarker] header field) this is the exact inverse: it rebuilds
/// the original XML-flavor model deep-equal.
///
/// Throws [FormatException] when the INI has no reconstructable data root
/// (mirroring [parseIniSeqFile]).
SeqFile iniToXmlSeqFile(IniSeqFile doc) {
  if (doc.headerFields.containsKey(ConvKey.hdrMarker)) return _xmlFromReservedIni(doc);
  final data = iniDataTree(doc);
  if (data == null) {
    throw const FormatException('INI .seq has no reconstructable %OBJROOT data root (not yet decoded)');
  }
  final memo = Map<SeqProperty, SeqProperty>.identity();
  final types = [for (final type in iniTypes(doc)) _xmlReady(type, memo)];
  // null-vs-empty typelist mirrors the section's presence, like XML's
  // <typelist> presence.
  final hasTypes = doc.sections.any((s) => !s.isDef && !s.isExtData && s.path == '%TYPES');
  final readyData = _xmlReady(data, memo);
  final header = doc.header;
  return SeqFile(
    header: SeqFileHeader(
      format: SeqFormat.xml,
      fileType: header.fileType,
      productName: header.productName,
      fileVersion: header.fileVersion,
    ),
    types: types,
    typelistEntries: hasTypes ? [for (final type in types) SeqTypelistEntry(root: type)] : null,
    rootAttributes: {
      if (header.fileType != null) 'type': header.fileType!,
      if (header.fileVersion != null) 'fileversion': header.fileVersion!,
      if (header.productName != null) 'productname': header.productName!,
    },
    data: readyData.copyWith(subProps: [...readyData.subProps, _iniChannelNode(doc)]),
  );
}

/// Converts an XML-flavor [SeqFile] to a legacy-INI-encoded [IniSeqFile] with
/// 100% information retention.
///
/// For a model carrying the [ConvKey.iniChannel] subtree (i.e. one produced by
/// [iniToXmlSeqFile] from a native INI) this rebuilds the ORIGINAL
/// [IniSeqFile] verbatim — [writeIniSeq] then reproduces the original bytes
/// exactly.
///
/// Otherwise it converts forward: the whole property tree is emitted as real
/// `[DEF, path]`/`[path]` sections (every member written explicitly — the INI
/// flavor accepts fully-materialized trees), scalars as native quoted values,
/// `<numericfmt>` as the native `%NUMFMT` directive, and every XML-only fact
/// (tags, verbatim ordered attribute maps, value attributes, elemproto trees,
/// extdata maps, typedef wrappers, protected blobs, root attributes) under
/// the reserved `%X*` keys cataloged in [ConvKey]. [iniToXmlSeqFile] inverts
/// the encoding deep-equal (42/42 corpus XML files byte-exactly through the
/// XML writer).
///
/// Throws [ArgumentError] for a binary- or INI-flavor [SeqFile]: those models
/// are PARTIAL decodes and converting them as if complete would fabricate a
/// file. Binary models convert via [binaryToXmlSeqFile], which marks the
/// output partial explicitly.
IniSeqFile xmlToIniSeqFile(SeqFile file) {
  final channel = file.data.prop(ConvKey.iniChannel);
  if (channel != null && _isIniChannel(channel)) return _iniFromChannel(channel);
  if (file.header.format != SeqFormat.xml) {
    throw ArgumentError(
      'xmlToIniSeqFile converts XML-flavor SeqFiles only; this model came from '
      '${file.header.format} (a partial decode — convert binary models via '
      'binaryToXmlSeqFile, which marks the output partial)',
    );
  }
  return _iniFromXml(file);
}

/// Lifts the PARTIAL binary-decode model produced by `parseBinarySeqFile`
/// into a writable XML-flavor [SeqFile] covering exactly the decoded surface:
/// the sequence/step/group skeleton, recovered type records, decoded
/// sequence-record subprops, step `TS` subprops and module bindings — nothing
/// more. The output root carries [ConvKey.partialDecodeAttr] so it can never
/// pass as a complete sequence file, and the `%BIN*` synthetic markers ride
/// along under the `x-BIN*` rename. Loops through this hop
/// (XML ↔ INI included) retain that surface deep-equal (corpus-gated over all
/// 297 corpus binaries).
///
/// Throws [ArgumentError] when [file] is not a binary-flavor model.
SeqFile binaryToXmlSeqFile(SeqFile file) {
  if (file.header.format != SeqFormat.binary) {
    throw ArgumentError('binaryToXmlSeqFile lifts binary-flavor (partial) models only; got ${file.header.format}');
  }
  final memo = Map<SeqProperty, SeqProperty>.identity();
  final types = [for (final type in file.types) _xmlReady(type, memo)];
  final header = file.header;
  return SeqFile(
    header: SeqFileHeader(
      format: SeqFormat.xml,
      fileType: header.fileType,
      productName: header.productName,
    ),
    types: types,
    typelistEntries: [for (final type in types) SeqTypelistEntry(root: type)],
    rootAttributes: {
      if (header.fileType != null) 'type': header.fileType!,
      if (header.productName != null) 'productname': header.productName!,
      ConvKey.partialDecodeAttr: ConvKey.partialDecodeBinary,
    },
    data: _xmlReady(file.data, memo),
  );
}

/// [binaryToXmlSeqFile] chained into [xmlToIniSeqFile]: the decoded binary
/// surface as a legacy-INI-encoded file, still marked partial (the
/// [ConvKey.partialDecodeAttr] root attribute rides in the reserved header
/// record).
IniSeqFile binaryToIniSeqFile(SeqFile file) => xmlToIniSeqFile(binaryToXmlSeqFile(file));

// ---------------------------------------------------------------------------
// Armor codec: arbitrary text as INI-safe printable ASCII
// ---------------------------------------------------------------------------

/// Percent-encodes [text] (as UTF-8 bytes) into the INI-safe alphabet: every
/// byte outside printable ASCII `0x21..0x7E`, plus `%` `&` `=` `"` `\` and the
/// space, becomes `%HH`. The result contains no whitespace, quotes, escapes,
/// or `=` — so a quoted `"…"` raw value built from it survives the INI
/// writer/parser verbatim (no ` = ` separator ambiguity, no escape
/// processing, no Latin-1 range errors, continuation splitting is
/// raw-concatenation-safe) and any Unicode content round-trips.
String armorText(String text) {
  const hex = '0123456789ABCDEF';
  final sb = StringBuffer();
  for (final byte in utf8.encode(text)) {
    final safe =
        byte > 0x20 &&
        byte <= 0x7E &&
        byte != 0x25 /* % */ &&
        byte != 0x26 /* & */ &&
        byte != 0x3D /* = */ &&
        byte != 0x22 /* " */ &&
        byte != 0x5C /* \ */;
    if (safe) {
      sb.writeCharCode(byte);
    } else {
      sb
        ..write('%')
        ..write(hex[byte >> 4])
        ..write(hex[byte & 0xF]);
    }
  }
  return sb.toString();
}

/// Inverse of [armorText]. Tolerates a malformed trailing `%H`/`%` (kept
/// verbatim — unreachable from [armorText] output, defensive only).
String unarmorText(String armored) {
  final bytes = <int>[];
  for (var i = 0; i < armored.length; i++) {
    final c = armored.codeUnitAt(i);
    if (c == 0x25 && i + 2 < armored.length) {
      final hi = _hexDigit(armored.codeUnitAt(i + 1));
      final lo = _hexDigit(armored.codeUnitAt(i + 2));
      if (hi >= 0 && lo >= 0) {
        bytes.add((hi << 4) | lo);
        i += 2;
        continue;
      }
    }
    bytes.add(c);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

int _hexDigit(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  return -1;
}

/// An ordered string map as one armored token: `k=v` pairs joined with `&`
/// (both sides [armorText]-armored, so neither separator can occur inside).
/// The empty map encodes as the empty string.
String _armorMap(Map<String, String> map) =>
    [for (final e in map.entries) '${armorText(e.key)}=${armorText(e.value)}'].join('&');

/// Inverse of [_armorMap], preserving order.
Map<String, String> _unarmorMap(String encoded) {
  if (encoded.isEmpty) return {};
  final out = <String, String>{};
  for (final pair in encoded.split('&')) {
    final eq = pair.indexOf('=');
    if (eq < 0) {
      out[unarmorText(pair)] = '';
    } else {
      out[unarmorText(pair.substring(0, eq))] = unarmorText(pair.substring(eq + 1));
    }
  }
  return out;
}

/// A nullable string as an armored token: `0` = null, `1` + armored text =
/// value (so null, `''`, and `'0'` stay distinct).
String _armorNullable(String? value) => value == null ? '0' : '1${armorText(value)}';

String? _unarmorNullable(String encoded) => encoded.startsWith('1') ? unarmorText(encoded.substring(1)) : null;

/// Wraps an armored token as a quoted INI raw value. The armored alphabet
/// contains no quote/backslash, so the INI unescape is a no-op and
/// `unquoteIni` recovers the token exactly.
String _quotedRaw(String armoredToken) => '"$armoredToken"';

/// True when [text] can be written as a native `escapeIniQuoted` value: all
/// code units are Latin-1 (the INI writer's byte encoding). Everything the
/// escape handles (`\` `"` newline/tab/CR) is Latin-1-safe; only supplemental
/// characters force the armored fallback.
bool _latin1Clean(String text) {
  for (final c in text.codeUnits) {
    if (c > 0xFF) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// XML-side decoration: make a synthesized (INI/binary) tree XML-serializable
// ---------------------------------------------------------------------------

/// A tag-safe XML name: what [writeSeqFileXml] can emit as an element tag and
/// `parseSeqFile` reads back as the same local name (no colon — a prefix
/// would change `name.local` on reparse).
final _validTag = RegExp(r'^[A-Za-z_][A-Za-z0-9._\-]*$');

/// The placeholder tag TestStand itself uses when a property's name lives in
/// the `name` attribute (`buildProperty` maps it to `attrs['name'] ?? ''`).
const _nameInAttributeTag = '_NAME_IN_ATTRIBUTE_';

/// The element tag for a property named [name]: the name itself when it is a
/// legal tag, else the [_nameInAttributeTag] placeholder. A name equal to the
/// placeholder itself must also take the attribute form (a bare placeholder
/// tag reads back as the empty name).
String _tagFor(String name) => _validTag.hasMatch(name) && name != _nameInAttributeTag ? name : _nameInAttributeTag;

/// The `name` attribute [_tagFor]'s choice requires: present exactly when the
/// tag is the placeholder AND the name is non-empty (a placeholder with no
/// `name` attribute reads back as `''`, matching an empty name).
Map<String, String> _nameAttrs(String name) => {
  if (_tagFor(name) == _nameInAttributeTag && name.isNotEmpty) 'name': name,
};

/// Rewrites a synthesized (INI- or binary-decoded) property tree into an
/// XML-serializable one that survives `parseSeqFile(writeSeqFileXml(…))`
/// deep-equal:
///
/// - every node gets an [SeqProperty.xmlTag] (its name, or the
///   `_NAME_IN_ATTRIBUTE_` placeholder + `name` attribute — the writer treats
///   a tag-less node as a bare scalar `<value>` and would DROP object
///   children);
/// - the attribute map is rebuilt parser-consistent: `name`/`classname`/
///   `typename` first (so the reparse derives the same name/className/
///   typeName), then the source attributes with every `%` directive renamed
///   under [ConvKey.directiveAttrPrefix] (`%` is illegal in XML attribute
///   names);
/// - a `%NUMFMT` attribute (retained by the INI reader) crosses natively into
///   [SeqProperty.numericFormat];
/// - an array gets `<value>` bounds: `lbound` from `%LO` (verbatim — nonzero
///   low bounds are corpus-real) or `[0]`, `ubound` from `%HI` (verbatim, the
///   same bracket syntax both flavors use) or the stored count (`[]` when
///   empty) — without them the reparse would not recognize an array.
///
/// Shared subtrees (the INI builder's inheritance cache aliases one instance
/// under many parents) decorate once via the identity [memo], preserving the
/// DAG shape and cost.
SeqProperty _xmlReady(SeqProperty p, Map<SeqProperty, SeqProperty> memo) {
  final done = memo[p];
  if (done != null) return done;

  final attrs = <String, String>{
    ..._nameAttrs(p.name),
    if (p.className != null) 'classname': p.className!,
    if (p.typeName != null) 'typename': p.typeName!,
  };
  var numericFormat = p.numericFormat;
  p.attributes.forEach((key, value) {
    if (key == ConvKey.numericFmt && numericFormat == null) {
      numericFormat = value;
      return;
    }
    attrs[key.startsWith('%') ? '${ConvKey.directiveAttrPrefix}${key.substring(1)}' : key] = value;
  });

  final array = p.array;
  var valueAttrs = p.valueAttributes;
  if (array != null && !valueAttrs.containsKey('lbound') && !valueAttrs.containsKey('ubound')) {
    final loRaw = p.attributes['%LO'];
    // The high index is anchored at the low bound: `hi - lo + 1 == length`, so
    // a nonzero `%LO` (corpus-real, e.g. `ColumnList` indexed 1..2) shifts the
    // fallback `%HI` by that low bound rather than assuming a 0 base.
    final lo = loRaw == null ? 0 : (int.tryParse(RegExp(r'-?\d+').firstMatch(loRaw)?.group(0) ?? '') ?? 0);
    valueAttrs = {
      'lbound': loRaw ?? '[0]',
      'ubound': p.attributes['%HI'] ?? (array.isEmpty ? '[]' : '[${lo + array.length - 1}]'),
    };
  }

  final out = SeqProperty(
    name: p.name,
    xmlTag: p.xmlTag ?? _tagFor(p.name),
    className: p.className,
    typeName: p.typeName,
    attributes: attrs,
    scalar: p.scalar,
    array: array == null ? null : [for (final element in array) _xmlReady(element, memo)],
    subProps: [for (final child in p.subProps) _xmlReady(child, memo)],
    valueAttributes: valueAttrs,
    elemProto: p.elemProto == null ? null : _xmlReady(p.elemProto!, memo),
    extData: p.extData,
    numericFormat: numericFormat,
    xmlComment: p.xmlComment,
  );
  memo[p] = out;
  return out;
}

// ---------------------------------------------------------------------------
// INI fidelity channel (INI → XML → INI, byte-exact)
// ---------------------------------------------------------------------------

/// One verbatim `key = rawValue` entry as a channel leaf. The raw value is a
/// single Latin-1 line (continuations already rejoined), which XML text
/// content carries verbatim.
SeqProperty _channelEntry(IniEntry entry) => SeqProperty(
  name: entry.key,
  xmlTag: _tagFor(entry.key),
  attributes: _nameAttrs(entry.key),
  scalar: entry.rawValue,
);

/// The reserved [ConvKey.iniChannel] subtree recording [doc]'s serialization
/// state verbatim: header entries and every section (kind, path, ordered
/// entries) in document order, plus the line terminator.
SeqProperty _iniChannelNode(IniSeqFile doc) => SeqProperty(
  name: ConvKey.iniChannel,
  xmlTag: ConvKey.iniChannel,
  attributes: {if (doc.lineTerminator == '\r\n') ConvKey.iniEolAttr: ConvKey.iniEolCrlf},
  subProps: [
    SeqProperty(
      name: ConvKey.iniChannelHeader,
      xmlTag: ConvKey.iniChannelHeader,
      subProps: [
        for (final field in doc.headerFields.entries) _channelEntry(IniEntry(field.key, field.value)),
      ],
    ),
    SeqProperty(
      name: ConvKey.iniChannelSections,
      xmlTag: ConvKey.iniChannelSections,
      subProps: [
        for (final section in doc.sections)
          SeqProperty(
            name: section.path,
            xmlTag: _tagFor(section.path),
            attributes: {
              ..._nameAttrs(section.path),
              ConvKey.iniKindAttr: section.isDef ? ConvKey.iniKindDef : ConvKey.iniKindVal,
              if (section.extDataKind != null) ConvKey.iniExtAttr: section.extDataKind!,
            },
            subProps: [for (final entry in section.entries) _channelEntry(entry)],
          ),
      ],
    ),
  ],
);

/// Whether a `Data` child named [ConvKey.iniChannel] actually has the
/// structural shape [_iniChannelNode] emits — a [ConvKey.iniChannelHeader] and
/// a [ConvKey.iniChannelSections] child. Guards against a genuine model member
/// that merely shares the reserved name (which would otherwise route into the
/// channel inverse and yield an empty INI), symmetric with the INI → XML side's
/// [ConvKey.hdrMarker] header marker.
bool _isIniChannel(SeqProperty channel) =>
    channel.prop(ConvKey.iniChannelHeader) != null && channel.prop(ConvKey.iniChannelSections) != null;

/// Rebuilds the exact [IniSeqFile] from a [ConvKey.iniChannel] subtree — the
/// inverse of [_iniChannelNode].
IniSeqFile _iniFromChannel(SeqProperty channel) {
  final headerFields = <String, String>{
    for (final e in channel.prop(ConvKey.iniChannelHeader)?.subProps ?? const <SeqProperty>[]) e.name: e.scalar ?? '',
  };
  return IniSeqFile(
    header: iniHeaderFromFields(headerFields),
    headerFields: headerFields,
    lineTerminator: channel.attributes[ConvKey.iniEolAttr] == ConvKey.iniEolCrlf ? '\r\n' : '\n',
    sections: [
      for (final s in channel.prop(ConvKey.iniChannelSections)?.subProps ?? const <SeqProperty>[])
        IniSection(
          isDef: s.attributes[ConvKey.iniKindAttr] == ConvKey.iniKindDef,
          path: s.name,
          extDataKind: s.attributes[ConvKey.iniExtAttr],
          entries: [for (final e in s.subProps) IniEntry(e.name, e.scalar ?? '')],
        ),
    ],
  );
}

// ---------------------------------------------------------------------------
// XML → INI forward emission
// ---------------------------------------------------------------------------

/// A bare INI token safe as a member key / path segment: never parses as a
/// directive, never contains path structure (`.`/`[`/`]`), commas (the
/// EXTDATA header separator), spaces (` = ` / ` LineNNNN` ambiguity), or
/// non-ASCII.
final _bareToken = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// A cosmetic native `member = Type` declaration value for [p] (bare when
/// safe, quoted otherwise, `Obj` when nothing usable) — the rebuilder reads
/// the authoritative [ConvKey.nodeAttrs] record instead, so this only has to
/// be write/reparse-stable.
String _declText(SeqProperty p) {
  final typeName = p.typeName;
  if (typeName != null && _latin1Clean(typeName)) return escapeIniQuoted('TYPE, $typeName');
  final className = p.className;
  if (className != null && _bareToken.hasMatch(className)) return className;
  if (className != null && _latin1Clean(className)) return escapeIniQuoted(className);
  return 'Obj';
}

/// Assigns each child of a node a unique path segment: its own name when it
/// is a safe [_bareToken] not already taken, else a deterministic `C<i>`
/// fallback (suffix-uniquified). Segments are opaque to the rebuilder — real
/// names travel in each child's [ConvKey.nodeName] record — so the scheme
/// only has to be collision-free and INI-safe.
List<String> _childSegments(List<SeqProperty> children) {
  final used = <String>{};
  final segs = <String>[];
  for (var i = 0; i < children.length; i++) {
    final name = children[i].name;
    var seg = _bareToken.hasMatch(name) ? name : 'C$i';
    while (!used.add(seg)) {
      seg = '${seg}_';
    }
    segs.add(seg);
  }
  return segs;
}

/// Whether a stored array element serializes as a bare scalar `<value>`
/// (matching the writer's tag-less rule) rather than an object element with
/// its own sections. A named element takes the object form instead, so its
/// name survives the round-trip (the scalar-element encoding carries only the
/// element's text and attributes, never a name); native XML scalar elements
/// are always name-less, so this leaves them on the scalar path.
bool _isScalarElement(SeqProperty element) =>
    element.xmlTag == null && element.name.isEmpty && element.subProps.isEmpty && element.array == null;

/// Emits [p]'s sections at [path] in preorder: `[DEF, path]` (child
/// declarations, one per sub-property, in order), then `[path]` (the reserved
/// per-node record + native scalar entries for its children), then the
/// children/elements/elemproto subtrees. [scalarOnParent] is true when the
/// caller already wrote this node's scalar on ITS value section.
void _emitNode(SeqProperty p, String path, List<IniSection> out, {required bool scalarOnParent}) {
  final children = p.subProps;
  final segs = _childSegments(children);

  final valueEntries = <IniEntry>[
    IniEntry(ConvKey.nodeName, _quotedRaw(armorText(p.name))),
    if (p.xmlTag != null) IniEntry(ConvKey.nodeTag, _quotedRaw(armorText(p.xmlTag!))),
    IniEntry(ConvKey.nodeAttrs, _quotedRaw(_armorMap(p.attributes))),
    if (p.className != p.attributes['classname'])
      IniEntry(ConvKey.nodeClassName, _quotedRaw(_armorNullable(p.className))),
    if (p.typeName != (p.attributes['typename'] ?? p.attributes['xsi:type']))
      IniEntry(ConvKey.nodeTypeName, _quotedRaw(_armorNullable(p.typeName))),
    if (p.valueAttributes.isNotEmpty) IniEntry(ConvKey.nodeValueAttrs, _quotedRaw(_armorMap(p.valueAttributes))),
  ];
  final scalar = p.scalar;
  if (scalar != null && !scalarOnParent) {
    valueEntries.add(IniEntry(ConvKey.nodeScalar, _quotedRaw(armorText(scalar))));
  }
  final numericFormat = p.numericFormat;
  if (numericFormat != null) {
    valueEntries.add(
      _latin1Clean(numericFormat)
          ? IniEntry(ConvKey.numericFmt, escapeIniQuoted(numericFormat))
          : IniEntry(ConvKey.numericFmtArmored, _quotedRaw(armorText(numericFormat))),
    );
  }
  if (p.xmlComment != null) {
    valueEntries.add(IniEntry(ConvKey.nodeComment, _quotedRaw(armorText(p.xmlComment!))));
  }
  final array = p.array;
  if (array != null) {
    valueEntries.add(IniEntry(ConvKey.nodeArrayLength, '${array.length}'));
    for (var i = 0; i < array.length; i++) {
      final element = array[i];
      if (_isScalarElement(element)) {
        valueEntries.add(IniEntry('${ConvKey.nodeScalarElem}: $i', _quotedRaw(armorText(element.scalar ?? ''))));
        if (element.attributes.isNotEmpty) {
          valueEntries.add(IniEntry('${ConvKey.nodeScalarElemAttrs}: $i', _quotedRaw(_armorMap(element.attributes))));
        }
      }
    }
  }
  if (p.elemProto != null) valueEntries.add(const IniEntry(ConvKey.nodeElemProto, '1'));
  for (var j = 0; j < p.extData.length; j++) {
    valueEntries.add(IniEntry('${ConvKey.nodeExtData}: $j', _quotedRaw(_armorMap(p.extData[j]))));
  }

  // Native scalar entries for the children (quoted, exact via the corpus
  // escape set); a non-Latin-1 scalar falls back to the child's own armored
  // record instead.
  final scalarOnParentByChild = List<bool>.filled(children.length, false);
  for (var i = 0; i < children.length; i++) {
    final childScalar = children[i].scalar;
    if (childScalar != null && _latin1Clean(childScalar)) {
      valueEntries.add(IniEntry(segs[i], escapeIniQuoted(childScalar)));
      scalarOnParentByChild[i] = true;
    }
  }

  if (children.isNotEmpty) {
    out.add(
      IniSection(
        isDef: true,
        path: path,
        entries: [for (var i = 0; i < children.length; i++) IniEntry(segs[i], _declText(children[i]))],
      ),
    );
  }
  out.add(IniSection(isDef: false, path: path, entries: valueEntries));

  for (var i = 0; i < children.length; i++) {
    _emitNode(children[i], '$path.${segs[i]}', out, scalarOnParent: scalarOnParentByChild[i]);
  }
  if (array != null) {
    for (var i = 0; i < array.length; i++) {
      if (!_isScalarElement(array[i])) {
        _emitNode(array[i], '$path[$i]', out, scalarOnParent: false);
      }
    }
  }
  if (p.elemProto != null) {
    _emitNode(p.elemProto!, '$path.${ConvKey.elemProtoSegment}', out, scalarOnParent: false);
  }
}

/// Forward XML → INI conversion (no fidelity channel present): see
/// [xmlToIniSeqFile].
IniSeqFile _iniFromXml(SeqFile file) {
  final header = file.header;
  // Typelist shape: real entries, entries synthesized from bare roots
  // (mirroring writeSeqFileXml's fallback), or none.
  final entries =
      file.typelistEntries ??
      (file.types.isNotEmpty ? [for (final type in file.types) SeqTypelistEntry(root: type)] : null);
  final typelistMark = file.typelistEntries != null
      ? ConvKey.typelistReal
      : (file.types.isNotEmpty ? ConvKey.typelistFromTypes : null);

  final headerFields = <String, String>{
    // Native header trio for flavor/readability; the armored trio below is
    // what the rebuilder reads (exact, null-aware).
    if (header.productName != null && _latin1Clean(header.productName!))
      'ProductName': escapeIniQuoted(header.productName!),
    if (header.fileVersion != null && _bareToken.hasMatch(header.fileVersion!)) 'Version': header.fileVersion!,
    if (header.fileType != null && _latin1Clean(header.fileType!)) 'Type': escapeIniQuoted(header.fileType!),
    ConvKey.hdrMarker: '1',
    ConvKey.hdrTrio: _quotedRaw(
      _armorMap({
        if (header.fileType != null) 't': header.fileType!,
        if (header.productName != null) 'p': header.productName!,
        if (header.fileVersion != null) 'v': header.fileVersion!,
      }),
    ),
    if (file.rootAttributes != null) ConvKey.hdrRootAttrs: _quotedRaw(_armorMap(file.rootAttributes!)),
    if (typelistMark != null) ConvKey.hdrTypelist: typelistMark,
    if (file.newline == '\r\n') ConvKey.hdrEol: ConvKey.iniEolCrlf,
  };

  final sections = <IniSection>[];

  // Root-objects alias, native shape: the data root plus one cosmetic
  // declaration per plaintext type.
  // A path per non-protected entry (protected entries carry no path — they
  // ride the reserved %XP blob), uniquified against every other section path
  // so the root-less `T$i` fallback can never collide with a real bare-named
  // type or the data root.
  final typePaths = <String?>[];
  final usedPaths = <String>{ConvKey.dataPath};
  if (entries != null) {
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].isProtected) {
        typePaths.add(null);
        continue;
      }
      final root = entries[i].root;
      var candidate = (root != null && _bareToken.hasMatch(root.name)) ? root.name : 'T$i';
      while (!usedPaths.add(candidate)) {
        candidate = '${candidate}_';
      }
      typePaths.add(candidate);
    }
  }
  sections.add(
    IniSection(
      isDef: true,
      path: ConvKey.objRootPath,
      entries: [
        const IniEntry(ConvKey.dataPath, 'SequenceFileData'),
        if (entries != null)
          for (var i = 0; i < entries.length; i++)
            if (entries[i].root != null && typePaths[i] != null) IniEntry(typePaths[i]!, _declText(entries[i].root!)),
      ],
    ),
  );

  if (entries != null) {
    sections.add(
      IniSection(
        isDef: false,
        path: ConvKey.typesPath,
        entries: [
          for (var i = 0; i < entries.length; i++)
            if (entries[i].isProtected)
              IniEntry('${ConvKey.typeProtected}: $i', _quotedRaw(armorText(entries[i].protectedData!)))
            else ...[
              IniEntry(
                typePaths[i]!,
                entries[i].root != null && _latin1Clean(entries[i].root!.name)
                    ? escapeIniQuoted(entries[i].root!.name)
                    : '""',
              ),
              IniEntry('${ConvKey.typeAttrs}: ${typePaths[i]!}', _quotedRaw(_armorMap(entries[i].attributes))),
            ],
        ],
      ),
    );
    for (var i = 0; i < entries.length; i++) {
      final root = entries[i].root;
      final typePath = typePaths[i];
      if (root != null && typePath != null) _emitNode(root, typePath, sections, scalarOnParent: false);
    }
  }

  _emitNode(file.data, ConvKey.dataPath, sections, scalarOnParent: false);

  return IniSeqFile(
    header: iniHeaderFromFields(headerFields),
    headerFields: headerFields,
    sections: sections,
  );
}

// ---------------------------------------------------------------------------
// Reserved-INI → XML rebuild (the inverse of _iniFromXml)
// ---------------------------------------------------------------------------

/// Rebuilds the original XML-flavor [SeqFile] from an INI produced by
/// [xmlToIniSeqFile] (detected via [ConvKey.hdrMarker]).
SeqFile _xmlFromReservedIni(IniSeqFile doc) {
  final defs = <String, IniSection>{};
  final vals = <String, IniSection>{};
  for (final section in doc.sections) {
    if (section.isExtData) continue;
    (section.isDef ? defs : vals)[section.path] = section;
  }

  final trio = _unarmorMap(unquoteIni(doc.headerFields[ConvKey.hdrTrio]) ?? '');
  final rootAttrsRaw = doc.headerFields[ConvKey.hdrRootAttrs];

  List<SeqTypelistEntry>? typelistEntries;
  var types = const <SeqProperty>[];
  final typelistMark = doc.headerFields[ConvKey.hdrTypelist];
  if (typelistMark != null) {
    final listSection = vals[ConvKey.typesPath];
    final rebuilt = <SeqTypelistEntry>[];
    for (final entry in listSection?.entries ?? const <IniEntry>[]) {
      if (entry.key.startsWith('${ConvKey.typeProtected}: ')) {
        rebuilt.add(SeqTypelistEntry(protectedData: unarmorText(unquoteIni(entry.rawValue)!)));
      } else if (!entry.isDirective) {
        final path = entry.key;
        rebuilt.add(
          SeqTypelistEntry(
            attributes: _unarmorMap(unquoteIni(listSection!.directives['${ConvKey.typeAttrs}: $path']) ?? ''),
            root: vals.containsKey(path) ? _rebuildNode(path, null, defs, vals) : null,
          ),
        );
      }
    }
    types = [
      for (final entry in rebuilt)
        if (entry.root != null) entry.root!,
    ];
    typelistEntries = typelistMark == ConvKey.typelistReal ? rebuilt : null;
  }

  return SeqFile(
    header: SeqFileHeader(
      format: SeqFormat.xml,
      fileType: trio['t'],
      productName: trio['p'],
      fileVersion: trio['v'],
    ),
    types: types,
    typelistEntries: typelistEntries,
    rootAttributes: rootAttrsRaw == null ? null : _unarmorMap(unquoteIni(rootAttrsRaw)!),
    data: _rebuildNode(ConvKey.dataPath, null, defs, vals),
    newline: doc.headerFields[ConvKey.hdrEol] == ConvKey.iniEolCrlf ? '\r\n' : '\n',
  );
}

/// Rebuilds one property node from its reserved sections. [scalarRaw] is the
/// native quoted scalar the PARENT's value section carried for this node (its
/// own [ConvKey.nodeScalar] record is the fallback).
SeqProperty _rebuildNode(String path, String? scalarRaw, Map<String, IniSection> defs, Map<String, IniSection> vals) {
  final val = vals[path];
  if (val == null) {
    throw FormatException('reserved .seq conversion: missing value section [$path]');
  }
  final dir = val.directives;
  String? armored(String key) {
    final raw = dir[key];
    return raw == null ? null : unarmorText(unquoteIni(raw)!);
  }

  final name = armored(ConvKey.nodeName);
  if (name == null) {
    throw FormatException('reserved .seq conversion: [$path] lacks ${ConvKey.nodeName}');
  }
  final attrs = _unarmorMap(unquoteIni(dir[ConvKey.nodeAttrs]) ?? '');
  var className = attrs['classname'];
  var typeName = attrs['typename'] ?? attrs['xsi:type'];
  final classOverride = dir[ConvKey.nodeClassName];
  if (classOverride != null) className = _unarmorNullable(unquoteIni(classOverride)!);
  final typeOverride = dir[ConvKey.nodeTypeName];
  if (typeOverride != null) typeName = _unarmorNullable(unquoteIni(typeOverride)!);

  final scalar = scalarRaw != null ? unquoteIni(scalarRaw) : armored(ConvKey.nodeScalar);
  final numericFormat = dir.containsKey(ConvKey.numericFmt)
      ? unquoteIni(dir[ConvKey.numericFmt])
      : armored(ConvKey.numericFmtArmored);

  final def = defs[path];
  final subProps = <SeqProperty>[];
  for (final entry in def?.entries ?? const <IniEntry>[]) {
    if (entry.isDirective) continue;
    subProps.add(_rebuildNode('$path.${entry.key}', val.members[entry.key], defs, vals));
  }

  List<SeqProperty>? array;
  final lengthRaw = dir[ConvKey.nodeArrayLength];
  if (lengthRaw != null) {
    final length = int.parse(lengthRaw.trim());
    array = [
      for (var i = 0; i < length; i++)
        if (dir.containsKey('${ConvKey.nodeScalarElem}: $i'))
          SeqProperty(
            name: '',
            scalar: armored('${ConvKey.nodeScalarElem}: $i'),
            attributes: _unarmorMap(unquoteIni(dir['${ConvKey.nodeScalarElemAttrs}: $i']) ?? ''),
          )
        else
          _rebuildNode('$path[$i]', null, defs, vals),
    ];
  }

  final extData = <Map<String, String>>[];
  for (var j = 0; dir.containsKey('${ConvKey.nodeExtData}: $j'); j++) {
    extData.add(_unarmorMap(unquoteIni(dir['${ConvKey.nodeExtData}: $j'])!));
  }

  return SeqProperty(
    name: name,
    xmlTag: armored(ConvKey.nodeTag),
    className: className,
    typeName: typeName,
    attributes: attrs,
    scalar: scalar,
    array: array,
    subProps: subProps,
    valueAttributes: dir.containsKey(ConvKey.nodeValueAttrs)
        ? _unarmorMap(unquoteIni(dir[ConvKey.nodeValueAttrs])!)
        : const {},
    elemProto: dir.containsKey(ConvKey.nodeElemProto)
        ? _rebuildNode('$path.${ConvKey.elemProtoSegment}', null, defs, vals)
        : null,
    extData: extData,
    numericFormat: numericFormat,
    xmlComment: armored(ConvKey.nodeComment),
  );
}
