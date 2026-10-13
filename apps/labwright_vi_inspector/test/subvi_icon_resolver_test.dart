import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/subvi_icon_resolver.dart';

import '../../../tool/corpus.dart';

final File _iconViFile = File(
  '${corpusVi.path}/vi-corpus/sources/vipm-io__caraya/src/classes/Test/'
  'Define Test.vi',
);

void main() {
  test('decodeViFileIcon reads an icon without inflating heaps', () {
    final icon = decodeViFileIcon(_iconViFile.path);
    expect(icon, isNotNull);
    expect(icon!.depth, LegacyIconDepth.eightBit);
  }, tags: 'corpus');

  test('linker paths resolve targets directly — no directory search', () {
    final vi = File(
      '${corpusVi.path}/vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps2000a/'
      'PicoScope2000aExampleStreamingMSO.vi',
    );
    final sw = Stopwatch()..start();
    final icons = resolveSubViIcons(vi.path, {
      'PicoScope2000aOpen.vi',
      'PicoScope2000aClose.vi',
      'Nonexistent Anywhere.vi',
    });
    sw.stop();
    expect(
      icons.keys,
      containsAll(['PicoScope2000aOpen.vi', 'PicoScope2000aClose.vi']),
    );
    expect(icons.keys, isNot(contains('Nonexistent Anywhere.vi')));
  }, tags: 'corpus');

  test('ring search finds a target with no linker path, nearest first', () {
    final vi = _iconViFile;
    final root = Directory.systemTemp.createTempSync('subvi_resolve_');
    addTearDown(() => root.deleteSync(recursive: true));
    final proj = Directory('${root.path}/proj/sub')
      ..createSync(recursive: true);
    final caller = File('${proj.path}/Caller.vi')..writeAsBytesSync([0]);
    File('${proj.path}/Near.vi').writeAsBytesSync(vi.readAsBytesSync());
    final sibling = Directory('${root.path}/proj/lib')
      ..createSync(recursive: true);
    File('${sibling.path}/Far.vi').writeAsBytesSync(vi.readAsBytesSync());
    final icons = resolveSubViIcons(caller.path, {
      'Near.vi',
      'Far.vi',
      'Nowhere.vi',
    });
    expect(icons.keys, containsAll(['Near.vi', 'Far.vi']));
    expect(icons.keys, isNot(contains('Nowhere.vi')));
  }, tags: 'corpus');

  test(
    'an empty wanted set resolves to an empty map without touching disk',
    () {
      expect(resolveSubViIcons('/nonexistent/x.vi', const {}), isEmpty);
    },
  );

  test(
    'a library member resolves through its link, by path or by qualified name',
    () {
      final caller = File(
        '${corpusVi.path}/vi-corpus/sources/rfporter__Modbus-Master/Examples/MB_Master Comm Tester.vi',
      );
      final icons = resolveSubViIcons(caller.path, {
        'Read Coils.vi',
        'Clear Errors.vi',
      }, levelsUp: 1);
      expect(icons.keys, [
        'Read Coils.vi',
      ], reason: 'Clear Errors.vi lives in <vilib>');
    },
    tags: 'corpus',
  );
}
