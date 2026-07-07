// The viewer's jump-to-source is a client-side vscode:// link built from a
// static template the server computes once at startup. These tests pin the
// template per platform; the page substitutes {file}/{line} (app.js).
import 'package:labwright/src/viewer.dart';
import 'package:test/test.dart';

void main() {
  test('native Linux/macOS: the absolute path supplies the slash', () {
    expect(
      editorLinkTemplate(isWindows: false),
      'vscode://file{file}:{line}',
      reason: r'vscode://file/abs/path.dart:12 — {file} starts with /',
    );
  });

  test('Windows: an explicit slash before the drive-letter path', () {
    expect(
      editorLinkTemplate(isWindows: true),
      'vscode://file/{file}:{line}',
      reason: r'vscode://file/C:/abs/path.dart:12 — the page normalizes \ to /',
    );
  });

  test('WSL: a vscode-remote authority naming the distro', () {
    expect(
      editorLinkTemplate(isWindows: false, wslDistro: 'Ubuntu-24.04'),
      'vscode://vscode-remote/wsl+Ubuntu-24.04{file}:{line}',
      reason: 'the Windows browser hands vscode:// to Windows VS Code, which owns the WSL remote',
    );
  });
}
