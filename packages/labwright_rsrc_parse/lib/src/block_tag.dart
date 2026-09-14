import 'dart:typed_data';

import 'block_layout.dart';
import 'blocks/BDHb_BDHc_BDHP_block_diagram.dart';
import 'blocks/BDPW_password.dart';
import 'blocks/BFAL_align_table.dart';
import 'blocks/BKMK_bookmarks.dart';
import 'blocks/CCST_compiled_code_state.dart';
import 'blocks/CNST_LPIN_BDTS_word_grid.dart';
import 'blocks/CONP_CPC2_connector_pane.dart';
import 'blocks/COUT_compiled_output.dart';
import 'blocks/CPD2_connector_pane_data.dart';
import 'blocks/CPMp_connector_pane_map.dart';
import 'blocks/CPST_CPSP_pascal_string_table.dart';
import 'blocks/DLDR_default_data_loader.dart';
import 'blocks/DSIM_data_space_image.dart';
import 'blocks/DTHP_data_type_heap.dart';
import 'blocks/FPEx_BDEx_extended_state.dart';
import 'blocks/FPHb_FPHc_FPHP_front_panel.dart';
import 'blocks/FPSE_BDSE_section_entry.dart';
import 'blocks/FPTD_front_panel_type_descriptors.dart';
import 'blocks/FTAB_font_table.dart';
import 'blocks/GCDI_generated_code_debug_info.dart';
import 'blocks/GCPR_VPDP_constant_record.dart';
import 'blocks/HIST_history.dart';
import 'blocks/HLPP_DLLP_help_path.dart';
import 'blocks/IPSR_offset_table.dart';
import 'blocks/LIBN_library_names.dart';
import 'blocks/LIvi_LIbd_LIfp_LIds_link_info.dart';
import 'blocks/LVSR_save_record.dart';
import 'blocks/MNGI_png_image.dart';
import 'blocks/MUID_modified_uid.dart';
import 'blocks/NUID_SUID_BNID_id_table.dart';
import 'blocks/PICC_icon_placement.dart';
import 'blocks/PICT_picture.dart';
import 'blocks/PRT_print_settings.dart';
import 'blocks/RTSG_OBSG_CCSG_signature.dart';
import 'blocks/SCSR_source_signature.dart';
import 'blocks/STRG_HLPT_string_block.dart';
import 'blocks/TITL_title.dart';
import 'blocks/TM80_type_map.dart';
import 'blocks/TRec_type_record.dart';
import 'blocks/VCTP_type_pool.dart';
import 'blocks/VICD_compiled_code.dart';
import 'blocks/VINS_embedded_vis.dart';
import 'blocks/VITS_tag_store.dart';
import 'blocks/WEMF_metafile.dart';
import 'blocks/icl8_icl4_ICON_icon.dart';
import 'blocks/vers_version.dart';

/// What a block holds, for grouping in listings.
enum BlockCategory {
  /// The front panel's object heap, in any encoding.
  frontPanelHeap,

  /// The block diagram's object heap, in any encoding.
  blockDiagramHeap,

  /// Type descriptors and type maps.
  typeInfo,

  /// Compiled machine code.
  compiledCode,

  /// Default values and images of the data space.
  dataSpace,

  /// The connector pane and its wiring.
  connectorPane,

  /// Icons and their placement.
  icon,

  /// Pictures and metafiles.
  image,

  /// Links to other resources.
  linkInfo,

  /// Text.
  text,

  /// Paths to help documents and libraries.
  helpPath,

  /// Save-time settings and versions.
  settings,

  /// Passwords and digests.
  security,

  /// Embedded VIs.
  embeddedVi,

  /// Tables of names.
  nameTable,

  /// Ids and signatures.
  identifier,

  /// Revision history.
  history,

  /// Role not established.
  unknown,
}

/// How far a block's layout is established.
enum BlockConfidence {
  /// The layout is decoded and re-serializes byte-exactly across the corpus.
  confirmed,

  /// The layout is decoded but some fields or variants are open.
  likely,

  /// The layout is not decoded.
  tentative,
}

/// Every section tag this package knows, with its display name, category,
/// confidence and payload decoder.
///
/// [tag] is the exact four-character string stored in the block list;
/// `STR ` and `PRT ` end in a space. [of] looks a tag up.
enum BlockTag {
  /// Front-panel object heap, a C4 record heap.
  fphb(
    'FPHb',
    'Front-panel heap',
    BlockCategory.frontPanelHeap,
    BlockConfidence.confirmed,
    decodeFrontPanel,
    frontPanelHeapLayout,
  ),

  /// Block-diagram object heap, a C4 record heap.
  bdhb(
    'BDHb',
    'Block-diagram heap',
    BlockCategory.blockDiagramHeap,
    BlockConfidence.confirmed,
    decodeBlockDiagram,
    blockDiagramHeapLayout,
  ),

  /// Front-panel heap in the `c` encoding, which is not a C4 record heap; not decoded.
  fphc('FPHc', 'Front-panel heap, variant c', BlockCategory.frontPanelHeap, BlockConfidence.tentative),

  /// Block-diagram heap in the `c` encoding, which is not a C4 record heap; not decoded.
  bdhc('BDHc', 'Block-diagram heap, variant c', BlockCategory.blockDiagramHeap, BlockConfidence.tentative),

  /// Front-panel heap in the `P` encoding; not decoded.
  fphp('FPHP', 'Front-panel heap, variant P', BlockCategory.frontPanelHeap, BlockConfidence.tentative),

  /// Block-diagram heap in the `P` encoding; not decoded.
  bdhp('BDHP', 'Block-diagram heap, variant P', BlockCategory.blockDiagramHeap, BlockConfidence.tentative),

  /// Type-descriptor pool: every data type of the VI, referenced by index from the heaps, [tm80] and [conp].
  vctp('VCTP', 'VI type pool', BlockCategory.typeInfo, BlockConfidence.confirmed, decodeTypePool, vctpLayout),

  /// Data-space type map (LabVIEW 8.0 and later): a flag word per top-level [vctp] type selecting its data-space role.
  tm80('TM80', 'Data-space type map', BlockCategory.typeInfo, BlockConfidence.confirmed, decodeTypeMap, tm80Layout),

  /// Predecessor of [tm80] whose type descriptors are stored inline; not decoded.
  dstm('DSTM', 'Data-space type map, inline types', BlockCategory.typeInfo, BlockConfidence.tentative),

  /// Locates the heap type-descriptor index range within the [vctp] top-level list.
  dthp('DTHP', 'Data-type heap table', BlockCategory.typeInfo, BlockConfidence.likely, decodeDataTypeHeap, dthpLayout),

  /// Front-panel type descriptors as a grid of u16 words.
  fptd(
    'FPTD',
    'Front-panel type descriptors',
    BlockCategory.typeInfo,
    BlockConfidence.likely,
    decodeU16Grid,
    fptdLayout,
  ),

  /// Compiled machine code for one target architecture, with its symbol table.
  vicd(
    'VICD',
    'VI compiled code',
    BlockCategory.compiledCode,
    BlockConfidence.confirmed,
    decodeCompiledCode,
    vicdLayout,
  ),

  /// Default data space: the flattened default values of the types [tm80] marks as saved, laid out per their [vctp] type.
  dfds('DFDS', 'Default data space', BlockCategory.dataSpace, BlockConfidence.likely),

  /// Data-space image: an icon raster or a PNG behind a raster header.
  dsim(
    'DSIM',
    'Data-space image',
    BlockCategory.dataSpace,
    BlockConfidence.confirmed,
    decodeDataSpaceImage,
    dsimLayout,
  ),

  /// Connector pane: the [vctp] index of the pane type.
  conp(
    'CONP',
    'Connector pane',
    BlockCategory.connectorPane,
    BlockConfidence.confirmed,
    decodeConnectorPane,
    connectorPaneLayout,
  ),

  /// Connector-pane reference in the compiled form.
  cpc2(
    'CPC2',
    'Connector pane, compiled',
    BlockCategory.connectorPane,
    BlockConfidence.likely,
    decodeConnectorPane,
    connectorPaneLayout,
  ),

  /// Connector pane map: which panel object each pane terminal is wired to.
  cpmp(
    'CPMp',
    'Connector pane map',
    BlockCategory.connectorPane,
    BlockConfidence.confirmed,
    decodeConnectorPaneMap,
    cpmpLayout,
  ),

  /// Connector-pane data, one u16.
  cpd2(
    'CPD2',
    'Connector-pane data v2',
    BlockCategory.connectorPane,
    BlockConfidence.likely,
    decodeCpd2Record,
    cpd2Layout,
  ),

  /// Listed by the LabVIEW wiki; not in the corpus.
  cpct('CPCT', 'Connector port content type', BlockCategory.connectorPane, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  cpdi('CPDI', 'Connector port DI', BlockCategory.connectorPane, BlockConfidence.tentative),

  /// Not decoded.
  cptm('CPTM', 'Connector-pane TM', BlockCategory.unknown, BlockConfidence.tentative),

  /// 32x32 icon at 8 bits per pixel in the Mac `icl8` layout.
  icl8('icl8', 'Icon, 8-bit', BlockCategory.icon, BlockConfidence.confirmed, decodeIcl8, icl8Layout),

  /// 32x32 icon at 4 bits per pixel in the Mac `icl4` layout.
  icl4('icl4', 'Icon, 4-bit', BlockCategory.icon, BlockConfidence.confirmed, decodeIcl4, icl4Layout),

  /// 32x32 icon at 1 bit per pixel in the Mac `ICON` layout.
  icon('ICON', 'Icon, 1-bit', BlockCategory.icon, BlockConfidence.confirmed, decodeIcon1, iconLayout),

  /// Icon placement rectangle.
  picc('PICC', 'Icon placement', BlockCategory.icon, BlockConfidence.confirmed, decodeIconPlacement, piccLayout),

  /// Mac icon-list resource; not in the corpus.
  icnList('ICN#', 'Icon with mask, 1-bit', BlockCategory.icon, BlockConfidence.tentative),

  /// Mac small icon-list resource; not in the corpus.
  icsList('ics#', 'Small icon with mask, 1-bit', BlockCategory.icon, BlockConfidence.tentative),

  /// Mac small icon resource; not in the corpus.
  ics4('ics4', 'Small icon, 4-bit', BlockCategory.icon, BlockConfidence.tentative),

  /// Mac small icon resource; not in the corpus.
  ics8('ics8', 'Small icon, 8-bit', BlockCategory.icon, BlockConfidence.tentative),

  /// Mac cursor resource; not in the corpus.
  curs('CURS', 'Cursor, 1-bit', BlockCategory.icon, BlockConfidence.tentative),

  /// QuickDraw PICT v2 picture: an opcode stream ending at OpEndPic.
  pict('PICT', 'Mac PICT picture', BlockCategory.image, BlockConfidence.confirmed, decodePict, pictLayout),

  /// A picture as a PNG stream, or occasionally an MNG stream.
  mngi('MNGI', 'PNG image', BlockCategory.image, BlockConfidence.confirmed, decodePngStream, mngiLayout),

  /// Windows enhanced metafile: EMR_HEADER followed by self-sized records ending at EMR_EOF.
  wemf('WEMF', 'Windows enhanced metafile', BlockCategory.image, BlockConfidence.confirmed, decodeEmf, wemfLayout),

  /// Listed by the LabVIEW wiki; not in the corpus.
  pngi('PNGI', 'PNG image', BlockCategory.image, BlockConfidence.tentative),

  /// Link info for the VI: linked resources by name and path.
  livi('LIvi', 'Link info: VI', BlockCategory.linkInfo, BlockConfidence.confirmed, decodeLinkInfo, linkInfoLayout),

  /// Link info for the front panel: typedefs and controls by name.
  lifp(
    'LIfp',
    'Link info: front panel',
    BlockCategory.linkInfo,
    BlockConfidence.confirmed,
    decodeLinkInfo,
    linkInfoLayout,
  ),

  /// Link info for the block diagram: sub-VIs by name and path.
  libd(
    'LIbd',
    'Link info: block diagram',
    BlockCategory.linkInfo,
    BlockConfidence.confirmed,
    decodeLinkInfo,
    linkInfoLayout,
  ),

  /// Link info for the data space.
  lids(
    'LIds',
    'Link info: data space',
    BlockCategory.linkInfo,
    BlockConfidence.confirmed,
    decodeLinkInfo,
    linkInfoLayout,
  ),

  /// Linked-instance info as a grid of u32 words; semantics not decoded.
  lpin(
    'LPIN',
    'Linked-instance info',
    BlockCategory.linkInfo,
    BlockConfidence.tentative,
    decodeWordGrid,
    wordGridLayout,
  ),

  /// Names of the libraries owning the VI, stored in the embedded section namespace.
  libn('LIBN', 'Library names', BlockCategory.nameTable, BlockConfidence.confirmed, decodeLibraryNames, libnLayout),

  /// An embedded VI, itself a complete RSRC file, stored in the embedded section namespace.
  vins('VINS', 'Embedded VI', BlockCategory.embeddedVi, BlockConfidence.confirmed, decodeEmbeddedVi, vinsLayout),

  /// VI description text.
  strg('STRG', 'VI description', BlockCategory.text, BlockConfidence.confirmed, decodeStringBlock, stringBlockLayout),

  /// Begins with a version word; layout not decoded.
  str('STR ', 'String', BlockCategory.text, BlockConfidence.tentative),

  /// VI title as a Pascal string.
  titl('TITL', 'VI title', BlockCategory.text, BlockConfidence.confirmed, decodeTitle, titlLayout),

  /// Context-help text, in the [strg] layout.
  hlpt('HLPT', 'Help text', BlockCategory.text, BlockConfidence.confirmed, decodeStringBlock, stringBlockLayout),

  /// Context-help document path (PTH0).
  hlpp('HLPP', 'Help path', BlockCategory.helpPath, BlockConfidence.confirmed, decodeHelpPath, helpPathLayout),

  /// Path of a linked DLL (PTH0).
  dllp('DLLP', 'DLL path', BlockCategory.helpPath, BlockConfidence.likely, decodeHelpPath, helpPathLayout),

  /// Help-related; not decoded.
  hlpu('HLPU', 'Help URL', BlockCategory.helpPath, BlockConfidence.tentative),

  /// Help-related; not decoded.
  hlpx('HLPX', 'Help (X)', BlockCategory.helpPath, BlockConfidence.tentative),

  /// Help-related; not decoded.
  hlpw('HLPW', 'Help (W)', BlockCategory.helpPath, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  lpth('LPTH', 'L. path', BlockCategory.helpPath, BlockConfidence.tentative),

  /// LabVIEW save record: the saving version and save-time settings.
  lvsr('LVSR', 'LabVIEW save record', BlockCategory.settings, BlockConfidence.confirmed, decodeSaveRecord, lvsrLayout),

  /// Version record in the Mac `vers` layout: numeric version plus short and long version strings.
  vers('vers', 'Version record', BlockCategory.settings, BlockConfidence.confirmed, decodeVersBlock, versLayout),

  /// LabVIEW 4.0 and older; listed by the LabVIEW wiki, not in the corpus.
  flag('FLAG', 'Integer flags', BlockCategory.settings, BlockConfidence.tentative),

  /// LabVIEW 4.0 and older; listed by the LabVIEW wiki, not in the corpus.
  lvin('LVIN', 'VI info', BlockCategory.settings, BlockConfidence.tentative),

  /// Block-diagram password: an MD5 digest of the password followed by derived digests.
  bdpw(
    'BDPW',
    'Block-diagram password',
    BlockCategory.security,
    BlockConfidence.confirmed,
    decodePasswordRecord,
    bdpwLayout,
  ),

  /// Font table: per-font metric records followed by packed Pascal names.
  ftab('FTAB', 'Font table', BlockCategory.nameTable, BlockConfidence.confirmed, decodeFontTable, ftabLayout),

  /// VI tag store: named, typed tag values.
  vits('VITS', 'VI tag store', BlockCategory.nameTable, BlockConfidence.confirmed, decodeTagStore, vitsLayout),

  /// Revision history record.
  hist('HIST', 'Revision history', BlockCategory.history, BlockConfidence.confirmed, decodeHistory, histLayout),

  /// Modified UID, one u32.
  muid('MUID', 'Modified UID', BlockCategory.identifier, BlockConfidence.confirmed, decodeModifiedUid, muidLayout),

  /// New UID table.
  nuid('NUID', 'New UID table', BlockCategory.identifier, BlockConfidence.confirmed, decodeIdTable, idTableLayout),

  /// Saved UID table.
  suid('SUID', 'Saved UID table', BlockCategory.identifier, BlockConfidence.confirmed, decodeIdTable, idTableLayout),

  /// Block-name id table.
  bnid(
    'BNID',
    'Block-name id table',
    BlockCategory.identifier,
    BlockConfidence.confirmed,
    decodeIdTable,
    idTableLayout,
  ),

  /// Not decoded.
  omid('OMId', 'Object-map id', BlockCategory.identifier, BlockConfidence.tentative),

  /// Not decoded.
  rsid('RSID', 'Resource id', BlockCategory.identifier, BlockConfidence.tentative),

  /// Run-time signature, a 16-byte digest.
  rtsg(
    'RTSG',
    'Run-time signature',
    BlockCategory.identifier,
    BlockConfidence.confirmed,
    decodeSignature,
    signatureLayout,
  ),

  /// Object signature, a 16-byte digest.
  obsg(
    'OBSG',
    'Object signature',
    BlockCategory.identifier,
    BlockConfidence.confirmed,
    decodeSignature,
    signatureLayout,
  ),

  /// Compiled-code signature, a 16-byte digest.
  ccsg(
    'CCSG',
    'Compiled-code signature',
    BlockCategory.identifier,
    BlockConfidence.confirmed,
    decodeSignature,
    signatureLayout,
  ),

  /// Source signature: a marker word and a 16-byte digest.
  scsr(
    'SCSR',
    'Source signature',
    BlockCategory.identifier,
    BlockConfidence.confirmed,
    decodeSourceSignature,
    scsrLayout,
  ),

  /// Generated-code property record.
  gcpr(
    'GCPR',
    'Generated-code property',
    BlockCategory.identifier,
    BlockConfidence.confirmed,
    decodeGcprRecord,
    gcprLayout,
  ),

  /// Generated-code debug info.
  gcdi(
    'GCDI',
    'Generated-code debug info',
    BlockCategory.identifier,
    BlockConfidence.tentative,
    decodeGcdiRecord,
    gcdiLayout,
  ),

  /// Front-panel section entry: one or two u32 words.
  fpse(
    'FPSE',
    'Front-panel section entry',
    BlockCategory.unknown,
    BlockConfidence.confirmed,
    decodeSectionEntry,
    sectionEntryLayout,
  ),

  /// Block-diagram section entry: one or two u32 words.
  bdse(
    'BDSE',
    'Block-diagram section entry',
    BlockCategory.unknown,
    BlockConfidence.confirmed,
    decodeSectionEntry,
    sectionEntryLayout,
  ),

  /// Front-panel extended state words.
  fpex(
    'FPEx',
    'Front-panel extended state',
    BlockCategory.unknown,
    BlockConfidence.confirmed,
    decodeExtendedState,
    extendedStateLayout,
  ),

  /// Block-diagram extended state words.
  bdex(
    'BDEx',
    'Block-diagram extended state',
    BlockCategory.unknown,
    BlockConfidence.confirmed,
    decodeExtendedState,
    extendedStateLayout,
  ),

  /// Not decoded.
  fpts('FPTS', 'Front-panel TS', BlockCategory.unknown, BlockConfidence.tentative),

  /// Block-diagram TS as a grid of u32 words; semantics not decoded.
  bdts('BDTS', 'Block-diagram TS', BlockCategory.unknown, BlockConfidence.tentative, decodeWordGrid, wordGridLayout),

  /// VI property data record.
  vpdp('VPDP', 'VI property data', BlockCategory.unknown, BlockConfidence.confirmed, decodeVpdpRecord, vpdpLayout),

  /// Print settings record.
  prt('PRT ', 'Print settings', BlockCategory.unknown, BlockConfidence.confirmed, decodePrintRecord, prtLayout),

  /// Default-data loader record, seven u32 words.
  dldr('DLDR', 'Default-data loader', BlockCategory.unknown, BlockConfidence.confirmed, decodeDldrRecord, dldrLayout),

  /// Type record: a 72-byte header followed by length-prefixed text runs.
  trec('TRec', 'Type record', BlockCategory.unknown, BlockConfidence.confirmed, decodeTextRecord, trecLayout),

  /// Compiled-code state: a key/value table.
  ccst('CCST', 'Compiled-code state', BlockCategory.unknown, BlockConfidence.likely, decodeKeyValueTable, ccstLayout),

  /// Align table: offset, value and kind per entry.
  bfal('BFAL', 'Align table', BlockCategory.unknown, BlockConfidence.confirmed, decodeAlignTable, bfalLayout),

  /// Bookmarks: two tables of text entries.
  bkmk('BKMK', 'Bookmarks', BlockCategory.unknown, BlockConfidence.likely, decodeBookmarkList, bkmkLayout),

  /// Constants as a grid of u32 words; semantics not decoded.
  cnst('CNST', 'Constants', BlockCategory.unknown, BlockConfidence.tentative, decodeWordGrid, wordGridLayout),

  /// Non-decreasing u32 offset table; semantics not decoded.
  ipsr('IPSR', 'IP source record', BlockCategory.unknown, BlockConfidence.tentative, decodeOffsetTable, ipsrLayout),

  /// Boolean text table: a count of Pascal strings.
  cpst(
    'CPST',
    'Boolean-text table',
    BlockCategory.text,
    BlockConfidence.likely,
    decodePascalStringTable,
    pascalStringTableLayout,
  ),

  /// Boolean text table (spec): a count of Pascal strings.
  cpsp(
    'CPSP',
    'Boolean-text table, spec',
    BlockCategory.text,
    BlockConfidence.likely,
    decodePascalStringTable,
    pascalStringTableLayout,
  ),

  /// Not decoded.
  gtmi('GTMI', 'Get-TM info', BlockCategory.unknown, BlockConfidence.tentative),

  /// Not decoded.
  hbin('HBIN', 'Heap bin', BlockCategory.unknown, BlockConfidence.tentative),

  /// Not decoded.
  hbuf('HBUF', 'Heap buffer', BlockCategory.unknown, BlockConfidence.tentative),

  /// Compiled output, three u32 words.
  cout('COUT', 'Compiled output', BlockCategory.unknown, BlockConfidence.likely, decodeCoutRecord, coutLayout),

  /// Not decoded.
  rtmp('RTMP', 'Run-time map / path', BlockCategory.unknown, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  dlgh('DLGH', 'Dialog HTML', BlockCategory.text, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  errh('ERRH', 'Error HTML', BlockCategory.text, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  nodh('NODH', 'NOD HTML', BlockCategory.text, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  noeg('NOEG', 'NOEG string', BlockCategory.text, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  mitm('MItm', 'M. item', BlockCategory.unknown, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  dnmList('DNm#', 'D. name strings list', BlockCategory.text, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  hdbList('HDb#', 'Help database item', BlockCategory.text, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  lstList('LST#', 'Short strings list', BlockCategory.text, BlockConfidence.tentative),

  /// Mac string-list resource; listed by the LabVIEW wiki, not in the corpus.
  strList('STR#', 'Short strings list', BlockCategory.text, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  fdfl('FDFL', 'FDFL strings', BlockCategory.text, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  cgrs('CGRS', 'Conglomerate resource', BlockCategory.unknown, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  lvzp('LVzp', 'Zipped application', BlockCategory.unknown, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  bdht('BDHT', 'Block-diagram heap, text', BlockCategory.text, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  fpht('FPHT', 'Front-panel heap, text', BlockCategory.text, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  bdhx('BDHX', 'Block-diagram heap, XML', BlockCategory.text, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  fphx('FPHX', 'Front-panel heap, XML', BlockCategory.text, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  ucrf('UCRF', 'Uncompressed resource file', BlockCategory.unknown, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  cprf('CPRF', 'Compressed resource file', BlockCategory.unknown, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  zcrf('ZCRF', 'Zlib-compressed resource file', BlockCategory.unknown, BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  dlg3('DLG3', 'Dialog resource file', BlockCategory.unknown, BlockConfidence.tentative)
  ;

  const BlockTag(this.tag, this.displayName, this.category, this.confidence, [this.decode, this.layout]);

  /// The four-character section tag as stored in the block list.
  final String tag;

  final String displayName;

  final BlockCategory category;

  final BlockConfidence confidence;

  /// Decodes one section payload; null while the layout is not decoded, and for [dfds],
  /// which needs sibling blocks.
  final Object? Function(Uint8List)? decode;

  /// The payload's byte layout, rendered into the block file's doc comment by
  /// `tool/gen_block_docs.dart`; null while the layout is not decoded.
  final BlockLayout? layout;

  /// The C4 record heaps that `walkHeapBody` and `buildDiagram` read.
  static const Set<BlockTag> recordHeaps = {fphb, bdhb};

  bool get isRecordHeap => recordHeaps.contains(this);

  bool get isDecoded => decode != null || this == dfds;

  static final Map<String, BlockTag> _byTag = {for (final t in values) t.tag: t};

  /// The tag whose [tag] is exactly [text], or null for one this package does not know.
  static BlockTag? of(String text) => _byTag[text];
}
