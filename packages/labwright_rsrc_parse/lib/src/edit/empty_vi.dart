import 'dart:typed_data';

import '../blocks/CONP_CPC2_connector_pane.dart';
import '../blocks/DTHP_data_type_heap.dart';
import '../blocks/FPEx_BDEx_link_entry_words.dart';
import '../blocks/FPSE_BDSE_section_entry.dart';
import '../blocks/FTAB_font_table.dart';
import '../blocks/LIvi_LIbd_LIfp_LIds_link_info.dart';
import '../blocks/LVSR_save_record.dart';
import '../blocks/MUID_max_uid.dart';
import '../blocks/vers_version.dart';
import '../container.dart';
import '../content_exact.dart';
import '../diagram/objects.dart';
import '../heap/heap.dart';
import '../heap/heap_tree.dart';
import 'block_diagram.dart';

/// The version word of a LabVIEW 21.0 save.
const int kLvVersion21 = 0x21008000;

/// The id the diagram root takes in a new VI, and the first id free after the panel's and the
/// diagram's own objects.
const int kEmptyViRootOid = 2;

const int kEmptyViFirstFreeOid = 4;

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
    ('VCTP', deflateHeapPayload(Uint8List.fromList(const [0, 0, 0, 0, 0, 0]))),
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

/// The panel heap: its root with an empty control list.
List<HeapNode> _emptyPanel() => [
  HeapObjectNode.create(
    HeapObjectClass.diagramFrame.code,
    1,
    tag: 0xf5,
    children: [
      HeapRecordNode(
        encodeHeapC4Record(HeapOpcode.bounds.byte, const HeapRect(top: 0, left: 0, bottom: 0, right: 0).payload),
      ),
      HeapRecordNode(encodeHeapScalarAttr(HeapAttribute.mouseWheelSupport.raw, HeapAttrWidth.u8, 0)),
      HeapGroupNode.counted(kPanelControlList),
    ],
  ),
];

/// The diagram heap: its root, holding the root frame with an empty object list, an empty node
/// order behind the endpoint table, and no signals.
List<HeapNode> _emptyDiagram() => [
  HeapObjectNode.create(
    HeapObjectClass.diagramRoot.code,
    kEmptyViRootOid,
    tag: 0x18,
    children: [
      HeapObjectNode.create(
        HeapObjectClass.bdFrame.code,
        kEmptyViRootOid + 1,
        children: [
          HeapGroupNode.counted(BdFrameList.objects.rawId),
          HeapGroupNode.counted(
            BdFrameList.nodes.rawId,
            children: [
              HeapObjectNode.create(
                HeapObjectClass.bdWire.code,
                kEmptyViFirstFreeOid - 1,
                children: [
                  HeapRecordNode(encodeHeapScalarAttr(HeapAttribute.objFlags.raw, HeapAttrWidth.u16, 0x1000)),
                  HeapGroupNode.counted(kBdTermList),
                  HeapRecordNode(
                    encodeHeapC4Record(
                      HeapOpcode.bounds.byte,
                      const HeapRect(top: 0, left: 0, bottom: 0, right: 0).payload,
                    ),
                  ),
                ],
              ),
            ],
          ),
          HeapGroupNode.counted(BdFrameList.signals.rawId),
          HeapRecordNode(encodeHeapScalarAttr(HeapAttribute.backgroundColor.raw, HeapAttrWidth.rgb, 0xffffff)),
        ],
      ),
    ],
  ),
];

/// The panel root's list of its controls, a counted group.
const int kPanelControlList = 0x155;
