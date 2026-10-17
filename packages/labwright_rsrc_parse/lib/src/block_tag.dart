import 'dart:typed_data';

import 'blocks/BDHb_BDHc_BDHP_block_diagram.dart';
import 'blocks/BDPW_password.dart';
import 'blocks/BDTS_diagram_tag_store.dart';
import 'blocks/BFAL_align_table.dart';
import 'blocks/BKMK_bookmarks.dart';
import 'blocks/CCST_conditional_symbols.dart';
import 'blocks/CNST_LPIN_node_uid_sets.dart';
import 'blocks/CONP_CPC2_connector_pane.dart';
import 'blocks/COUT_record.dart';
import 'blocks/CPD2_connector_pane_data.dart';
import 'blocks/CPMp_connector_pane_map.dart';
import 'blocks/CPST_CPSP_polymorphic_instance_names.dart';
import 'blocks/DFDS_default_data_space.dart';
import 'blocks/DLDR_record.dart';
import 'blocks/DSIM_data_space_image.dart';
import 'blocks/DTHP_data_type_heap.dart';
import 'blocks/FPEx_BDEx_link_entry_words.dart';
import 'blocks/FPHb_FPHc_FPHP_front_panel.dart';
import 'blocks/FPSE_BDSE_section_entry.dart';
import 'blocks/FPTD_front_panel_datalog_type.dart';
import 'blocks/FTAB_font_table.dart';
import 'blocks/GCDI_generated_code_debug_info.dart';
import 'blocks/GCPR_VPDP_constant_record.dart';
import 'blocks/HIST_history.dart';
import 'blocks/IPSR_offset_table.dart';
import 'blocks/LIBN_library_names.dart';
import 'blocks/LIvi_LIbd_LIfp_LIds_link_info.dart';
import 'blocks/LVSR_save_record.dart';
import 'blocks/MNGI_png_image.dart';
import 'blocks/MUID_max_uid.dart';
import 'blocks/NUID_SUID_BNID_id_table.dart';
import 'blocks/PICC_records.dart';
import 'blocks/PICT_picture.dart';
import 'blocks/PRT_print_settings.dart';
import 'blocks/RTSG_OBSG_CCSG_signature.dart';
import 'blocks/SCSR_source_signature.dart';
import 'blocks/STRG_HLPT_string_block.dart';
import 'blocks/TITL_title.dart';
import 'blocks/TM80_type_map.dart';
import 'blocks/TRec_text_record.dart';
import 'blocks/VCTP_type_pool.dart';
import 'blocks/VICD_compiled_code.dart';
import 'blocks/VINS_embedded_vis.dart';
import 'blocks/VITS_tag_store.dart';
import 'blocks/WEMF_metafile.dart';
import 'blocks/icl8_icl4_ICON_icon.dart';
import 'blocks/vers_version.dart';
import 'byte_layout.dart';
import 'byte_record.dart';
import 'decode.dart' show inflateHeapPayload;
import 'pth0.dart';

/// Every section tag this package knows, with its display name and payload
/// decoder, declared in family order.
///
/// [tag] is the exact four-character string stored in the block list;
/// `STR ` and `PRT ` end in a space. [of] looks a tag up.
enum BlockTag {
  /// Front-panel object heap, a C4 record heap.
  fphb(
    'FPHb',
    'Front-panel heap',
    decodeFrontPanel,
    Fphb.layout,
  ),

  /// Block-diagram object heap, a C4 record heap.
  bdhb(
    'BDHb',
    'Block-diagram heap',
    decodeBlockDiagram,
    Bdhb.layout,
  ),

  /// Front-panel heap in the `c` encoding, which is not a C4 record heap; not decoded.
  fphc('FPHc', 'Front-panel heap, variant c'),

  /// Block-diagram heap in the `c` encoding, which is not a C4 record heap; not decoded.
  bdhc('BDHc', 'Block-diagram heap, variant c'),

  /// Front-panel heap in the `P` encoding; not decoded.
  fphp('FPHP', 'Front-panel heap, variant P'),

  /// Block-diagram heap in the `P` encoding; not decoded.
  bdhp('BDHP', 'Block-diagram heap, variant P'),

  /// Type-descriptor pool: every data type of the VI, referenced by index from the heaps, [tm80] and [conp].
  vctp('VCTP', 'VI type pool', ViTypePool.new, ViTypePool.layout),

  /// Data-space type map (LabVIEW 8.0 and later): a flag word per top-level [vctp] type selecting its data-space role.
  tm80('TM80', 'Data-space type map', ViTypeMap.new, ViTypeMapIndexed.layout),

  /// Predecessor of [tm80] whose type descriptors are stored inline; not decoded.
  dstm('DSTM', 'Data-space type map, inline types'),

  /// Locates the heap type-descriptor index range within the [vctp] top-level list.
  dthp('DTHP', 'Data-type heap table', ViDataTypeHeap.new, ViDataTypeHeapCompact.layout),

  /// The front panel's datalog record type: a [vctp] top-level index, or an embedded pool before LabVIEW 8.6.
  fptd(
    'FPTD',
    'Front-panel datalog type',
    ViFrontPanelType.new,
    ViFrontPanelTypeIndex.layout,
  ),

  /// Compiled machine code for one target architecture, with its symbol table.
  vicd(
    'VICD',
    'VI compiled code',
    ViCompiledCode.new,
    ViCompiledCode.layout,
  ),

  /// Default data space: the flattened default values of the types [tm80] marks as saved, laid out per their [vctp] type.
  /// Decoded by `ViDataSpace.new` with a [DfdsContext] built from the VI's `VCTP`, `TM80` and
  /// `vers`, so [decode] is null.
  dfds('DFDS', 'Default data space', null, ViDataSpace.layout),

  /// Data-space image: an icon raster or a PNG behind a raster header.
  dsim(
    'DSIM',
    'Data-space image',
    ViDataSpaceImage.new,
    ViDataSpaceImage.layout,
  ),

  /// The connector pane's function type: a [vctp] top-level index, or an embedded pool before LabVIEW 8.6.
  conp('CONP', 'Connector pane', ViConnectorPane.new, ViConnectorPaneIndex.layout),

  /// A second function type with the same terminals as [conp], in the same forms; role TODO.
  cpc2('CPC2', 'Connector pane, second copy', ViConnectorPane.new, ViConnectorPaneIndex.layout),

  /// Connector pane map: which panel object each pane terminal is wired to.
  cpmp(
    'CPMp',
    'Connector pane map',
    ViConnectorPaneMap.new,
    ViConnectorPaneMap.layout,
  ),

  /// The [cpc2] index again; rare.
  cpd2(
    'CPD2',
    'Connector-pane data v2',
    ViConnectorPaneData.new,
    ViConnectorPaneData.layout,
  ),

  /// Listed by the LabVIEW wiki; not in the corpus.
  cpct('CPCT', 'Connector port content type'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  cpdi('CPDI', 'Connector port DI'),

  /// The LabVIEW 7 predecessor of [conp]; one corpus file, not decoded.
  cptm('CPTM', 'Connector pane, LabVIEW 7'),

  /// 32x32 icon at 8 bits per pixel in the Mac `icl8` layout.
  icl8('icl8', 'Icon, 8-bit', ViLegacyIcon.icl8, ViLegacyIcon.icl8Layout),

  /// 32x32 icon at 4 bits per pixel in the Mac `icl4` layout.
  icl4('icl4', 'Icon, 4-bit', ViLegacyIcon.icl4, ViLegacyIcon.icl4Layout),

  /// 32x32 icon at 1 bit per pixel in the Mac `ICON` layout.
  icon('ICON', 'Icon, 1-bit', ViLegacyIcon.icon1, ViLegacyIcon.iconLayout),

  /// Twelve-byte records of a kind, flags and a rectangle inside the panels; roles not decoded.
  picc('PICC', 'PICC records', ViPiccRecord.new, ViPiccRecord.layout),

  /// Mac icon-list resource; not in the corpus.
  icnList('ICN#', 'Icon with mask, 1-bit'),

  /// Mac small icon-list resource; not in the corpus.
  icsList('ics#', 'Small icon with mask, 1-bit'),

  /// Mac small icon resource; not in the corpus.
  ics4('ics4', 'Small icon, 4-bit'),

  /// Mac small icon resource; not in the corpus.
  ics8('ics8', 'Small icon, 8-bit'),

  /// Mac cursor resource; not in the corpus.
  curs('CURS', 'Cursor, 1-bit'),

  /// QuickDraw PICT v2 picture: an opcode stream ending at OpEndPic.
  pict('PICT', 'Mac PICT picture', ViPictPicture.new, ViPictPicture.layout),

  /// A picture as a PNG stream, or occasionally an MNG stream.
  mngi('MNGI', 'PNG image', ViPngStream.new, ViPngStream.layout),

  /// Windows enhanced metafile: EMR_HEADER followed by self-sized records ending at EMR_EOF.
  wemf('WEMF', 'Windows enhanced metafile', ViEmfMetafile.new, ViEmfMetafile.layout),

  /// Listed by the LabVIEW wiki; not in the corpus.
  pngi('PNGI', 'PNG image'),

  /// Link info for the VI: linked resources by name and path.
  livi('LIvi', 'Link info: VI', ViLinkInfo.new, ViLinkInfo.layout),

  /// Link info for the front panel: typedefs and controls by name.
  lifp(
    'LIfp',
    'Link info: front panel',
    ViLinkInfo.new,
    ViLinkInfo.layout,
  ),

  /// Link info for the block diagram: sub-VIs by name and path.
  libd(
    'LIbd',
    'Link info: block diagram',
    ViLinkInfo.new,
    ViLinkInfo.layout,
  ),

  /// Link info for the data space.
  lids(
    'LIds',
    'Link info: data space',
    ViLinkInfo.new,
    ViLinkInfo.layout,
  ),

  /// Ids of the loop-invariant objects: constants inside loops, nodes fed only by them, and their wires.
  lpin('LPIN', 'Loop-invariant-node UID set', ViNodeUidSet.new, ViNodeUidSet.layout),

  /// Names of the libraries owning the VI, stored in the embedded section namespace.
  libn('LIBN', 'Library names', ViLibraryNames.new, ViLibraryNames.layout),

  /// An embedded VI, itself a complete RSRC file, stored in the embedded section namespace.
  vins('VINS', 'Embedded VI', decodeEmbeddedVi, Vins.layout),

  /// VI description text.
  strg('STRG', 'VI description', ViStringBlock.new, ViStringBlock.layout),

  /// Begins with a version word; layout not decoded.
  str('STR ', 'String'),

  /// The custom front-panel window title, a Pascal string.
  titl('TITL', 'Window title', ViTitle.new, ViTitle.layout),

  /// The help tag, the topic key into the help file [hlpp] names, in the [strg] layout.
  hlpt('HLPT', 'Help tag', ViStringBlock.new, ViStringBlock.layout),

  /// Context-help document path (PTH0).
  hlpp('HLPP', 'Help path', ViPath.new, ViPath.layout),

  /// Path of a linked DLL (PTH0).
  dllp('DLLP', 'DLL path', ViPath.new, ViPath.layout),

  /// Help-related; not decoded.
  hlpu('HLPU', 'Help URL'),

  /// Help-related; not decoded.
  hlpx('HLPX', 'Help (X)'),

  /// Help-related; not decoded.
  hlpw('HLPW', 'Help (W)'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  lpth('LPTH', 'L. path'),

  /// LabVIEW save record: the saving version and save-time settings.
  lvsr('LVSR', 'LabVIEW save record', ViSaveRecord.new, ViSaveRecord.layout),

  /// Version record in the Mac `vers` layout: numeric version plus short and long version strings.
  vers('vers', 'Version record', ViVersBlock.new, ViVersBlock.layout),

  /// LabVIEW 4.0 and older; listed by the LabVIEW wiki, not in the corpus.
  flag('FLAG', 'Integer flags'),

  /// LabVIEW 4.0 and older; listed by the LabVIEW wiki, not in the corpus.
  lvin('LVIN', 'VI info'),

  /// Block-diagram password: an MD5 digest of the password followed by derived digests.
  bdpw(
    'BDPW',
    'Block-diagram password',
    ViPasswordRecord.new,
    ViPasswordRecord.layout,
  ),

  /// Font table: per-font metric records followed by packed Pascal names.
  ftab('FTAB', 'Font table', ViFontTable.new, ViFontTable.layout),

  /// VI tag store: named, typed tag values.
  vits('VITS', 'VI tag store', ViTagStore.new, ViTagStore.layout),

  /// Revision history record.
  hist('HIST', 'Revision history', ViHistory.new, ViHistory.layout),

  /// The largest object id over the front-panel and block-diagram heaps.
  muid('MUID', 'Maximum UID', ViMaxUid.new, ViMaxUid.layout),

  /// Block-diagram object ids, a zero and a wire first; roles not decoded.
  nuid('NUID', 'New UID table', ViIdTable.new, ViIdTable.layout),

  /// (uid, value) pairs over block-diagram terminals; the values' role is not decoded.
  suid('SUID', 'Saved UID table', ViUidValueTable.new, ViUidValueTable.layout),

  /// (uid, value) pairs over block-diagram wires; the values' role is not decoded.
  bnid('BNID', 'Block-name id table', ViUidValueTable.new, ViUidValueTable.layout),

  /// Not decoded.
  omid('OMId', 'Object-map id'),

  /// Not decoded.
  rsid('RSID', 'Resource id'),

  /// Run-time signature, a 16-byte digest.
  rtsg(
    'RTSG',
    'Run-time signature',
    ViSignature.new,
    ViSignature.layout,
  ),

  /// Object signature, a 16-byte digest.
  obsg(
    'OBSG',
    'Object signature',
    ViSignature.new,
    ViSignature.layout,
  ),

  /// Compiled-code signature, a 16-byte digest that signs the compiler build, not the VI.
  ccsg(
    'CCSG',
    'Compiled-code signature',
    ViSignature.new,
    ViSignature.layout,
  ),

  /// Source signature: a marker word and a 16-byte digest.
  scsr(
    'SCSR',
    'Source signature',
    ViSourceSignature.new,
    ViSourceSignature.layout,
  ),

  /// Generated-code property record.
  gcpr(
    'GCPR',
    'Generated-code property',
    ViConstantRecord.gcpr,
    ViConstantRecord.gcprLayout,
  ),

  /// Generated-code debug info.
  gcdi(
    'GCDI',
    'Generated-code debug info',
    ViGcdiRecord.new,
    ViGcdiRecord.layout,
  ),

  /// Front-panel section entry: one or two u32 words.
  fpse(
    'FPSE',
    'Front-panel section entry',
    ViSectionEntry.new,
    ViSectionEntry.layout,
  ),

  /// Block-diagram section entry: one or two u32 words.
  bdse(
    'BDSE',
    'Block-diagram section entry',
    ViSectionEntry.new,
    ViSectionEntry.layout,
  ),

  /// One zero word per front-panel link entry.
  fpex('FPEx', 'Front-panel link-entry words', ViLinkEntryWords.new, ViLinkEntryWords.layout),

  /// One zero word per block-diagram link entry.
  bdex('BDEx', 'Block-diagram link-entry words', ViLinkEntryWords.new, ViLinkEntryWords.layout),

  /// Not decoded.
  fpts('FPTS', 'Front-panel TS'),

  /// Block-diagram TS as a grid of u32 words; semantics not decoded.
  bdts(
    'BDTS',
    'Block-diagram tag store',
    ViDiagramTagStore.new,
    ViDiagramTagStore.layout,
  ),

  /// VI property data record.
  vpdp('VPDP', 'VI property data', ViConstantRecord.vpdp, ViConstantRecord.vpdpLayout),

  /// Print settings record.
  prt('PRT ', 'Print settings', ViPrintRecord.new, ViPrintRecord.layout),

  /// Seven pointer-sized slots of an in-memory structure, in standard VIs that carry [dfds];
  /// cleared to 1 then zeros by every version but LabVIEW 7.1; roles TODO.
  dldr('DLDR', 'DLDR record', ViDldrRecord.new, ViDldrRecord.layout),

  /// Text record: a label's bounds, colour and text, one section per label, LabVIEW 7.1 to 8.5.
  trec('TRec', 'Text record', ViTextRecord.new, ViTextRecord.layout),

  /// Conditional-compilation symbols and their values at save time.
  ccst('CCST', 'Conditional-compilation symbols', ViConditionalSymbols.new, ViConditionalSymbols.layout),

  /// Align table: offset, value and kind per entry.
  bfal('BFAL', 'Align table', ViAlignTable.new, ViAlignTable.layout),

  /// Bookmarks: two tables of text entries.
  bkmk('BKMK', 'Bookmarks', ViBookmarkList.new, ViBookmarkList.layout),

  /// Ids of the constant-folded objects: diagram constants, nodes fed only by them, and their wires.
  cnst('CNST', 'Constant-node UID set', ViNodeUidSet.new, ViNodeUidSet.layout),

  /// Strictly rising byte offsets into the compiled code; what they mark is not decoded.
  ipsr('IPSR', 'Code offsets', ViOffsetTable.new, ViOffsetTable.layout),

  /// Polymorphic VI instance menu names, one Pascal string per instance.
  cpst(
    'CPST',
    'Polymorphic instance menu names',
    ViPolymorphicNames.new,
    ViPolymorphicNames.layout,
  ),

  /// Polymorphic VI instance selector names, one Pascal string per instance.
  cpsp(
    'CPSP',
    'Polymorphic instance selector names',
    ViPolymorphicNames.new,
    ViPolymorphicNames.layout,
  ),

  /// Not decoded.
  gtmi('GTMI', 'Get-TM info'),

  /// Not decoded.
  hbin('HBIN', 'Heap bin'),

  /// Not decoded.
  hbuf('HBUF', 'Heap buffer'),

  /// Three u32 words: a constant 1, a timestamp and a per-directory word; role TODO.
  cout('COUT', 'COUT record', ViCoutRecord.new, ViCoutRecord.layout),

  /// Not decoded.
  rtmp('RTMP', 'Run-time map / path'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  dlgh('DLGH', 'Dialog HTML'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  errh('ERRH', 'Error HTML'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  nodh('NODH', 'NOD HTML'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  noeg('NOEG', 'NOEG string'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  mitm('MItm', 'M. item'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  dnmList('DNm#', 'D. name strings list'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  hdbList('HDb#', 'Help database item'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  lstList('LST#', 'Short strings list'),

  /// Mac string-list resource; listed by the LabVIEW wiki, not in the corpus.
  strList('STR#', 'Short strings list'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  fdfl('FDFL', 'FDFL strings'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  cgrs('CGRS', 'Conglomerate resource'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  lvzp('LVzp', 'Zipped application'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  bdht('BDHT', 'Block-diagram heap, text'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  fpht('FPHT', 'Front-panel heap, text'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  bdhx('BDHX', 'Block-diagram heap, XML'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  fphx('FPHX', 'Front-panel heap, XML'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  ucrf('UCRF', 'Uncompressed resource file'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  cprf('CPRF', 'Compressed resource file'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  zcrf('ZCRF', 'Zlib-compressed resource file'),

  /// Listed by the LabVIEW wiki; not in the corpus.
  dlg3('DLG3', 'Dialog resource file');

  const BlockTag(this.tag, this.displayName, [this.decode, this.layout]);

  /// The four-character section tag as stored in the block list.
  final String tag;

  final String displayName;

  /// Decodes one section payload; null while the layout is not decoded, and for [dfds],
  /// which needs sibling blocks.
  final Object? Function(Uint8List)? decode;

  /// The payload's byte layout, rendered into the block file's doc comment by
  /// `tool/gen_block_docs.dart`; null while the layout is not decoded.
  final ByteLayout? layout;

  /// The C4 record heaps that `walkHeapBody`, `buildBlockDiagram` and `buildFrontPanel` read.
  static const Set<BlockTag> recordHeaps = {fphb, bdhb};

  /// The front panel's object heap in every encoding.
  static const Set<BlockTag> frontPanelHeaps = {fphb, fphc, fphp};

  /// The block diagram's object heap in every encoding.
  static const Set<BlockTag> blockDiagramHeaps = {bdhb, bdhc, bdhp};

  bool get isRecordHeap => recordHeaps.contains(this);

  /// Whether the payload has a model: a [decode] function, or for [dfds] the context-taking
  /// `ViDataSpace.new`.
  bool get isDecoded => decode != null || this == dfds;

  /// Whether [decode] yields a [ByteRecord], so the payload can be re-emitted through the model.
  bool get hasWriter => decode is ByteRecord Function(Uint8List);

  /// Decodes [payload] when the tag [hasWriter], else null.
  ByteRecord? decodeRecord(Uint8List payload) => switch (decode) {
    final ByteRecord Function(Uint8List) decode => decode(payload),
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
