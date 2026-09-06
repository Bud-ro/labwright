library;

import 'seq_file.dart';
import 'seq_ini.dart';
import 'seq_property.dart';

bool seqFileDeepEquals(SeqFile a, SeqFile b) {
  if (a.header.format != b.header.format ||
      a.header.fileType != b.header.fileType ||
      a.header.productName != b.header.productName ||
      a.header.fileVersion != b.header.fileVersion ||
      a.newline != b.newline) {
    return false;
  }
  if (!_nullableOrderedMapEquals(a.rootAttributes, b.rootAttributes)) return false;
  final aDefs = a.typelistEntries;
  final bDefs = b.typelistEntries;
  if ((aDefs == null) != (bDefs == null)) return false;
  if (aDefs != null && bDefs != null) {
    if (aDefs.length != bDefs.length) return false;
    for (var i = 0; i < aDefs.length; i++) {
      if (aDefs[i].protectedData != bDefs[i].protectedData) return false;
      if (!_orderedMapEquals(aDefs[i].attributes, bDefs[i].attributes)) return false;
      if (!_nullablePropEquals(aDefs[i].root, bDefs[i].root)) return false;
    }
  }
  return seqPropertyDeepEquals(a.data, b.data);
}

bool seqPropertyDeepEquals(SeqProperty a, SeqProperty b) {
  if (a.name != b.name ||
      a.className != b.className ||
      a.typeName != b.typeName ||
      a.xmlTag != b.xmlTag ||
      a.scalar != b.scalar ||
      a.numericFormat != b.numericFormat ||
      a.xmlComment != b.xmlComment) {
    return false;
  }
  if (!_orderedMapEquals(a.attributes, b.attributes)) return false;
  if (!_orderedMapEquals(a.valueAttributes, b.valueAttributes)) return false;
  if (!_nullablePropEquals(a.elemProto, b.elemProto)) return false;
  if (a.extData.length != b.extData.length) return false;
  for (var i = 0; i < a.extData.length; i++) {
    if (!_orderedMapEquals(a.extData[i], b.extData[i])) return false;
  }
  final aArr = a.array;
  final bArr = b.array;
  if ((aArr == null) != (bArr == null)) return false;
  if (aArr != null && bArr != null) {
    if (aArr.length != bArr.length) return false;
    for (var i = 0; i < aArr.length; i++) {
      if (!seqPropertyDeepEquals(aArr[i], bArr[i])) return false;
    }
  }
  if (a.subProps.length != b.subProps.length) return false;
  for (var i = 0; i < a.subProps.length; i++) {
    if (!seqPropertyDeepEquals(a.subProps[i], b.subProps[i])) return false;
  }
  return true;
}

bool iniDeepEquals(IniSeqFile a, IniSeqFile b) {
  if (a.lineTerminator != b.lineTerminator) return false;
  if (!_orderedMapEquals(a.headerFields, b.headerFields)) return false;
  if (a.sections.length != b.sections.length) return false;
  for (var i = 0; i < a.sections.length; i++) {
    final sa = a.sections[i];
    final sb = b.sections[i];
    if (sa.isDef != sb.isDef || sa.path != sb.path || sa.extDataKind != sb.extDataKind) return false;
    if (sa.entries.length != sb.entries.length) return false;
    for (var j = 0; j < sa.entries.length; j++) {
      if (sa.entries[j].key != sb.entries[j].key || sa.entries[j].rawValue != sb.entries[j].rawValue) {
        return false;
      }
    }
  }
  return true;
}

bool _nullablePropEquals(SeqProperty? a, SeqProperty? b) {
  if (a == null || b == null) return identical(a, b) || (a == null && b == null);
  return seqPropertyDeepEquals(a, b);
}

bool _nullableOrderedMapEquals(Map<String, String>? a, Map<String, String>? b) {
  if (a == null || b == null) return a == null && b == null;
  return _orderedMapEquals(a, b);
}

bool _orderedMapEquals(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  final ai = a.entries.iterator;
  final bi = b.entries.iterator;
  while (ai.moveNext() && bi.moveNext()) {
    if (ai.current.key != bi.current.key || ai.current.value != bi.current.value) return false;
  }
  return true;
}
