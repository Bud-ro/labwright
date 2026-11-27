import 'dart:io';

import '../../../tool/corpus.dart';
import '../test/export_snapshot.dart';

void main() => writeExportSnapshots(Directory('${repoRoot().path}/packages/labwright_seq/$exportSnapshotPath'));
