import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/subvi_icon_resolver.dart';

import '../../../tool/corpus.dart';

final File _iconViFile = File(
  '${corpusVi.path}/vipm-io_caraya/vipm-io-caraya-ca35333/src/classes/Test/'
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
      '${corpusVi.path}/picotech_picosdk-ni-labview-examples/'
      'picotech-picosdk-ni-labview-examples-dceb711/ps2000a/'
      'PicoScope2000aExampleStreamingMSO.vi',
    );
    final sw = Stopwatch()..start();
    final icons = resolveIconsOnDisk(vi.path, {
      'PicoScope2000aOpen.vi',
      'PicoScope2000aClose.vi',
      'Nonexistent Anywhere.vi',
    }, 4);
    sw.stop();
    expect(
      icons.keys,
      containsAll(['PicoScope2000aOpen.vi', 'PicoScope2000aClose.vi']),
    );
    expect(icons.keys, isNot(contains('Nonexistent Anywhere.vi')));
  }, tags: 'corpus');

  test(
    'ring search finds a target with no linker path, nearest first',
    () {
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
      final icons = resolveIconsOnDisk(caller.path, {
        'Near.vi',
        'Far.vi',
        'Nowhere.vi',
      }, 4);
      expect(icons.keys, containsAll(['Near.vi', 'Far.vi']));
      expect(icons.keys, isNot(contains('Nowhere.vi')));
    },
    tags: 'corpus',
  );

  test(
    'an empty wanted set resolves to an empty map without touching disk',
    () async {
      expect(
        await resolveSubViIconsFor('/nonexistent/x.vi', const {}),
        isEmpty,
      );
    },
  );
}
