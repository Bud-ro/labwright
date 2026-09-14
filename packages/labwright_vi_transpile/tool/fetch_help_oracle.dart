/// Usage:
///   dart run tool/fetch_help_oracle.dart [--cache=DIR] [--limit=N] [--refresh]
///                                        [--delay-ms=N] [--icons]
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _cdxEndpoint = 'http://web.archive.org/cdx/search/cdx';

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

class _Capture {
  _Capture({required this.url, required this.timestamp, required this.partNumber, required this.slug});

  final String url;
  final String timestamp;
  final String partNumber;

  final String slug;
}

class _Index {
  _Index(this.topics, this.captures);

  final List<_Capture> topics;
  final int captures;
}

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
  final url = '$query&filter=original:.*/glang/.*';
  final text = await cache.fetchText(url, 'cdx_glang.txt', force: refresh);
  if (text == null) throw StateError('topic index unavailable from $url');

  final best = <String, _Capture>{};
  var captures = 0;
  for (final line in const LineSplitter().convert(text)) {
    final parts = line.split(' ');
    if (parts.length < 2) continue;
    final match = RegExp(r'/help/([\w-]+)/glang/([\w-]+)/?$').firstMatch(parts[0]);
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

class _Terminal {
  _Terminal({required this.name, required this.isInput, required this.wireGlyph, required this.description});

  final String name;
  final bool isInput;

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

  final String title;

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

final _terminalRowPattern = RegExp(
  r'<td class="Icon">(.*?)</td>\s*<td[^>]*>(.*?)</td>',
  caseSensitive: false,
  dotAll: true,
);

final _terminalAnchorPattern = RegExp(r'<a name="(Input|Output)\d+"></a>', caseSensitive: false);

final _terminalGlyphPattern = RegExp(r'<img src="[^"]*/([^"/]+)\.gif"', caseSensitive: false);

final _terminalNamePattern = RegExp(
  r'^\s*<strong>(.*?)</strong>\s*(?:(,|and|or)\s*)?',
  caseSensitive: false,
  dotAll: true,
);

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
    iconUrl: pane == null ? null : Uri.parse(capture.url).resolve(pane.group(1)!).toString(),
    terminals: terminals,
  );
}

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

String _text(String html) {
  var s = html.replaceAll(_tagPattern, ' ');
  _entities.forEach((k, v) => s = s.replaceAll(k, v));
  s = s.replaceAllMapped(
    RegExp(r'&#(x?)([0-9a-fA-F]+);'),
    (m) => String.fromCharCode(int.parse(m.group(2)!, radix: m.group(1)!.isEmpty ? 10 : 16)),
  );
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

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

  Future<Uint8List?> fetchBytes(String url, String relPath, {bool force = false}) async {
    final file = File('$root/$relPath');
    if (!force && file.existsSync()) return file.readAsBytesSync();
    final body = await _get(url);
    if (body == null) return null;
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(body);
    return body;
  }

  Future<Uint8List?> _get(String url) async {
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
          final body = BytesBuilder(copy: false);
          await for (final chunk in response) {
            body.add(chunk);
          }
          return body.takeBytes();
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
