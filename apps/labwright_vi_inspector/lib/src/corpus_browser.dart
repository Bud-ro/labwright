import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'representative_vis.dart';

/// The fetched corpus: every `index.json` under the VI corpus directory, searchable as one,
/// with each record's path made relative to that directory.
class CorpusLibrary {
  CorpusLibrary(this.directory, this.search, {required this.indexFiles});

  /// The `corpus/vi` directory the index files were read from.
  final Directory directory;

  final CorpusSearch search;

  final int indexFiles;

  /// The file a record names.
  File fileOf(CorpusIndexEntry entry) =>
      File('${directory.path}/${entry.path}');

  /// How many records each file type has.
  Map<CorpusFileType, int> get typeCounts {
    final counts = <CorpusFileType, int>{};
    for (final entry in search.entries) {
      counts.update(entry.type, (n) => n + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  /// The command that fetches the corpus repositories.
  static const fetchCommand = 'dart run tool/fetch_corpus.dart';

  /// The `corpus/vi` directory: `$LABWRIGHT_CORPUS/vi` when that variable is set, else the one
  /// under the repository that holds [from] (the working directory by default); null when
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

  /// Reads every index file under [directory]; on another isolate unless [inIsolate] is false.
  static Future<CorpusLibrary> load(
    Directory directory, {
    bool inIsolate = true,
  }) async {
    final path = directory.path;
    final loaded = inIsolate
        ? await Isolate.run(() => _read(path))
        : _read(path);
    return CorpusLibrary(
      directory,
      CorpusSearch(loaded.$2),
      indexFiles: loaded.$1,
    );
  }

  static (int, List<CorpusIndexEntry>) _read(String root) {
    final entries = <CorpusIndexEntry>[];
    var files = 0;
    final prefix = root.length + 1;
    final indexFiles =
        Directory(root)
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((file) {
              final relative = file.path
                  .substring(prefix)
                  .replaceAll(r'\', '/');
              return relative.endsWith('/${CorpusIndex.fileName}') &&
                  !relative.contains('/.git/');
            })
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in indexFiles) {
      final dir = file.parent.path.substring(prefix).replaceAll(r'\', '/');
      files++;
      for (final entry in CorpusIndex.decode(file.readAsStringSync()).entries) {
        entries.add(entry.withPath('$dir/${entry.path}'));
      }
    }
    return (files, entries);
  }
}

/// Searches the fetched corpus and the featured examples, and opens what is picked.
class CorpusBrowser extends StatefulWidget {
  const CorpusBrowser({
    super.key,
    required this.library,
    required this.onOpen,
    required this.onOpenFeatured,
    this.featured = kRepresentativeVis,
    this.fetching,
  });

  /// The loaded corpus; null while loading or when no corpus is fetched.
  final Future<CorpusLibrary?> library;

  final void Function(CorpusLibrary library, CorpusIndexEntry entry) onOpen;

  final void Function(RepresentativeVi vi) onOpenFeatured;

  final List<RepresentativeVi> featured;

  /// The featured example being fetched, if any.
  final String? fetching;

  @override
  State<CorpusBrowser> createState() => _CorpusBrowserState();
}

/// Which records a search shows.
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

/// How many hits a section lists before it says how many more there are.
const int kCorpusSectionLimit = 200;

class _CorpusBrowserState extends State<CorpusBrowser> {
  final _controller = TextEditingController();

  CorpusScope _scope = CorpusScope.all;

  final Set<CorpusFileType> _types = {};

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<CorpusLibrary?>(
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
              onChanged: (_) => setState(() {}),
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
                        onPressed: () => setState(_controller.clear),
                      ),
              ),
            ),
          ),
          if (library != null) _filters(library),
          const Divider(height: 1),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : _results(context, library, snapshot.error),
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
            onSelectionChanged: (selected) =>
                setState(() => _scope = selected.single),
          ),
          const SizedBox(width: 8),
          for (final type in types)
            FilterChip(
              key: Key('corpus-type-${type.extension}'),
              label: Text('.${type.extension} ${counts[type]}'),
              tooltip: type.label,
              selected: _types.contains(type),
              onSelected: (on) => setState(() {
                if (on) {
                  _types.add(type);
                } else {
                  _types.remove(type);
                }
              }),
            ),
        ],
      ),
    );
  }

  Widget _results(BuildContext context, CorpusLibrary? library, Object? error) {
    final query = _controller.text.trim();
    final rows = <Widget>[];
    if (query.isEmpty) {
      rows.add(_header('Featured', widget.featured.length));
      for (final vi in widget.featured) {
        rows.add(_featuredTile(vi));
      }
    }
    if (library == null) {
      rows.add(
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            error != null
                ? 'The corpus index could not be read: $error'
                : 'No fetched corpus was found next to this checkout. Run '
                      '`${CorpusLibrary.fetchCommand}` in the labwright repository to '
                      'fetch the corpus repositories and their index.json files; '
                      'LABWRIGHT_CORPUS can name the corpus directory.',
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      );
    } else {
      final hits = library.search.search(
        query,
        snippets: _scope.snippetsOnly,
        types: _types.isEmpty ? null : _types,
      );
      final snippets = [
        for (final hit in hits)
          if (hit.entry.isSnippet) hit,
      ];
      final files = [
        for (final hit in hits)
          if (!hit.entry.isSnippet) hit,
      ];
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            query.isEmpty
                ? '${library.search.length} files indexed from ${library.indexFiles} '
                      'index files under ${library.directory.path}'
                : '${hits.length} of ${library.search.length} files match',
            key: const Key('corpus-status'),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
      );
      if (query.isNotEmpty || _scope != CorpusScope.all || _types.isNotEmpty) {
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
    return ListView(key: const Key('corpus-results'), children: rows);
  }

  Widget _header(String title, int count) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      '$title ($count)',
      style: const TextStyle(fontWeight: FontWeight.bold),
    ),
  );

  Iterable<Widget> _hitTiles(
    CorpusLibrary library,
    List<CorpusSearchHit> hits,
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

  Widget _hitTile(CorpusLibrary library, CorpusSearchHit hit, String query) {
    final entry = hit.entry;
    final details = <String>[
      if (entry.version != null) 'LabVIEW ${entry.version}',
      if (entry.name != null &&
          entry.name!.toLowerCase() != entry.fileName.toLowerCase())
        entry.name!,
      if (entry.error != null) 'did not parse: ${entry.error}',
    ];
    final matched = query.isEmpty
        ? const <CorpusMatch>[]
        : hit.matches
              .where(
                (m) =>
                    m.field != CorpusMatchField.path &&
                    m.field != CorpusMatchField.name &&
                    m.field != CorpusMatchField.type,
              )
              .take(4)
              .toList();
    return ListTile(
      dense: true,
      leading: Icon(
        entry.isSnippet ? Icons.image_outlined : Icons.memory_outlined,
        size: 18,
      ),
      title: Text(entry.fileName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.path,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
            overflow: TextOverflow.ellipsis,
          ),
          if (details.isNotEmpty || matched.isNotEmpty)
            Text(
              [...details, for (final match in matched) match.text].join(' · '),
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
      trailing: Text(
        entry.type.label,
        style: const TextStyle(fontSize: 11, color: Colors.grey),
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
  required Future<CorpusLibrary?> library,
  required void Function(CorpusLibrary library, CorpusIndexEntry entry) onOpen,
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
        fetching: fetching,
        onOpen: (library, entry) {
          Navigator.of(context).pop();
          onOpen(library, entry);
        },
        onOpenFeatured: (vi) {
          Navigator.of(context).pop();
          onOpenFeatured(vi);
        },
      ),
    ),
  ),
);
