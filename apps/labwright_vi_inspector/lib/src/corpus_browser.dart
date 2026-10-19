import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';

import 'corpus_database.dart';
import 'representative_vis.dart';

/// The corpus repositories whose released indexes the browser fetches when no labwright
/// checkout pins them.
const List<String> kCorpusRepositories = [
  'https://github.com/Bud-ro/vi-corpus',
  'https://github.com/Bud-ro/vi-snippets',
];

/// A corpus repository on GitHub and, when a checkout pins it, the commit to fetch the index of.
class CorpusPin {
  const CorpusPin(this.url, {this.ref});

  /// `https://github.com/<owner>/<name>`, without `.git`.
  final String url;

  final String? ref;

  String get name => url.substring(url.lastIndexOf('/') + 1);

  /// `<owner>/<name>`.
  String get repo => url.substring('https://github.com/'.length);

  /// The release asset to fetch: the `index-<commit>` release when pinned, else the latest.
  Uri get asset => Uri.parse(
    ref == null
        ? '$url/releases/latest/download/index.sqlite.xz'
        : '$url/releases/download/index-${ref!.substring(0, 12)}/index.sqlite.xz',
  );
}

/// One file a search over the fetched indexes found, and the repository it is in.
class CorpusLibraryHit {
  const CorpusLibraryHit(this.repository, this.hit);

  /// The corpus repository's name.
  final String repository;

  final CorpusHit hit;
}

/// How many hits each index contributes to a search, and a section lists.
const int kCorpusSectionLimit = 200;

/// The fetched corpus indexes: every `<repository>.sqlite` in the cache directory, searched as
/// one, with the repositories to fetch them from and the checkout, if any, that holds the files.
class CorpusLibrary {
  CorpusLibrary(this.cache, this.pins, {this.checkout, this.inIsolate = true}) {
    reload();
  }

  /// Where fetched indexes are kept: `$LABWRIGHT_CORPUS_INDEX`, else `labwright/corpus-index`
  /// under the user's cache directory.
  final Directory cache;

  final List<CorpusPin> pins;

  /// The `corpus/vi` directory of a labwright checkout, whose repositories hold the files.
  final Directory? checkout;

  /// Whether searches run on a worker isolate, which keeps the UI responsive; tests turn it off.
  final bool inIsolate;

  List<CorpusDatabase> databases = const [];

  /// How many files the indexes hold together.
  int files = 0;

  /// How many files each type has, over every index.
  Map<CorpusFileType, int> typeCounts = const {};

  /// The hits of every index for [query], snippets only or files only when [snippetsOnly] is
  /// set, restricted to [types] when given; at most [limit] per index, by repository then path.
  Future<List<CorpusLibraryHit>> search(
    String query, {
    Set<CorpusFileType>? types,
    bool? snippetsOnly,
    int limit = kCorpusSectionLimit,
  }) async {
    var selected = types ?? CorpusFileType.values.toSet();
    if (snippetsOnly != null) {
      selected = {
        for (final type in selected)
          if ((type == CorpusFileType.snippet) == snippetsOnly) type,
      };
    }
    if (selected.isEmpty) return const [];
    final paths = [for (final db in databases) db.file.path];
    final hits = inIsolate
        ? await Isolate.run(() => _searchFiles(paths, query, selected, limit))
        : _searchFiles(paths, query, selected, limit);
    return hits..sort((a, b) {
      final byRepository = a.repository.compareTo(b.repository);
      return byRepository != 0
          ? byRepository
          : a.hit.path.compareTo(b.hit.path);
    });
  }

  /// Opens each index at [paths], searches it, and closes it.
  static List<CorpusLibraryHit> _searchFiles(
    List<String> paths,
    String query,
    Set<CorpusFileType> types,
    int limit,
  ) {
    final hits = <CorpusLibraryHit>[];
    for (final path in paths) {
      final db = CorpusDatabase.open(File(path));
      try {
        for (final hit in db.search(query, types: types, limit: limit)) {
          hits.add(CorpusLibraryHit(db.repository, hit));
        }
      } finally {
        db.close();
      }
    }
    return hits;
  }

  /// The hit's file in the checkout, when there is one and it holds the file.
  File? localFileOf(CorpusLibraryHit hit) {
    if (checkout == null) return null;
    final file = File('${checkout!.path}/${hit.repository}/${hit.hit.path}');
    return file.existsSync() ? file : null;
  }

  /// The hit's file on GitHub, at the commit its index was built from.
  Uri remoteUrlOf(CorpusLibraryHit hit) {
    final db = databases.firstWhere((db) => db.repository == hit.repository);
    final pin = pins.firstWhere(
      (pin) => pin.name == hit.repository,
      orElse: () => CorpusPin('https://github.com/Bud-ro/${hit.repository}'),
    );
    final path = hit.hit.path.split('/').map(Uri.encodeComponent).join('/');
    return Uri.parse(
      'https://raw.githubusercontent.com/${pin.repo}/${db.commit}/$path',
    );
  }

  /// Downloads each pinned repository's released index into [cache] and reopens the indexes,
  /// reporting each step through [onProgress]; a repository without the release is reported
  /// and skipped.
  Future<void> fetch(
    Future<Uint8List> Function(Uri) fetchBytes, {
    void Function(String message)? onProgress,
  }) async {
    cache.createSync(recursive: true);
    for (final pin in pins) {
      onProgress?.call('Fetching ${pin.name}…');
      final Uint8List compressed;
      try {
        compressed = await fetchBytes(pin.asset);
      } catch (e) {
        onProgress?.call('${pin.name}: $e');
        continue;
      }
      final bytes = await Isolate.run(
        () => XZDecoder().decodeBytes(compressed),
      );
      final out = File('${cache.path}/${pin.name}.sqlite');
      File('${out.path}.part')
        ..writeAsBytesSync(bytes)
        ..renameSync(out.path);
    }
    reload();
    onProgress?.call('$files files indexed');
  }

  /// Closes and reopens every index in [cache], and recounts its files.
  void reload() {
    for (final db in databases) {
      db.close();
    }
    final indexes = cache.existsSync()
        ? (cache
              .listSync(followLinks: false)
              .whereType<File>()
              .where((f) => f.path.endsWith('.sqlite'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
        : const <File>[];
    databases = [for (final file in indexes) CorpusDatabase.open(file)];
    files = databases.fold(0, (sum, db) => sum + db.files);
    final counts = <CorpusFileType, int>{};
    for (final db in databases) {
      for (final MapEntry(key: type, value: n) in db.typeCounts.entries) {
        counts.update(type, (m) => m + n, ifAbsent: () => n);
      }
    }
    typeCounts = counts;
  }

  void close() {
    for (final db in databases) {
      db.close();
    }
    databases = const [];
  }

  /// The library for this machine: indexes cached under [cacheDirectory], the pins of the
  /// labwright checkout that holds [from] (the working directory by default) or
  /// [kCorpusRepositories] without one.
  static CorpusLibrary open({
    Directory? from,
    Map<String, String>? environment,
    bool inIsolate = true,
  }) {
    final env = environment ?? Platform.environment;
    final checkout = locate(from: from, environment: env);
    return CorpusLibrary(
      cacheDirectory(env),
      checkout == null
          ? [for (final url in kCorpusRepositories) CorpusPin(url)]
          : pinsOf(checkout.parent),
      checkout: checkout,
      inIsolate: inIsolate,
    );
  }

  /// `$LABWRIGHT_CORPUS_INDEX`, else `labwright/corpus-index` under `$XDG_CACHE_HOME`,
  /// `%LOCALAPPDATA%` or `~/.cache`.
  static Directory cacheDirectory(Map<String, String> env) {
    final configured = env['LABWRIGHT_CORPUS_INDEX'];
    if (configured != null && configured.isNotEmpty)
      return Directory(configured);
    final base =
        env['XDG_CACHE_HOME'] ??
        env['LOCALAPPDATA'] ??
        '${env['HOME'] ?? env['USERPROFILE'] ?? '.'}/.cache';
    return Directory('$base/labwright/corpus-index');
  }

  /// The `corpus/vi` directory of the labwright checkout that holds [from]: `$LABWRIGHT_CORPUS/vi`
  /// when that variable is set, else found by walking up to `corpus/repos.json`; null when
  /// neither exists.
  static Directory? locate({
    Directory? from,
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    final configured = env['LABWRIGHT_CORPUS'];
    if (configured != null && configured.isNotEmpty) {
      final dir = Directory('$configured/vi');
      return dir.existsSync() ? dir : null;
    }
    var dir = (from ?? Directory.current).absolute;
    while (true) {
      if (File('${dir.path}/corpus/repos.json').existsSync()) {
        final vi = Directory('${dir.path}/corpus/vi');
        return vi.existsSync() ? vi : null;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) return null;
      dir = parent;
    }
  }

  /// The `vi` repositories `corpus/repos.json` under [corpus] pins.
  static List<CorpusPin> pinsOf(Directory corpus) {
    final json =
        jsonDecode(File('${corpus.path}/repos.json').readAsStringSync())
            as Map<String, dynamic>;
    return [
      for (final repo
          in ((json['vi'] as List?) ?? const []).cast<Map<String, dynamic>>())
        CorpusPin(
          (repo['repo'] as String).replaceAll(RegExp(r'\.git$'), ''),
          ref: repo['ref'] as String?,
        ),
    ];
  }
}

/// Searches the fetched corpus indexes and the featured examples, fetches the indexes, and
/// opens what is picked.
class CorpusBrowser extends StatefulWidget {
  const CorpusBrowser({
    super.key,
    required this.library,
    required this.fetchBytes,
    required this.onOpen,
    required this.onOpenFeatured,
    this.featured = kRepresentativeVis,
    this.fetching,
  });

  final Future<CorpusLibrary> library;

  final Future<Uint8List> Function(Uri) fetchBytes;

  final void Function(CorpusLibrary library, CorpusLibraryHit hit) onOpen;

  final void Function(RepresentativeVi vi) onOpenFeatured;

  final List<RepresentativeVi> featured;

  /// The featured example being fetched, if any.
  final String? fetching;

  @override
  State<CorpusBrowser> createState() => _CorpusBrowserState();
}

/// Which files a search shows.
enum CorpusScope {
  all('All'),
  snippets('Snippets'),
  files('VIs & files');

  const CorpusScope(this.label);

  final String label;

  bool? get snippetsOnly => switch (this) {
    all => null,
    snippets => true,
    files => false,
  };
}

/// How long typing pauses before a search runs.
const Duration kCorpusSearchDebounce = Duration(milliseconds: 150);

class _CorpusBrowserState extends State<CorpusBrowser> {
  final _controller = TextEditingController();

  CorpusScope _scope = CorpusScope.all;

  final Set<CorpusFileType> _types = {};

  String? _progress;

  CorpusLibrary? _library;

  Timer? _debounce;

  int _generation = 0;

  bool _searching = false;

  List<CorpusLibraryHit> _hits = const [];

  @override
  void initState() {
    super.initState();
    widget.library.then((library) {
      if (!mounted) return;
      _library = library;
      _scheduleSearch(now: true);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  bool get _filtering =>
      _controller.text.trim().isNotEmpty ||
      _scope != CorpusScope.all ||
      _types.isNotEmpty;

  /// Runs the current search on the library, after a pause in typing unless [now]; the latest
  /// request wins and stale results are dropped.
  void _scheduleSearch({bool now = false}) {
    _debounce?.cancel();
    final generation = ++_generation;
    final library = _library;
    if (library == null || library.databases.isEmpty || !_filtering) {
      setState(() {
        _hits = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    Future<void> run() async {
      final hits = await library.search(
        _controller.text.trim(),
        snippetsOnly: _scope.snippetsOnly,
        types: _types.isEmpty ? null : _types,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _hits = hits;
        _searching = false;
      });
    }

    if (now) {
      run();
    } else {
      _debounce = Timer(kCorpusSearchDebounce, run);
    }
  }

  Future<void> _fetch(CorpusLibrary library) async {
    setState(() => _progress = 'Fetching…');
    try {
      await library.fetch(
        widget.fetchBytes,
        onProgress: (message) {
          if (mounted) setState(() => _progress = message);
        },
      );
    } catch (e) {
      if (mounted) setState(() => _progress = 'Could not fetch the index: $e');
      return;
    }
    if (!mounted) return;
    setState(() => _progress = null);
    _scheduleSearch(now: true);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<CorpusLibrary>(
    future: widget.library,
    builder: (context, snapshot) {
      final library = snapshot.data;
      final loading = snapshot.connectionState != ConnectionState.done;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              key: const Key('corpus-search'),
              controller: _controller,
              autofocus: true,
              onChanged: (_) => _scheduleSearch(),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText:
                    'Search the corpus: a VI name, primitive, object class, sub-VI or library '
                    '(prefixes: name: prim: class: sub: lib: member: type: version:)',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _controller.clear();
                          _scheduleSearch(now: true);
                        },
                      ),
              ),
            ),
          ),
          if (library != null) _filters(library),
          const Divider(height: 1),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : _results(library, snapshot.error),
          ),
        ],
      );
    },
  );

  Widget _filters(CorpusLibrary library) {
    final counts = library.typeCounts;
    final types = [
      for (final type in CorpusFileType.values)
        if (counts.containsKey(type)) type,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<CorpusScope>(
            key: const Key('corpus-scope'),
            showSelectedIcon: false,
            segments: [
              for (final scope in CorpusScope.values)
                ButtonSegment(value: scope, label: Text(scope.label)),
            ],
            selected: {_scope},
            onSelectionChanged: (selected) {
              _scope = selected.single;
              _scheduleSearch(now: true);
            },
          ),
          const SizedBox(width: 8),
          for (final type in types)
            FilterChip(
              key: Key('corpus-type-${type.extension}'),
              label: Text('.${type.extension} ${counts[type]}'),
              tooltip: type.label,
              selected: _types.contains(type),
              onSelected: (on) {
                if (on) {
                  _types.add(type);
                } else {
                  _types.remove(type);
                }
                _scheduleSearch(now: true);
              },
            ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: const Key('corpus-fetch'),
            onPressed: _progress == null ? () => _fetch(library) : null,
            icon: _progress == null
                ? const Icon(Icons.cloud_download_outlined, size: 16)
                : const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
            label: Text(
              library.databases.isEmpty ? 'Fetch index' : 'Refetch index',
            ),
          ),
        ],
      ),
    );
  }

  Widget _results(CorpusLibrary? library, Object? error) {
    final query = _controller.text.trim();
    final rows = <Widget>[];
    final featured = <Widget>[
      if (query.isEmpty) ...[
        _header('Featured', widget.featured.length),
        for (final vi in widget.featured) _featuredTile(vi),
      ],
    ];
    if (library == null) {
      rows.add(_note('The corpus index could not be opened: $error'));
    } else if (library.databases.isEmpty) {
      rows.add(
        _note(
          _progress ??
              'No corpus index is cached under ${library.cache.path}. Fetch index downloads the SQLite '
                  'index each corpus repository releases (${library.pins.map((p) => p.name).join(', ')}) '
                  'so every VI, control, snippet, library, class and project file in the corpus can be '
                  'searched here.',
        ),
      );
    } else {
      final snippets = [
        for (final hit in _hits)
          if (hit.hit.isSnippet) hit,
      ];
      final files = [
        for (final hit in _hits)
          if (!hit.hit.isSnippet) hit,
      ];
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            _progress ??
                (_filtering
                    ? _searching
                          ? 'Searching…'
                          : '${_hits.length} of ${library.files} files match'
                    : '${library.files} files indexed in ${library.databases.length} '
                          'repositor${library.databases.length == 1 ? 'y' : 'ies'}: '
                          '${library.databases.map((db) => '${db.repository} @ ${db.commit.substring(0, db.commit.length.clamp(0, 12))}').join(', ')}'),
            key: const Key('corpus-status'),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
      );
      if (_filtering) {
        if (_scope != CorpusScope.files) {
          rows.add(_header('Snippets', snippets.length));
          rows.addAll(_hitTiles(library, snippets, query));
        }
        if (_scope != CorpusScope.snippets) {
          rows.add(_header('VIs & files', files.length));
          rows.addAll(_hitTiles(library, files, query));
        }
      }
    }
    return ListView(
      key: const Key('corpus-results'),
      children: [...rows, ...featured],
    );
  }

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.all(16),
    child: Text(
      text,
      key: const Key('corpus-status'),
      style: const TextStyle(color: Colors.grey),
    ),
  );

  Widget _header(String title, int count) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      '$title ($count)',
      style: const TextStyle(fontWeight: FontWeight.bold),
    ),
  );

  Iterable<Widget> _hitTiles(
    CorpusLibrary library,
    List<CorpusLibraryHit> hits,
    String query,
  ) sync* {
    for (final hit in hits.take(kCorpusSectionLimit)) {
      yield _hitTile(library, hit, query);
    }
    if (hits.length > kCorpusSectionLimit) {
      yield Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Text(
          '${hits.length - kCorpusSectionLimit} more; narrow the search to see them',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      );
    }
  }

  Widget _hitTile(CorpusLibrary library, CorpusLibraryHit entry, String query) {
    final hit = entry.hit;
    final details = <String>[
      if (hit.version != null) 'LabVIEW ${hit.version}',
      if (hit.name != null &&
          hit.name!.toLowerCase() != hit.fileName.toLowerCase())
        hit.name!,
      if (hit.error != null) 'did not parse: ${hit.error}',
    ];
    final matched = query.isEmpty
        ? const <String>[]
        : [
            ...hit.prims,
            ...hit.objectClasses,
            for (final name in hit.subVis) 'calls $name',
            for (final name in hit.libraries) 'in $name',
            for (final name in hit.members) 'member $name',
          ].take(4).toList();
    final local = library.localFileOf(entry) != null;
    return ListTile(
      dense: true,
      enabled: widget.fetching == null,
      leading: Icon(
        hit.isSnippet ? Icons.image_outlined : Icons.memory_outlined,
        size: 18,
      ),
      title: Text(hit.fileName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${entry.repository}/${hit.path}',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
            overflow: TextOverflow.ellipsis,
          ),
          if (details.isNotEmpty || matched.isNotEmpty)
            Text(
              [...details, ...matched].join(' · '),
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!local)
            const Icon(
              Icons.cloud_download_outlined,
              size: 14,
              color: Colors.grey,
            ),
          if (!local) const SizedBox(width: 6),
          Text(
            hit.type.label,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
      onTap: () => widget.onOpen(library, entry),
    );
  }

  Widget _featuredTile(RepresentativeVi vi) => ListTile(
    dense: true,
    enabled: widget.fetching == null,
    leading: widget.fetching == vi.name
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.cloud_download_outlined, size: 18),
    title: Text(vi.name),
    subtitle: Text(
      vi.feature + (vi.missingNote == null ? '' : ' · ${vi.missingNote}'),
      style: const TextStyle(fontSize: 11, color: Colors.grey),
    ),
    trailing: Text(
      vi.repo,
      style: const TextStyle(fontSize: 11, color: Colors.grey),
    ),
    onTap: () => widget.onOpenFeatured(vi),
  );
}

/// Opens the corpus browser over [context] as a dialog.
Future<void> showCorpusBrowser(
  BuildContext context, {
  required Future<CorpusLibrary> library,
  required Future<Uint8List> Function(Uri) fetchBytes,
  required void Function(CorpusLibrary library, CorpusLibraryHit hit) onOpen,
  required void Function(RepresentativeVi vi) onOpenFeatured,
  String? fetching,
}) => showDialog<void>(
  context: context,
  builder: (context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1000, maxHeight: 760),
      child: CorpusBrowser(
        key: const Key('corpus-browser'),
        library: library,
        fetchBytes: fetchBytes,
        fetching: fetching,
        onOpen: (library, hit) {
          Navigator.of(context).pop();
          onOpen(library, hit);
        },
        onOpenFeatured: (vi) {
          Navigator.of(context).pop();
          onOpenFeatured(vi);
        },
      ),
    ),
  ),
);
