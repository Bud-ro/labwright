import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:crypto/crypto.dart';

Iterable<String> localDirectiveUris(String source) sync* {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  for (final directive in unit.directives) {
    if (directive is! UriBasedDirective) continue;
    final uris = [
      directive.uri.stringValue,
      if (directive is NamespaceDirective)
        for (final config in directive.configurations) config.uri.stringValue,
    ];
    for (final uri in uris) {
      if (uri == null || uri.startsWith('package:') || uri.startsWith('dart:')) {
        continue;
      }
      yield uri;
    }
  }
}

List<String> reachableFiles(File entry) {
  final reachable = <String>{};
  void visit(File file) {
    final path = file.absolute.uri.normalizePath().toFilePath();
    if (!reachable.add(path) || !file.existsSync()) return;
    for (final uri in localDirectiveUris(file.readAsStringSync())) {
      visit(File.fromUri(file.absolute.uri.resolve(uri)));
    }
  }

  visit(entry);
  return reachable.where((p) => File(p).existsSync()).toList()..sort();
}

class SuiteHashes {
  SuiteHashes(this.setupHash, this.sites);

  final String setupHash;
  final Map<String, String> sites;
  String? testHash(String? file, int? line) =>
      file == null || line == null ? null : sites['${File(file).absolute.uri.normalizePath().toFilePath()}:$line'];
}

class _TestSite {
  _TestSite(this.offset, this.end, this.startLine);

  final int offset;
  final int end;
  final int startLine;
}

class _TestSiteCollector extends RecursiveAstVisitor<void> {
  _TestSiteCollector(this.lineAt);

  final int Function(int offset) lineAt;
  final List<_TestSite> sites = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    if (name == 'test' || name == 'skipTest') {
      sites.add(_TestSite(node.offset, node.end, lineAt(node.offset)));
    }
    super.visitMethodInvocation(node);
  }
}

SuiteHashes computeSuiteHashes(String entryPath) {
  final files = reachableFiles(File(entryPath));
  final setup = BytesBuilder(copy: false);
  final bySite = <String, String>{};
  final root = File(entryPath).absolute.parent.uri.normalizePath().toFilePath();
  for (final path in files) {
    final rel = path.startsWith(root) ? path.substring(root.length) : path;
    setup.add(utf8.encode('\x00file:$rel\n'));
    final String source;
    try {
      source = File(path).readAsStringSync();
    } catch (_) {
      continue;
    }
    final result = parseString(content: source, throwIfDiagnostics: false);
    final collector = _TestSiteCollector((offset) => result.lineInfo.getLocation(offset).lineNumber);
    result.unit.accept(collector);
    final sites = collector.sites;
    for (final site in sites) {
      final tokens = BytesBuilder(copy: false);
      for (var t = result.unit.beginToken; !t.isEof; t = t.next!) {
        if (t.offset >= site.offset && t.end <= site.end) {
          tokens.add(utf8.encode(t.lexeme));
          tokens.addByte(0x0A);
        }
      }
      bySite.putIfAbsent('$path:${site.startLine}', () => sha1.convert(tokens.takeBytes()).toString());
    }
    var excluded = -1;
    for (var t = result.unit.beginToken; !t.isEof; t = t.next!) {
      final owner = sites.indexWhere((s) => t.offset >= s.offset && t.end <= s.end);
      if (owner >= 0) {
        if (owner != excluded) {
          excluded = owner;
          setup.add(utf8.encode('\x00test-site\n'));
        }
        continue;
      }
      excluded = -1;
      setup.add(utf8.encode(t.lexeme));
      setup.addByte(0x0A);
    }
  }
  return SuiteHashes(sha1.convert(setup.takeBytes()).toString(), bySite);
}
