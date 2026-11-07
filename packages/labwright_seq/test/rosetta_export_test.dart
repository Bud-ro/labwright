@Tags(['corpus'])
library;

import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// What a rosetta pair holds: one sequence saved both ways, or sibling sequences from the LabVIEW and Python plug-in repositories.
enum RosettaPairing {
  /// The same sequence saved as binary and as XML: the exports must be identical.
  sameSequence('_BIN.seq', '_XML.seq'),

  /// Sibling sequences that differ only in authored content: step names, code modules, measurement services and their parameters, pin map paths, and the plug-in file global's name.
  labViewPythonSiblings('_labview_BIN.seq', '_python_XML.seq');

  const RosettaPairing(this.binarySuffix, this.xmlSuffix);
  final String binarySuffix;
  final String xmlSuffix;
  static RosettaPairing of(String binaryName) =>
      binaryName.endsWith(labViewPythonSiblings.binarySuffix) ? labViewPythonSiblings : sameSequence;
}

const _labViewFileGlobalRenames = {'MeasurementLink': 'MeasurementPlugIns'};

final _commentOnly = RegExp(r'^\s*//');
final _stubDeclaration = RegExp(r'^Future<Object\?> call\w+\(');
final _trailingComment = RegExp(r'([;{(])\s*//.*$');
final _moduleCall = RegExp(r"await call\w+\(\)|throw UnimplementedError\('\w+ call: (?:[^'\\]|\\.)*'\)");

List<String> authoredContentRemoved(String source) {
  final kept = <String>[];
  var inStub = false;
  for (final line in source.split('\n')) {
    if (_stubDeclaration.hasMatch(line)) inStub = true;
    if (inStub) {
      inStub = !line.endsWith(';');
      continue;
    }
    if (line.trim().isEmpty || _commentOnly.hasMatch(line)) continue;
    kept.add(
      _labViewFileGlobalRenames.entries.fold(
        line.replaceFirstMapped(_trailingComment, (m) => m[1]!).replaceAll(_moduleCall, '<module call>'),
        (text, rename) => text.replaceAll(RegExp('\\b${rename.key}\\b'), rename.value),
      ),
    );
  }
  return kept;
}

void main() {
  final rosetta = Directory('${corpusSeqDir.path}/seq-corpus/rosetta');
  final binaries =
      rosetta
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('_BIN.seq'))
          .map((f) => f.uri.pathSegments.last)
          .toList()
        ..sort();
  SeqFile load(String name) => parseSeqFile(File('${rosetta.path}/$name').readAsBytesSync());
  final exporters = {'Dart': exportSeqFileToDart, 'labwright': exportSeqFileToLabwright};

  for (final binaryName in binaries) {
    final pairing = RosettaPairing.of(binaryName);
    final xmlName = binaryName.replaceFirst(pairing.binarySuffix, pairing.xmlSuffix);
    test('$binaryName exports as $xmlName does (${pairing.name})', () {
      final binary = load(binaryName), xml = load(xmlName);
      expect((binary.header.format, xml.header.format), (SeqFormat.binary, SeqFormat.xml));
      exporters.forEach((kind, export) {
        final fromBinary = export(binary, sourceName: 'rosetta.seq');
        final fromXml = export(xml, sourceName: 'rosetta.seq');
        switch (pairing) {
          case RosettaPairing.sameSequence:
            expect(fromBinary, fromXml, reason: kind);
          case RosettaPairing.labViewPythonSiblings:
            expect(authoredContentRemoved(fromBinary), authoredContentRemoved(fromXml), reason: kind);
        }
      });
    });
  }
}
