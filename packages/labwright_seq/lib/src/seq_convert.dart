import 'dart:convert';

import 'seq_file.dart';
import 'seq_format.dart';
import 'seq_ini.dart';
import 'seq_property.dart';
import 'seq_write_ini.dart';

abstract final class ConvKey {
  static const directiveAttrPrefix = directiveXmlPrefix;

  static const iniChannel = 'x-ini-source';

  static const iniChannelHeader = 'header';

  static const iniChannelSections = 'sections';

  static const iniEolAttr = 'eol';

  static const iniEolCrlf = 'crlf';

  static const iniKindAttr = 'kind';

  static const iniKindDef = 'def';

  static const iniKindVal = 'val';

  static const iniExtAttr = 'ext';

  static const partialDecodeAttr = 'x-partial-decode';

  static const partialDecodeBinary = 'binary';

  static const hdrMarker = '%XSEQ';

  static const hdrTrio = '%XHDR';

  static const hdrRootAttrs = '%XROOTA';

  static const hdrEol = '%XEOL';

  static const hdrTypelist = '%XTL';

  static const typelistReal = '1';

  static const typelistFromTypes = '2';

  static const typesPath = '%XTYPES';

  static const typeAttrs = '%XT';

  static const typeProtected = '%XP';

  static const dataPath = 'SF';

  static const objRootPath = '%OBJROOT';

  static const nodeName = '%XNM';

  static const nodeTag = '%XTAG';

  static const nodeAttrs = '%XA';

  static const nodeClassName = '%XCN';

  static const nodeTypeName = '%XTN';

  static const nodeValueAttrs = '%XV';

  static const nodeArrayLength = '%XN';

  static const nodeScalarElem = '%XE';

  static const nodeScalarElemAttrs = '%XEA';

  static const nodeElemProto = '%XEP';

  static const elemProtoSegment = '%EP';

  static const nodeScalar = '%XSCA';

  static const numericFmt = '%NUMFMT';

  static const numericFmtArmored = '%XNFA';

  static const nodeComment = '%XCMT';

  static const nodeExtData = '%XX';
}

SeqFile iniToXmlSeqFile(IniSeqFile doc) {
  if (doc.headerFields.containsKey(ConvKey.hdrMarker)) return _xmlFromReservedIni(doc);
  final data = iniDataTree(doc);
  if (data == null) {
    throw const FormatException('INI .seq has no reconstructable %OBJROOT data root (not yet decoded)');
  }
  final memo = Map<SeqProperty, SeqProperty>.identity();
  final types = [for (final type in iniTypes(doc)) _xmlReady(type, memo)];
  final hasTypes = doc.sections.any((s) => !s.isDef && !s.isExtData && s.path == '%TYPES');
  final readyData = _xmlReady(data, memo);
  final header = doc.header;
  return SeqFile(
    header: SeqFileHeader(
      format: SeqFormat.xml,
      fileType: header.fileType,
      productName: header.productName,
      fileVersion: header.fileVersion,
    ),
    types: types,
    typelistEntries: hasTypes ? [for (final type in types) SeqTypelistEntry(root: type)] : null,
    rootAttributes: {
      if (header.fileType != null) 'type': header.fileType!,
      if (header.fileVersion != null) 'fileversion': header.fileVersion!,
      if (header.productName != null) 'productname': header.productName!,
    },
    data: readyData.copyWith(subProps: [...readyData.subProps, _iniChannelNode(doc)]),
  );
}

IniSeqFile xmlToIniSeqFile(SeqFile file) {
  final channel = file.data.prop(ConvKey.iniChannel);
  if (channel != null && _isIniChannel(channel)) return _iniFromChannel(channel);
  if (file.header.format != SeqFormat.xml) {
    throw ArgumentError(
      'xmlToIniSeqFile converts XML-flavor SeqFiles only; this model came from '
      '${file.header.format} (a partial decode — convert binary models via '
      'binaryToXmlSeqFile, which marks the output partial)',
    );
  }
  return _iniFromXml(file);
}

SeqFile binaryToXmlSeqFile(SeqFile file) {
  if (file.header.format != SeqFormat.binary) {
    throw ArgumentError('binaryToXmlSeqFile lifts binary-flavor (partial) models only; got ${file.header.format}');
  }
  final memo = Map<SeqProperty, SeqProperty>.identity();
  final types = [for (final type in file.types) _xmlReady(type, memo)];
  final header = file.header;
  return SeqFile(
    header: SeqFileHeader(
      format: SeqFormat.xml,
      fileType: header.fileType,
      productName: header.productName,
    ),
    types: types,
    typelistEntries: [for (final type in types) SeqTypelistEntry(root: type)],
    rootAttributes: {
      if (header.fileType != null) 'type': header.fileType!,
      if (header.productName != null) 'productname': header.productName!,
      ConvKey.partialDecodeAttr: ConvKey.partialDecodeBinary,
    },
    data: _xmlReady(file.data, memo),
  );
}

IniSeqFile binaryToIniSeqFile(SeqFile file) => xmlToIniSeqFile(binaryToXmlSeqFile(file));

String armorText(String text) {
  const hex = '0123456789ABCDEF';
  final sb = StringBuffer();
  for (final byte in utf8.encode(text)) {
    final safe =
        byte > 0x20 &&
        byte <= 0x7E &&
        byte != 0x25 /* % */ &&
        byte != 0x26 /* & */ &&
        byte != 0x3D /* = */ &&
        byte != 0x22 /* " */ &&
        byte != 0x5C /* \ */;
    if (safe) {
      sb.writeCharCode(byte);
    } else {
      sb
        ..write('%')
        ..write(hex[byte >> 4])
        ..write(hex[byte & 0xF]);
    }
  }
  return sb.toString();
}

String unarmorText(String armored) {
  final bytes = <int>[];
  for (var i = 0; i < armored.length; i++) {
    final c = armored.codeUnitAt(i);
    if (c == 0x25 && i + 2 < armored.length) {
      final hi = _hexDigit(armored.codeUnitAt(i + 1));
      final lo = _hexDigit(armored.codeUnitAt(i + 2));
      if (hi >= 0 && lo >= 0) {
        bytes.add((hi << 4) | lo);
        i += 2;
        continue;
      }
    }
    bytes.add(c);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

int _hexDigit(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  return -1;
}

String _armorMap(Map<String, String> map) =>
    [for (final e in map.entries) '${armorText(e.key)}=${armorText(e.value)}'].join('&');

Map<String, String> _unarmorMap(String encoded) {
  if (encoded.isEmpty) return {};
  final out = <String, String>{};
  for (final pair in encoded.split('&')) {
    final eq = pair.indexOf('=');
    if (eq < 0) {
      out[unarmorText(pair)] = '';
    } else {
      out[unarmorText(pair.substring(0, eq))] = unarmorText(pair.substring(eq + 1));
    }
  }
  return out;
}

String _armorNullable(String? value) => value == null ? '0' : '1${armorText(value)}';

String? _unarmorNullable(String encoded) => encoded.startsWith('1') ? unarmorText(encoded.substring(1)) : null;

String _quotedRaw(String armoredToken) => '"$armoredToken"';

bool _latin1Clean(String text) {
  for (final c in text.codeUnits) {
    if (c > 0xFF) return false;
  }
  return true;
}

final _validTag = RegExp(r'^[A-Za-z_][A-Za-z0-9._\-]*$');

const _nameInAttributeTag = '_NAME_IN_ATTRIBUTE_';

String _tagFor(String name) => _validTag.hasMatch(name) && name != _nameInAttributeTag ? name : _nameInAttributeTag;

Map<String, String> _nameAttrs(String name) => {
  if (_tagFor(name) == _nameInAttributeTag && name.isNotEmpty) 'name': name,
};

SeqProperty _xmlReady(SeqProperty p, Map<SeqProperty, SeqProperty> memo) {
  final done = memo[p];
  if (done != null) return done;

  final attrs = <String, String>{
    ..._nameAttrs(p.name),
    if (p.className != null) 'classname': p.className!,
    if (p.typeName != null) 'typename': p.typeName!,
  };
  var numericFormat = p.numericFormat;
  p.attributes.forEach((key, value) {
    if (key == ConvKey.numericFmt && numericFormat == null) {
      numericFormat = value;
      return;
    }
    attrs[key.startsWith('%') ? '${ConvKey.directiveAttrPrefix}${key.substring(1)}' : key] = value;
  });

  final array = p.array;
  var valueAttrs = p.valueAttributes;
  if (array != null && !valueAttrs.containsKey('lbound') && !valueAttrs.containsKey('ubound')) {
    final loRaw = p.attributes['%LO'];
    final lo = loRaw == null ? 0 : (int.tryParse(RegExp(r'-?\d+').firstMatch(loRaw)?.group(0) ?? '') ?? 0);
    valueAttrs = {
      'lbound': loRaw ?? '[0]',
      'ubound': p.attributes['%HI'] ?? (array.isEmpty ? '[]' : '[${lo + array.length - 1}]'),
    };
  }

  final out = SeqProperty(
    name: p.name,
    xmlTag: p.xmlTag ?? _tagFor(p.name),
    className: p.className,
    typeName: p.typeName,
    attributes: attrs,
    scalar: p.scalar,
    array: array == null ? null : [for (final element in array) _xmlReady(element, memo)],
    subProps: [for (final child in p.subProps) _xmlReady(child, memo)],
    valueAttributes: valueAttrs,
    elemProto: p.elemProto == null ? null : _xmlReady(p.elemProto!, memo),
    extData: p.extData,
    numericFormat: numericFormat,
    xmlComment: p.xmlComment,
  );
  memo[p] = out;
  return out;
}

SeqProperty _channelEntry(IniEntry entry) => SeqProperty(
  name: entry.key,
  xmlTag: _tagFor(entry.key),
  attributes: _nameAttrs(entry.key),
  scalar: entry.rawValue,
);

SeqProperty _iniChannelNode(IniSeqFile doc) => SeqProperty(
  name: ConvKey.iniChannel,
  xmlTag: ConvKey.iniChannel,
  attributes: {if (doc.lineTerminator == '\r\n') ConvKey.iniEolAttr: ConvKey.iniEolCrlf},
  subProps: [
    SeqProperty(
      name: ConvKey.iniChannelHeader,
      xmlTag: ConvKey.iniChannelHeader,
      subProps: [
        for (final field in doc.headerFields.entries) _channelEntry(IniEntry(field.key, field.value)),
      ],
    ),
    SeqProperty(
      name: ConvKey.iniChannelSections,
      xmlTag: ConvKey.iniChannelSections,
      subProps: [
        for (final section in doc.sections)
          SeqProperty(
            name: section.path,
            xmlTag: _tagFor(section.path),
            attributes: {
              ..._nameAttrs(section.path),
              ConvKey.iniKindAttr: section.isDef ? ConvKey.iniKindDef : ConvKey.iniKindVal,
              if (section.extDataKind != null) ConvKey.iniExtAttr: section.extDataKind!,
            },
            subProps: [for (final entry in section.entries) _channelEntry(entry)],
          ),
      ],
    ),
  ],
);

bool _isIniChannel(SeqProperty channel) =>
    channel.prop(ConvKey.iniChannelHeader) != null && channel.prop(ConvKey.iniChannelSections) != null;

IniSeqFile _iniFromChannel(SeqProperty channel) {
  final headerFields = <String, String>{
    for (final e in channel.prop(ConvKey.iniChannelHeader)?.subProps ?? const <SeqProperty>[]) e.name: e.scalar ?? '',
  };
  return IniSeqFile(
    header: iniHeaderFromFields(headerFields),
    headerFields: headerFields,
    lineTerminator: channel.attributes[ConvKey.iniEolAttr] == ConvKey.iniEolCrlf ? '\r\n' : '\n',
    sections: [
      for (final s in channel.prop(ConvKey.iniChannelSections)?.subProps ?? const <SeqProperty>[])
        IniSection(
          isDef: s.attributes[ConvKey.iniKindAttr] == ConvKey.iniKindDef,
          path: s.name,
          extDataKind: s.attributes[ConvKey.iniExtAttr],
          entries: [for (final e in s.subProps) IniEntry(e.name, e.scalar ?? '')],
        ),
    ],
  );
}

final _bareToken = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

String _declText(SeqProperty p) {
  final typeName = p.typeName;
  if (typeName != null && _latin1Clean(typeName)) return escapeIniQuoted('TYPE, $typeName');
  final className = p.className;
  if (className != null && _bareToken.hasMatch(className)) return className;
  if (className != null && _latin1Clean(className)) return escapeIniQuoted(className);
  return 'Obj';
}

List<String> _childSegments(List<SeqProperty> children) {
  final used = <String>{};
  final segs = <String>[];
  for (var i = 0; i < children.length; i++) {
    final name = children[i].name;
    var seg = _bareToken.hasMatch(name) ? name : 'C$i';
    while (!used.add(seg)) {
      seg = '${seg}_';
    }
    segs.add(seg);
  }
  return segs;
}

bool _isScalarElement(SeqProperty element) =>
    element.xmlTag == null && element.name.isEmpty && element.subProps.isEmpty && element.array == null;

void _emitNode(SeqProperty p, String path, List<IniSection> out, {required bool scalarOnParent}) {
  final children = p.subProps;
  final segs = _childSegments(children);

  final valueEntries = <IniEntry>[
    IniEntry(ConvKey.nodeName, _quotedRaw(armorText(p.name))),
    if (p.xmlTag != null) IniEntry(ConvKey.nodeTag, _quotedRaw(armorText(p.xmlTag!))),
    IniEntry(ConvKey.nodeAttrs, _quotedRaw(_armorMap(p.attributes))),
    if (p.className != p.attributes['classname'])
      IniEntry(ConvKey.nodeClassName, _quotedRaw(_armorNullable(p.className))),
    if (p.typeName != (p.attributes['typename'] ?? p.attributes['xsi:type']))
      IniEntry(ConvKey.nodeTypeName, _quotedRaw(_armorNullable(p.typeName))),
    if (p.valueAttributes.isNotEmpty) IniEntry(ConvKey.nodeValueAttrs, _quotedRaw(_armorMap(p.valueAttributes))),
  ];
  final scalar = p.scalar;
  if (scalar != null && !scalarOnParent) {
    valueEntries.add(IniEntry(ConvKey.nodeScalar, _quotedRaw(armorText(scalar))));
  }
  final numericFormat = p.numericFormat;
  if (numericFormat != null) {
    valueEntries.add(
      _latin1Clean(numericFormat)
          ? IniEntry(ConvKey.numericFmt, escapeIniQuoted(numericFormat))
          : IniEntry(ConvKey.numericFmtArmored, _quotedRaw(armorText(numericFormat))),
    );
  }
  if (p.xmlComment != null) {
    valueEntries.add(IniEntry(ConvKey.nodeComment, _quotedRaw(armorText(p.xmlComment!))));
  }
  final array = p.array;
  if (array != null) {
    valueEntries.add(IniEntry(ConvKey.nodeArrayLength, '${array.length}'));
    for (var i = 0; i < array.length; i++) {
      final element = array[i];
      if (_isScalarElement(element)) {
        valueEntries.add(IniEntry('${ConvKey.nodeScalarElem}: $i', _quotedRaw(armorText(element.scalar ?? ''))));
        if (element.attributes.isNotEmpty) {
          valueEntries.add(IniEntry('${ConvKey.nodeScalarElemAttrs}: $i', _quotedRaw(_armorMap(element.attributes))));
        }
      }
    }
  }
  if (p.elemProto != null) valueEntries.add(const IniEntry(ConvKey.nodeElemProto, '1'));
  for (var j = 0; j < p.extData.length; j++) {
    valueEntries.add(IniEntry('${ConvKey.nodeExtData}: $j', _quotedRaw(_armorMap(p.extData[j]))));
  }

  final scalarOnParentByChild = List<bool>.filled(children.length, false);
  for (var i = 0; i < children.length; i++) {
    final childScalar = children[i].scalar;
    if (childScalar != null && _latin1Clean(childScalar)) {
      valueEntries.add(IniEntry(segs[i], escapeIniQuoted(childScalar)));
      scalarOnParentByChild[i] = true;
    }
  }

  if (children.isNotEmpty) {
    out.add(
      IniSection(
        isDef: true,
        path: path,
        entries: [for (var i = 0; i < children.length; i++) IniEntry(segs[i], _declText(children[i]))],
      ),
    );
  }
  out.add(IniSection(isDef: false, path: path, entries: valueEntries));

  for (var i = 0; i < children.length; i++) {
    _emitNode(children[i], '$path.${segs[i]}', out, scalarOnParent: scalarOnParentByChild[i]);
  }
  if (array != null) {
    for (var i = 0; i < array.length; i++) {
      if (!_isScalarElement(array[i])) {
        _emitNode(array[i], '$path[$i]', out, scalarOnParent: false);
      }
    }
  }
  if (p.elemProto != null) {
    _emitNode(p.elemProto!, '$path.${ConvKey.elemProtoSegment}', out, scalarOnParent: false);
  }
}

IniSeqFile _iniFromXml(SeqFile file) {
  final header = file.header;
  final entries =
      file.typelistEntries ??
      (file.types.isNotEmpty ? [for (final type in file.types) SeqTypelistEntry(root: type)] : null);
  final typelistMark = file.typelistEntries != null
      ? ConvKey.typelistReal
      : (file.types.isNotEmpty ? ConvKey.typelistFromTypes : null);

  final headerFields = <String, String>{
    if (header.productName != null && _latin1Clean(header.productName!))
      'ProductName': escapeIniQuoted(header.productName!),
    if (header.fileVersion != null && _bareToken.hasMatch(header.fileVersion!)) 'Version': header.fileVersion!,
    if (header.fileType != null && _latin1Clean(header.fileType!)) 'Type': escapeIniQuoted(header.fileType!),
    ConvKey.hdrMarker: '1',
    ConvKey.hdrTrio: _quotedRaw(
      _armorMap({
        if (header.fileType != null) 't': header.fileType!,
        if (header.productName != null) 'p': header.productName!,
        if (header.fileVersion != null) 'v': header.fileVersion!,
      }),
    ),
    if (file.rootAttributes != null) ConvKey.hdrRootAttrs: _quotedRaw(_armorMap(file.rootAttributes!)),
    if (typelistMark != null) ConvKey.hdrTypelist: typelistMark,
    if (file.newline == '\r\n') ConvKey.hdrEol: ConvKey.iniEolCrlf,
  };

  final sections = <IniSection>[];

  final typePaths = <String?>[];
  final usedPaths = <String>{ConvKey.dataPath};
  if (entries != null) {
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].isProtected) {
        typePaths.add(null);
        continue;
      }
      final root = entries[i].root;
      var candidate = (root != null && _bareToken.hasMatch(root.name)) ? root.name : 'T$i';
      while (!usedPaths.add(candidate)) {
        candidate = '${candidate}_';
      }
      typePaths.add(candidate);
    }
  }
  sections.add(
    IniSection(
      isDef: true,
      path: ConvKey.objRootPath,
      entries: [
        const IniEntry(ConvKey.dataPath, 'SequenceFileData'),
        if (entries != null)
          for (var i = 0; i < entries.length; i++)
            if (entries[i].root != null && typePaths[i] != null) IniEntry(typePaths[i]!, _declText(entries[i].root!)),
      ],
    ),
  );

  if (entries != null) {
    sections.add(
      IniSection(
        isDef: false,
        path: ConvKey.typesPath,
        entries: [
          for (var i = 0; i < entries.length; i++)
            if (entries[i].isProtected)
              IniEntry('${ConvKey.typeProtected}: $i', _quotedRaw(armorText(entries[i].protectedData!)))
            else ...[
              IniEntry(
                typePaths[i]!,
                entries[i].root != null && _latin1Clean(entries[i].root!.name)
                    ? escapeIniQuoted(entries[i].root!.name)
                    : '""',
              ),
              IniEntry('${ConvKey.typeAttrs}: ${typePaths[i]!}', _quotedRaw(_armorMap(entries[i].attributes))),
            ],
        ],
      ),
    );
    for (var i = 0; i < entries.length; i++) {
      final root = entries[i].root;
      final typePath = typePaths[i];
      if (root != null && typePath != null) _emitNode(root, typePath, sections, scalarOnParent: false);
    }
  }

  _emitNode(file.data, ConvKey.dataPath, sections, scalarOnParent: false);

  return IniSeqFile(
    header: iniHeaderFromFields(headerFields),
    headerFields: headerFields,
    sections: sections,
  );
}

SeqFile _xmlFromReservedIni(IniSeqFile doc) {
  final defs = <String, IniSection>{};
  final vals = <String, IniSection>{};
  for (final section in doc.sections) {
    if (section.isExtData) continue;
    (section.isDef ? defs : vals)[section.path] = section;
  }

  final trio = _unarmorMap(unquoteIni(doc.headerFields[ConvKey.hdrTrio]) ?? '');
  final rootAttrsRaw = doc.headerFields[ConvKey.hdrRootAttrs];

  List<SeqTypelistEntry>? typelistEntries;
  var types = const <SeqProperty>[];
  final typelistMark = doc.headerFields[ConvKey.hdrTypelist];
  if (typelistMark != null) {
    final listSection = vals[ConvKey.typesPath];
    final rebuilt = <SeqTypelistEntry>[];
    for (final entry in listSection?.entries ?? const <IniEntry>[]) {
      if (entry.key.startsWith('${ConvKey.typeProtected}: ')) {
        rebuilt.add(SeqTypelistEntry(protectedData: unarmorText(unquoteIni(entry.rawValue)!)));
      } else if (!entry.isDirective) {
        final path = entry.key;
        rebuilt.add(
          SeqTypelistEntry(
            attributes: _unarmorMap(unquoteIni(listSection!.directives['${ConvKey.typeAttrs}: $path']) ?? ''),
            root: vals.containsKey(path) ? _rebuildNode(path, null, defs, vals) : null,
          ),
        );
      }
    }
    types = [
      for (final entry in rebuilt)
        if (entry.root != null) entry.root!,
    ];
    typelistEntries = typelistMark == ConvKey.typelistReal ? rebuilt : null;
  }

  return SeqFile(
    header: SeqFileHeader(
      format: SeqFormat.xml,
      fileType: trio['t'],
      productName: trio['p'],
      fileVersion: trio['v'],
    ),
    types: types,
    typelistEntries: typelistEntries,
    rootAttributes: rootAttrsRaw == null ? null : _unarmorMap(unquoteIni(rootAttrsRaw)!),
    data: _rebuildNode(ConvKey.dataPath, null, defs, vals),
    newline: doc.headerFields[ConvKey.hdrEol] == ConvKey.iniEolCrlf ? '\r\n' : '\n',
  );
}

SeqProperty _rebuildNode(String path, String? scalarRaw, Map<String, IniSection> defs, Map<String, IniSection> vals) {
  final val = vals[path];
  if (val == null) {
    throw FormatException('reserved .seq conversion: missing value section [$path]');
  }
  final dir = val.directives;
  String? armored(String key) {
    final raw = dir[key];
    return raw == null ? null : unarmorText(unquoteIni(raw)!);
  }

  final name = armored(ConvKey.nodeName);
  if (name == null) {
    throw FormatException('reserved .seq conversion: [$path] lacks ${ConvKey.nodeName}');
  }
  final attrs = _unarmorMap(unquoteIni(dir[ConvKey.nodeAttrs]) ?? '');
  var className = attrs['classname'];
  var typeName = attrs['typename'] ?? attrs['xsi:type'];
  final classOverride = dir[ConvKey.nodeClassName];
  if (classOverride != null) className = _unarmorNullable(unquoteIni(classOverride)!);
  final typeOverride = dir[ConvKey.nodeTypeName];
  if (typeOverride != null) typeName = _unarmorNullable(unquoteIni(typeOverride)!);

  final scalar = scalarRaw != null ? unquoteIni(scalarRaw) : armored(ConvKey.nodeScalar);
  final numericFormat = dir.containsKey(ConvKey.numericFmt)
      ? unquoteIni(dir[ConvKey.numericFmt])
      : armored(ConvKey.numericFmtArmored);

  final def = defs[path];
  final subProps = <SeqProperty>[];
  for (final entry in def?.entries ?? const <IniEntry>[]) {
    if (entry.isDirective) continue;
    subProps.add(_rebuildNode('$path.${entry.key}', val.members[entry.key], defs, vals));
  }

  List<SeqProperty>? array;
  final lengthRaw = dir[ConvKey.nodeArrayLength];
  if (lengthRaw != null) {
    final length = int.parse(lengthRaw.trim());
    array = [
      for (var i = 0; i < length; i++)
        if (dir.containsKey('${ConvKey.nodeScalarElem}: $i'))
          SeqProperty(
            name: '',
            scalar: armored('${ConvKey.nodeScalarElem}: $i'),
            attributes: _unarmorMap(unquoteIni(dir['${ConvKey.nodeScalarElemAttrs}: $i']) ?? ''),
          )
        else
          _rebuildNode('$path[$i]', null, defs, vals),
    ];
  }

  final extData = <Map<String, String>>[];
  for (var j = 0; dir.containsKey('${ConvKey.nodeExtData}: $j'); j++) {
    extData.add(_unarmorMap(unquoteIni(dir['${ConvKey.nodeExtData}: $j'])!));
  }

  return SeqProperty(
    name: name,
    xmlTag: armored(ConvKey.nodeTag),
    className: className,
    typeName: typeName,
    attributes: attrs,
    scalar: scalar,
    array: array,
    subProps: subProps,
    valueAttributes: dir.containsKey(ConvKey.nodeValueAttrs)
        ? _unarmorMap(unquoteIni(dir[ConvKey.nodeValueAttrs])!)
        : const {},
    elemProto: dir.containsKey(ConvKey.nodeElemProto)
        ? _rebuildNode('$path.${ConvKey.elemProtoSegment}', null, defs, vals)
        : null,
    extData: extData,
    numericFormat: numericFormat,
    xmlComment: armored(ConvKey.nodeComment),
  );
}
