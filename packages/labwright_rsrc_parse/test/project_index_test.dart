import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

const _lvlib = '''<?xml version='1.0' encoding='UTF-8'?>
<Library LVVersion="12008004">
\t<Property Name="NI.Lib.Version" Type="Str">1.0.0.0</Property>
\t<Item Name="API" Type="Folder">
\t\t<Item Name="Read Coils.vi" Type="VI" URL="../MB_Master/Read Coils.vi"/>
\t</Item>
\t<Item Name="MB_ADU.lvclass" Type="LVClass" URL="../MB_ADU/MB_ADU.lvclass"/>
</Library>
''';

const _lvclass = '''<?xml version='1.0' encoding='UTF-8'?>
<LVClass LVVersion="20008000">
\t<Item Name="MB_ADU.ctl" Type="Class Private Data" URL="MB_ADU.ctl"/>
\t<Item Name="Read TX Data.vi" Type="VI" URL="../Read TX Data.vi"/>
</LVClass>
''';

void main() {
  test('flattened text carries six bits per character and round-trips', () {
    final bytes = Uint8List.fromList([for (var i = 0; i < 300; i++) (i * 37) & 0xff]);
    final text = lvFlattenedText(bytes);
    expect(text.codeUnits.every((unit) => unit >= 0x21 && unit <= 0x60), isTrue);
    expect(lvFlattenedTextBytes(text).sublist(0, bytes.length), bytes);
    expect(lvFlattenedTextBytes('!!!!'), [0, 0, 0]);
    expect(lvFlattenedTextBytes('````'), [0xff, 0xff, 0xff]);
    expect(lvFlattenedTextBytes('`\n`\n`\n`'), [0xff, 0xff, 0xff], reason: 'line breaks are ignored');
  });

  test('a library file lists its items with their folders and properties', () {
    final library = LvLibraryFile.parse(_lvlib, fileName: 'MB Master.lvlib');
    expect(library.kind, LvLibraryKind.library);
    expect(library.properties, {'NI.Lib.Version': '1.0.0.0'});
    expect(
      [for (final item in library.items) (item.name, item.type, item.url, item.folders.join('/'))],
      [
        ('API', 'Folder', null, ''),
        ('Read Coils.vi', 'VI', '../MB_Master/Read Coils.vi', 'API'),
        ('MB_ADU.lvclass', 'LVClass', '../MB_ADU/MB_ADU.lvclass', ''),
      ],
    );
    expect(() => LvLibraryFile.parse(_lvlib, fileName: 'x.lvclass'), throwsFormatException);
    expect(() => LvLibraryFile.parse(_lvlib, fileName: 'x.txt'), throwsFormatException);
  });

  test('a library URL resolves from the library file taken as a directory', () {
    final p = Directory.current.path;
    expect(
      resolveLibraryUrl(_at('$p/lib/MB Master.lvlib'), '../MB_Master/Read Coils.vi'),
      _at('$p/lib/MB_Master/Read Coils.vi'),
    );
    expect(
      resolveLibraryUrl(_at('$p/MB_ADU/MB_ADU.lvclass'), 'MB_ADU.ctl'),
      _at('$p/MB_ADU/MB_ADU.lvclass/MB_ADU.ctl'),
    );
    expect(
      resolveViPath(_at('$p/Examples/Tester.vi'), ['', '', 'MB_Master', 'Read Coils.vi']),
      _at('$p/MB_Master/Read Coils.vi'),
    );
    expect(resolveViPath(_at('$p/Tester.vi'), ['', 'Sub.vi']), _at('$p/Sub.vi'));
  });

  test('the index names every member by its owning libraries and resolves link entries', () {
    final root = Directory.systemTemp.createTempSync('lv_project');
    try {
      File(_at('${root.path}/lib/MB Master.lvlib'))
        ..createSync(recursive: true)
        ..writeAsStringSync(_lvlib);
      File(_at('${root.path}/lib/MB_ADU/MB_ADU.lvclass'))
        ..createSync(recursive: true)
        ..writeAsStringSync(_lvclass);
      File(_at('${root.path}/lib/MB_Master/Read Coils.vi')).createSync(recursive: true);
      final index = LvProjectIndex.scan(root);
      expect(index.libraries.length, 2);
      expect(index.fileOf(['MB Master.lvlib', 'Read Coils.vi']), _at('${root.path}/lib/MB_Master/Read Coils.vi'));
      expect(index.fileOf(['MB Master.lvlib', 'MB_ADU.lvclass']), _at('${root.path}/lib/MB_ADU/MB_ADU.lvclass'));
      expect(
        index.fileOf(['MB Master.lvlib', 'MB_ADU.lvclass', 'Read TX Data.vi']),
        _at('${root.path}/lib/MB_ADU/Read TX Data.vi'),
      );
      expect(index.fileOf(['MB_ADU.lvclass', 'Read TX Data.vi']), isNull, reason: 'the class is owned by the library');
      final byPath = ViLinkEntryFramed(
        0,
        0,
        'IUVI',
        qualifiedName: const ['MB Master.lvlib', 'Read Coils.vi'],
        path: _relativePath(['', '', 'MB_Master', 'Read Coils.vi']),
      );
      expect(
        index.fileOfLink(byPath, viPath: _at('${root.path}/lib/Examples/Tester.vi')),
        _at('${root.path}/lib/MB_Master/Read Coils.vi'),
      );
      final byName = ViLinkEntryFramed(
        0,
        0,
        'IUVI',
        qualifiedName: const ['MB Master.lvlib', 'MB_ADU.lvclass', 'Read TX Data.vi'],
        path: _relativePath(['', 'elsewhere', 'Read TX Data.vi']),
      );
      expect(
        index.fileOfLink(byName, viPath: _at('${root.path}/lib/Examples/Tester.vi')),
        _at('${root.path}/lib/MB_ADU/Read TX Data.vi'),
        reason: 'the path record misses, the qualified name answers',
      );
      expect(index.fileOfLink(const ViLinkEntryFramed(0, 0, 'IUVI'), viPath: _at('${root.path}/x.vi')), isNull);
    } finally {
      root.deleteSync(recursive: true);
    }
  });
}

/// [path] spelled as this platform spells it.
String _at(String path) => Uri.file(path.replaceAll('\\', '/')).toFilePath();

ViPath _relativePath(List<String> components) {
  final body = BytesBuilder()
    ..add([0, 1])
    ..add([components.length >> 8, components.length & 0xff]);
  for (final component in components) {
    body.addByte(component.length);
    body.add(component.codeUnits);
  }
  final payload = body.toBytes();
  final bytes = BytesBuilder()
    ..add('PTH0'.codeUnits)
    ..add([0, 0, payload.length >> 8, payload.length & 0xff])
    ..add(payload);
  return ViPath(bytes.toBytes());
}
