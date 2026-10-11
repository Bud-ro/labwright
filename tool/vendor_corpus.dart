import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// Run: `dart run tool/vendor_corpus.dart <corpus-dir> owner/repo@sha[:SPDX] ...`
Future<void> main(List<String> args) async {
  final corpus = Directory(args.first).absolute;
  final config = jsonDecode(File('${corpus.path}/corpus.json').readAsStringSync()) as Map<String, dynamic>;
  final keep = (config['keep'] as List).cast<String>();
  final budget = config['budget'] as int?;
  final sources = [for (final spec in args.skip(1)) _Source.parse(spec)];
  final work = Directory('${corpus.path}/.vendor')..createSync(recursive: true);
  final downloads = <_Source, Future<bool>>{};
  var next = 0;
  var failed = 0;
  for (final source in sources) {
    while (next < sources.length && next < sources.indexOf(source) + _prefetch) {
      final ahead = sources[next++];
      if (!_isVendored(corpus, ahead)) downloads[ahead] = _ghTarball(ahead, _tarOf(work, ahead));
    }
    final fetched = downloads.remove(source);
    if (budget != null && !_isVendored(corpus, source) && _vendoredBytes(corpus) >= budget) {
      stdout.writeln(
        'budget of $budget bytes reached; ${sources.length - sources.indexOf(source)} sources not vendored',
      );
      await Future.wait(downloads.values);
      exitCode = 1;
      return;
    }
    if (!await _vendor(corpus, source, keep, fetched)) failed++;
  }
  if (failed > 0) exitCode = 1;
}

int _vendoredBytes(Directory corpus) {
  final file = File('${corpus.path}/sources.json');
  if (!file.existsSync()) return 0;
  return (jsonDecode(file.readAsStringSync()) as List).fold(0, (sum, entry) => sum + (entry['bytes'] as int));
}

const _prefetch = 4;

File _tarOf(Directory work, _Source source) => File('${work.path}/${source.name}.tar.gz');

bool _isVendored(Directory corpus, _Source source) =>
    File('${corpus.path}/sources/${source.name}/manifest.json').existsSync();

const _fileCap = 95 * 1024 * 1024;

const _rsrc = ['.vi', '.ctl', '.vim', '.vit', '.ctt', '.llb', '.lvlibp'];
const _lvXml = ['.lvproj', '.lvlib', '.lvclass', '.xctl', '.lvsc', '.xnode', '.lvtest'];
const _teststand = ['.seq', '.ini', '.cfg', '.tsw', '.tpj'];
const _notVendored = [
  '.exe',
  '.msi',
  '.zip',
  '.7z',
  '.rar',
  '.tar',
  '.gz',
  '.tgz',
  '.iso',
  '.dmg',
  '.jar',
  '.cab',
  '.vip',
  '.vipc',
  '.lvbitx',
  '.rtexe',
  '.lvappbuild',
  '.pdb',
  '.ipch',
  '.pch',
  '.sdf',
  '.opensdf',
  '.suo',
  '.ncb',
  '.tlog',
  '.ilk',
  '.exp',
  '.idb',
  '.obj',
  '.o',
  '.a',
  '.lib',
  '.so',
  '.dylib',
  '.pyc',
  '.db',
  '.pdf',
  '.doc',
  '.docx',
  '.ppt',
  '.pptx',
  '.mp4',
  '.mp3',
  '.avi',
  '.mov',
  '.mkv',
  '.wmv',
  '.flv',
  '.webm',
  '.psd',
  '.ai',
  '.ive',
  '.stl',
  '.DS_Store',
];
const _treeFileCap = 1024 * 1024;
const _notVendoredDirs = ['node_modules', '__pycache__', '.vs', '.idea', '.git'];

final _licenseStem = RegExp(r'^(licen[cs]e|copying|unlicense)([-_.].+)?$', caseSensitive: false);

class _Source {
  _Source(this.repo, this.commit, this.spdx);

  factory _Source.parse(String spec) {
    final at = spec.indexOf('@');
    if (at < 0) throw ArgumentError('expected owner/repo@sha, got $spec');
    final colon = spec.indexOf(':', at);
    return _Source(
      spec.substring(0, at),
      colon < 0 ? spec.substring(at + 1) : spec.substring(at + 1, colon),
      colon < 0 ? null : spec.substring(colon + 1),
    );
  }

  final String repo;
  final String commit;
  final String? spdx;

  String get name => repo.replaceAll('/', '__');
}

Future<bool> _vendor(Directory corpus, _Source source, List<String> keep, Future<bool>? fetched) async {
  final dest = Directory('${corpus.path}/sources/${source.name}');
  if (_isVendored(corpus, source)) {
    stdout.writeln('${source.repo}: already vendored');
    return true;
  }
  if (dest.existsSync()) dest.deleteSync(recursive: true);
  stdout.writeln('${source.repo} @ ${source.commit.substring(0, 12)}');
  final work = Directory('${corpus.path}/.vendor');
  final tar = _tarOf(work, source);
  final tree = Directory('${work.path}/${source.name}');
  try {
    if (!await (fetched ?? _ghTarball(source, tar))) return false;
    if (tree.existsSync()) tree.deleteSync(recursive: true);
    tree.createSync();
    final extracted = await Process.run('tar', ['-xzf', tar.path, '-C', tree.path, '--strip-components=1']);
    if (extracted.exitCode != 0) {
      stderr.writeln('  tar failed: ${extracted.stderr}');
      return false;
    }
    final license = _findLicense(tree);
    if (license == null) {
      stderr.writeln('  no license file; not vendored');
      return false;
    }
    final spdx = source.spdx ?? await _ghSpdx(source.repo);
    final selection = _select(tree, keep);
    final files = <Map<String, Object>>[];
    var bytes = 0;
    for (final MapEntry(key: path, value: via) in selection.kept.entries) {
      final file = File('${tree.path}/$path');
      final content = file.readAsBytesSync();
      File('${dest.path}/$path')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(content);
      files.add({'path': path, 'bytes': content.length, 'sha256': sha256.convert(content).toString(), 'via': via});
      bytes += content.length;
    }
    File('${dest.path}/LICENSE.md').writeAsBytesSync(license.readAsBytesSync());
    final manifest = {
      'repo': source.repo,
      'url': 'https://github.com/${source.repo}',
      'commit': source.commit,
      'license': spdx,
      'licenseFile': _relative(tree, license),
      'fetched': DateTime.now().toUtc().toIso8601String().substring(0, 10),
      'files': files,
      'skipped': selection.skipped,
      'external': selection.external.toList()..sort(),
    };
    File('${dest.path}/manifest.json').writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(manifest)}\n');
    _appendSourcesJson(corpus, source, spdx, files.length, bytes);
    stdout.writeln('  ${files.length} files, ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB, $spdx');
    await _commit(corpus, source, files.length, bytes);
    return true;
  } finally {
    if (tar.existsSync()) tar.deleteSync();
    if (tree.existsSync()) tree.deleteSync(recursive: true);
  }
}

Future<bool> _ghTarball(_Source source, File tar) async {
  final process = await Process.start('gh', ['api', 'repos/${source.repo}/tarball/${source.commit}']);
  final errors = process.stderr.transform(utf8.decoder).join();
  await process.stdout.pipe(tar.openWrite());
  final code = await process.exitCode;
  if (code != 0) stderr.writeln('  gh api failed ($code): ${(await errors).trim()}');
  return code == 0;
}

Future<String> _ghSpdx(String repo) async {
  final result = await Process.run('gh', ['api', 'repos/$repo', '--jq', '.license.spdx_id']);
  final id = (result.stdout as String).trim();
  return id.isEmpty || id == 'null' ? 'NOASSERTION' : id;
}

File? _findLicense(Directory tree) {
  final candidates =
      tree
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((f) => _licenseStem.hasMatch(f.uri.pathSegments.last))
          .toList()
        ..sort((a, b) {
          final depth = a.path.split('/').length.compareTo(b.path.split('/').length);
          return depth != 0 ? depth : a.path.compareTo(b.path);
        });
  return candidates.firstOrNull;
}

String _relative(Directory tree, FileSystemEntity entity) => entity.path.substring(tree.path.length + 1);

typedef _Selection = ({Map<String, String> kept, List<Map<String, Object>> skipped, Set<String> external});

_Selection _select(Directory tree, List<String> keep) {
  final all = <String, int>{
    for (final file in tree.listSync(recursive: true, followLinks: false).whereType<File>())
      _relative(tree, file): file.lengthSync(),
  };
  final byLowerPath = {for (final path in all.keys) path.toLowerCase(): path};
  final byLowerName = <String, List<String>>{};
  for (final path in all.keys) {
    byLowerName.putIfAbsent(path.split('/').last.toLowerCase(), () => []).add(path);
  }
  final kept = <String, String>{};
  final skipped = <Map<String, Object>>[];
  final external = <String>{};

  bool admit(String path, String via) {
    if (kept.containsKey(path)) return false;
    if (all[path]! > _fileCap) {
      skipped.add({'path': path, 'bytes': all[path]!, 'reason': 'over ${_fileCap ~/ 1024 ~/ 1024} MB'});
      return false;
    }
    kept[path] = via;
    return true;
  }

  for (final path in all.keys.toList()..sort()) {
    if (keep.any(path.toLowerCase().endsWith)) admit(path, 'extension');
  }

  String? resolve(String from, _Ref ref) {
    final dir = from.contains('/') ? from.substring(0, from.lastIndexOf('/')) : '';
    switch (ref.kind) {
      case _RefKind.relative:
        final base = dir.split('/').where((s) => s.isNotEmpty).toList();
        for (var i = 0; i < ref.up; i++) {
          if (base.isEmpty) return null;
          base.removeLast();
        }
        final joined = [...base, ...ref.segments].join('/').toLowerCase();
        return byLowerPath[joined];
      case _RefKind.name:
        final name = ref.segments.last.toLowerCase();
        final sibling = byLowerPath[dir.isEmpty ? name : '${dir.toLowerCase()}/$name'];
        if (sibling != null) return sibling;
        final matches = byLowerName[name];
        return matches != null && matches.length == 1 ? matches.single : null;
      case _RefKind.absolute:
        for (var k = ref.segments.length; k >= 1; k--) {
          final tail = ref.segments.sublist(ref.segments.length - k).join('/').toLowerCase();
          final matches = [
            for (final lower in byLowerPath.keys)
              if (lower == tail || lower.endsWith('/$tail')) byLowerPath[lower]!,
          ];
          if (matches.length == 1) return matches.single;
          if (matches.isEmpty && k < ref.segments.length) return null;
        }
        return null;
      case _RefKind.external:
        return null;
    }
  }

  var frontier = kept.keys.toList();
  while (frontier.isNotEmpty) {
    final next = <String>[];
    for (final path in frontier) {
      for (final ref in _refsOf(File('${tree.path}/$path'), path)) {
        final target = resolve(path, ref);
        if (target == null) {
          if (ref.kind == _RefKind.external || ref.kind == _RefKind.absolute) external.add(ref.text);
          continue;
        }
        if (admit(target, 'ref:$path')) next.add(target);
      }
    }
    frontier = next;
  }
  for (final path in all.keys.toList()..sort()) {
    final lower = path.toLowerCase();
    final junk =
        _notVendored.any((ext) => lower.endsWith(ext.toLowerCase())) ||
        RegExp(r'\.z\d\d$').hasMatch(lower) ||
        path.split('/').any(_notVendoredDirs.contains);
    if (!junk && all[path]! <= _treeFileCap) admit(path, 'tree');
  }
  return (kept: kept, skipped: skipped, external: external);
}

enum _RefKind { relative, name, absolute, external }

class _Ref {
  const _Ref(this.kind, this.segments, {this.up = 0, required this.text});

  final _RefKind kind;
  final List<String> segments;
  final int up;
  final String text;
}

Iterable<_Ref> _refsOf(File file, String path) {
  final lower = path.toLowerCase();
  if (_rsrc.any(lower.endsWith)) return _rsrcRefs(file.readAsBytesSync());
  if (_lvXml.any(lower.endsWith)) return _xmlRefs(utf8.decode(file.readAsBytesSync(), allowMalformed: true));
  if (_teststand.any(lower.endsWith)) return _teststandRefs(file.readAsBytesSync());
  return const [];
}

Iterable<_Ref> _rsrcRefs(Uint8List bytes) sync* {
  List<Uint8List> regions;
  try {
    regions = [for (final section in decodeSections(bytes)) section.bytes];
  } catch (_) {
    regions = [bytes];
  }
  final seen = <String>{};
  for (final region in regions) {
    for (var i = 0; i + 12 <= region.length; i++) {
      if (region[i] != 0x50 || region[i + 1] != 0x54 || region[i + 2] != 0x48 || region[i + 3] != 0x30) continue;
      final extent = ViPath.extentAt(region, i);
      if (extent == null) continue;
      final viPath = ViPath(Uint8List.sublistView(region, i, i + extent));
      if (!seen.add(viPath.text)) continue;
      i += extent - 1;
      switch (viPath.form) {
        case ViPathForm.relative:
          yield _Ref(_RefKind.relative, viPath.segments, up: viPath.upLevels, text: viPath.text);
        case ViPathForm.name:
          yield _Ref(_RefKind.name, viPath.segments, text: viPath.text);
        case ViPathForm.absolute:
        case ViPathForm.unc:
          yield _Ref(_RefKind.absolute, viPath.segments, text: viPath.text);
        case ViPathForm.symbolic:
          yield _Ref(_RefKind.external, viPath.segments, text: viPath.text);
        case ViPathForm.empty:
        case ViPathForm.notAPath:
        case ViPathForm.url:
          break;
      }
    }
    yield* _tokenRefs([latin1.decode(region)], seen);
  }
}

final _xmlUrl = RegExp(r'\bURL="([^"]+)"');

Iterable<_Ref> _xmlRefs(String xml) sync* {
  for (final match in _xmlUrl.allMatches(xml)) {
    final text = match.group(1)!.replaceAll('&amp;', '&').replaceAll('&quot;', '"').replaceAll('&apos;', "'");
    final parts = text.split(RegExp(r'[\\/]'));
    if (parts.length == 1) {
      yield _Ref(_RefKind.name, parts, text: text);
    } else if (text.startsWith('/<') || text.startsWith('<')) {
      yield _Ref(_RefKind.external, parts, text: text);
    } else if (parts.first.length == 2 && parts.first.endsWith(':') ||
        text.startsWith('/C/') ||
        text.startsWith('/c/')) {
      yield _Ref(_RefKind.absolute, parts.where((s) => s.isNotEmpty).toList(), text: text);
    } else {
      var up = 0;
      final segments = <String>[];
      for (final part in parts) {
        if (part == '..') {
          up++;
        } else if (part != '.' && part.isNotEmpty) {
          segments.add(part);
        }
      }
      yield _Ref(_RefKind.relative, segments, up: up, text: text);
    }
  }
}

final _fileToken = RegExp(
  r"[A-Za-z0-9_\-. ()\[\]&+,'%#@!~]{1,120}\.(?:seq|vi|ctl|vim|vit|ctt|llb|lvlib|lvclass|lvproj|dll|ini|cfg|csv|txt|xml|json|py|exe|bat|cmd|ps1|tsw|tpj|html?|png|bmp|jpe?g|gif|ico|wav|dat|bin|tdms|xlsx?|docx?|pdf|cs|c|h|cpp|vb|js|m|mat|sql|db|lib|so|tsf|txt)\b",
  caseSensitive: false,
);

Iterable<_Ref> _teststandRefs(Uint8List bytes) => _tokenRefs([latin1.decode(bytes), _utf16le(bytes)], {});

Iterable<_Ref> _tokenRefs(List<String> texts, Set<String> seen) sync* {
  for (final text in texts) {
    for (final match in _fileToken.allMatches(text)) {
      final token = match.group(0)!.trim();
      if (!seen.add(token.toLowerCase())) continue;
      final start = match.start;
      final prefix = text.substring(start > 400 ? start - 400 : 0, start);
      final pathStart = prefix.lastIndexOf(RegExp(r'[\x00-\x1f"<>|*?=]'));
      final full = '${prefix.substring(pathStart + 1)}$token'.trim();
      final parts = full.split(RegExp(r'[\\/]'));
      if (parts.length == 1) {
        yield _Ref(_RefKind.name, [token], text: token);
      } else if (parts.first.length == 2 && parts.first.endsWith(':') || full.startsWith('<')) {
        yield _Ref(_RefKind.external, parts, text: full);
      } else {
        var up = 0;
        final segments = <String>[];
        for (final part in parts) {
          if (part == '..') {
            up++;
          } else if (part != '.' && part.isNotEmpty) {
            segments.add(part);
          }
        }
        yield _Ref(_RefKind.relative, segments, up: up, text: full);
        yield _Ref(_RefKind.name, [token], text: token);
      }
    }
  }
}

String _utf16le(Uint8List bytes) {
  final even = bytes.length & ~1;
  final units = Uint16List.view(bytes.buffer, bytes.offsetInBytes, even ~/ 2);
  final out = StringBuffer();
  for (final unit in units) {
    out.writeCharCode(unit < 0xd800 || unit > 0xdfff ? unit : 0x20);
  }
  return out.toString();
}

void _appendSourcesJson(Directory corpus, _Source source, String spdx, int files, int bytes) {
  final file = File('${corpus.path}/sources.json');
  final list = file.existsSync()
      ? (jsonDecode(file.readAsStringSync()) as List).cast<Map<String, dynamic>>()
      : <Map<String, dynamic>>[];
  list
    ..removeWhere((entry) => entry['name'] == source.name)
    ..add({
      'name': source.name,
      'repo': source.repo,
      'commit': source.commit,
      'license': spdx,
      'files': files,
      'bytes': bytes,
    })
    ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  file.writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(list)}\n');
}

Future<void> _commit(Directory corpus, _Source source, int files, int bytes) async {
  final add = await Process.run('git', ['-C', corpus.path, 'add', 'sources/${source.name}', 'sources.json']);
  if (add.exitCode != 0) throw StateError('git add failed: ${add.stderr}');
  final message =
      'Vendor ${source.repo} @ ${source.commit.substring(0, 12)}\n\n'
      '$files files, ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB.\n';
  final commit = await Process.run('git', ['-C', corpus.path, 'commit', '-q', '-m', message]);
  if (commit.exitCode != 0) throw StateError('git commit failed: ${commit.stderr}');
}
