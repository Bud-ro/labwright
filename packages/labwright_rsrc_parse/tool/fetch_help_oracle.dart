/// Harvests LabVIEW's built-in function reference from archived copies of the
/// legacy static help and emits it as JSON for use as an identification oracle.
///
/// The published reference states, for every built-in function, its name, the
/// palette that owns it, a prose description, and — via the connector-pane image
/// map and the parameter table — every terminal's name, direction and wire type.
/// That is independent ground truth against which the corpus-derived primitive
/// catalogues can be checked.
///
/// Nothing fetched here is written into the repository. Pages, images and the
/// emitted dataset all land under the cache root (`--cache`, or `$NI_HELP_CACHE`,
/// default `<tmp>/ni_help_oracle`), matching how the VI corpus itself is fetched
/// rather than committed.
///
/// Usage:
///   dart run tool/fetch_help_oracle.dart [--cache=DIR] [--limit=N] [--refresh]
///                                        [--delay-ms=N] [--icons]
///
/// Every response is cached on disk keyed by URL, so a second run performs no
/// network I/O. `--refresh` re-fetches the topic index; cached topic pages are
/// still reused unless their files are removed.
///
/// The archive's rate limiter returns HTTP 429 readily; requests are serialized
/// with a delay between them and retried with exponential backoff.
library;

import 'dart:convert';
import 'dart:io';

/// The archive's URL-index API. Queried once with a path prefix to enumerate
/// every captured topic, which is cheaper and more complete than walking the
/// table of contents, and avoids the per-URL availability endpoint entirely.
const _cdxEndpoint = 'http://web.archive.org/cdx/search/cdx';

/// Replay prefix that returns the originally captured bytes rather than a copy
/// rewritten for archive playback. Formatted with the capture timestamp.
String _replayUrl(String timestamp, String original) => 'http://web.archive.org/web/${timestamp}id_/$original';

Future<void> main(List<String> args) async {
  final opts = _Options.parse(args);
  final cache = _Cache(opts.cacheRoot, delay: opts.delay);
  stdout.writeln('cache root: ${opts.cacheRoot}');

  final index = await _topicIndex(cache, refresh: opts.refresh);
  stdout.writeln('index: ${index.captures} captures over ${index.topics.length} distinct topics');

  final topics = opts.limit == null ? index.topics : index.topics.take(opts.limit!).toList();
  final records = <_Topic>[];
  var failed = 0;
  for (var i = 0; i < topics.length; i++) {
    final capture = topics[i];
    final html = await cache.fetchText(
      _replayUrl(capture.timestamp, capture.url),
      '${capture.partNumber}/${capture.slug}.html',
    );
    if (html == null) {
      failed++;
      continue;
    }
    final topic = _parseTopic(capture, html);
    if (topic != null) records.add(topic);
    if ((i + 1) % 50 == 0) stdout.writeln('  ${i + 1}/${topics.length} fetched, ${records.length} parsed');
  }

  if (opts.icons) {
    var got = 0;
    for (final t in records) {
      if (t.iconUrl == null) continue;
      if (await cache.fetchBytes(t.iconUrl!, 'icons/${t.partNumber}/${t.slug}.gif') != null) got++;
    }
    stdout.writeln('icons: $got/${records.where((t) => t.iconUrl != null).length} fetched');
  }

  final out = File('${opts.cacheRoot}/oracle.json');
  out.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'source': 'archived LabVIEW help, glang topics',
      'topicCount': records.length,
      'topics': records.map((t) => t.toJson()).toList(),
    }),
  );
  stdout.writeln(
    'done: ${records.length} topics parsed, $failed unfetched, '
    '${records.where((t) => t.iconUrl != null).length} with a connector-pane image, '
    '${records.where((t) => t.terminals.isNotEmpty).length} with terminals -> ${out.path}',
  );
}

class _Options {
  _Options({
    required this.cacheRoot,
    required this.limit,
    required this.refresh,
    required this.delay,
    required this.icons,
  });

  final String cacheRoot;
  final int? limit;
  final bool refresh;
  final Duration delay;
  final bool icons;

  static _Options parse(List<String> args) {
    String? value(String name) {
      final hit = args.firstWhere((a) => a.startsWith('--$name='), orElse: () => '');
      return hit.isEmpty ? null : hit.substring(name.length + 3);
    }

    final root =
        value('cache') ?? Platform.environment['NI_HELP_CACHE'] ?? '${Directory.systemTemp.path}/ni_help_oracle';
    final limit = value('limit');
    final delayMs = value('delay-ms');
    return _Options(
      cacheRoot: root,
      limit: limit == null ? null : int.parse(limit),
      refresh: args.contains('--refresh'),
      delay: Duration(milliseconds: delayMs == null ? 400 : int.parse(delayMs)),
      icons: args.contains('--icons'),
    );
  }
}

/// One archived capture of one help topic.
class _Capture {
  _Capture({required this.url, required this.timestamp, required this.partNumber, required this.slug});

  final String url;
  final String timestamp;
  final String partNumber;

  /// The topic's path segment, lowercased. Distinct part numbers spell the same
  /// topic identically apart from case, so the lowercased slug is the join key.
  final String slug;
}

class _Index {
  _Index(this.topics, this.captures);

  final List<_Capture> topics;
  final int captures;
}

/// Enumerates every archived `glang` topic and keeps one capture per topic,
/// preferring the newest part number (the trailing revision letter of the help's
/// part number rises with the LabVIEW release, so a later letter is a later
/// edition of the same document).
Future<_Index> _topicIndex(_Cache cache, {required bool refresh}) async {
  final query = Uri.parse(_cdxEndpoint).replace(
    queryParameters: {
      'url': 'zone.ni.com/reference/en-XX/help/',
      'matchType': 'prefix',
      'fl': 'original,timestamp',
      'collapse': 'urlkey',
      'filter': 'statuscode:200',
    },
  );
  // The CDX API takes repeated `filter` parameters; Uri's map form cannot express
  // that, so the topic-path filter is appended by hand.
  final url = '$query&filter=original:.*/glang/.*';
  final text = await cache.fetchText(url, 'cdx_glang.txt', force: refresh);
  if (text == null) throw StateError('topic index unavailable from $url');

  final best = <String, _Capture>{};
  var captures = 0;
  for (final line in const LineSplitter().convert(text)) {
    final parts = line.split(' ');
    if (parts.length < 2) continue;
    final match = RegExp(r'/help/([^/]+)/glang/([^/]+)/?$').firstMatch(parts[0]);
    if (match == null) continue;
    captures++;
    final partNumber = match.group(1)!;
    final slug = match.group(2)!.toLowerCase();
    final existing = best[slug];
    if (existing == null || partNumber.compareTo(existing.partNumber) > 0) {
      best[slug] = _Capture(url: parts[0], timestamp: parts[1], partNumber: partNumber, slug: slug);
    }
  }
  final topics = best.values.toList()..sort((a, b) => a.slug.compareTo(b.slug));
  return _Index(topics, captures);
}

/// A terminal of a built-in function, as the reference states it.
class _Terminal {
  _Terminal({required this.name, required this.isInput, required this.wireGlyph, required this.description});

  final String name;
  final bool isInput;

  /// Basename of the small image the reference draws beside the terminal. The
  /// reference uses one image per (direction, wire type) pair, so this string
  /// distinguishes wire types without asserting what each one means.
  final String wireGlyph;
  final String description;

  Map<String, Object?> toJson() => {
    'name': name,
    'direction': isInput ? 'input' : 'output',
    'wireGlyph': wireGlyph,
    'description': description,
  };
}

class _Topic {
  _Topic({
    required this.slug,
    required this.partNumber,
    required this.title,
    required this.kind,
    required this.palette,
    required this.paletteSlug,
    required this.requires,
    required this.description,
    required this.iconUrl,
    required this.terminals,
  });

  final String slug;
  final String partNumber;

  /// The topic's name with the trailing kind word removed: `Wait (ms)`.
  final String title;

  /// The trailing word of the heading — `Function`, `VI`, `Structure`, ... —
  /// which separates true block-diagram primitives from library VIs.
  final String kind;
  final String? palette;
  final String? paletteSlug;
  final String? requires;
  final String description;
  final String? iconUrl;
  final List<_Terminal> terminals;

  int get inputs => terminals.where((t) => t.isInput).length;
  int get outputs => terminals.length - inputs;

  Map<String, Object?> toJson() => {
    'slug': slug,
    'partNumber': partNumber,
    'title': title,
    'kind': kind,
    'palette': palette,
    'paletteSlug': paletteSlug,
    'requires': requires,
    'description': description,
    'iconUrl': iconUrl,
    'inputs': inputs,
    'outputs': outputs,
    'terminals': terminals.map((t) => t.toJson()).toList(),
  };
}

final _headingPattern = RegExp(r'<H1[^>]*>(.*?)</H1>', caseSensitive: false, dotAll: true);
final _palettePattern = RegExp(
  r'Owning Palette:</strong>\s*<a href="\.\./([^/"]+)/?"[^>]*>(.*?)</a>',
  caseSensitive: false,
  dotAll: true,
);
final _requiresPattern = RegExp(r'Requires:</strong>\s*(.*?)</p>', caseSensitive: false, dotAll: true);
final _descriptionPattern = RegExp(
  r'<!--\s*VI/Function Description\s*-->\s*<p class="Body">(.*?)</p>',
  caseSensitive: false,
  dotAll: true,
);
final _connectorPanePattern = RegExp(
  r'<img src="([^"]+)"\s+usemap="#connector_pane"',
  caseSensitive: false,
);

/// One row of the parameter table: the glyph cell, then the description cell.
final _terminalRowPattern = RegExp(
  r'<td class="Icon">(.*?)</td>\s*<td[^>]*>(.*?)</td>',
  caseSensitive: false,
  dotAll: true,
);

/// The terminal anchors in a glyph cell. A row can carry SEVERAL — the
/// reference merges terminals that share a wire type and a sentence (`x` and
/// `y` of a binary operation), so the anchors, not the rows, count the arity.
final _terminalAnchorPattern = RegExp(r'<a name="(Input|Output)\d+"></a>', caseSensitive: false);

/// The wire-type glyph a row draws beside its terminals.
final _terminalGlyphPattern = RegExp(r'<img src="[^"]*/([^"/]+)\.gif"', caseSensitive: false);

/// A parameter name at the very front of a description cell, with the
/// conjunction that may join it to the next one. The reference bolds parameter
/// names in the running prose too, so only the leading run names terminals.
final _terminalNamePattern = RegExp(
  r'^\s*<strong>(.*?)</strong>\s*(?:(,|and|or)\s*)?',
  caseSensitive: false,
  dotAll: true,
);

/// Splits `Wait (ms) Function` into title `Wait (ms)` and kind `Function`.
/// Headings that do not end in a known kind word keep the whole heading as the
/// title and report an empty kind rather than guessing.
const _kindWords = ['Function', 'Functions', 'VI', 'VIs', 'Structure', 'Node', 'Constant', 'Method', 'Property'];

_Topic? _parseTopic(_Capture capture, String html) {
  final heading = _headingPattern.firstMatch(html);
  if (heading == null) return null;
  final full = _text(heading.group(1)!);
  if (full.isEmpty) return null;

  var title = full, kind = '';
  for (final word in _kindWords) {
    if (full.length > word.length + 1 && full.endsWith(' $word')) {
      title = full.substring(0, full.length - word.length - 1);
      kind = word;
      break;
    }
  }

  final palette = _palettePattern.firstMatch(html);
  final requires = _requiresPattern.firstMatch(html);
  final description = _descriptionPattern.firstMatch(html);
  final pane = _connectorPanePattern.firstMatch(html);

  final terminals = <_Terminal>[];
  for (final row in _terminalRowPattern.allMatches(html)) {
    final anchors = _terminalAnchorPattern.allMatches(row.group(1)!).toList();
    if (anchors.isEmpty) continue;
    final glyph = _terminalGlyphPattern.firstMatch(row.group(1)!)?.group(1)?.toLowerCase() ?? '';
    final cell = row.group(2)!;
    final names = _leadingNames(cell, anchors.length);
    for (var at = 0; at < anchors.length; at++) {
      // A row that names fewer terminals than it anchors still states the
      // arity; the unnamed ones are recorded with an empty name rather than
      // borrowing a sibling's.
      terminals.add(
        _Terminal(
          name: at < names.length ? names[at] : '',
          isInput: anchors[at].group(1)!.toLowerCase() == 'input',
          wireGlyph: glyph,
          description: _text(cell),
        ),
      );
    }
  }

  return _Topic(
    slug: capture.slug,
    partNumber: capture.partNumber,
    title: title,
    kind: kind,
    palette: palette == null ? null : _text(palette.group(2)!),
    paletteSlug: palette?.group(1),
    requires: requires == null ? null : _text(requires.group(1)!),
    description: description == null ? '' : _text(description.group(1)!),
    iconUrl: pane == null ? null : _absolute(pane.group(1)!),
    terminals: terminals,
  );
}

/// The parameter names heading [cell], at most [limit] of them.
///
/// Names run only while each bolded run is joined to the next by a conjunction:
/// `<b>x</b> and <b>y</b> must be…` names two terminals, while `<b>max(x, y)</b>
/// is the larger value…` names one and stops.
List<String> _leadingNames(String cell, int limit) {
  final names = <String>[];
  var rest = cell;
  while (names.length < limit) {
    final match = _terminalNamePattern.firstMatch(rest);
    if (match == null) break;
    final name = _text(match.group(1)!);
    if (name.isEmpty) break;
    names.add(name);
    if (match.group(2) == null) break;
    rest = rest.substring(match.end);
  }
  return names;
}

/// Resolves a page-relative image path against the host that still serves it.
String _absolute(String src) => src.startsWith('http') ? src : 'http://zone.ni.com$src';

final _tagPattern = RegExp(r'<[^>]*>');
const _entities = {
  '&nbsp;': ' ',
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&#39;': "'",
  '&mdash;': '—',
  '&ndash;': '–',
  '&raquo;': '»',
  '&plusmn;': '±',
  '&times;': '×',
  '&minus;': '−',
  '&deg;': '°',
  '&pi;': 'π',
  '&infin;': '∞',
  '&le;': '≤',
  '&ge;': '≥',
  '&ne;': '≠',
};

/// Strips markup and collapses whitespace, leaving the reference's own wording.
String _text(String html) {
  var s = html.replaceAll(_tagPattern, ' ');
  _entities.forEach((k, v) => s = s.replaceAll(k, v));
  s = s.replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m.group(1)!)));
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// A URL-keyed on-disk cache in front of a deliberately slow HTTP client.
class _Cache {
  _Cache(this.root, {required this.delay});

  final String root;
  final Duration delay;
  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  Future<String?> fetchText(String url, String relPath, {bool force = false}) async {
    final bytes = await fetchBytes(url, relPath, force: force);
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  Future<List<int>?> fetchBytes(String url, String relPath, {bool force = false}) async {
    final file = File('$root/$relPath');
    if (!force && file.existsSync()) return file.readAsBytesSync();
    final body = await _get(url);
    if (body == null) return null;
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(body);
    return body;
  }

  /// Serialized, spaced-out GET with backoff on the archive's rate limiter.
  Future<List<int>?> _get(String url) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final since = DateTime.now().difference(_last);
      if (since < delay) await Future<void>.delayed(delay - since);
      _last = DateTime.now();
      try {
        final request = await _client.getUrl(Uri.parse(url));
        request.followRedirects = true;
        request.maxRedirects = 10;
        final response = await request.close();
        if (response.statusCode == 200) {
          final chunks = <int>[];
          await for (final chunk in response) {
            chunks.addAll(chunk);
          }
          return chunks;
        }
        await response.drain<void>();
        if (response.statusCode != 429 && response.statusCode < 500) {
          stderr.writeln('  ${response.statusCode} $url');
          return null;
        }
      } on Object catch (e) {
        stderr.writeln('  ${e.runtimeType} $url');
      }
      await Future<void>.delayed(delay * (1 << (attempt + 2)));
    }
    stderr.writeln('  gave up $url');
    return null;
  }
}
