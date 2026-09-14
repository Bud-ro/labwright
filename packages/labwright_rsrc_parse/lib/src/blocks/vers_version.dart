/// `vers` — version record in the Mac `vers` layout: the numeric version of the saving
/// LabVIEW followed by its short and long version strings.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       4     versionWord                u32      [BCD major][minor << 4 | patch][stage][build],
///                                                   see ViVersionWord
/// 4       2     flags                      u16      role TODO; the Mac layout holds the region
///                                                   code here
/// 6       rest  versionText                pstr     short version string
/// …       rest  infoText                   pstr     long version string, after versionText
/// ```
///
/// [ViVersionWord] decodes the 4-byte numeric version, which `LVSR` repeats at its start;
/// [ViVersBlock] is a view over the whole payload; [decodeVersBlock] requires the two Pascal
/// strings to end exactly at the end of the payload.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';
import '../viparse.dart' show ViSection;

const _versionWord = BlockField(
  0,
  4,
  'versionWord',
  'u32',
  '[BCD major][minor << 4 | patch][stage][build], see ViVersionWord',
);
const _flags = BlockField(4, 2, 'flags', 'u16', 'role TODO; the Mac layout holds the region code here');
const _versionText = BlockField(6, null, 'versionText', 'pstr', 'short version string');
const _infoText = BlockField(7, null, 'infoText', 'pstr', 'long version string, after versionText');

const BlockLayout versLayout = [_versionWord, _flags, _versionText, _infoText];

/// The numeric version packed into the first four bytes of `vers` and `LVSR`.
class ViVersionWord {
  const ViVersionWord({
    required this.major,
    required this.minor,
    required this.patch,
    required this.stage,
    required this.build,
  });

  final int major;

  final int minor;

  final int patch;

  /// Release stage byte; `0x80` is a release build.
  final int stage;

  final int build;

  String get version => patch == 0 ? '$major.$minor' : '$major.$minor.$patch';
}

ViVersionWord decodeVersionWord(Uint8List bytes) {
  assert(bytes.length >= _versionWord.end, 'a version word is four bytes');
  return ViVersionWord(
    major: (bytes[0] >> 4) * 10 + (bytes[0] & 0x0f),
    minor: bytes[1] >> 4,
    patch: bytes[1] & 0x0f,
    stage: bytes[2],
    build: bytes[3],
  );
}

ViVersionWord? versionWordFromSections(Iterable<ViSection> sections) {
  for (final section in sections) {
    if (section.tag == 'vers') return decodeVersBlock(section.bytes).versionWord;
  }
  return null;
}

/// A view over a `vers` payload.
class ViVersBlock implements BlockRecord {
  ViVersBlock._(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  ViVersionWord get versionWord => decodeVersionWord(bytes);

  int get flags => _view.getUint16(_flags.offset);

  int get _versionTextEnd => _versionText.offset + 1 + bytes[_versionText.offset];

  String get versionText => String.fromCharCodes(bytes, _versionText.offset + 1, _versionTextEnd);

  String get infoText => String.fromCharCodes(bytes, _versionTextEnd + 1);

  @override
  Uint8List serialize() => bytes;
}

ViVersBlock decodeVersBlock(Uint8List bytes) {
  assert(bytes.length >= _versionText.offset + 2, 'vers holds the version word, flags and two Pascal strings');
  final infoStart = _versionText.offset + 1 + bytes[_versionText.offset];
  assert(
    infoStart < bytes.length && infoStart + 1 + bytes[infoStart] == bytes.length,
    'the two strings end the payload',
  );
  return ViVersBlock._(bytes);
}
