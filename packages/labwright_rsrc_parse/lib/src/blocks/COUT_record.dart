/// `COUT` - COUT Record: [ViCoutRecord]
///
/// Three u32 words carried by seven LabVIEW 2020 files of one project, none of which has an
/// embedded VI or an owning library: a constant 1, a timestamp, and a third word that is the
/// same for the five dialog VIs of one directory across a 2020 batch save and a 2021 re-save,
/// and another for the two error VIs of a second directory saved in 2024. The third word
/// occurs in no other block of any corpus file, and neither the name of the tag nor its
/// expansion is attested anywhere public.
///
/// ```text
/// offset  size  field     type   meaning
/// 0       4     one       u32    Always 1.
/// 4       4     timestamp u32    Seconds since 1904-01-01 UTC, the Mac epoch; 2020 to 2024 in the corpus,
///                                five files stamped within 44 seconds of one another.
/// 8       4     unknown8         One value per directory, kept across re-saves, found nowhere else; role
///                                TODO.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViCoutRecord extends ByteRecord {
  ViCoutRecord(Uint8List bytes) : super(bytes, layout);

  /// Seconds since 1904-01-01 UTC, the Mac epoch; 2020 to 2024 in the corpus, five files stamped
  /// within 44 seconds of one another.
  int get timestamp => _timestamp.read(view);

  DateTime get time => DateTime.utc(1904).add(Duration(seconds: timestamp));

  static const _one = U32(0); // Always 1.
  static const _timestamp = U32(4);
  static const _unknown8 = Unknown(
    8,
    size: 4,
  ); // One value per directory, kept across re-saves, found nowhere else; role TODO.

  static const layout = ByteLayout([_one, _timestamp, _unknown8]);
}
