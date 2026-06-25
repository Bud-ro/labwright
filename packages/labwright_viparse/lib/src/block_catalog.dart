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
/// Coverage is the 81 distinct tags observed across the 7583-VI corpus; an
/// unknown tag resolves to [ViBlockInfo.unknownFor] rather than throwing.
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
  const ViBlockInfo(this.tag, this.name, this.category, this.confidence, this.note);

  final String tag;
  final String name;
  final ViBlockCategory category;
  final BlockConfidence confidence;
  final String note;

  /// True only for the corpus-confirmed `C4` record heaps — the blocks the heap
  /// record-walk may be applied to.
  bool get isRecordHeap => category == ViBlockCategory.recordHeap;

  /// The fallback for a tag not in the catalog.
  static ViBlockInfo unknownFor(String tag) =>
      ViBlockInfo(tag, 'Unknown ($tag)', ViBlockCategory.unknown, BlockConfidence.tentative, 'Not catalogued.');
}

/// Look up a block tag. Never throws — an uncatalogued tag yields
/// [ViBlockInfo.unknownFor].
ViBlockInfo blockInfo(String tag) => _catalog[tag] ?? ViBlockInfo.unknownFor(tag);

/// Convenience: is [tag] one of the confirmed `C4` record heaps?
bool isRecordHeapTag(String tag) => blockInfo(tag).category == ViBlockCategory.recordHeap;

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
  // --- C4 record heaps (corpus-confirmed: valid content-length + heap lead) ---
  'FPHb': ViBlockInfo('FPHb', 'Front-panel heap', _h, _cf, 'C4 record heap; 7568/7568 valid.'),
  'BDHb': ViBlockInfo('BDHb', 'Block-diagram heap', _h, _cf, 'C4 record heap; 7568/7568 valid.'),
  'FPHc': ViBlockInfo('FPHc', 'Front-panel heap (variant c)', _h, _cf, 'C4 record heap; 14/14 valid.'),
  'BDHc': ViBlockInfo('BDHc', 'Block-diagram heap (variant c)', _h, _cf, 'C4 record heap; 14/14 valid.'),

  // --- Type info ---
  'VCTP': ViBlockInfo('VCTP', 'VI type pool', _ti, _cf, 'Type-descriptor table [count][records]; compressed; not a heap.'),
  'TM80': ViBlockInfo('TM80', 'Type map (LV 8.0+)', _ti, _lk, 'Compressed. Short form (~71%) = [u16 count][u16 field1][count u16 entries]; entry semantics not yet decoded. See decodeTypeMap.'),
  'DTHP': ViBlockInfo('DTHP', 'Data-type heap table', _ti, _lk, '4-byte [u16][u16] header (7541/7583 = 99.45%); rare extended form carries 40xx-tagged data-item names. See decodeDataTypeHeap.'),
  'FPTD': ViBlockInfo('FPTD', 'Front-panel type descriptors', _ti, _tt, 'Format not yet decoded.'),

  // --- Compiled code ---
  'VICD': ViBlockInfo('VICD', 'VI compiled code', _cc, _cf, 'Machine-code image (e.g. i386); compressed; opaque.'),

  // --- Data space ---
  'DFDS': ViBlockInfo('DFDS', 'Default data space', _ds, _lk, 'Compressed serialized default control/indicator values, type-directed by VCTP. No self-describing header (decompressed body starts with zeros) — decoding needs the VCTP type-size walk; not yet parsed.'),
  'DSIM': ViBlockInfo('DSIM', 'Data-space image', _ds, _tt, 'Large uncompressed image; format not yet decoded.'),
  'DSTM': ViBlockInfo('DSTM', 'Data-space (TM)', _ds, _tt, 'Format not yet decoded.'),

  // --- Connector pane ---
  'CONP': ViBlockInfo('CONP', 'Connector pane', _cp, _cf, 'u16 VCTP index of the conpane type descriptor (100% in-range); see decodeConnectorPane.'),
  'CPC2': ViBlockInfo('CPC2', 'Connector pane (compiled)', _cp, _lk, 'Distinct 2-byte conpane reference (byte-equal to CONP only 55/7503); resolves as a VCTP index just ~84%, so its index reading is NOT confirmed.'),
  'CPMp': ViBlockInfo('CPMp', 'Connector pane map', _cp, _tt, 'Format not yet decoded.'),

  // --- Icons ---
  'icl8': ViBlockInfo('icl8', 'Icon, 8-bit', _ic, _cf, 'Legacy 32x32 @ 8bpp palette bitmap (1024 B, 7583/7583). See decodeLegacyIcon.'),
  'icl4': ViBlockInfo('icl4', 'Icon, 4-bit', _ic, _cf, 'Legacy 32x32 @ 4bpp palette bitmap (512 B). See decodeLegacyIcon.'),
  'ICON': ViBlockInfo('ICON', 'Icon, 1-bit', _ic, _cf, 'Legacy 32x32 @ 1bpp mono bitmap (128 B, 7534). Real bitmap, NOT a name table. See decodeLegacyIcon.'),
  'PICC': ViBlockInfo('PICC', 'Icon picture record', _ic, _tt, '12-byte icon record (not a bitmap); the colour RGB icon lives under PICC/DSIM/FPHb via extractRgbIcon.'),
  'PICT': ViBlockInfo('PICT', 'Mac PICT image', _im, _lk, 'QuickDraw PICT.'),

  // --- Images ---
  'MNGI': ViBlockInfo('MNGI', 'PNG image', _im, _cf, 'Begins with the PNG magic 89 50 4E 47.'),
  'WEMF': ViBlockInfo('WEMF', 'Windows enhanced metafile', _im, _lk, 'EMF record stream.'),

  // --- Link info ---
  'LIvi': ViBlockInfo('LIvi', 'Link info: VI', _li, _cf, 'Embeds ASCII "LVIN".'),
  'LIfp': ViBlockInfo('LIfp', 'Link info: front panel', _li, _cf, 'Embeds ASCII "FPHP".'),
  'LIbd': ViBlockInfo('LIbd', 'Link info: block diagram', _li, _cf, 'Embeds ASCII "BDHP".'),
  'LIds': ViBlockInfo('LIds', 'Link info: data space', _li, _cf, 'Embeds ASCII "VIDS".'),
  'LPIN': ViBlockInfo('LPIN', 'Linked-instance info', _li, _tt, 'Format not yet decoded.'),
  'DLLP': ViBlockInfo('DLLP', 'DLL/library path', _li, _tt, 'Format not yet decoded.'),

  // --- Text ---
  'STRG': ViBlockInfo('STRG', 'VI description text', _tx, _cf, '[u32 len][UTF-8 text] (100% of corpus); the VI description. See decodeStringBlock.'),
  'STR': ViBlockInfo('STR', 'String', _tx, _tt, 'Format not yet decoded.'),
  'TITL': ViBlockInfo('TITL', 'VI title', _tx, _cf, 'Pascal-string title.'),
  'HLPT': ViBlockInfo('HLPT', 'Help tag/text', _tx, _cf, 'Same [u32 len][UTF-8] layout as STRG (200/200); markdown-ish context help. See helpTextFromSections.'),

  // --- Help path ---
  'HLPP': ViBlockInfo('HLPP', 'Help path', _hp, _cf, 'PTH0 path: "PTH0"+i32 len+i16 type+i16 count+Pascal components (128/128). See decodeHelpPath.'),
  'HLPU': ViBlockInfo('HLPU', 'Help URL/path', _hp, _tt, 'Help-related; format not yet decoded.'),
  'HLPX': ViBlockInfo('HLPX', 'Help (X)', _hp, _tt, 'Help-related; format not yet decoded.'),
  'HLPW': ViBlockInfo('HLPW', 'Help (W)', _hp, _tt, 'Help-related; format not yet decoded.'),

  // --- Settings / version ---
  'LVSR': ViBlockInfo('LVSR', 'LabVIEW save record', _st, _cf, 'VI settings/flags (160/144/136 B). Decoded: version word @0 (BCD, == vers 99.95%) + BD password hash @96 (== BDPW). See decodeSaveRecord.'),
  'vers': ViBlockInfo('vers', 'Version record', _st, _cf, 'LabVIEW version that saved the VI.'),

  // --- Security ---
  'BDPW': ViBlockInfo('BDPW', 'Block-diagram password', _se, _cf, 'Password hash; sample is MD5("") d41d8cd9…'),

  // --- Embedded VIs ---
  'VINS': ViBlockInfo('VINS', 'Embedded sub-VIs', _ev, _cf, 'Nested RSRC VIs; recovered by readEmbeddedVis.'),

  // --- Name tables ---
  'FTAB': ViBlockInfo('FTAB', 'Font table', _nt, _cf, 'u16 ver@0=1, u16 fontCount@6, u32 nameOffset@8 -> packed Pascal font-name strings. See decodeFontTable.'),
  'VITS': ViBlockInfo('VITS', 'VI tag store / name tail', _nt, _tt, 'Trailing name/tag store.'),

  // --- History ---
  'HIST': ViBlockInfo('HIST', 'Revision history', _hi, _cf, '40-byte record: version@0=2, flags@4, entryCount@8, reserved@12/28/32=0. See decodeHistory.'),

  // --- Identifiers / signatures (small fixed blobs; roles undetermined) ---
  'MUID': ViBlockInfo('MUID', 'Modified UID', _id, _tt, '4-byte id.'),
  'NUID': ViBlockInfo('NUID', 'New UID table', _id, _tt, 'Id table.'),
  'SUID': ViBlockInfo('SUID', 'Saved UID table', _id, _tt, 'Id table.'),
  'BNID': ViBlockInfo('BNID', 'Block-name id table', _id, _tt, 'Id table.'),
  'OMId': ViBlockInfo('OMId', 'Object-map id', _id, _tt, 'Id table.'),
  'RSID': ViBlockInfo('RSID', 'Resource id', _id, _tt, 'Id.'),
  'RTSG': ViBlockInfo('RTSG', 'Run-time signature', _id, _tt, '16-byte signature.'),
  'OBSG': ViBlockInfo('OBSG', 'Object signature', _id, _tt, '16-byte signature.'),
  'CCSG': ViBlockInfo('CCSG', 'Compiled-code signature', _id, _tt, '16-byte signature.'),
  'SCSR': ViBlockInfo('SCSR', 'Source signature', _id, _tt, '20-byte record.'),
  'GCPR': ViBlockInfo('GCPR', 'Generated-code property', _id, _tt, 'Format not yet decoded.'),
  'GCDI': ViBlockInfo('GCDI', 'Generated-code debug info', _id, _tt, 'Compressed; format not yet decoded.'),

  // --- FP/BD section markers + extended records (small; roles undetermined) ---
  'FPSE': ViBlockInfo('FPSE', 'Front-panel section entry', _un, _tt, 'Small offset/size record.'),
  'BDSE': ViBlockInfo('BDSE', 'Block-diagram section entry', _un, _tt, 'Small offset/size record.'),
  'FPEx': ViBlockInfo('FPEx', 'Front-panel extended', _un, _tt, 'Format not yet decoded.'),
  'BDEx': ViBlockInfo('BDEx', 'Block-diagram extended', _un, _tt, 'Format not yet decoded.'),
  'FPTS': ViBlockInfo('FPTS', 'Front-panel TS', _un, _tt, 'Format not yet decoded.'),
  'BDTS': ViBlockInfo('BDTS', 'Block-diagram TS', _un, _tt, 'Format not yet decoded.'),
  'FPHP': ViBlockInfo('FPHP', 'Front-panel heap (legacy?)', _un, _tt, 'Rare; not a confirmed C4 heap in corpus.'),
  'BDHP': ViBlockInfo('BDHP', 'Block-diagram heap (legacy?)', _un, _tt, 'Rare; not a confirmed C4 heap in corpus.'),

  // --- Other recognized-but-undecoded tags ---
  'VPDP': ViBlockInfo('VPDP', 'VI property data', _un, _tt, 'Format not yet decoded.'),
  'PRT': ViBlockInfo('PRT', 'Print settings', _un, _tt, 'Format not yet decoded.'),
  'DLDR': ViBlockInfo('DLDR', 'Default-data loader', _un, _tt, 'Format not yet decoded.'),
  'TRec': ViBlockInfo('TRec', 'Type record', _un, _tt, 'Format not yet decoded.'),
  'CCST': ViBlockInfo('CCST', 'Compiled-code state', _un, _tt, 'Format not yet decoded.'),
  'BFAL': ViBlockInfo('BFAL', 'BF align table', _un, _tt, 'Format not yet decoded.'),
  'BKMK': ViBlockInfo('BKMK', 'Bookmarks', _un, _tt, 'Bookmark list.'),
  'CNST': ViBlockInfo('CNST', 'Constants', _un, _tt, 'Format not yet decoded.'),
  'IPSR': ViBlockInfo('IPSR', 'IP source record', _un, _tt, 'Format not yet decoded.'),
  'CPST': ViBlockInfo('CPST', 'Connector-pane state', _un, _tt, 'Format not yet decoded.'),
  'CPSP': ViBlockInfo('CPSP', 'Connector-pane spec', _un, _tt, 'Format not yet decoded.'),
  'CPD2': ViBlockInfo('CPD2', 'Connector-pane data v2', _un, _tt, 'Format not yet decoded.'),
  'CPTM': ViBlockInfo('CPTM', 'Connector-pane TM', _un, _tt, 'Format not yet decoded.'),
  'GTMI': ViBlockInfo('GTMI', 'Get-TM info', _un, _tt, 'Format not yet decoded.'),
  'HBIN': ViBlockInfo('HBIN', 'Heap bin', _un, _tt, 'Format not yet decoded.'),
  'HBUF': ViBlockInfo('HBUF', 'Heap buffer', _un, _tt, 'Format not yet decoded.'),
  'COUT': ViBlockInfo('COUT', 'Compiled output', _un, _tt, 'Format not yet decoded.'),
  'RTMP': ViBlockInfo('RTMP', 'Run-time map', _un, _tt, 'Format not yet decoded.'),
};
