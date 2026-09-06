import 'dart:convert';
import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';

Future<void> main(List<String> args) async {
  final path =
      args.firstOrNull ??
      '${Platform.environment['NI_HELP_CACHE'] ?? '${Directory.systemTemp.path}/ni_help_oracle'}/oracle.json';
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('error: no dataset at $path (run labwright_rsrc_parse\'s tool/fetch_help_oracle.dart first)');
    exitCode = 1;
    return;
  }

  final topics = [
    for (final raw in jsonDecode(file.readAsStringSync())['topics'] as List) _Topic(raw as Map<String, dynamic>),
  ];
  final byName = <String, _Topic>{};
  for (final topic in topics) {
    final existing = byName[_key(topic.title)];
    if (existing == null || topic.partNumber.compareTo(existing.partNumber) > 0) byName[_key(topic.title)] = topic;
  }

  stdout.writeln('dataset: ${topics.length} topics, ${byName.length} distinct names, from $path');
  stdout.writeln(
    '  ${topics.where((t) => t.iconUrl != null).length} carry a connector-pane image, '
    '${topics.where((t) => t.terminals.isNotEmpty).length} state their terminals',
  );

  final matched = <PrimOp, _Topic>{}, unmatched = <PrimOp>[];
  for (final op in PrimOp.values) {
    final topic = byName[_key(op.opName)];
    if (topic == null) {
      unmatched.add(op);
    } else {
      matched[op] = topic;
    }
  }

  stdout.writeln('\n== catalogue entries the reference corroborates: ${matched.length}/${PrimOp.values.length} ==');
  for (final basis in PrimNameBasis.values) {
    final of = PrimOp.values.where((op) => op.basis == basis).toList();
    final hit = of.where(matched.containsKey).length;
    stdout.writeln('  ${basis.name.padRight(12)} $hit/${of.length}');
  }

  stdout.writeln('\n== named, corroborated, and still without a lowering rule ==');
  stdout.writeln('   (the reference states the terminals a rule needs)');
  final needing = matched.keys.where((op) => !kLvMappedPrimOps.contains(op)).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  for (final op in needing) {
    final topic = matched[op]!;
    stdout.writeln('  ${op.id}  ${op.opName}  [${op.basis.name}]  palette: ${topic.palette ?? '-'}');
    for (final terminal in topic.terminals) {
      stdout.writeln('        ${terminal.isInput ? 'in ' : 'out'}  ${terminal.name}  (${terminal.wireGlyph})');
    }
    if (topic.terminals.isEmpty) stdout.writeln('        (the topic states no terminal table)');
  }
  stdout.writeln('\n== node classes the corpus names, checked against the reference ==');
  for (final entry in kLvNamedNodeClasses.entries) {
    final topic = byName[_key(entry.value.name)];
    final rule = kLvMappedPrimClasses.contains(entry.key) ? 'has a rule' : 'NO RULE';
    if (topic == null) {
      stdout.writeln('  0x${entry.key.toRadixString(16)}  ${entry.value.name}  [$rule]  — the reference has no topic');
      continue;
    }
    stdout.writeln(
      '  0x${entry.key.toRadixString(16)}  ${entry.value.name}  [$rule]  '
      '${topic.inputs} in, ${topic.outputs} out   ${topic.terminals.map((t) => t.name).join(' | ')}',
    );
  }

  stdout.writeln('\n== the arity the reference states for the ops that DO have a rule ==');
  stdout.writeln('   (a rule reading a different number of terminals is reading a different node)');
  final ruled = matched.keys.where(kLvMappedPrimOps.contains).toList()..sort((a, b) => a.id.compareTo(b.id));
  for (final op in ruled) {
    final topic = matched[op]!;
    stdout.writeln(
      '  ${op.id.toString().padRight(6)}${op.opName.padRight(30)} ${topic.inputs} in, ${topic.outputs} out'
      '   ${topic.terminals.map((t) => t.name).join(' | ')}',
    );
  }

  stdout.writeln('\n== catalogue names the reference does not carry: ${unmatched.length} ==');
  for (final op in unmatched) {
    stdout.writeln('  ${op.id}  ${op.opName}  [${op.basis.name}]');
  }

  final claimed = matched.values.map((t) => t.slug).toSet();
  final unclaimed = byName.values.where((t) => !claimed.contains(t.slug)).toList()
    ..sort((a, b) => a.title.compareTo(b.title));
  stdout.writeln('\n== reference topics no catalogue entry claims: ${unclaimed.length} ==');
  final functions = unclaimed.where((t) => t.kind == 'Function').toList();
  stdout.writeln('   (${functions.length} of them are Functions — the block-diagram primitives)');
  for (final topic in functions) {
    stdout.writeln('  ${topic.title}  in ${topic.palette ?? '-'}  ${topic.inputs}->${topic.outputs}');
  }
}

String _key(String name) => name
    .replaceAll(RegExp(r'\s*\((?:Not in|Windows|Mac OS X|Linux)[^)]*\)\s*$', caseSensitive: false), '')
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

class _Terminal {
  _Terminal(Map<String, dynamic> json)
    : name = json['name'] as String,
      isInput = json['direction'] == 'input',
      wireGlyph = json['wireGlyph'] as String;

  final String name;
  final bool isInput;
  final String wireGlyph;
}

class _Topic {
  _Topic(Map<String, dynamic> json)
    : slug = json['slug'] as String,
      partNumber = json['partNumber'] as String,
      title = json['title'] as String,
      kind = json['kind'] as String,
      palette = json['palette'] as String?,
      iconUrl = json['iconUrl'] as String?,
      inputs = json['inputs'] as int,
      outputs = json['outputs'] as int,
      terminals = [for (final t in json['terminals'] as List) _Terminal(t as Map<String, dynamic>)];

  final String slug;
  final String partNumber;
  final String title;
  final String kind;
  final String? palette;
  final String? iconUrl;
  final int inputs;
  final int outputs;
  final List<_Terminal> terminals;
}
