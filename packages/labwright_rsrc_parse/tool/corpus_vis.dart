import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart' show extractSnippetVi, isPngBytes;

import '../../../tool/corpus.dart';

/// Every VI under [root], sorted by path: the `.vi` files and the snippet PNGs that carry
/// one; [readCorpusVi] reads either as VI bytes.
List<File> listCorpusVis(Directory root) => [
  ...corpusFiles(root, '.vi'),
  ...corpusFiles(root, '.png').where((file) => extractSnippetVi(file.readAsBytesSync()) != null),
]..sort((left, right) => left.path.compareTo(right.path));

/// The VI a snippet PNG carries, else the file's bytes.
Uint8List readCorpusVi(File file) {
  final bytes = file.readAsBytesSync();
  return isPngBytes(bytes) ? extractSnippetVi(bytes) ?? bytes : bytes;
}
