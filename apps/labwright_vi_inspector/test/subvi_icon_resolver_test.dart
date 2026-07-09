import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/subvi_icon_resolver.dart';

/// Builds a temp project tree: the caller VI and a sibling target VI in the same
/// folder, plus a large decoy subtree elsewhere under the root. Returns the
/// caller's path. The decoy tree is what a naive `listSync(recursive: true)`
/// would eagerly materialise before any cap applied — the bug this guards.
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
  test('resolves a wanted sibling subVI without walking the whole tree', () {
    final t = _tree(2000);
    addTearDown(() => t.root.deleteSync(recursive: true));
    // Nearest-first + early-exit: the target sits in the caller's own folder, so
    // even a tiny entry budget (far smaller than the 2000-file decoy tree) finds
    // it — proving the walk does not eagerly traverse everything.
    final loader = buildProjectViLoader(
      t.callerPath,
      wantedNames: {'Target.vi'},
      maxEntries: 20,
    );
    expect(loader('Target.vi'), isNotNull);
    expect(loader('Target.vi'), [1, 2, 3]);
  });

  test('a bounded walk never exceeds maxFiles and returns', () {
    final t = _tree(500);
    addTearDown(() => t.root.deleteSync(recursive: true));
    // No wantedNames: the walk still terminates, bounded by maxFiles/maxEntries.
    final loader = buildProjectViLoader(t.callerPath, maxFiles: 50);
    // The nearby target is indexed; an unknown name is simply null.
    expect(loader('Target.vi'), isNotNull);
    expect(loader('Nonexistent.vi'), isNull);
  });

  test('an unreadable / missing name resolves to null', () {
    final t = _tree(0);
    addTearDown(() => t.root.deleteSync(recursive: true));
    final loader = buildProjectViLoader(t.callerPath);
    expect(loader('Not There.vi'), isNull);
  });
}
