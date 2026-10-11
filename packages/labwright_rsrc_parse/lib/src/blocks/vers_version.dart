/// `vers` - Version Record: [ViVersBlock]
///
/// The Mac `vers` resource layout: the numeric version of the saving LabVIEW, a region code,
/// then the short and long version strings; the short string spells the numeric version and the
/// long one is empty. A VI with compiled code carries five sections: the first, third and fifth
/// give the saving version with its build number, the second and fourth the base release with
/// patch and build cleared, which `LVSR` repeats. A VI whose compiled code is kept separately
/// carries only the first, and `LVSR` then repeats it with patch and build cleared.
///
/// ```text
/// offset  size  field       type   meaning
/// 0       4     versionWord u32    BCD major byte, then minor in the high nibble and patch in the low, then
///                                  the stage and build bytes, see ViVersionWord.
/// 4       2     regionCode  u16    The Mac region code: zero for nearly every save, 14 and 1 in localized
///                                  ones.
/// 6       …     versionText pstr   Short version string.
/// …       …     infoText    pstr   Long version string, after versionText; empty in the corpus.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

/// The numeric version packed into the first four bytes of `vers` and `LVSR`.
class ViVersionWord {
  const ViVersionWord({
    required this.major,
    required this.minor,
    required this.patch,
    required this.stage,
    required this.build,
  });

  /// The version word at [offset] of [view].
  factory ViVersionWord.at(ByteData view, int offset) {
    assert(offset + 4 <= view.lengthInBytes, 'a version word is four bytes');
    final b0 = view.getUint8(offset);
    final b1 = view.getUint8(offset + 1);
    return ViVersionWord(
      major: (b0 >> 4) * 10 + (b0 & 0x0f),
      minor: b1 >> 4,
      patch: b1 & 0x0f,
      stage: view.getUint8(offset + 2),
      build: view.getUint8(offset + 3),
    );
  }

  final int major;

  final int minor;

  final int patch;

  /// Release stage byte, named by [releaseStage] when it is one LabVIEW uses.
  final int stage;

  ViVersionStage? get releaseStage => ViVersionStage.of(stage);

  final int build;

  String get version => patch == 0 ? '$major.$minor' : '$major.$minor.$patch';

  /// Whether this version is [major].[minor] or later.
  bool isAtLeast(int major, int minor) => this.major > major || this.major == major && this.minor >= minor;
}

/// The release stage a version word's stage byte names; the corpus is all [release] but for
/// one [beta] and a few saves with `0x82`.
enum ViVersionStage {
  development(0x20),

  alpha(0x40),

  beta(0x60),

  release(0x80);

  const ViVersionStage(this.code);

  final int code;

  static ViVersionStage? of(int code) {
    for (final stage in values) {
      if (stage.code == code) return stage;
    }
    return null;
  }
}

final class ViVersBlock extends ByteRecord {
  ViVersBlock(Uint8List bytes) : super(bytes, layout) {
    assert(view.lengthInBytes > _versionText.offset, 'vers holds two Pascal strings');
    final infoStart = _versionText.endIn(view);
    assert(
      infoStart < view.lengthInBytes && PStr.endAt(view, infoStart) == view.lengthInBytes,
      'the two strings end the payload',
    );
  }

  /// BCD major byte, then minor in the high nibble and patch in the low, then the stage and
  /// build bytes, see [ViVersionWord].
  ViVersionWord get versionWord => ViVersionWord.at(view, _versionWord.offset);

  /// The Mac region code: zero for nearly every save, 14 and 1 in localized ones.
  int get regionCode => _regionCode.read(view);

  /// Short version string.
  String get versionText => _versionText.read(view);

  /// Long version string, after versionText; empty in the corpus.
  String get infoText => PStr.readAt(view, _versionText.endIn(view));

  static const _versionWord = U32(0);
  static const _regionCode = U16(4);
  static const _versionText = PStr(6);
  static const _infoText = PStr(7);

  static const layout = ByteLayout([_versionWord, _regionCode, _versionText, _infoText]);
}
