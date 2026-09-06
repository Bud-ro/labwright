import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/subvi_icon_resolver.dart';

Directory? _corpusDir() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final candidate = Directory(
      '${dir.path}/packages/labwright_rsrc_parse/corpus/vi',
    );
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

File? _iconViFile() {
  final corpus = _corpusDir();
  if (corpus == null) return null;
  final f = File(
    '${corpus.path}/vipm-io_caraya/vipm-io-caraya-ca35333/src/classes/Test/'
    'Define Test.vi',
  );
  return f.existsSync() ? f : null;
}

void main() {
  test('decodeViFileIcon reads an icon without inflating heaps', () {
    final vi = _iconViFile();
    if (vi == null) return;
    final icon = decodeViFileIcon(vi.path);
    expect(icon, isNotNull);
    expect(icon!.pixels, hasLength(1024));
  });

  test('linker paths resolve targets directly — no directory search', () {
    final corpus = _corpusDir();
    if (corpus == null) return;
    final vi = File(
      '${corpus.path}/picotech_picosdk-ni-labview-examples/'
      'picotech-picosdk-ni-labview-examples-dceb711/ps2000a/'
      'PicoScope2000aExampleStreamingMSO.vi',
    );
    if (!vi.existsSync()) return;
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
  });

  test('ring search finds a target with no linker path, nearest first', () {
    final vi = _iconViFile();
    if (vi == null) return;
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
  });

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
