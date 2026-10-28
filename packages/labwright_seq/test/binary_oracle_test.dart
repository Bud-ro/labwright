@Tags(['corpus'])
library;

import 'dart:io';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Attributes the XML side carries differently or not at all: the tag doubles as class and type for elements.
const _tagAttributes = {'name', 'xsi:type', 'typename', 'classname'};

const _nameInAttribute = '_NAME_IN_ATTRIBUTE_';

/// Every difference between a binary-derived and an XML-derived property subtree, as `path: what`.
List<String> propertyDiffs(SeqProperty p, SeqProperty q, [String path = 'Data']) {
  final diffs = <String>[];
  void walk(String path, SeqProperty p, SeqProperty q) {
    final xmlClass = q.className ?? (q.xmlTag == _nameInAttribute ? null : q.xmlTag);
    if (p.className != xmlClass) diffs.add('$path: class ${p.className} vs $xmlClass');
    if (p.typeName != q.typeName) diffs.add('$path: type ${p.typeName} vs ${q.typeName}');
    if ((p.scalar ?? '') != (q.scalar ?? '')) diffs.add('$path: value ${p.scalar} vs ${q.scalar}');
    if (p.arrayLBound != q.arrayLBound || p.arrayUBound != q.arrayUBound) {
      diffs.add('$path: bounds ${p.arrayLBound}..${p.arrayUBound} vs ${q.arrayLBound}..${q.arrayUBound}');
    }
    if (p.valueAttributes['representation'] != q.valueAttributes['representation']) {
      diffs.add('$path: representation');
    }
    if (p.numericFormat != q.numericFormat) diffs.add('$path: numericfmt ${p.numericFormat} vs ${q.numericFormat}');
    if (p.xmlComment != q.xmlComment) diffs.add('$path: comment');
    for (final key in {...p.attributes.keys, ...q.attributes.keys}) {
      if (_tagAttributes.contains(key) || key.startsWith('%BIN')) continue;
      if (p.attributes[key] != q.attributes[key]) {
        diffs.add('$path: @$key ${p.attributes[key]} vs ${q.attributes[key]}');
      }
    }
    if (p.extData.length != q.extData.length) {
      diffs.add('$path: extdata ${p.extData.length} vs ${q.extData.length}');
    } else {
      for (var i = 0; i < p.extData.length; i++) {
        if ('${p.extData[i]}' != '${q.extData[i]}') diffs.add('$path: extdata[$i]');
      }
    }
    if ((p.elemProto == null) != (q.elemProto == null)) {
      diffs.add('$path: elemproto ${p.elemProto != null} vs ${q.elemProto != null}');
    } else if (p.elemProto != null) {
      walk('$path/<proto>', p.elemProto!, q.elemProto!);
    }
    final pa = p.array, qa = q.array;
    if ((pa == null) != (qa == null)) {
      diffs.add('$path: array ${pa != null} vs ${qa != null}');
    } else if (pa != null && qa != null) {
      if (pa.length != qa.length) {
        diffs.add('$path: ${pa.length} vs ${qa.length} elements');
      } else {
        for (var i = 0; i < pa.length; i++) {
          walk('$path[$i]', pa[i], qa[i]);
        }
      }
    }
    final pn = [for (final c in p.subProps) c.name], qn = [for (final c in q.subProps) c.name];
    if ('$pn' != '$qn') diffs.add('$path: children $pn vs $qn');
    final byName = {for (final c in q.subProps) c.name: c};
    for (final c in p.subProps) {
      final o = byName[c.name];
      if (o != null) walk('$path/${c.name}', c, o);
    }
  }

  walk(path, p, q);
  return diffs;
}

/// Differences between a binary file and its XML twin, over the typelist and the data tree.
List<String> fileDiffs(SeqFile bin, SeqFile xml) {
  final diffs = <String>[];
  final bt = bin.typelistEntries!, xt = xml.typelistEntries!;
  if (bt.length != xt.length) diffs.add('typelist: ${bt.length} vs ${xt.length} entries');
  for (var i = 0; i < bt.length && i < xt.length; i++) {
    final br = bt[i].root!, xr = xt[i].root;
    if (xr == null) {
      if (!br.attributes.containsKey(BinAttr.protected)) diffs.add('type ${br.name}: protected in XML only');
      continue;
    }
    if (br.name != xr.name) {
      diffs.add('type[$i]: ${br.name} vs ${xr.name}');
      continue;
    }
    if ('${bt[i].attributes}' != '${xt[i].attributes}') {
      diffs.add('type ${br.name}: entry ${bt[i].attributes} vs ${xt[i].attributes}');
    }
    diffs.addAll(propertyDiffs(br, xr, 'type/${br.name}'));
  }
  diffs.addAll(propertyDiffs(bin.data, xml.data));
  return diffs;
}

void main() {
  final rosetta = Directory('${corpusSeqDir.path}/seq-corpus/rosetta');
  SeqFile load(String name) => parseSeqFile(File('${rosetta.path}/$name').readAsBytesSync());

  test('every fetched binary twin has a model twin', () {
    final binaries = rosetta.listSync().whereType<File>().where((f) => f.path.endsWith('_BIN.seq')).toList();
    expect(binaries, hasLength(6));
    for (final bin in binaries) {
      final prefix = bin.uri.pathSegments.last.replaceAll('_labview_BIN.seq', '').replaceAll('_BIN.seq', '');
      final twins = rosetta.listSync().whereType<File>().where(
        (f) => f.uri.pathSegments.last.startsWith(prefix) && !f.path.endsWith('_BIN.seq'),
      );
      expect(twins, isNotEmpty, reason: '${bin.path} has no XML twin');
    }
  });

  test('OutputVoltage: the same sequence saved both ways agrees field for field (bar the Python version drift)', () {
    final bin = load('OutputVoltage_BIN.seq');
    final xml = load('OutputVoltage_XML.seq');
    final diffs = fileDiffs(bin, xml);
    expect(
      diffs,
      everyElement(allOf(endsWith('/TS/SData/PythonCall/PythonVersion: value 3.9 vs 3.10'))),
      reason: diffs.join('\n'),
    );
    expect(diffs, hasLength(4), reason: 'the twins were saved from different adapter versions');
    expect(bin.sequences.single.steps.map((s) => s.name), xml.sequences.single.steps.map((s) => s.name));
    expect(bin.sequences.single.steps.map((s) => s.type), xml.sequences.single.steps.map((s) => s.type));
    expect(
      bin.sequences.single.steps.map((s) => s.id),
      xml.sequences.single.steps.map((s) => s.id),
    );
    final binMain = bin.sequences.single.main.single, xmlMain = xml.sequences.single.main.single;
    expect(binMain.measurementParameters.length, xmlMain.measurementParameters.length);
    expect(
      binMain.measurementParameters.map((p) => (p.name, p.value)),
      xmlMain.measurementParameters.map((p) => (p.name, p.value)),
    );
    expect(measureCoverage(bin).ratio, closeTo(measureCoverage(xml).ratio, 0.01));
  });

  test('LabVIEW/Python twin pairs differ only where the adapter differs', () {
    const pairs = {
      'NIDmm_labview_BIN.seq': 'NIDmm_python_XML.seq',
      'NIFgen_labview_BIN.seq': 'NIFgen_python_XML.seq',
      'NIScope_labview_BIN.seq': 'NIScope_python_XML.seq',
      'DmmHAL_labview_BIN.seq': 'DmmHAL_python_XML.seq',
      'SmuFAL_labview_BIN.seq': 'SmuFAL_python_XML.seq',
    };
    final allowed = RegExp(
      r'^(typelist: |type\[|type/|type \w+: entry|Data/Seq\[\d+\]/(Main|Setup|Cleanup)\[\d+\]/'
      r'(TS/Id: value|TS/ResultOption: value|TS/SData|PinMapPath: value|Measurement/(Name: value|Parameters))|Data/FileGlobalDefaults|Data/Seq\[\d+\]/Locals)',
    );
    pairs.forEach((binName, xmlName) {
      final bin = load(binName);
      final xml = load(xmlName);
      final diffs = fileDiffs(bin, xml);
      final unexpected = [
        for (final d in diffs)
          if (!allowed.hasMatch(d)) d,
      ];
      expect(unexpected, isEmpty, reason: '$binName: ${unexpected.join('\n')}');
      expect(bin.sequences.map((s) => s.name), xml.sequences.map((s) => s.name), reason: binName);
      expect(bin.sequences.single.steps.length, xml.sequences.single.steps.length, reason: binName);
      expect(
        bin.sequences.single.steps.map((s) => s.module.adapter),
        everyElement(isIn([SeqAdapter.labView, SeqAdapter.dotNet, SeqAdapter.none])),
        reason: '$binName: the LabVIEW twin calls VIs where the Python twin calls Python',
      );
      final binTypes = {for (final t in bin.types) t.name};
      for (final step in bin.sequences.single.steps) {
        expect(binTypes, contains(step.type), reason: '$binName: ${step.name}');
      }
    });
  });
}
