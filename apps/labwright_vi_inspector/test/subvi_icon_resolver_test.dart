import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/subvi_icon_resolver.dart';

/// Builds a temp project tree: the caller VI and a sibling target VI in the same
/// folder, plus a decoy subtree elsewhere under the root. Returns the caller's
/// path. Every `.vi` under the root must be indexed (a complete walk).
({String callerPath, Directory root}) _tree(int decoys) {
  final root = Directory.systemTemp.createTempSync('subvi_loader_');
  final proj = Directory('${root.path}/proj/sub')..createSync(recursive: true);
  File('${proj.path}/Caller.vi').writeAsBytesSync([0]);
  File('${proj.path}/Target.vi').writeAsBytesSync([1, 2, 3]);
  final decoy = Directory('${root.path}/decoy/deep')
    ..createSync(recursive: true);
  for (var i = 0; i < decoys; i++) {
    File('${decoy.path}/decoy_$i.vi').writeAsBytesSync([0]);
  }
  return (callerPath: '${proj.path}/Caller.vi', root: root);
}

void main() {
  test('indexProjectVis indexes every .vi in the project subtree', () {
    final t = _tree(300);
    addTearDown(() => t.root.deleteSync(recursive: true));
    final index = indexProjectVis(t.callerPath);
    // The sibling target, the caller, and every decoy are all reachable.
    expect(index['Target.vi'], '${t.root.path}/proj/sub/Target.vi');
    expect(index['Caller.vi'], isNotNull);
    expect(index['decoy_0.vi'], isNotNull);
    expect(index['decoy_299.vi'], isNotNull);
    expect(index['Nonexistent.vi'], isNull);
  });

  test('levelsUp bounds how far up the walk starts', () {
    final t = _tree(0);
    addTearDown(() => t.root.deleteSync(recursive: true));
    // From proj/sub, levelsUp:0 stays in the caller's own folder — the sibling
    // target is still found, the decoy tree (a cousin) is out of scope.
    final near = indexProjectVis(t.callerPath, levelsUp: 0);
    expect(near['Target.vi'], isNotNull);
  });

  test('buildProjectViLoader resolves bytes off the main isolate', () async {
    final t = _tree(50);
    addTearDown(() => t.root.deleteSync(recursive: true));
    final loader = await buildProjectViLoader(t.callerPath);
    expect(loader('Target.vi'), [1, 2, 3]);
    expect(loader('Missing.vi'), isNull);
  });
}
