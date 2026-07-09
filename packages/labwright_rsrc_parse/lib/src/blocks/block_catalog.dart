/// Catalog of LabVIEW RSRC resource-block tags (the 4-char block names in a
/// `.vi`), each mapped to a coarse [ViBlockCategory] so callers can treat a block
/// by *what it is* instead of guessing from its bytes.
///
/// This is the foundation for per-block parsing: today most blocks are still
/// opaque, but classifying them correctly is what stops, e.g., a type-descriptor
/// pool (`VCTP`) or a compiled-code blob (`VICD`) from being mis-read as a
/// record heap. Every entry carries a [BlockConfidence] label (clean-room — we
/// have no NI source); `confirmed` means corpus-verified or self-identifying
/// (a magic number / embedded ASCII), `likely` is strong convention, `tentative`
/// is a best-effort name with the format not yet decoded.
///
/// Coverage: the 81 distinct tags observed across the 7583-VI corpus, plus the
/// remaining tags documented on labviewwiki.org/wiki/Resource_Container that we
/// have not yet seen in a real VI (catalogued as `tentative` with a TODO so the
/// registry is complete). An unknown tag resolves to [ViBlockInfo.unknownFor]
/// rather than throwing.
///
/// This catalog doubles as the **block registry**: each entry's
/// [ViBlockInfo.decoder] names the function that decodes it (grep it to find the
/// file under `lib/src/blocks/`), or is null when no decoder exists yet.
library;

/// Coarse role of a resource block. Drives display and parser dispatch.
enum ViBlockCategory {
  /// `C4`-record bracket-tree heap — the FP/BD object graph. The ONLY blocks that
  /// should get the heap record-walk. Corpus-confirmed set: `FPHb`, `BDHb`,
  /// `FPHc`, `BDHc` (each 100%: a valid `u32` content-length header followed by a
  /// group-open/`C4` lead, across all 7568 VIs that have them).
  recordHeap,

  /// Type descriptors / the VI type pool (`VCTP`) — the table of every data type
  /// the VI uses. Its own `[count][type-record…]` format, NOT a record heap.
  typeInfo,

  /// Compiled machine code (`VICD`) — e.g. an `i386` code image. Opaque to us.
  compiledCode,

  /// Default / run-time data images (`DFDS` default data space, …).
  dataSpace,

  /// Connector-pane / terminal-pattern description (`CONP`, `CPC2`, …).
  connectorPane,

  /// Icon bitmaps (`icl8` 8-bit, `icl4` 4-bit, `ICON` 1-bit mask).
  icon,

  /// Embedded raster/vector images by magic number (`MNGI`=PNG, `WEMF`=Win EMF,
  /// `PICT`=Mac PICT).
  image,

  /// Dependency / link tables (`LIvi`/`LIfp`/`LIbd`/`LIds` — each embeds an ASCII
  /// `LVIN`/`FPHP`/`BDHP`/`VIDS` tag).
  linkInfo,

  /// Human-readable text: strings, titles, help text (`STRG`, `TITL`, `HLPT`…).
  text,

  /// A help-file path (`HLPP` begins with the `PTH0` path magic).
  helpPath,

  /// VI settings / save record / version (`LVSR`, `vers`).
  settings,

  /// Security: a password hash (`BDPW` — the sample is the MD5 of the empty
  /// string, `d41d8cd9…`).
  security,

  /// Embedded sub-VIs (`VINS`) — already recovered by `readEmbeddedVis`.
  embeddedVi,

  /// Name / font tables (`FTAB`, `VITS`).
  nameTable,

  /// GUIDs / signatures / unique-id tables (`*UID`, `*SG`, …) — small fixed blobs.
  identifier,

  /// Edit/revision history (`HIST`).
  history,

  /// Recognized tag whose byte format is not yet decoded.
  unknown,
}

/// How sure we are of a block's identity (clean-room, no NI source).
enum BlockConfidence { confirmed, likely, tentative }

/// One catalog entry: a block tag, a human name, its [ViBlockCategory], a
/// [BlockConfidence], and a short note on the evidence.
class ViBlockInfo {
  const ViBlockInfo(this.tag, this.name, this.category, this.confidence, this.note, {this.decoder});

  final String tag;
  final String name;
  final ViBlockCategory category;
  final BlockConfidence confidence;
  final String note;

  /// The name of the function that decodes this block (e.g. `decodeTypePool`,
  /// `buildDiagram`), or null when no decoder exists yet. This is the registry
  /// pointer that answers "where is the code for this block?": grep the name to
  /// find its file under `lib/src/blocks/`. Tags with a null decoder are either
  /// recognized-but-undecoded or only catalogued from documentation (see the
  /// `// --- Documented … not yet observed/decoded ---` section); decoding one is
  /// "add a `decodeXxxx` to its `blocks/` file and set this field".
  final String? decoder;

  bool get isDecoded => decoder != null;

  static ViBlockInfo unknownFor(String tag) =>
      ViBlockInfo(tag, 'Unknown ($tag)', ViBlockCategory.unknown, BlockConfidence.tentative, 'Not catalogued.');
}

/// Look up a block tag. Never throws — an uncatalogued tag yields
/// [ViBlockInfo.unknownFor].
ViBlockInfo blockInfo(String tag) => _catalog[tag] ?? ViBlockInfo.unknownFor(tag);

bool isRecordHeapTag(String tag) => blockInfo(tag).category == ViBlockCategory.recordHeap;

/// Whether [tag] is a catalogued block (identified by type), vs an entirely
/// unrecognized tag that falls back to [ViBlockInfo.unknownFor].
bool isCataloguedTag(String tag) => _catalog.containsKey(tag);

const ViBlockCategory _h = ViBlockCategory.recordHeap;
const ViBlockCategory _ti = ViBlockCategory.typeInfo;
const ViBlockCategory _cc = ViBlockCategory.compiledCode;
const ViBlockCategory _ds = ViBlockCategory.dataSpace;
const ViBlockCategory _cp = ViBlockCategory.connectorPane;
const ViBlockCategory _ic = ViBlockCategory.icon;
const ViBlockCategory _im = ViBlockCategory.image;
const ViBlockCategory _li = ViBlockCategory.linkInfo;
const ViBlockCategory _tx = ViBlockCategory.text;
const ViBlockCategory _hp = ViBlockCategory.helpPath;
const ViBlockCategory _st = ViBlockCategory.settings;
const ViBlockCategory _se = ViBlockCategory.security;
const ViBlockCategory _ev = ViBlockCategory.embeddedVi;
const ViBlockCategory _nt = ViBlockCategory.nameTable;
const ViBlockCategory _id = ViBlockCategory.identifier;
const ViBlockCategory _hi = ViBlockCategory.history;
const ViBlockCategory _un = ViBlockCategory.unknown;

const BlockConfidence _cf = BlockConfidence.confirmed;
const BlockConfidence _lk = BlockConfidence.likely;
const BlockConfidence _tt = BlockConfidence.tentative;

const Map<String, ViBlockInfo> _catalog = {
  'FPHb': ViBlockInfo('FPHb', 'Front-panel heap', _h, _cf, 'C4 record heap; 7568/7568 valid.', decoder: 'buildDiagram'),
  'BDHb': ViBlockInfo(
    'BDHb',
    'Block-diagram heap',
    _h,
    _cf,
    'C4 record heap; 7568/7568 valid.',
    decoder: 'buildDiagram',
  ),
  'FPHc': ViBlockInfo(
    'FPHc',
    'Front-panel heap (variant c)',
    _h,
    _cf,
    'C4 record heap; 14/14 valid.',
    decoder: 'buildDiagram',
  ),
  'BDHc': ViBlockInfo(
    'BDHc',
    'Block-diagram heap (variant c)',
    _h,
    _cf,
    'C4 record heap; 14/14 valid.',
    decoder: 'buildDiagram',
  ),

  'VCTP': ViBlockInfo(
    'VCTP',
    'VI type pool',
    _ti,
    _cf,
    'Type-descriptor table [count][records]; compressed; not a heap.',
    decoder: 'decodeTypePool',
  ),
  'TM80': ViBlockInfo(
    'TM80',
    'Type map (LV 8.0+)',
    _ti,
    _lk,
    'Compressed. Short form (~71%) = [u16 count][u16 field1][count u16 entries]; entry semantics not yet decoded. See decodeTypeMap.',
    decoder: 'decodeTypeMap',
  ),
  'DTHP': ViBlockInfo(
    'DTHP',
    'Data-type heap table',
    _ti,
    _lk,
    '4-byte [u16][u16] header (7541/7583 = 99.45%); rare extended form carries 40xx-tagged data-item names. See decodeDataTypeHeap.',
    decoder: 'decodeDataTypeHeap',
  ),
  'FPTD': ViBlockInfo(
    'FPTD',
    'Front-panel type descriptors',
    _ti,
    _lk,
    'Usually 2 bytes (u16, 3499/3531); occasionally a larger table. Likely a type-descriptor index/count.',
  ),

  'VICD': ViBlockInfo(
    'VICD',
    'VI compiled code',
    _cc,
    _cf,
    '16-byte envelope: u32 flags + 4CC arch (i386/wx64/...) + u32le code size; body is target machine code (recognized opaque, not disassembled). See decodeCompiledCode.',
    decoder: 'decodeCompiledCode',
  ),

  'DFDS': ViBlockInfo(
    'DFDS',
    'Default data space',
    _ds,
    _lk,
    'Compressed default data space: the serialized default value of each data item, laid out per its VCTP type. 3567 corpus instances (~7.4 MB); 723 share one byte-identical 204-byte empty form. No simple framing (leading u32==0 in only 28%, no length law vs the VCTP pool count). A byte-exact type-directed layout needs per-type serialized sizes for the whole VCTP type pool, but the pool is only partially catalogued: 0 of 3534 DFDS-paired pools consist solely of catalogued type codes (0x00/0x53/0x60/0x62/0x80/0xf1-typedef and others carry no size rule), so no walk tiles it and the body is retained verbatim.',
  ),
  'DSIM': ViBlockInfo(
    'DSIM',
    'Data-space image',
    _ds,
    _cf,
    'Leading u32==0 + u16 geometry (repeated at offset 30); the body is either a colour-icon PNG or a raw width*height*bpp raster (u32@22 = pixel byte count), optionally trailed by a palette. Byte-faithfully framed: PNG chunk envelope + verified CRC-32 as model, compressed IDAT retained opaque (decodeImageBlock); envelope dimensions via decodeDataSpaceImage.',
    decoder: 'decodeDataSpaceImage',
  ),
  'DSTM': ViBlockInfo('DSTM', 'Data-space (TM)', _ds, _tt, 'Format not yet decoded.'),

  'CONP': ViBlockInfo(
    'CONP',
    'Connector pane',
    _cp,
    _cf,
    'u16 VCTP index of the conpane type descriptor (100% in-range); see decodeConnectorPane.',
    decoder: 'decodeConnectorPane',
  ),
  'CPC2': ViBlockInfo(
    'CPC2',
    'Connector pane (compiled)',
    _cp,
    _lk,
    'Distinct 2-byte conpane reference (byte-equal to CONP only 55/7503); resolves as a VCTP index just ~84%, so its index reading is NOT confirmed.',
    decoder: 'decodeConnectorPane',
  ),
  'CPMp': ViBlockInfo(
    'CPMp',
    'Connector pane map',
    _cp,
    _cf,
    '[u16le terminalCount][count x u16le object index, 0xFFFF = unassigned] (3531/3531 exact). Maps conpane terminals to panel objects. See decodeConnectorPaneMap.',
    decoder: 'decodeConnectorPaneMap',
  ),

  'icl8': ViBlockInfo(
    'icl8',
    'Icon, 8-bit',
    _ic,
    _cf,
    'Legacy 32x32 @ 8bpp palette bitmap (1024 B, 7583/7583). See decodeLegacyIcon.',
    decoder: 'decodeLegacyIcon',
  ),
  'icl4': ViBlockInfo(
    'icl4',
    'Icon, 4-bit',
    _ic,
    _cf,
    'Legacy 32x32 @ 4bpp palette bitmap (512 B). See decodeLegacyIcon.',
    decoder: 'decodeLegacyIcon',
  ),
  'ICON': ViBlockInfo(
    'ICON',
    'Icon, 1-bit',
    _ic,
    _cf,
    'Legacy 32x32 @ 1bpp mono bitmap (128 B, 7534). Real bitmap, NOT a name table. See decodeLegacyIcon.',
    decoder: 'decodeLegacyIcon',
  ),
  'PICC': ViBlockInfo(
    'PICC',
    'Icon picture record',
    _ic,
    _cf,
    '12 B = six u16be fields [id, 1, top, left, bottom, right] (3283/3283); icon placement rect (roles per corpus geometry). See decodeIconPlacement.',
    decoder: 'decodeIconPlacement',
  ),
  'PICT': ViBlockInfo(
    'PICT',
    'Mac PICT image',
    _im,
    _cf,
    'QuickDraw PICT v2: bounds rect + 00 11 02 FF version opcode; stream is standard PICT. See decodePictEnvelope.',
    decoder: 'decodePictEnvelope',
  ),

  'MNGI': ViBlockInfo(
    'MNGI',
    'PNG image',
    _im,
    _cf,
    'A bare PNG stream (magic 89 50 4E 47) run to IEND; the rare MNG variant stays copied. Byte-faithfully framed: signature + chunk length/type/verified-CRC-32 as model, compressed IDAT retained opaque (decodeImageBlock); envelope dimensions via decodePngEnvelope.',
    decoder: 'decodePngEnvelope',
  ),
  'WEMF': ViBlockInfo(
    'WEMF',
    'Windows enhanced metafile',
    _im,
    _cf,
    'EMF: EMR_HEADER (le) + " EMF" signature @40; bounds decoded, stream is standard EMF. See decodeEmfEnvelope.',
    decoder: 'decodeEmfEnvelope',
  ),

  'LIvi': ViBlockInfo(
    'LIvi',
    'Link info: VI',
    _li,
    _cf,
    'u16 ver=1 + "LVIN" + u32 entry count + linkage entries (VILB/VICC/...); dependency names + PTH0 paths recovered; full entry grammar not yet decoded. See decodeLinkInfo.',
    decoder: 'decodeLinkInfo',
  ),
  'LIfp': ViBlockInfo(
    'LIfp',
    'Link info: front panel',
    _li,
    _cf,
    'u16 ver=1 + "FPHP" + u32 entry count + linkage entries (FPPI/TDCC/...); typedef/control names recovered. See decodeLinkInfo.',
    decoder: 'decodeLinkInfo',
  ),
  'LIbd': ViBlockInfo(
    'LIbd',
    'Link info: block diagram',
    _li,
    _cf,
    'u16 ver=1 + "BDHP" + u32 entry count + linkage entries (IUVI/...); sub-VI dependency names recovered. See decodeLinkInfo.',
    decoder: 'decodeLinkInfo',
  ),
  'LIds': ViBlockInfo(
    'LIds',
    'Link info: data space',
    _li,
    _cf,
    'u16 ver=1 + "VIDS" + u32 entry count + linkage entries. See decodeLinkInfo.',
    decoder: 'decodeLinkInfo',
  ),
  'LPIN': ViBlockInfo(
    'LPIN',
    'Linked-instance info',
    _li,
    _tt,
    'Per-VI big-endian u32 word grid (multiples of 4 B, 8–804 B); values are '
        'offset-like pairs. Word semantics not decoded. See decodeWordGrid.',
    decoder: 'decodeWordGrid',
  ),
  'DLLP': ViBlockInfo(
    'DLLP',
    'DLL/library path',
    _hp,
    _lk,
    'PTH0 path (begins "PTH0"); decodeHelpPath parses it. Rare (n=1 in corpus).',
    decoder: 'decodeHelpPath',
  ),

  'STRG': ViBlockInfo(
    'STRG',
    'VI description text',
    _tx,
    _cf,
    '[u32 len][UTF-8 text] (100% of corpus); the VI description. See decodeStringBlock.',
    decoder: 'decodeStringBlock',
  ),
  'STR': ViBlockInfo('STR', 'String', _tx, _tt, 'Format not yet decoded.'),
  'TITL': ViBlockInfo('TITL', 'VI title', _tx, _cf, 'Pascal-string VI title. See decodeTitle.', decoder: 'decodeTitle'),
  'HLPT': ViBlockInfo(
    'HLPT',
    'Help tag/text',
    _tx,
    _cf,
    'Same [u32 len][UTF-8] layout as STRG (200/200); markdown-ish context help. See helpTextFromSections.',
    decoder: 'decodeStringBlock',
  ),

  'HLPP': ViBlockInfo(
    'HLPP',
    'Help path',
    _hp,
    _cf,
    'PTH0 path: "PTH0"+i32 len+i16 type+i16 count+Pascal components (128/128). See decodeHelpPath.',
    decoder: 'decodeHelpPath',
  ),
  'HLPU': ViBlockInfo('HLPU', 'Help URL/path', _hp, _tt, 'Help-related; format not yet decoded.'),
  'HLPX': ViBlockInfo('HLPX', 'Help (X)', _hp, _tt, 'Help-related; format not yet decoded.'),
  'HLPW': ViBlockInfo('HLPW', 'Help (W)', _hp, _tt, 'Help-related; format not yet decoded.'),

  'LVSR': ViBlockInfo(
    'LVSR',
    'LabVIEW save record',
    _st,
    _cf,
    'VI settings/flags (160/144/136 B). Decoded: version word @0 (BCD, == vers 99.95%) + BD password hash @96 (== BDPW). See decodeSaveRecord.',
    decoder: 'decodeSaveRecord',
  ),
  'vers': ViBlockInfo(
    'vers',
    'Version record',
    _st,
    _cf,
    'Binary version word [BCD major][minor<<4|patch][stage][build] + ASCII version/title. See decodeVersionWord.',
    decoder: 'decodeVersionWord',
  ),

  'BDPW': ViBlockInfo(
    'BDPW',
    'Block-diagram password',
    _se,
    _cf,
    'Three 16-byte MD5 digests (48 B, 7538/7539; legacy 32 B once): password hash (d41d8cd9... = MD5("") when unprotected) + two derived digests (derivation not re-derived). See decodePasswordRecord.',
    decoder: 'decodePasswordRecord',
  ),

  'VINS': ViBlockInfo(
    'VINS',
    'Embedded sub-VIs',
    _ev,
    _cf,
    'Nested RSRC VIs, each a complete parseable VI. See readEmbeddedVis.',
    decoder: 'readEmbeddedVis',
  ),

  'FTAB': ViBlockInfo(
    'FTAB',
    'Font table',
    _nt,
    _cf,
    'u16 ver@0=1, u16 fontCount@6, u32 nameOffset@8 -> packed Pascal font-name strings. See decodeFontTable.',
    decoder: 'decodeFontTable',
  ),
  'VITS': ViBlockInfo(
    'VITS',
    'VI tag store',
    _nt,
    _cf,
    '[u32 count] + count entries, each flat [u32 nameLen][name][u32 payloadLen][payload] or a nested flattened-variant record (marker byte[2]==0x80) bounded by its variant length or, when final, by the store end; 7133/7143 walk exactly, the rest carry a non-final multi-field variant not framed here, flagged walkComplete=false. See decodeTagStore.',
    decoder: 'decodeTagStore',
  ),

  'HIST': ViBlockInfo(
    'HIST',
    'Revision history',
    _hi,
    _cf,
    '40-byte record: version@0=2, flags@4, entryCount@8, reserved@12/28/32=0. See decodeHistory.',
    decoder: 'decodeHistory',
  ),

  'MUID': ViBlockInfo(
    'MUID',
    'Modified UID',
    _id,
    _cf,
    '4-byte u32 id, varied per VI. See decodeModifiedUid.',
    decoder: 'decodeModifiedUid',
  ),
  'NUID': ViBlockInfo(
    'NUID',
    'New UID table',
    _id,
    _cf,
    '[u32 count][count u32 ids], len==4+4*count (100%). See decodeIdTable. Id values opaque.',
    decoder: 'decodeIdTable',
  ),
  'SUID': ViBlockInfo(
    'SUID',
    'Saved UID table',
    _id,
    _cf,
    '[u32 count][count u32 ids], len==4+4*count (100%). See decodeIdTable. Id values opaque.',
    decoder: 'decodeIdTable',
  ),
  'BNID': ViBlockInfo(
    'BNID',
    'Block-name id table',
    _id,
    _cf,
    '[u32 count][count u32 ids], len==4+4*count (100%). See decodeIdTable. Id values opaque.',
    decoder: 'decodeIdTable',
  ),
  'OMId': ViBlockInfo('OMId', 'Object-map id', _id, _tt, 'Rare (n=1 in corpus); not characterized.'),
  'RSID': ViBlockInfo('RSID', 'Resource id', _id, _tt, 'Rare (n=1 in corpus); not characterized.'),
  'RTSG': ViBlockInfo(
    'RTSG',
    'Run-time signature',
    _id,
    _cf,
    '16-byte signature, varied per VI (7582/7582): a single opaque identity digest; format decoded, derivation not. See decodeRuntimeSignature.',
    decoder: 'decodeRuntimeSignature',
  ),
  'OBSG': ViBlockInfo(
    'OBSG',
    'Object signature',
    _id,
    _cf,
    '16-byte signature, varied per VI (99%); opaque value, role=identity. See decodeRuntimeSignature.',
    decoder: 'decodeRuntimeSignature',
  ),
  'CCSG': ViBlockInfo(
    'CCSG',
    'Compiled-code signature',
    _id,
    _cf,
    '16-byte signature, near-CONSTANT (4 distinct/528) — shared toolchain '
        'signature, not per-VI. See decodeRuntimeSignature.',
    decoder: 'decodeRuntimeSignature',
  ),
  'SCSR': ViBlockInfo(
    'SCSR',
    'Source signature',
    _id,
    _cf,
    '20 B: u32 marker 0x01000000 + 16-byte signature. See decodeScsrRecord.',
    decoder: 'decodeScsrRecord',
  ),
  'GCPR': ViBlockInfo(
    'GCPR',
    'Generated-code property',
    _id,
    _cf,
    'Fixed 13-byte record, constant (all-zero) across the corpus. See decodeGcprRecord.',
    decoder: 'decodeGcprRecord',
  ),
  'GCDI': ViBlockInfo(
    'GCDI',
    'Generated-code debug info',
    _id,
    _tt,
    'Compressed; mostly 9 B decompressed; format not yet decoded.',
    decoder: 'decodeGcdiRecord',
  ),

  'FPSE': ViBlockInfo(
    'FPSE',
    'Front-panel section entry',
    _un,
    _cf,
    '4-byte u32 (FP section offset/size marker; 7535/7582), rarely 8 B with a second word. See decodeSectionMarker.',
    decoder: 'decodeSectionMarker',
  ),
  'BDSE': ViBlockInfo(
    'BDSE',
    'Block-diagram section entry',
    _un,
    _cf,
    '4-byte u32 (BD section offset/size marker; 7535/7582), rarely 8 B with a second word. See decodeSectionMarker.',
    decoder: 'decodeSectionMarker',
  ),
  'FPEx': ViBlockInfo(
    'FPEx',
    'Front-panel extended',
    _un,
    _cf,
    'u32be flag words (4-32 B dominate); bit meanings not yet decoded. See decodeExtendedState.',
    decoder: 'decodeExtendedState',
  ),
  'BDEx': ViBlockInfo(
    'BDEx',
    'Block-diagram extended',
    _un,
    _cf,
    'u32be flag words (4-32 B dominate); bit meanings not yet decoded. See decodeExtendedState.',
    decoder: 'decodeExtendedState',
  ),
  'FPTS': ViBlockInfo('FPTS', 'Front-panel TS', _un, _tt, 'Format not yet decoded.'),
  'BDTS': ViBlockInfo('BDTS', 'Block-diagram TS', _un, _tt, 'Format not yet decoded.'),
  'FPHP': ViBlockInfo('FPHP', 'Front-panel heap (legacy?)', _un, _tt, 'Rare; not a confirmed C4 heap in corpus.'),
  'BDHP': ViBlockInfo('BDHP', 'Block-diagram heap (legacy?)', _un, _tt, 'Rare; not a confirmed C4 heap in corpus.'),

  'VPDP': ViBlockInfo(
    'VPDP',
    'VI property data',
    _un,
    _cf,
    'Fixed 4-byte record, constant (all-zero) across the corpus. See decodeVpdpRecord.',
    decoder: 'decodeVpdpRecord',
  ),
  'PRT ': ViBlockInfo(
    'PRT ',
    'Print settings',
    _un,
    _cf,
    'Fixed 128 B (rarely 132/136) print record: version byte 0x01 @4; the '
        'default form is a fixed non-zero 128-byte record (1734/3818, 125 '
        'distinct values overall); field semantics not decoded. See decodePrintRecord.',
    decoder: 'decodePrintRecord',
  ),
  'DLDR': ViBlockInfo(
    'DLDR',
    'Default-data loader',
    _un,
    _cf,
    'Fixed 28-byte body = a seven-word big-endian u32 grid (NOT constant: 2 '
        'distinct/3471). The first word is 1 in 3470/3471; the remaining words '
        'are per-VI. Word semantics not decoded. See decodeDldrRecord.',
    decoder: 'decodeDldrRecord',
  ),
  'TRec': ViBlockInfo(
    'TRec',
    'Type record',
    _un,
    _cf,
    '13-byte header (semantics not yet decoded) + u16-prefixed text runs (descriptions/tips). See decodeTextRecord.',
    decoder: 'decodeTextRecord',
  ),
  'CCST': ViBlockInfo(
    'CCST',
    'Compiled-code state',
    _un,
    _lk,
    'Usually a 4-byte all-zero record (2583/2617); occasionally larger.',
  ),
  'BFAL': ViBlockInfo('BFAL', 'BF align table', _un, _tt, 'Format not yet decoded.'),
  'BKMK': ViBlockInfo(
    'BKMK',
    'Bookmarks',
    _un,
    _lk,
    'Bookmark list; an 8-byte empty record when there are none (743/988), larger with bookmark text.',
    decoder: 'decodeBookmarkList',
  ),
  'CNST': ViBlockInfo(
    'CNST',
    'Constants',
    _un,
    _tt,
    'Per-VI big-endian u32 word grid (multiples of 4 B, 4–452 B; 24/903 are '
        'multiples of 4 but not 8, so not strictly u32 pairs). Values are '
        'offset-like; meaning not decoded. See decodeWordGrid.',
    decoder: 'decodeWordGrid',
  ),
  'IPSR': ViBlockInfo('IPSR', 'IP source record', _un, _tt, 'Format not yet decoded.', decoder: 'decodeOffsetTable'),
  'CPST': ViBlockInfo(
    'CPST',
    'Boolean-text table',
    _tx,
    _lk,
    '[u32 len] + Pascal strings of boolean labels (e.g. "True/False:"). Decodable via the string framing.',
  ),
  'CPSP': ViBlockInfo(
    'CPSP',
    'Boolean-text table (spec)',
    _tx,
    _lk,
    '[u32 len] + Pascal strings of boolean labels ("True","False").',
  ),
  'CPD2': ViBlockInfo(
    'CPD2',
    'Connector-pane data v2',
    _cp,
    _lk,
    'Fixed 2-byte big-endian u16; value semantics not decoded. See decodeCpd2Record.',
    decoder: 'decodeCpd2Record',
  ),
  'CPTM': ViBlockInfo('CPTM', 'Connector-pane TM', _un, _tt, 'Format not yet decoded.'),
  'GTMI': ViBlockInfo('GTMI', 'Get-TM info', _un, _tt, 'Format not yet decoded.'),
  'HBIN': ViBlockInfo('HBIN', 'Heap bin', _un, _tt, 'Format not yet decoded.'),
  'HBUF': ViBlockInfo('HBUF', 'Heap buffer', _un, _tt, 'Format not yet decoded.'),
  'COUT': ViBlockInfo(
    'COUT',
    'Compiled output',
    _un,
    _lk,
    'Fixed 12-byte per-VI value = a three-word big-endian u32 grid (opaque; '
        'likely a hash/id). Rare (n=7). See decodeWordGrid.',
    decoder: 'decodeWordGrid',
  ),
  'RTMP': ViBlockInfo(
    'RTMP',
    'Run-time map / path',
    _un,
    _tt,
    'Rare (n=2); one instance is a PTH0 path. Format not yet decoded.',
  ),

  // --- Documented on labviewwiki.org/wiki/Resource_Container but NOT yet observed
  //     in our corpus (so unconfirmed) and NOT yet decoded. Catalogued here so the
  //     registry is complete and each has a home; TODO: confirm against a real VI
  //     and write a decoder (then move it into its own blocks/ file + set decoder).
  'FLAG': ViBlockInfo(
    'FLAG',
    'Integer flags',
    _st,
    _tt,
    'labviewwiki: integer flags. Not observed in corpus. TODO decode.',
  ),
  'LVIN': ViBlockInfo(
    'LVIN',
    'VI info (LV 4.0 and older)',
    _st,
    _tt,
    'labviewwiki: general VI file information, predecessor of LVSR (pre-LV 6.0). Not observed in corpus. TODO decode.',
  ),
  'CPCT': ViBlockInfo(
    'CPCT',
    'Connector port content type',
    _cp,
    _tt,
    'labviewwiki: connector port content type (CPC2 predecessor). Not observed in corpus. TODO decode.',
  ),
  'CPDI': ViBlockInfo(
    'CPDI',
    'Connector port DI',
    _cp,
    _tt,
    'labviewwiki: connector port DI. Not observed in corpus. TODO decode.',
  ),
  'DLGH': ViBlockInfo(
    'DLGH',
    'Dialog HTML',
    _tx,
    _tt,
    'labviewwiki: dialog HTML. Not observed in corpus. TODO decode.',
  ),
  'ERRH': ViBlockInfo('ERRH', 'Error HTML', _tx, _tt, 'labviewwiki: error HTML. Not observed in corpus. TODO decode.'),
  'NODH': ViBlockInfo('NODH', 'NOD HTML', _tx, _tt, 'labviewwiki: NOD HTML. Not observed in corpus. TODO decode.'),
  'NOEG': ViBlockInfo(
    'NOEG',
    'NOEG string',
    _tx,
    _tt,
    'labviewwiki: NOEG string. Not observed in corpus. TODO decode.',
  ),
  'MItm': ViBlockInfo('MItm', 'M. item', _un, _tt, 'labviewwiki: M. item. Not observed in corpus. TODO decode.'),
  'DNm#': ViBlockInfo(
    'DNm#',
    'D. name strings list',
    _tx,
    _tt,
    'labviewwiki: D. name strings list. Not observed in corpus. TODO decode.',
  ),
  'HDb#': ViBlockInfo(
    'HDb#',
    'Help database item',
    _tx,
    _tt,
    'labviewwiki: help database item. Not observed in corpus. TODO decode.',
  ),
  'LST#': ViBlockInfo(
    'LST#',
    'Short strings list',
    _tx,
    _tt,
    'labviewwiki: short strings list. Not observed in corpus. TODO decode.',
  ),
  'STR#': ViBlockInfo(
    'STR#',
    'Short strings list',
    _tx,
    _tt,
    'labviewwiki: short strings list. Not observed in corpus. TODO decode.',
  ),
  'FDFL': ViBlockInfo(
    'FDFL',
    'FDFL strings',
    _tx,
    _tt,
    'labviewwiki: FDFL strings. Not observed in corpus. TODO decode.',
  ),
  'LPTH': ViBlockInfo('LPTH', 'L. path', _hp, _tt, 'labviewwiki: L. path. Not observed in corpus. TODO decode.'),
  'LIBN': ViBlockInfo(
    'LIBN',
    'Library names',
    _nt,
    _tt,
    'labviewwiki: library names. Recovered today via readEmbeddedSections, not yet a catalogued decoder. TODO decode.',
  ),
  'CGRS': ViBlockInfo(
    'CGRS',
    'Conglomerate resource',
    _un,
    _tt,
    'labviewwiki: conglomerate resource. Not observed in corpus. TODO decode.',
  ),
  'PNGI': ViBlockInfo(
    'PNGI',
    'PNG image',
    _im,
    _tt,
    'labviewwiki: PNG image bitmap (cf. MNGI). Not observed in corpus. TODO decode.',
  ),
  'ICN#': ViBlockInfo(
    'ICN#',
    'Icon large double, 1-bit',
    _ic,
    _tt,
    'labviewwiki: 32x64 @ 1bpp. Not observed in corpus. TODO decode.',
  ),
  'ics#': ViBlockInfo(
    'ics#',
    'Icon small, 1-bit',
    _ic,
    _tt,
    'labviewwiki: 16x16 @ 1bpp. Not observed in corpus. TODO decode.',
  ),
  'ics4': ViBlockInfo(
    'ics4',
    'Icon small, 4-bit',
    _ic,
    _tt,
    'labviewwiki: 16x16 @ 4bpp. Not observed in corpus. TODO decode.',
  ),
  'ics8': ViBlockInfo(
    'ics8',
    'Icon small, 8-bit',
    _ic,
    _tt,
    'labviewwiki: 16x16 @ 8bpp. Not observed in corpus. TODO decode.',
  ),
  'CURS': ViBlockInfo(
    'CURS',
    'Cursor, 1-bit',
    _ic,
    _tt,
    'labviewwiki: 16x34 @ 1bpp cursor. Not observed in corpus. TODO decode.',
  ),
  'LVzp': ViBlockInfo(
    'LVzp',
    'Zipped application',
    _un,
    _tt,
    'labviewwiki: a whole application compressed to a ZIP file. Not observed in corpus. TODO decode.',
  ),
  'BDHT': ViBlockInfo(
    'BDHT',
    'Block-diagram heap (text)',
    _tx,
    _tt,
    'labviewwiki: block-diagram heap, text form. Not observed in corpus. TODO decode.',
  ),
  'FPHT': ViBlockInfo(
    'FPHT',
    'Front-panel heap (text)',
    _tx,
    _tt,
    'labviewwiki: front-panel heap, text form. Not observed in corpus. TODO decode.',
  ),
  'BDHX': ViBlockInfo(
    'BDHX',
    'Block-diagram heap (XML)',
    _tx,
    _tt,
    'labviewwiki: block-diagram heap, XML form. Not observed in corpus. TODO decode.',
  ),
  'FPHX': ViBlockInfo(
    'FPHX',
    'Front-panel heap (XML)',
    _tx,
    _tt,
    'labviewwiki: front-panel heap, XML form. Not observed in corpus. TODO decode.',
  ),
  'UCRF': ViBlockInfo(
    'UCRF',
    'Uncompressed resource file',
    _un,
    _tt,
    'labviewwiki: uncompressed resource file. Not observed in corpus. TODO decode.',
  ),
  'CPRF': ViBlockInfo(
    'CPRF',
    'Compressed resource file (Comp)',
    _un,
    _tt,
    'labviewwiki: "Comp"-compressed resource file. Not observed in corpus. TODO decode.',
  ),
  'ZCRF': ViBlockInfo(
    'ZCRF',
    'Compressed resource file (ZLib)',
    _un,
    _tt,
    'labviewwiki: ZLib-compressed resource file. Not observed in corpus. TODO decode.',
  ),
  'DLG3': ViBlockInfo(
    'DLG3',
    'Dialog resource file',
    _un,
    _tt,
    'labviewwiki: dialog resource file. Not observed in corpus. TODO decode.',
  ),
};
