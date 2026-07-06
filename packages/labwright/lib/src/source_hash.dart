/// Content identity for a suite: SHA-1 hashes over the suite's local sources,
/// factored so external tooling (and the viewer's hot reload) can tell WHAT
/// changed:
///
///  * a per-test `testHash` — the token stream of that test's `test(...)` /
///    `skipTest(...)` registration call (name, requirements, body closure);
///  * one `setupHash` — the token streams of every file reachable from the
///    entry script via local imports, with all test-registration subtrees
///    factored OUT (so editing one test body changes only that test's hash,
///    while editing shared setup/helpers changes the setup hash).
///
/// Token streams, not raw bytes: formatting and comments do not change a hash.
/// The walk follows relative directives only (`package:`/`dart:` never), same
/// as `labwright scan` — sources imported by `package:` URI are NOT covered.
/// Skip-if-unchanged tooling must treat an ABSENT test hash as "assume
/// modified": tear-off or wrapper registrations have no `test(...)` call at
/// the captured site, so no hash can be attributed.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:crypto/crypto.dart';

/// The local (non-`package:`/`dart:`) URIs a Dart file's directives point
/// at, from a real AST parse (syntactic only — no resolution needed).
/// Comments and string literals containing import-shaped text cannot fool
/// this, and conditional imports contribute EVERY branch (any of them may
/// be the one that loads).
Iterable<String> localDirectiveUris(String source) sync* {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  for (final directive in unit.directives) {
    if (directive is! UriBasedDirective) continue; // `part of` has no target
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

/// Every file reachable from [entry] via local import/export/part directives,
/// transitively — including THROUGH files outside the entry's folder — as
/// canonical paths (sorted, deterministic).
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

/// The factored content identity of one suite: [setupHash] plus a test hash
/// per registration site that could be attributed (keyed `<abs path>:<line>`).
class SuiteHashes {
  SuiteHashes(this.setupHash, this.sites);

  final String setupHash;
  final Map<String, String> sites;

  /// The test hash for the registration at [file]:[line], or null when no
  /// `test(...)`/`skipTest(...)` call could be attributed there (tear-offs,
  /// wrappers) — callers must treat null as "assume modified".
  String? testHash(String? file, int? line) =>
      file == null || line == null ? null : sites['${File(file).absolute.uri.normalizePath().toFilePath()}:$line'];
}

/// One `test(...)`/`skipTest(...)` invocation found in a source file.
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

/// Computes [SuiteHashes] for the suite rooted at [entryPath]. Parses each
/// reachable file once; a file that fails to read hashes as its path only
/// (deterministic, still detects add/remove). This walks and reads files —
/// call it off the bench-critical path.
SuiteHashes computeSuiteHashes(String entryPath) {
  final files = reachableFiles(File(entryPath));
  final setup = BytesBuilder(copy: false);
  final bySite = <String, String>{};

  // File markers are RELATIVE to the entry script's directory so a setupHash
  // is comparable across checkouts/machines; a file reached from outside that
  // root (via ../) falls back to its absolute path.
  final root = File(entryPath).absolute.parent.uri.normalizePath().toFilePath();
  for (final path in files) {
    final rel = path.startsWith(root) ? path.substring(root.length) : path;
    setup.add(utf8.encode('\x00file:$rel\n'));
    final String source;
    try {
      source = File(path).readAsStringSync();
    } catch (_) {
      continue; // unreadable: path marker alone still contributes
    }
    final result = parseString(content: source, throwIfDiagnostics: false);
    final collector = _TestSiteCollector((offset) => result.lineInfo.getLocation(offset).lineNumber);
    result.unit.accept(collector);
    final sites = collector.sites;

    // Per-test hashes: the smallest invocation starting on (or covering) each
    // distinct start line — the line _callerLocation captures at registration.
    for (final site in sites) {
      final tokens = BytesBuilder(copy: false);
      for (var t = result.unit.beginToken; !t.isEof; t = t.next!) {
        if (t.offset >= site.offset && t.end <= site.end) {
          tokens.add(utf8.encode(t.lexeme));
          tokens.addByte(0x0A);
        }
      }
      final key = '$path:${site.startLine}';
      // Two invocations starting on one line: keep the smaller (inner) one —
      // deterministic, and the inner call is the registration itself.
      final existing = bySite.containsKey(key);
      if (!existing) bySite[key] = sha1.convert(tokens.takeBytes()).toString();
    }

    // Setup hash: every token NOT inside any test subtree; each excluded
    // subtree contributes a fixed placeholder so test count/positions still
    // register without their contents.
    var excluded = -1;
    for (var t = result.unit.beginToken; !t.isEof; t = t.next!) {
      final inside = sites.any((s) => t.offset >= s.offset && t.end <= s.end);
      if (inside) {
        final owner = sites.indexWhere((s) => t.offset >= s.offset && t.end <= s.end);
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
