import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart' show extractSnippetVi, isPngBytes;

/// The file extensions LabVIEW saves in the VI resource format: VIs, controls, malleable and
/// template VIs and their control counterparts.
const viExtensions = ['.vi', '.ctl', '.vim', '.vit', '.ctt'];

/// Every VI under [root], sorted by path: the files with a [viExtensions] extension and the
/// snippet PNGs that carry one; [readCorpusVi] reads either as VI bytes.
List<File> listCorpusVis(Directory root) =>
    root.listSync(recursive: true, followLinks: false).whereType<File>().where((file) {
      final lower = file.path.toLowerCase();
      if (viExtensions.any(lower.endsWith)) return true;
      return lower.endsWith('.png') && extractSnippetVi(file.readAsBytesSync()) != null;
    }).toList()..sort((left, right) => left.path.compareTo(right.path));

/// The VI a snippet PNG carries, else the file's bytes.
Uint8List readCorpusVi(File file) {
  final bytes = file.readAsBytesSync();
  return isPngBytes(bytes) ? extractSnippetVi(bytes) ?? bytes : bytes;
}
