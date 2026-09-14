import 'dart:typed_data';

import 'block_layout.dart';
import 'block_record.dart';
import 'blocks/BDHb_BDHc_BDHP_block_diagram.dart';
import 'blocks/BDPW_password.dart';
import 'blocks/BDTS_diagram_tag_store.dart';
import 'blocks/BFAL_align_table.dart';
import 'blocks/BKMK_bookmarks.dart';
import 'blocks/CCST_compiled_code_state.dart';
import 'blocks/CNST_LPIN_word_grid.dart';
import 'blocks/CONP_CPC2_connector_pane.dart';
import 'blocks/COUT_compiled_output.dart';
import 'blocks/CPD2_connector_pane_data.dart';
import 'blocks/CPMp_connector_pane_map.dart';
import 'blocks/CPST_CPSP_pascal_string_table.dart';
import 'blocks/DFDS_default_data_space.dart';
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
import 'decode.dart' show inflateHeapPayload;

/// How far a block's layout is established.
enum BlockConfidence {
  /// The layout is decoded and re-serializes byte-exactly across the corpus.
  confirmed,

  /// The layout is decoded but some fields or variants are open.
  likely,

  /// The layout is not decoded.
  tentative,
}

/// Every section tag this package knows, with its display name, confidence and payload
/// decoder, declared in family order.
///
/// [tag] is the exact four-character string stored in the block list;
/// `STR ` and `PRT ` end in a space. [of] looks a tag up.
enum BlockTag {
  /// Front-panel object heap, a C4 record heap.
  fphb(
    'FPHb',
    'Front-panel heap',
    BlockConfidence.confirmed,
    decodeFrontPanel,
    frontPanelHeapLayout,
  ),

  /// Block-diagram object heap, a C4 record heap.
  bdhb(
    'BDHb',
    'Block-diagram heap',
    BlockConfidence.confirmed,
    decodeBlockDiagram,
    blockDiagramHeapLayout,
  ),

  /// Front-panel heap in the `c` encoding, which is not a C4 record heap; not decoded.
  fphc('FPHc', 'Front-panel heap, variant c', BlockConfidence.tentative),

  /// Block-diagram heap in the `c` encoding, which is not a C4 record heap; not decoded.
  bdhc('BDHc', 'Block-diagram heap, variant c', BlockConfidence.tentative),

  /// Front-panel heap in the `P` encoding; not decoded.
  fphp('FPHP', 'Front-panel heap, variant P', BlockConfidence.tentative),

  /// Block-diagram heap in the `P` encoding; not decoded.
  bdhp('BDHP', 'Block-diagram heap, variant P', BlockConfidence.tentative),

  /// Type-descriptor pool: every data type of the VI, referenced by index from the heaps, [tm80] and [conp].
  vctp('VCTP', 'VI type pool', BlockConfidence.confirmed, decodeTypePool, vctpLayout),

  /// Data-space type map (LabVIEW 8.0 and later): a flag word per top-level [vctp] type selecting its data-space role.
  tm80('TM80', 'Data-space type map', BlockConfidence.confirmed, decodeTypeMap, tm80Layout),

  /// Predecessor of [tm80] whose type descriptors are stored inline; not decoded.
  dstm('DSTM', 'Data-space type map, inline types', BlockConfidence.tentative),

  /// Locates the heap type-descriptor index range within the [vctp] top-level list.
  dthp('DTHP', 'Data-type heap table', BlockConfidence.likely, decodeDataTypeHeap, dthpLayout),

  /// Front-panel type descriptors as a grid of u16 words.
  fptd(
    'FPTD',
    'Front-panel type descriptors',
    BlockConfidence.likely,
    decodeU16Grid,
    fptdLayout,
  ),

  /// Compiled machine code for one target architecture, with its symbol table.
  vicd(
    'VICD',
    'VI compiled code',
    BlockConfidence.confirmed,
    decodeCompiledCode,
    vicdLayout,
  ),

  /// Default data space: the flattened default values of the types [tm80] marks as saved, laid out per their [vctp] type.
  /// Decoded by `decodeDataSpace` with a [DfdsContext] built from the VI's `VCTP`, `TM80` and
  /// `vers`, so [decode] is null.
  dfds('DFDS', 'Default data space', BlockConfidence.confirmed, null, dfdsLayout),

  /// Data-space image: an icon raster or a PNG behind a raster header.
  dsim(
    'DSIM',
    'Data-space image',
    BlockConfidence.confirmed,
    decodeDataSpaceImage,
    dsimLayout,
  ),

  /// Connector pane: the [vctp] index of the pane type.
  conp(
    'CONP',
    'Connector pane',
    BlockConfidence.confirmed,
    decodeConnectorPane,
    connectorPaneLayout,
  ),

  /// Connector-pane reference in the compiled form.
  cpc2(
    'CPC2',
    'Connector pane, compiled',
    BlockConfidence.likely,
    decodeConnectorPane,
    connectorPaneLayout,
  ),

  /// Connector pane map: which panel object each pane terminal is wired to.
  cpmp(
    'CPMp',
    'Connector pane map',
    BlockConfidence.confirmed,
    decodeConnectorPaneMap,
    cpmpLayout,
  ),

  /// Connector-pane data, one u16.
  cpd2(
    'CPD2',
    'Connector-pane data v2',
    BlockConfidence.likely,
    decodeCpd2Record,
    cpd2Layout,
  ),

  /// Listed by the LabVIEW wiki; not in the corpus.
  cpct('CPCT', 'Connector port content type', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  cpdi('CPDI', 'Connector port DI', BlockConfidence.tentative),

  /// Not decoded.
  cptm('CPTM', 'Connector-pane TM', BlockConfidence.tentative),

  /// 32x32 icon at 8 bits per pixel in the Mac `icl8` layout.
  icl8('icl8', 'Icon, 8-bit', BlockConfidence.confirmed, decodeIcl8, icl8Layout),

  /// 32x32 icon at 4 bits per pixel in the Mac `icl4` layout.
  icl4('icl4', 'Icon, 4-bit', BlockConfidence.confirmed, decodeIcl4, icl4Layout),

  /// 32x32 icon at 1 bit per pixel in the Mac `ICON` layout.
  icon('ICON', 'Icon, 1-bit', BlockConfidence.confirmed, decodeIcon1, iconLayout),

  /// Icon placement rectangle.
  picc('PICC', 'Icon placement', BlockConfidence.confirmed, decodeIconPlacement, piccLayout),

  /// Mac icon-list resource; not in the corpus.
  icnList('ICN#', 'Icon with mask, 1-bit', BlockConfidence.tentative),

  /// Mac small icon-list resource; not in the corpus.
  icsList('ics#', 'Small icon with mask, 1-bit', BlockConfidence.tentative),

  /// Mac small icon resource; not in the corpus.
  ics4('ics4', 'Small icon, 4-bit', BlockConfidence.tentative),

  /// Mac small icon resource; not in the corpus.
  ics8('ics8', 'Small icon, 8-bit', BlockConfidence.tentative),

  /// Mac cursor resource; not in the corpus.
  curs('CURS', 'Cursor, 1-bit', BlockConfidence.tentative),

  /// QuickDraw PICT v2 picture: an opcode stream ending at OpEndPic.
  pict('PICT', 'Mac PICT picture', BlockConfidence.confirmed, decodePict, pictLayout),

  /// A picture as a PNG stream, or occasionally an MNG stream.
  mngi('MNGI', 'PNG image', BlockConfidence.confirmed, decodePngStream, mngiLayout),

  /// Windows enhanced metafile: EMR_HEADER followed by self-sized records ending at EMR_EOF.
  wemf('WEMF', 'Windows enhanced metafile', BlockConfidence.confirmed, decodeEmf, wemfLayout),

  /// Listed by the LabVIEW wiki; not in the corpus.
  pngi('PNGI', 'PNG image', BlockConfidence.tentative),

  /// Link info for the VI: linked resources by name and path.
  livi('LIvi', 'Link info: VI', BlockConfidence.confirmed, decodeLinkInfo, linkInfoLayout),

  /// Link info for the front panel: typedefs and controls by name.
  lifp(
    'LIfp',
    'Link info: front panel',
    BlockConfidence.confirmed,
    decodeLinkInfo,
    linkInfoLayout,
  ),

  /// Link info for the block diagram: sub-VIs by name and path.
  libd(
    'LIbd',
    'Link info: block diagram',
    BlockConfidence.confirmed,
    decodeLinkInfo,
    linkInfoLayout,
  ),

  /// Link info for the data space.
  lids(
    'LIds',
    'Link info: data space',
    BlockConfidence.confirmed,
    decodeLinkInfo,
    linkInfoLayout,
  ),

  /// Linked-instance info as a grid of u32 words; semantics not decoded.
  lpin(
    'LPIN',
    'Linked-instance info',
    BlockConfidence.tentative,
    decodeWordGrid,
    wordGridLayout,
  ),

  /// Names of the libraries owning the VI, stored in the embedded section namespace.
  libn('LIBN', 'Library names', BlockConfidence.confirmed, decodeLibraryNames, libnLayout),

  /// An embedded VI, itself a complete RSRC file, stored in the embedded section namespace.
  vins('VINS', 'Embedded VI', BlockConfidence.confirmed, decodeEmbeddedVi, vinsLayout),

  /// VI description text.
  strg('STRG', 'VI description', BlockConfidence.confirmed, decodeStringBlock, stringBlockLayout),

  /// Begins with a version word; layout not decoded.
  str('STR ', 'String', BlockConfidence.tentative),

  /// VI title as a Pascal string.
  titl('TITL', 'VI title', BlockConfidence.confirmed, decodeTitle, titlLayout),

  /// Context-help text, in the [strg] layout.
  hlpt('HLPT', 'Help text', BlockConfidence.confirmed, decodeStringBlock, stringBlockLayout),

  /// Context-help document path (PTH0).
  hlpp('HLPP', 'Help path', BlockConfidence.confirmed, decodeHelpPath, helpPathLayout),

  /// Path of a linked DLL (PTH0).
  dllp('DLLP', 'DLL path', BlockConfidence.likely, decodeHelpPath, helpPathLayout),

  /// Help-related; not decoded.
  hlpu('HLPU', 'Help URL', BlockConfidence.tentative),

  /// Help-related; not decoded.
  hlpx('HLPX', 'Help (X)', BlockConfidence.tentative),

  /// Help-related; not decoded.
  hlpw('HLPW', 'Help (W)', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  lpth('LPTH', 'L. path', BlockConfidence.tentative),

  /// LabVIEW save record: the saving version and save-time settings.
  lvsr('LVSR', 'LabVIEW save record', BlockConfidence.confirmed, decodeSaveRecord, lvsrLayout),

  /// Version record in the Mac `vers` layout: numeric version plus short and long version strings.
  vers('vers', 'Version record', BlockConfidence.confirmed, decodeVersBlock, versLayout),

  /// LabVIEW 4.0 and older; listed by the LabVIEW wiki, not in the corpus.
  flag('FLAG', 'Integer flags', BlockConfidence.tentative),

  /// LabVIEW 4.0 and older; listed by the LabVIEW wiki, not in the corpus.
  lvin('LVIN', 'VI info', BlockConfidence.tentative),

  /// Block-diagram password: an MD5 digest of the password followed by derived digests.
  bdpw(
    'BDPW',
    'Block-diagram password',
    BlockConfidence.confirmed,
    decodePasswordRecord,
    bdpwLayout,
  ),

  /// Font table: per-font metric records followed by packed Pascal names.
  ftab('FTAB', 'Font table', BlockConfidence.confirmed, decodeFontTable, ftabLayout),

  /// VI tag store: named, typed tag values.
  vits('VITS', 'VI tag store', BlockConfidence.confirmed, decodeTagStore, vitsLayout),

  /// Revision history record.
  hist('HIST', 'Revision history', BlockConfidence.confirmed, decodeHistory, histLayout),

  /// Modified UID, one u32.
  muid('MUID', 'Modified UID', BlockConfidence.confirmed, decodeModifiedUid, muidLayout),

  /// New UID table.
  nuid('NUID', 'New UID table', BlockConfidence.confirmed, decodeIdTable, idTableLayout),

  /// Saved UID table.
  suid('SUID', 'Saved UID table', BlockConfidence.confirmed, decodeIdTable, idTableLayout),

  /// Block-name id table.
  bnid(
    'BNID',
    'Block-name id table',
    BlockConfidence.confirmed,
    decodeIdTable,
    idTableLayout,
  ),

  /// Not decoded.
  omid('OMId', 'Object-map id', BlockConfidence.tentative),

  /// Not decoded.
  rsid('RSID', 'Resource id', BlockConfidence.tentative),

  /// Run-time signature, a 16-byte digest.
  rtsg(
    'RTSG',
    'Run-time signature',
    BlockConfidence.confirmed,
    decodeSignature,
    signatureLayout,
  ),

  /// Object signature, a 16-byte digest.
  obsg(
    'OBSG',
    'Object signature',
    BlockConfidence.confirmed,
    decodeSignature,
    signatureLayout,
  ),

  /// Compiled-code signature, a 16-byte digest.
  ccsg(
    'CCSG',
    'Compiled-code signature',
    BlockConfidence.confirmed,
    decodeSignature,
    signatureLayout,
  ),

  /// Source signature: a marker word and a 16-byte digest.
  scsr(
    'SCSR',
    'Source signature',
    BlockConfidence.confirmed,
    decodeSourceSignature,
    scsrLayout,
  ),

  /// Generated-code property record.
  gcpr(
    'GCPR',
    'Generated-code property',
    BlockConfidence.confirmed,
    decodeGcprRecord,
    gcprLayout,
  ),

  /// Generated-code debug info.
  gcdi(
    'GCDI',
    'Generated-code debug info',
    BlockConfidence.tentative,
    decodeGcdiRecord,
    gcdiLayout,
  ),

  /// Front-panel section entry: one or two u32 words.
  fpse(
    'FPSE',
    'Front-panel section entry',
    BlockConfidence.confirmed,
    decodeSectionEntry,
    sectionEntryLayout,
  ),

  /// Block-diagram section entry: one or two u32 words.
  bdse(
    'BDSE',
    'Block-diagram section entry',
    BlockConfidence.confirmed,
    decodeSectionEntry,
    sectionEntryLayout,
  ),

  /// Front-panel extended state words.
  fpex(
    'FPEx',
    'Front-panel extended state',
    BlockConfidence.confirmed,
    decodeExtendedState,
    extendedStateLayout,
  ),

  /// Block-diagram extended state words.
  bdex(
    'BDEx',
    'Block-diagram extended state',
    BlockConfidence.confirmed,
    decodeExtendedState,
    extendedStateLayout,
  ),

  /// Not decoded.
  fpts('FPTS', 'Front-panel TS', BlockConfidence.tentative),

  /// Block-diagram TS as a grid of u32 words; semantics not decoded.
  bdts(
    'BDTS',
    'Block-diagram tag store',
    BlockConfidence.confirmed,
    decodeDiagramTagStore,
    bdtsLayout,
  ),

  /// VI property data record.
  vpdp('VPDP', 'VI property data', BlockConfidence.confirmed, decodeVpdpRecord, vpdpLayout),

  /// Print settings record.
  prt('PRT ', 'Print settings', BlockConfidence.confirmed, decodePrintRecord, prtLayout),

  /// Default-data loader record, seven u32 words.
  dldr('DLDR', 'Default-data loader', BlockConfidence.confirmed, decodeDldrRecord, dldrLayout),

  /// Type record: a 72-byte header followed by length-prefixed text runs.
  trec('TRec', 'Type record', BlockConfidence.confirmed, decodeTextRecord, trecLayout),

  /// Compiled-code state: a key/value table.
  ccst('CCST', 'Compiled-code state', BlockConfidence.likely, decodeKeyValueTable, ccstLayout),

  /// Align table: offset, value and kind per entry.
  bfal('BFAL', 'Align table', BlockConfidence.confirmed, decodeAlignTable, bfalLayout),

  /// Bookmarks: two tables of text entries.
  bkmk('BKMK', 'Bookmarks', BlockConfidence.likely, decodeBookmarkList, bkmkLayout),

  /// Constants as a grid of u32 words; semantics not decoded.
  cnst('CNST', 'Constants', BlockConfidence.tentative, decodeWordGrid, wordGridLayout),

  /// Non-decreasing u32 offset table; semantics not decoded.
  ipsr('IPSR', 'IP source record', BlockConfidence.tentative, decodeOffsetTable, ipsrLayout),

  /// Boolean text table: a count of Pascal strings.
  cpst(
    'CPST',
    'Boolean-text table',
    BlockConfidence.likely,
    decodePascalStringTable,
    pascalStringTableLayout,
  ),

  /// Boolean text table (spec): a count of Pascal strings.
  cpsp(
    'CPSP',
    'Boolean-text table, spec',
    BlockConfidence.likely,
    decodePascalStringTable,
    pascalStringTableLayout,
  ),

  /// Not decoded.
  gtmi('GTMI', 'Get-TM info', BlockConfidence.tentative),

  /// Not decoded.
  hbin('HBIN', 'Heap bin', BlockConfidence.tentative),

  /// Not decoded.
  hbuf('HBUF', 'Heap buffer', BlockConfidence.tentative),

  /// Compiled output, three u32 words.
  cout('COUT', 'Compiled output', BlockConfidence.likely, decodeCoutRecord, coutLayout),

  /// Not decoded.
  rtmp('RTMP', 'Run-time map / path', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  dlgh('DLGH', 'Dialog HTML', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  errh('ERRH', 'Error HTML', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  nodh('NODH', 'NOD HTML', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  noeg('NOEG', 'NOEG string', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  mitm('MItm', 'M. item', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  dnmList('DNm#', 'D. name strings list', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  hdbList('HDb#', 'Help database item', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  lstList('LST#', 'Short strings list', BlockConfidence.tentative),

  /// Mac string-list resource; listed by the LabVIEW wiki, not in the corpus.
  strList('STR#', 'Short strings list', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  fdfl('FDFL', 'FDFL strings', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  cgrs('CGRS', 'Conglomerate resource', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  lvzp('LVzp', 'Zipped application', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  bdht('BDHT', 'Block-diagram heap, text', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  fpht('FPHT', 'Front-panel heap, text', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  bdhx('BDHX', 'Block-diagram heap, XML', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  fphx('FPHX', 'Front-panel heap, XML', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  ucrf('UCRF', 'Uncompressed resource file', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  cprf('CPRF', 'Compressed resource file', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  zcrf('ZCRF', 'Zlib-compressed resource file', BlockConfidence.tentative),

  /// Listed by the LabVIEW wiki; not in the corpus.
  dlg3('DLG3', 'Dialog resource file', BlockConfidence.tentative)
  ;

  const BlockTag(this.tag, this.displayName, this.confidence, [this.decode, this.layout]);

  /// The four-character section tag as stored in the block list.
  final String tag;

  final String displayName;

  final BlockConfidence confidence;

  /// Decodes one section payload; null while the layout is not decoded, and for [dfds],
  /// which needs sibling blocks.
  final Object? Function(Uint8List)? decode;

  /// The payload's byte layout, rendered into the block file's doc comment by
  /// `tool/gen_block_docs.dart`; null while the layout is not decoded.
  final BlockLayout? layout;

  /// The C4 record heaps that `walkHeapBody` and `buildDiagram` read.
  static const Set<BlockTag> recordHeaps = {fphb, bdhb};

  /// The front panel's object heap in every encoding.
  static const Set<BlockTag> frontPanelHeaps = {fphb, fphc, fphp};

  /// The block diagram's object heap in every encoding.
  static const Set<BlockTag> blockDiagramHeaps = {bdhb, bdhc, bdhp};

  bool get isRecordHeap => recordHeaps.contains(this);

  /// Whether the payload has a model: a [decode] function, or for [dfds] the context-taking
  /// `decodeDataSpace`.
  bool get isDecoded => decode != null || this == dfds;

  /// Whether [decode] yields a [BlockRecord], so the payload can be re-emitted through the model.
  bool get hasWriter => decode is BlockRecord Function(Uint8List);

  /// Decodes [payload] when the tag [hasWriter], else null.
  BlockRecord? decodeRecord(Uint8List payload) => switch (decode) {
    final BlockRecord Function(Uint8List) decode => decode(payload),
    _ => null,
  };

  /// Tags whose payload may be stored in the zlib envelope, a `u32` inflated length followed by
  /// a zlib stream that [inflateHeapPayload] opens; [tm80], [vicd] and [dfds] payloads also occur
  /// without it.
  static const Set<BlockTag> enveloped = {fphb, bdhb, fphc, bdhc, dfds, gcdi, tm80, vctp, vicd};

  bool get isEnveloped => enveloped.contains(this);

  static final Map<String, BlockTag> _byTag = {for (final t in values) t.tag: t};

  /// The tag whose [tag] is exactly [text], or null for one this package does not know.
  static BlockTag? of(String text) => _byTag[text];
}
