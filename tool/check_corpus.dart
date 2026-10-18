import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'corpus_indexing.dart';

/// Run: `dart run tool/check_corpus.dart <corpus-dir>`
///
/// Checks the metadata a corpus repository keeps against its tree: `sources.json`, each
/// source's `manifest.json`, `corpus.json`, `candidates.json` and `rosetta/manifest.json` in a
/// repository of vendored sources; `manifest.json`, `held.json` and `LICENSES.md` in a snippet
/// collection; and every `index.json`. What the tree holds comes from `git ls-tree`, so files a
/// sparse checkout leaves out are still checked for presence and size; their contents (hashes,
/// snippet chunks, index freshness) are checked for the sources that are on disk. A `held.json`
/// entry names an image by its page and image URL, or a source by the count it holds. Exits 1
/// when anything is wrong.
Future<void> main(List<String> args) async {
  if (args.length != 1 || args.first == '--help' || args.first == '-h') {
    stderr.writeln('usage: dart run tool/check_corpus.dart <corpus-dir>');
    exitCode = 2;
    return;
  }
  final corpus = Directory(args.first).absolute;
  if (!corpus.existsSync()) {
    stderr.writeln('no such directory: ${corpus.path}');
    exitCode = 2;
    return;
  }
  final check = _Check(corpus, await _Tree.read(corpus));
  if (check.tree.has('sources.json')) {
    await check.sourcesRepository();
  } else if (check.tree.has('manifest.json')) {
    await check.snippetCollection();
  } else {
    check.problem('.', 'neither a sources.json nor a manifest.json: not a corpus repository');
  }
  for (final line in check.notes) {
    stdout.writeln(line);
  }
  for (final line in check.problems) {
    stdout.writeln('PROBLEM $line');
  }
  stdout.writeln('${check.problems.length} problems');
  if (check.problems.isNotEmpty) exitCode = 1;
}

/// The files of the repository's `HEAD` with their sizes, or of the working tree when the
/// directory is not a git repository.
class _Tree {
  _Tree(this.sizes, {required this.fromGit});

  final Map<String, int> sizes;

  final bool fromGit;

  static Future<_Tree> read(Directory corpus) async {
    final result = await Process.run('git', [
      '-C',
      corpus.path,
      'ls-tree',
      '-r',
      '-l',
      '-z',
      'HEAD',
    ], stdoutEncoding: utf8);
    if (result.exitCode == 0) {
      final sizes = <String, int>{};
      for (final record in (result.stdout as String).split('\x00')) {
        final tab = record.indexOf('\t');
        if (tab < 0) continue;
        final meta = record.substring(0, tab).split(RegExp(r'\s+'));
        if (meta.length < 4 || meta[1] != 'blob') continue;
        sizes[record.substring(tab + 1)] = int.tryParse(meta[3]) ?? 0;
      }
      return _Tree(sizes, fromGit: true);
    }
    final prefix = corpus.path.length + 1;
    return _Tree({
      for (final entity in corpus.listSync(recursive: true, followLinks: false))
        if (entity is File && !entity.path.substring(prefix).replaceAll(r'\', '/').startsWith('.git/'))
          entity.path.substring(prefix).replaceAll(r'\', '/'): entity.lengthSync(),
    }, fromGit: false);
  }

  bool has(String path) => sizes.containsKey(path);

  /// The paths under [dir] (with its trailing slash), relative to it.
  Iterable<String> under(String dir) sync* {
    for (final path in sizes.keys) {
      if (path.startsWith(dir)) yield path.substring(dir.length);
    }
  }

  /// The names of the directories directly under [dir].
  Set<String> directoriesUnder(String dir) => {
    for (final path in under(dir))
      if (path.contains('/')) path.substring(0, path.indexOf('/')),
  };
}

final _sha40 = RegExp(r'^[0-9a-f]{40}$');
final _sha64 = RegExp(r'^[0-9a-f]{64}$');
final _ownerRepo = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');
final _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

class _Check {
  _Check(this.corpus, this.tree);

  final Directory corpus;

  final _Tree tree;

  final List<String> problems = [];

  final List<String> notes = [];

  void problem(String path, String message) => problems.add('$path: $message');

  void note(String message) => notes.add(message);

  File file(String path) => File('${corpus.path}/$path');

  bool onDisk(String path) => file(path).existsSync();

  Object? readJson(String path) {
    if (!tree.has(path)) {
      problem(path, 'missing from the tree');
      return null;
    }
    if (!onDisk(path)) {
      problem(path, 'not checked out');
      return null;
    }
    try {
      return jsonDecode(file(path).readAsStringSync());
    } on FormatException catch (e) {
      problem(path, 'not JSON: ${e.message}');
      return null;
    }
  }

  List<Map<String, dynamic>>? jsonList(String path, Object? json) {
    if (json is! List) {
      if (json != null) problem(path, 'expected a list');
      return null;
    }
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < json.length; i++) {
      if (json[i] is Map<String, dynamic>) {
        out.add(json[i] as Map<String, dynamic>);
      } else {
        problem(path, 'entry $i is not an object');
      }
    }
    return out;
  }

  /// [value] as a string matching [pattern], else records a problem and returns null.
  String? string(String path, Map<String, dynamic> entry, String key, {RegExp? pattern, bool required = true}) {
    final value = entry[key];
    if (value == null) {
      if (required) problem(path, 'missing "$key"${_at(entry)}');
      return null;
    }
    if (value is! String || value.isEmpty) {
      problem(path, '"$key" is not a non-empty string${_at(entry)}');
      return null;
    }
    if (pattern != null && !pattern.hasMatch(value)) {
      problem(path, '"$key" is "$value", not ${pattern.pattern}${_at(entry)}');
      return null;
    }
    return value;
  }

  int? integer(String path, Map<String, dynamic> entry, String key) {
    final value = entry[key];
    if (value is int && value >= 0) return value;
    problem(path, '"$key" is not a non-negative integer${_at(entry)}');
    return null;
  }

  String _at(Map<String, dynamic> entry) {
    final id = entry['name'] ?? entry['file'] ?? entry['path'] ?? entry['repo'];
    return id == null ? '' : ' in entry "$id"';
  }

  void url(String path, Map<String, dynamic> entry, String key, {bool required = true}) {
    final value = string(path, entry, key, required: required);
    if (value == null) return;
    final uri = Uri.tryParse(value);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
      problem(path, '"$key" is not an http(s) URL: $value${_at(entry)}');
    }
  }

  // ----- a repository of vendored sources -----

  Future<void> sourcesRepository() async {
    final keep = _corpusJson();
    final sources = _sourcesJson();
    _candidatesJson();
    await _rosetta();
    if (sources == null) return;
    final names = {for (final source in sources) source['name'] as String};
    final dirs = tree.directoriesUnder('sources/');
    for (final name in dirs.difference(names)) {
      problem('sources/$name', 'not listed in sources.json');
    }
    for (final name in names.difference(dirs)) {
      problem('sources.json', 'source "$name" has no directory under sources/');
    }
    var materialized = 0;
    for (final source in sources) {
      final name = source['name'] as String;
      if (!dirs.contains(name)) continue;
      final dir = 'sources/$name';
      for (final required in ['manifest.json', 'LICENSE.md', CorpusIndex.fileName]) {
        if (!tree.has('$dir/$required')) problem('$dir/$required', 'missing from the tree');
      }
      if (!onDisk('$dir/manifest.json')) continue;
      materialized++;
      await _materializedSource(dir, source, keep);
    }
    note('${sources.length} sources listed, $materialized checked out and checked in full');
  }

  List<String>? _corpusJson() {
    final json = readJson('corpus.json');
    if (json == null) return null;
    if (json is! Map<String, dynamic> || json['keep'] is! List) {
      problem('corpus.json', 'expected an object with a "keep" list');
      return null;
    }
    final keep = <String>[];
    for (final extension in json['keep'] as List) {
      if (extension is String &&
          extension.startsWith('.') &&
          extension.length > 1 &&
          extension == extension.toLowerCase()) {
        keep.add(extension);
      } else {
        problem('corpus.json', '"keep" entry $extension is not a lower-case extension with its dot');
      }
    }
    if (json['budget'] case final budget? when budget is! int) problem('corpus.json', '"budget" is not an integer');
    return keep;
  }

  List<Map<String, dynamic>>? _sourcesJson() {
    final list = jsonList('sources.json', readJson('sources.json'));
    if (list == null) return null;
    final seen = <String>{};
    String? previous;
    for (final entry in list) {
      final name = string('sources.json', entry, 'name');
      final repo = string('sources.json', entry, 'repo', pattern: _ownerRepo);
      string('sources.json', entry, 'commit', pattern: _sha40);
      string('sources.json', entry, 'license');
      integer('sources.json', entry, 'files');
      integer('sources.json', entry, 'bytes');
      if (name == null) continue;
      if (repo != null && name != repo.replaceAll('/', '__')) {
        problem('sources.json', 'source "$name" is not named after its repo "$repo"');
      }
      if (!seen.add(name)) problem('sources.json', 'source "$name" is listed twice');
      if (previous != null && previous.compareTo(name) > 0) problem('sources.json', 'source "$name" is out of order');
      previous = name;
    }
    return [
      for (final entry in list)
        if (entry['name'] is String) entry,
    ];
  }

  void _candidatesJson() {
    if (!tree.has('candidates.json')) return;
    final list = jsonList('candidates.json', readJson('candidates.json'));
    if (list == null) return;
    for (final entry in list) {
      string('candidates.json', entry, 'repo', pattern: _ownerRepo);
      string('candidates.json', entry, 'commit', pattern: _sha40);
      string('candidates.json', entry, 'reason');
    }
  }

  Future<void> _rosetta() async {
    const path = 'rosetta/manifest.json';
    if (!tree.directoriesUnder('').contains('rosetta')) return;
    final list = jsonList(path, readJson(path));
    if (list == null) return;
    final listed = <String>{};
    for (final entry in list) {
      final name = string(path, entry, 'file');
      string(path, entry, 'repo', pattern: _ownerRepo);
      url(path, entry, 'url');
      string(path, entry, 'commit', pattern: _sha40);
      string(path, entry, 'path');
      final sha = string(path, entry, 'sha256', pattern: _sha64);
      string(path, entry, 'license');
      if (name == null) continue;
      if (!listed.add(name)) problem(path, '"$name" is listed twice');
      final file = 'rosetta/$name';
      if (!tree.has(file)) {
        problem(file, 'listed in rosetta/manifest.json but missing from the tree');
      } else if (sha != null && onDisk(file)) {
        final actual = sha256.convert(this.file(file).readAsBytesSync()).toString();
        if (actual != sha) problem(file, 'sha256 is $actual, rosetta/manifest.json says $sha');
      }
    }
    for (final name in tree.under('rosetta/')) {
      if (name != 'manifest.json' && !listed.contains(name)) {
        problem('rosetta/$name', 'not listed in rosetta/manifest.json');
      }
    }
  }

  Future<void> _materializedSource(String dir, Map<String, dynamic> source, List<String>? keep) async {
    final path = '$dir/manifest.json';
    final json = readJson(path);
    if (json is! Map<String, dynamic>) {
      if (json != null) problem(path, 'expected an object');
      return;
    }
    for (final key in ['repo', 'commit', 'license']) {
      if (json[key] != source[key]) problem(path, '"$key" is ${json[key]}, sources.json says ${source[key]}');
    }
    if (json['url'] != 'https://github.com/${source['repo']}') problem(path, '"url" is not the repo on GitHub');
    string(path, json, 'licenseFile');
    string(path, json, 'fetched', pattern: _isoDate);
    if (json['skipped'] is! List) problem(path, '"skipped" is not a list');
    if (json['external'] is! List) problem(path, '"external" is not a list');
    if (!json.containsKey('files')) problem(path, 'missing "files"');
    final files = jsonList(path, json['files']);
    if (files == null) return;
    final expected = <String, int>{};
    var bytes = 0;
    for (final entry in files) {
      final relative = string(path, entry, 'path');
      final size = integer(path, entry, 'bytes');
      final sha = string(path, entry, 'sha256', pattern: _sha64);
      final via = string(path, entry, 'via');
      if (relative == null || size == null) continue;
      if (expected.containsKey(relative)) problem(path, '"$relative" is listed twice');
      expected[relative] = size;
      bytes += size;
      if (via != null && via != 'extension' && via != 'tree' && !via.startsWith('ref:')) {
        problem(path, '"via" of "$relative" is "$via", not extension, tree or ref:<path>');
      }
      if (via == 'extension' && keep != null && !keep.any(relative.toLowerCase().endsWith)) {
        problem(path, '"$relative" was kept for its extension, which corpus.json does not keep');
      }
      final file = this.file('$dir/$relative');
      if (!file.existsSync()) {
        problem('$dir/$relative', 'listed in manifest.json but not on disk');
      } else if (sha != null) {
        final content = file.readAsBytesSync();
        if (content.length != size) problem('$dir/$relative', 'is ${content.length} bytes, manifest.json says $size');
        final actual = sha256.convert(content).toString();
        if (actual != sha) problem('$dir/$relative', 'sha256 is $actual, manifest.json says $sha');
      }
    }
    if (files.length != source['files']) {
      problem('sources.json', '"${source['name']}" has ${files.length} files, sources.json says ${source['files']}');
    }
    if (bytes != source['bytes']) {
      problem('sources.json', '"${source['name']}" has $bytes bytes, sources.json says ${source['bytes']}');
    }
    const extras = {'manifest.json', 'LICENSE.md', 'vi-package-manifest.json', CorpusIndex.fileName};
    for (final relative in tree.under('$dir/')) {
      if (extras.contains(relative)) continue;
      final size = expected[relative];
      if (size == null) {
        problem('$dir/$relative', 'in the tree but not in manifest.json');
      } else if (tree.sizes['$dir/$relative'] != size) {
        problem('$dir/$relative', 'is ${tree.sizes['$dir/$relative']} bytes in the tree, manifest.json says $size');
      }
    }
    for (final relative in expected.keys) {
      if (!tree.has('$dir/$relative')) problem('$dir/$relative', 'listed in manifest.json but missing from the tree');
    }
    await _index(dir);
  }

  Future<void> _index(String dir) async {
    final path = '$dir/${CorpusIndex.fileName}';
    final fresh = (await buildCorpusIndex(Directory('${corpus.path}/$dir'))).encode();
    if (!onDisk(path)) {
      problem(path, 'missing; run `dart run tool/index_corpus.dart <corpus-dir>`');
    } else if (file(path).readAsStringSync() != fresh) {
      problem(path, 'stale; run `dart run tool/index_corpus.dart <corpus-dir>`');
    }
  }

  // ----- a snippet collection -----

  Future<void> snippetCollection() async {
    const path = 'manifest.json';
    final json = readJson(path);
    if (json is! Map<String, dynamic>) {
      if (json != null) problem(path, 'expected an object');
      return;
    }
    string(path, json, 'description');
    final sources = json['sources'];
    final sourceKeys = <String>{};
    if (sources is! Map<String, dynamic>) {
      problem(path, '"sources" is not an object');
    } else {
      for (final MapEntry(:key, :value) in sources.entries) {
        sourceKeys.add(key);
        if (value is! Map<String, dynamic>) {
          problem(path, 'source "$key" is not an object');
          continue;
        }
        string(path, value, 'name');
        url(path, value, 'pageUrl');
        string(path, value, 'basis');
      }
    }
    if (!json.containsKey('snippets')) problem(path, 'missing "snippets"');
    final snippets = jsonList(path, json['snippets']);
    final listed = <String>{};
    var carried = 0;
    if (snippets != null) {
      String? previous;
      for (final entry in snippets) {
        final name = string(path, entry, 'file');
        url(path, entry, 'pageUrl');
        url(path, entry, 'imageUrl');
        for (final optional in ['author', 'uploader', 'license']) {
          string(path, entry, optional, required: false);
        }
        url(path, entry, 'authorLink', required: false);
        if (name == null) continue;
        if (!listed.add(name)) problem(path, '"$name" is listed twice');
        if (previous != null && previous.compareTo(name) > 0) problem(path, '"$name" is out of order');
        previous = name;
        if (!name.toLowerCase().endsWith('.png')) problem(path, '"$name" is not a PNG');
        final slash = name.indexOf('/');
        if (slash < 0 || !sourceKeys.contains(name.substring(0, slash))) {
          problem(path, '"$name" is not under a directory named in "sources"');
        }
        if (!tree.has(name)) {
          problem(name, 'listed in manifest.json but missing from the tree');
        } else if (onDisk(name)) {
          carried++;
          if (extractSnippetVi(file(name).readAsBytesSync()) == null) problem(name, 'carries no VI in an niVI chunk');
        }
      }
    }
    for (final name in tree.sizes.keys) {
      if (name.toLowerCase().endsWith('.png') && !listed.contains(name)) problem(name, 'not listed in manifest.json');
    }
    _heldJson();
    _licensesMd(sourceKeys);
    if (!tree.has('INTERESTING.txt')) problem('INTERESTING.txt', 'missing from the tree');
    if (!tree.has(CorpusIndex.fileName)) problem(CorpusIndex.fileName, 'missing from the tree');
    if (carried == listed.length) {
      await _index('.');
    } else {
      note('${CorpusIndex.fileName}: not checked, only $carried of ${listed.length} snippets are checked out');
    }
    note('${listed.length} snippets listed, $carried checked out and checked in full');
  }

  void _heldJson() {
    if (!tree.has('held.json')) return;
    final list = jsonList('held.json', readJson('held.json'));
    if (list == null) return;
    for (final entry in list) {
      string('held.json', entry, 'source');
      if (entry.containsKey('count')) {
        integer('held.json', entry, 'count');
        string('held.json', entry, 'reason');
      } else {
        string('held.json', entry, 'reason', required: false);
        url('held.json', entry, 'pageUrl');
        url('held.json', entry, 'imageUrl');
      }
    }
  }

  void _licensesMd(Set<String> sourceKeys) {
    const path = 'LICENSES.md';
    if (!tree.has(path)) {
      problem(path, 'missing from the tree');
      return;
    }
    if (!onDisk(path)) return;
    final text = file(path).readAsStringSync();
    for (final key in sourceKeys) {
      if (!text.contains('`$key`')) problem(path, 'does not name the source `$key`');
    }
  }
}
