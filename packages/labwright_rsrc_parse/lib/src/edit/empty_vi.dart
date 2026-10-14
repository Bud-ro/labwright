import 'dart:typed_data';

import '../blocks/CONP_CPC2_connector_pane.dart';
import '../blocks/DTHP_data_type_heap.dart';
import '../blocks/FPEx_BDEx_link_entry_words.dart';
import '../blocks/FPSE_BDSE_section_entry.dart';
import '../blocks/FTAB_font_table.dart';
import '../blocks/LIvi_LIbd_LIfp_LIds_link_info.dart';
import '../blocks/LVSR_save_record.dart';
import '../blocks/MUID_max_uid.dart';
import '../blocks/VCTP_type_pool.dart';
import '../blocks/vers_version.dart';
import '../container.dart';
import '../content_exact.dart';
import '../diagram/objects.dart';
import '../heap/heap.dart';
import '../heap/heap_tree.dart';
import 'block_diagram.dart';
import 'records.dart';

/// The version word of a LabVIEW 21.0 save.
const int kLvVersion21 = 0x21008000;

/// The ids a new VI's own objects take: the panel root and its parts, the diagram root, its
/// frame and the frame's endpoint table; [kEmptyViFirstFreeOid] is the first id after them.
enum EmptyViOid {
  panelRoot(1),
  diagramRoot(2),
  diagramFrame(3),
  endpointTable(7),
  panelFrame(10),
  paneViewport(12),
  paneLabel(15),
  paneScrollbarVertical(16),
  paneScrollbarHorizontal(17),
  paneScrollbarCorner(18),
  paneBackground(19),
  paneTerminal(20),
  panelProps(21),
  panelAux(22);

  const EmptyViOid(this.oid);

  final int oid;
}

const int kEmptyViFirstFreeOid = 23;

/// The pool of a new VI: the void type and the connector pane's function type over twelve
/// void parameters, the 4-2-2-4 pattern; [kEmptyViPanePatternWord] is the pattern's word.
const int kEmptyViVoidTypeIndex = 0;

const int kEmptyViPaneTypeIndex = 1;

const int kEmptyViPanePatternWord = 120;

const int kEmptyViPaneTerminals = 12;

/// The MD5 digest of nothing, which a VI without a password or a source carries.
const List<int> kEmptyDigest = [
  0xd4, 0x1d, 0x8c, 0xd9, 0x8f, 0x00, 0xb2, 0x04, //
  0xe9, 0x80, 0x09, 0x98, 0xec, 0xf8, 0x42, 0x7e,
];

/// A VI with nothing on its panel or diagram, as LabVIEW 21.0 saves one: its sections in the
/// order the corpus keeps them, each built through its block's layout.
Uint8List emptyViBytes({String name = 'untitled.vi'}) {
  final sections = <(String, Uint8List)>[
    (
      'LVSR',
      ViSaveRecord.encode(
        versionWord: kLvVersion21,
        statusFlags: 0,
        optionFlags: 0x600,
        flags12: 4,
        unknown16: 3,
        windowFlags: 0x3c,
        hiddenButtons: 0,
        frontPanelFlags: 0x1f,
        stateFlags: 0x40800200,
        unknown28: 1,
        priority: ViPriority.normal,
        viType: ViKind.standard,
        executionSystem: ViExecutionSystem.sameAsCaller,
        unknown40: List.filled(12, 0),
        unknown52: List.filled(16, 0),
        frontPanelGrid: 12,
        blockDiagramGrid: 16,
        unknown76: 0,
        controlStyle: ViControlStyle.modern,
        unknown80: List.filled(16, 0),
        unknown96: kEmptyDigest,
        unknown112: 0,
        unknown116: 0,
        unknown120: List.filled(16, 0),
        unknown136: 1,
        unknown137: const [0, 0, 0],
        unknown140: 0xffffffff,
        unknown144: kEmptyDigest,
      ),
    ),
    ('vers', ViVersBlock.encode(versionWord: kLvVersion21, versionText: '21.0')),
    ('CONP', ViConnectorPaneIndex.encode(1)),
    ('LIvi', ViLinkInfo.encode(rootKind: 'LVIN', entries: const [])),
    ('CPC2', ViConnectorPaneIndex.encode(1)),
    ('LIfp', ViLinkInfo.encode(rootKind: 'FPHP', entries: const [])),
    ('FPEx', ViLinkEntryWords.encode(const [0])),
    ('FPHb', deflateHeapPayload(encodeHeapTree(_emptyPanel()))),
    ('FPSE', ViSectionEntry.encode(0)),
    ('LIbd', ViLinkInfo.encode(rootKind: 'BDHP', entries: const [])),
    ('BDEx', ViLinkEntryWords.encode(const [0])),
    ('BDHb', deflateHeapPayload(encodeHeapTree(_emptyDiagram()))),
    ('BDSE', ViSectionEntry.encode(0)),
    ('DTHP', ViDataTypeHeapCompact.encode(heapTypeCount: 0, firstTopLevelIndex: 2)),
    ('MUID', ViMaxUid.encode(kEmptyViFirstFreeOid - 1)),
    ('VCTP', deflateHeapPayload(_emptyPool())),
    (
      'FTAB',
      ViFontTable.encode(
        platform: 2,
        fonts: [
          for (var i = 0; i < 3; i++)
            (
              name: 'Segoe UI',
              size: 15,
              flagsByte: 4,
              styleFlags: 0,
              weight: 0,
              resolvedSize: 15,
              metricA: 217,
              metricB: 212,
            ),
          (
            name: '0',
            size: 32768,
            flagsByte: 132,
            styleFlags: 0,
            weight: 32768,
            resolvedSize: 15,
            metricA: 217,
            metricB: 212,
          ),
          (
            name: 'Courier New',
            size: 15,
            flagsByte: 4,
            styleFlags: 0,
            weight: 0,
            resolvedSize: 15,
            metricA: 280,
            metricB: 189,
          ),
        ],
      ),
    ),
  ];
  return encodeViFile(name, sections);
}

/// The type pool: the void type, the pane's function type, and the latter as the one
/// top-level type.
Uint8List _emptyPool() {
  final void_ = ViVoidType.encode();
  final pane = ViFunctionType.encode(
    List.filled(kEmptyViPaneTerminals, kEmptyViVoidTypeIndex),
    trailer: [0, 0, 0, kEmptyViPanePatternWord, ...List.filled(50, 0)],
  );
  return Uint8List.fromList([
    0, 0, 0, 2, //
    ...void_,
    ...pane,
    0, 1,
    0, kEmptyViPaneTypeIndex,
  ]);
}

/// The panel heap: its root over the panel frame, whose pane viewport holds the control list.
List<HeapNode> _emptyPanel() {
  HeapObjectNode part(EmptyViOid id, List<HeapNode> children) =>
      object(HeapObjectClass.controlChrome.code, id.oid, children: children);
  return [
    object(
      HeapObjectClass.diagramRoot.code,
      EmptyViOid.panelRoot.oid,
      rawTag: 0x18,
      children: [
        object(
          HeapObjectClass.diagramFrame.code,
          EmptyViOid.panelFrame.oid,
          rawTag: 0xf5,
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x10000),
            c4Rect(HeapOpcode.bounds, kZeroRect),
            attr(HeapAttribute.mouseWheelSupport, HeapAttrWidth.u8, 0),
            list(kPanelControlRefs),
            object(
              HeapObjectClass.contentViewport.code,
              EmptyViOid.paneViewport.oid,
              rawTag: 0xdb,
              children: [
                attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x260830),
                attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0xf0),
                c4Rect(HeapOpcode.bounds, kEmptyViPaneBounds),
                list(kControlParts, [
                  object(
                    HeapObjectClass.controlLabel.code,
                    EmptyViOid.paneLabel.oid,
                    children: [
                      attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x17014a),
                      attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x10),
                      attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 0x1c),
                      attr(HeapAttribute.howGrow, HeapAttrWidth.u8, 0x5),
                      c4Rect(HeapOpcode.bounds, const HeapRect(top: 0, left: 0, bottom: 17, right: 29)),
                      worded(kPartOffset, kPartOffsetWord, [
                        attr(HeapAttribute.relativeOffset, HeapAttrWidth.u8, 0xf7),
                      ]),
                      attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, kTransparent),
                      attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, kTransparent),
                      worded(kPartText, kPartTextWord, [
                        attr(HeapAttribute.cosmColorB, HeapAttrWidth.u16, 0x404),
                        attr(HeapAttribute.shortText, HeapAttrWidth.rgb, 0x50616e65),
                        attr(HeapAttribute.contentColor, HeapAttrWidth.rgb, kTransparent),
                      ]),
                    ],
                  ),
                  part(EmptyViOid.paneScrollbarVertical, [
                    attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0xd72),
                    attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x27),
                    attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 0x1c),
                    attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0xc2),
                    c4Rect(HeapOpcode.bounds, const HeapRect(top: 0, left: 1073, bottom: 600, right: 1090)),
                    worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u8, 0)]),
                    attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xb3b3b3),
                  ]),
                  part(EmptyViOid.paneScrollbarHorizontal, [
                    attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0xd72),
                    attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x26),
                    attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 0x1c),
                    attr(HeapAttribute.howGrow, HeapAttrWidth.u8, 0x38),
                    c4Rect(HeapOpcode.bounds, const HeapRect(top: 600, left: 0, bottom: 617, right: 1073)),
                    worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u8, 0)]),
                    attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xb3b3b3),
                  ]),
                  part(EmptyViOid.paneScrollbarCorner, [
                    attr(HeapAttribute.objFlags, HeapAttrWidth.u16, 0xd73),
                    attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x2c),
                    attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 0x1c),
                    attr(HeapAttribute.howGrow, HeapAttrWidth.u8, 0xa),
                    c4Rect(HeapOpcode.bounds, const HeapRect(top: 600, left: 1073, bottom: 617, right: 1090)),
                    worded(kPartOffset, kPartOffsetWord, [
                      attr(HeapAttribute.relativeOffset, HeapAttrWidth.u16, 0xfe93),
                    ]),
                    attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, 0xb3b3b3),
                    attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xb3b3b3),
                  ]),
                  part(EmptyViOid.paneBackground, [
                    attr(HeapAttribute.objFlags, HeapAttrWidth.u8, 0x73),
                    attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x1c),
                    attr(HeapAttribute.howGrow, HeapAttrWidth.u8, 0x78),
                    c4Rect(HeapOpcode.bounds, kEmptyViPaneDocBounds),
                    worded(kPartOffset, kPartOffsetWord, [
                      attr(HeapAttribute.relativeOffset, HeapAttrWidth.u16, 0xfd40),
                    ]),
                    attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, 0xe2e2e2),
                    attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xe2e2e2),
                  ]),
                  object(
                    HeapObjectClass.connectorTerminal.code,
                    EmptyViOid.paneTerminal.oid,
                    children: [attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x42)],
                  ),
                ]),
                attr(HeapAttribute.paneFlags, HeapAttrWidth.u24, 0x50d51),
                attr(HeapAttribute.minPaneSize, HeapAttrWidth.rgb, 0x10001),
                c4Rect(HeapOpcode.docBounds, kEmptyViPaneDocBounds),
                list(kPanelControlList),
                worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u8, 0)]),
              ],
            ),
            rectAttr(HeapAttribute.savedSize, kZeroRect),
            object(
              HeapObjectClass.diagramProps.code,
              EmptyViOid.panelProps.oid,
              rawTag: 0x45,
              children: [
                attr(HeapAttribute.conId, HeapAttrWidth.u16, 0x12e1),
                raw(const [0x10, 0x49, 0x01, 0xfb, 0x00, 0x10, 0x08, 0x49]),
              ],
            ),
            object(HeapObjectClass.rootAux.code, EmptyViOid.panelAux.oid, rawTag: 0x9d),
          ],
        ),
        c4Rect(HeapOpcode.pBounds, kEmptyViPaneBounds),
        c4Rect(HeapOpcode.dBounds, kZeroRect),
        attr(HeapAttribute.origin, HeapAttrWidth.rgb, 0x6f014b),
        attr(HeapAttribute.instrStyle, HeapAttrWidth.u8, 0x1f),
        list(0x02a),
      ],
    ),
  ];
}

/// The diagram heap: its root, holding the root frame with an empty object list, an empty node
/// order behind the endpoint table, and no signals.
List<HeapNode> _emptyDiagram() => [
  object(
    HeapObjectClass.diagramRoot.code,
    EmptyViOid.diagramRoot.oid,
    rawTag: 0x18,
    children: [
      object(
        HeapObjectClass.bdFrame.code,
        EmptyViOid.diagramFrame.oid,
        rawTag: 0xf5,
        children: [
          list(BdFrameList.objects.rawId),
          list(BdFrameList.nodes.rawId, [
            object(
              HeapObjectClass.bdWire.code,
              EmptyViOid.endpointTable.oid,
              children: [
                list(kBdTermList),
                c4Rect(HeapOpcode.bounds, kZeroRect),
                attr(HeapAttribute.shortCount, HeapAttrWidth.u8, 1),
              ],
            ),
          ]),
          list(BdFrameList.signals.rawId),
          attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, 0xffffff),
        ],
      ),
      c4Rect(HeapOpcode.pBounds, kZeroRect),
      c4Rect(HeapOpcode.dBounds, kZeroRect),
      attr(HeapAttribute.instrStyle, HeapAttrWidth.u8, 0x1f),
    ],
  ),
];

/// The pane's viewport and document rectangles in a new VI.
const HeapRect kEmptyViPaneBounds = HeapRect(top: 46, left: 0, bottom: 663, right: 1090);

const HeapRect kEmptyViPaneDocBounds = HeapRect(top: 0, left: 0, bottom: 600, right: 1073);

/// The colour word of a transparent part.
const int kTransparent = 0x1000000;

/// The panel frame's list of references to its controls, and the viewport's list holding
/// them.
const int kPanelControlRefs = 0x055;

const int kPanelControlList = 0x14e;

/// A control's part list.
const int kControlParts = 0x0e1;

/// A part's offset group and text group, whose open records carry a word, not a count.
const int kPartOffset = 0x08d;

const int kPartOffsetWord = 0x258;

const int kPartText = 0x12d;

const int kPartTextWord = 0x001;
