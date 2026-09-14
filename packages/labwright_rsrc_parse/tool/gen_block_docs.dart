import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

const _fenceOpen = '/// ```text';
const _fenceClose = '/// ```';
const _nameWidth = 26;
const _typeWidth = 8;
const _lineWidth = 100;

void main() {
  final blocks = Directory('${File.fromUri(Platform.script).parent.parent.path}/lib/src/blocks');
  for (final file in blocks.listSync().whereType<File>()) {
    if (!file.path.endsWith('.dart')) continue;
    final layouts = _layoutsOf(file);
    if (layouts.isEmpty) continue;
    final lines = file.readAsLinesSync();
    final open = lines.indexOf(_fenceOpen);
    final close = open < 0 ? -1 : lines.indexOf(_fenceClose, open + 1);
    if (open < 0 || close < 0) throw StateError('${file.path}: no ```text fence in the library doc comment');
    lines.replaceRange(open + 1, close, [
      for (final (tags, layout) in layouts) ...[
        if (layouts.length > 1) '/// ${tags.join(' / ')}:',
        ..._render(layout),
      ],
    ]);
    file.writeAsStringSync('${lines.join('\n')}\n');
  }
}

/// The distinct layouts of the tags named by the file, each with the tags sharing it, in file-name order.
List<(List<String>, BlockLayout)> _layoutsOf(File file) {
  final name = file.uri.pathSegments.last.replaceAll('.dart', '');
  final out = <(List<String>, BlockLayout)>[];
  for (final token in name.split('_')) {
    final tag = BlockTag.of(token) ?? BlockTag.of('$token ');
    if (tag == null) break;
    final layout = tag.layout;
    if (layout == null) continue;
    final shared = out.where((e) => identical(e.$2, layout)).firstOrNull;
    if (shared == null) {
      out.add(([tag.tag], layout));
    } else {
      shared.$1.add(tag.tag);
    }
  }
  return out;
}

List<String> _render(BlockLayout layout) {
  final out = <String>[];
  out.add(_row('offset', 'size', 'field', 'type', 'meaning'));
  String? optional;
  var afterVariable = false;
  for (final f in layout) {
    if (f.optional != optional) {
      optional = f.optional;
      if (optional != null) out.add('/// optional, when $optional:');
    }
    final size = f.size == null ? 'rest' : '${f.size}';
    final meaning = f.isUndecoded ? 'retained; not decoded' : f.meaning;
    out.addAll(_wrapRow(afterVariable ? '…' : '${f.offset}', size, f.name, f.type, meaning));
    afterVariable |= f.size == null;
  }
  return out;
}

String _row(String offset, String size, String name, String type, String meaning) =>
    '${_head(offset, size, name, type)}$meaning'.trimRight();

String _head(String offset, String size, String name, String type) =>
    '/// ${offset.padRight(7)} ${size.padRight(5)} ${name.padRight(_nameWidth)} ${type.padRight(_typeWidth)} ';

List<String> _wrapRow(String offset, String size, String name, String type, String meaning) {
  final head = _head(offset, size, name, type);
  final indent = head.length;
  final words = meaning.split(' ');
  final lines = <String>[];
  var line = StringBuffer(head.padRight(indent));
  var lineHasWord = false;
  for (final word in words) {
    if (lineHasWord && line.length + 1 + word.length > _lineWidth) {
      lines.add(line.toString().trimRight());
      line = StringBuffer('///'.padRight(indent));
      lineHasWord = false;
    }
    if (lineHasWord) line.write(' ');
    line.write(word);
    lineHasWord = true;
  }
  lines.add(line.toString().trimRight());
  return lines;
}
