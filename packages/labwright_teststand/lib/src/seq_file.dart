import 'dart:convert';
import 'dart:typed_data';

import 'seq_format.dart';
import 'seq_property.dart';
import 'xml_lite.dart';

/// A parsed TestStand sequence file: the header, the type list, and the root
/// `Data` property object, with a typed lens over the sequences and their steps.
///
/// Built from the **XML** encoding (M1). The binary `TOF1` encoding maps onto the
/// same model and is a later milestone — [parseSeqFile] throws for it rather than
/// guessing.
class SeqFile {
  SeqFile({required this.header, required this.types, required this.data});

  final SeqFileHeader header;

  /// The `<typelist>` entries (each a type's root property object).
  final List<SeqProperty> types;

  /// The root `Data` property object holding the file's contents.
  final SeqProperty data;

  /// The sequences in the file (`Data > Seq` array). Empty if the path is absent
  /// (e.g. a type-palette file) — honest rather than throwing.
  List<Sequence> get sequences =>
      [for (final s in data.prop('Seq')?.array ?? const <SeqProperty>[]) Sequence(s)];

  @override
  String toString() =>
      'SeqFile(${header.fileType}, v${header.fileVersion}, '
      '${types.length} types, ${sequences.length} sequences)';
}

/// A single sequence: a name and its three ordered step groups.
class Sequence {
  Sequence(this.raw);

  /// The underlying property object — full access to every sequence property.
  final SeqProperty raw;

  String get name => raw.name;

  List<Step> get setup => _group('Setup');
  List<Step> get main => _group('Main');
  List<Step> get cleanup => _group('Cleanup');

  /// All steps in editor order (Setup, then Main, then Cleanup).
  List<Step> get steps => [...setup, ...main, ...cleanup];

  List<Step> _group(String name) =>
      [for (final s in raw.prop(name)?.array ?? const <SeqProperty>[]) Step(s)];

  @override
  String toString() => 'Sequence($name, ${steps.length} steps)';
}

/// A single step within a sequence group.
class Step {
  Step(this.raw);

  /// The underlying property object — full access to every step property.
  final SeqProperty raw;

  /// The step's display name (its `name=` attribute).
  String get name => raw.name;

  /// The step type, e.g. `Statement`, `NI_MultipleNumericLimitTest`,
  /// `SequenceCall`, `MessagePopup`. null if untyped.
  String? get type => raw.typeName;

  @override
  String toString() => 'Step($name : ${type ?? '?'})';
}

/// Parses TestStand sequence-file [bytes] into a [SeqFile].
///
/// Supports the **XML** encoding. Throws [UnsupportedError] for the binary
/// `TOF1` encoding (not yet decoded) and [FormatException] for unrecognized
/// input — never a silent partial result.
SeqFile parseSeqFile(Uint8List bytes) {
  final fmt = detectSeqFormat(bytes);
  switch (fmt) {
    case SeqFormat.xml:
      return _parseXml(bytes);
    case SeqFormat.binary:
      throw UnsupportedError('binary TOF1 .seq decoding is not yet implemented (M2)');
    case SeqFormat.ini:
    case SeqFormat.unknown:
      throw FormatException('not a recognized XML TestStand sequence file ($fmt)');
  }
}

SeqFile _parseXml(Uint8List bytes) {
  final root = parseXml(stripBom(utf8.decode(bytes)));
  if (root.name != 'teststandfileheader') {
    throw FormatException('unexpected root element <${root.name}>');
  }
  final types = <SeqProperty>[];
  final typelist = root.child('typelist');
  if (typelist != null) {
    for (final typedef in typelist.childrenNamed('typedef')) {
      // A typedef wraps exactly one type root element.
      if (typedef.children.isNotEmpty) types.add(buildProperty(typedef.children.first));
    }
  }
  final dataEl = root.child('Data');
  if (dataEl == null) throw const FormatException('missing <Data> element');
  return SeqFile(
    header: detectSeqHeader(bytes),
    types: types,
    data: buildProperty(dataEl),
  );
}
