/// `LVSR` — LabVIEW save record: the version that saved the VI and its save-time settings.
///
/// The version word repeats the numeric part of `vers`; the digest at 96 is the first
/// digest of `BDPW`.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     versionWord                u32      saving LabVIEW version, see ViVersionWord
/// 4       2     saveFlags                  u16      bit set named by ViSaveFlag; other bits TODO
/// 6       46    TODO                                retained; not decoded
/// 52      16    TODO                       u8[16]   retained; not decoded
/// 68      12    TODO                                retained; not decoded
/// 80      16    TODO                       u8[16]   retained; not decoded
/// optional, when the record reaches offset 112:
/// 96      16    blockDiagramPasswordDigest u8[16]   MD5 of the block-diagram password, MD5("")
///                                                   when unprotected
/// optional, when the record reaches offset 120:
/// 112     8     TODO                                retained; not decoded
/// optional, when the record reaches offset 136:
/// 120     16    TODO                       u8[16]   retained; not decoded
/// optional, when the record reaches offset 144:
/// 136     8     TODO                                retained; not decoded
/// optional, when the record reaches offset 160:
/// 144     16    secondaryDigest            u8[16]   digest; role TODO
/// ```
///
/// [ViSaveRecord] is a view over the payload; [ViSaveFlag] names the decoded bits of
/// `saveFlags`; [decodeSaveRecord] requires at least 8 bytes and exposes each later field
/// only when the record reaches it.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';
import '../viparse.dart' show ViSection;
import 'BDPW_password.dart' show emptyPasswordDigest;
import 'vers_version.dart';

const _versionWord = BlockField(0, 4, 'versionWord', 'u32', 'saving LabVIEW version, see ViVersionWord');
const _saveFlags = BlockField(4, 2, 'saveFlags', 'u16', 'bit set named by ViSaveFlag; other bits TODO');
const _todo6 = BlockField.undecoded(6, 46);
const _todo52 = BlockField.undecoded(52, 16, type: 'u8[16]');
const _todo68 = BlockField.undecoded(68, 12);
const _todo80 = BlockField.undecoded(80, 16, type: 'u8[16]');
const _passwordDigest = BlockField(
  96,
  16,
  'blockDiagramPasswordDigest',
  'u8[16]',
  'MD5 of the block-diagram password, MD5("") when unprotected',
  optional: 'the record reaches offset 112',
);
const _todo112 = BlockField.undecoded(112, 8, optional: 'the record reaches offset 120');
const _todo120 = BlockField.undecoded(120, 16, type: 'u8[16]', optional: 'the record reaches offset 136');
const _todo136 = BlockField.undecoded(136, 8, optional: 'the record reaches offset 144');
const _secondaryDigest = BlockField(
  144,
  16,
  'secondaryDigest',
  'u8[16]',
  'digest; role TODO',
  optional: 'the record reaches offset 160',
);

const BlockLayout lvsrLayout = [
  _versionWord,
  _saveFlags,
  _todo6,
  _todo52,
  _todo68,
  _todo80,
  _passwordDigest,
  _todo112,
  _todo120,
  _todo136,
  _secondaryDigest,
];

/// Bits of `saveFlags`.
enum ViSaveFlag {
  /// `0x0800`: last saved by an evaluation-license LabVIEW, whose block-diagram
  /// images carry the "LabVIEW Evaluation Software" watermark.
  evaluationLicense(0x0800),

  /// `0x1000`: last saved by a Home or Student edition, whose block-diagram
  /// images carry the "Student Edition" watermark.
  homeStudentEdition(0x1000)
  ;

  const ViSaveFlag(this.mask);

  final int mask;
}

/// A view over an `LVSR` payload.
class ViSaveRecord implements BlockRecord {
  ViSaveRecord._(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  ViVersionWord get versionWord => decodeVersionWord(bytes);

  int get saveFlagWord => _view.getUint16(_saveFlags.offset);

  Set<ViSaveFlag> get saveFlags => {
    for (final flag in ViSaveFlag.values)
      if (saveFlagWord & flag.mask != 0) flag,
  };

  Uint8List? _bytesOf(BlockField field) =>
      bytes.length >= field.end ? Uint8List.sublistView(bytes, field.offset, field.end) : null;

  /// Null when the record ends before offset 112.
  Uint8List? get blockDiagramPasswordDigest => _bytesOf(_passwordDigest);

  /// Null when the record ends before offset 160.
  Uint8List? get secondaryDigest => _bytesOf(_secondaryDigest);

  bool get isBlockDiagramPasswordProtected {
    final digest = blockDiagramPasswordDigest;
    return digest != null && !_sameBytes(digest, emptyPasswordDigest);
  }

  @override
  Uint8List serialize() => bytes;
}

ViSaveRecord decodeSaveRecord(Uint8List bytes) {
  assert(bytes.length >= _saveFlags.end, 'LVSR holds at least the version word and the flag word');
  return ViSaveRecord._(bytes);
}

ViSaveRecord? saveRecordFromSections(Iterable<ViSection> sections) {
  for (final section in sections) {
    if (section.tag == 'LVSR') return decodeSaveRecord(section.bytes);
  }
  return null;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
