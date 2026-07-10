import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/subvi_icon_resolver.dart';

/// Builds a temp project tree with a caller VI, a same-folder target, a
/// sibling-folder target one ring out, and a decoy subtree. Targets carry
/// [viBytes] (a real icon-bearing VI when the corpus is fetched).
({String callerPath, Directory root}) _tree(List<int> viBytes) {
  final root = Directory.systemTemp.createTempSync('subvi_stream_');
  final proj = Directory('${root.path}/proj/sub')..createSync(recursive: true);
  File('${proj.path}/Caller.vi').writeAsBytesSync([0]);
  File('${proj.path}/Near.vi').writeAsBytesSync(viBytes);
  final sibling = Directory('${root.path}/proj/lib')
    ..createSync(recursive: true);
  File('${sibling.path}/Far.vi').writeAsBytesSync(viBytes);
  final decoy = Directory('${root.path}/decoy')..createSync(recursive: true);
  for (var i = 0; i < 50; i++) {
    File('${decoy.path}/decoy_$i.vi').writeAsBytesSync([0]);
  }
  return (callerPath: '${proj.path}/Caller.vi', root: root);
}

/// A real icon-bearing VI from the corpus, or a 1-byte stub when the corpus is
/// not fetched (stream tests then skip).
List<int> _realViWithIcon() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final candidate = File(
      '${dir.path}/packages/labwright_rsrc_parse/corpus/vi/vipm-io_caraya/'
      'vipm-io-caraya-ca35333/src/classes/Test/Define Test.vi',
    );
    if (candidate.existsSync()) return candidate.readAsBytesSync();
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return const [0];
}

void main() {
  test('searchIconRing searches a subtree, skipping the excluded ring', () {
    final real = _realViWithIcon();
    if (real.length < 100) return;
    final t = _tree(real);
    addTearDown(() => t.root.deleteSync(recursive: true));
    // Ring 0: the caller's own folder — finds Near.vi only.
    final ring0 = searchIconRing('${t.root.path}/proj/sub', null, {
      'Near.vi',
      'Far.vi',
    });
    expect(ring0.keys, contains('Near.vi'));
    expect(ring0.keys, isNot(contains('Far.vi')));
    // Ring 1: the parent subtree minus ring 0 — finds Far.vi.
    final ring1 = searchIconRing(
      '${t.root.path}/proj',
      '${t.root.path}/proj/sub',
      {'Far.vi'},
    );
    expect(ring1.keys, contains('Far.vi'));
  });

  test('streamSubViIcons yields nearest finds first and completes', () async {
    final real = _realViWithIcon();
    if (real.length < 100) return;
    final t = _tree(real);
    addTearDown(() => t.root.deleteSync(recursive: true));
    final batches = await streamSubViIcons(t.callerPath, {
      'Near.vi',
      'Far.vi',
      'Nowhere.vi',
    }).toList();
    final flat = [for (final batch in batches) ...batch.keys];
    // Near.vi (own folder) arrives in an earlier batch than Far.vi (a ring out);
    // a name that exists nowhere is simply absent after the rings exhaust.
    expect(flat.indexOf('Near.vi'), lessThan(flat.indexOf('Far.vi')));
    expect(flat, isNot(contains('Nowhere.vi')));
  });

  test('an empty wanted set streams nothing', () async {
    final t = _tree(const [0]);
    addTearDown(() => t.root.deleteSync(recursive: true));
    expect(await streamSubViIcons(t.callerPath, const {}).toList(), isEmpty);
  });
}
