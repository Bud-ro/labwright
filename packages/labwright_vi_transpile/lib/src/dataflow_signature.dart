import 'dataflow_ir.dart';

/// What a dataflow computes, spelled without object ids: every unit by what it is, every
/// port by its unit and ordinal, every edge by the ports it joins and its Dart type, every
/// structure by its terminals and frames. Two diagrams with the same signature run the same.
String lvDataflowSignature(LvDataflow flow) {
  final names = <int, String>{};
  final out = StringBuffer();
  void ports(String unit, LvUnit u) {
    for (final (i, port) in u.inputPorts.indexed) {
      names[port] = '$unit.in$i';
    }
    for (final (i, port) in u.outputPorts.indexed) {
      names[port] = '$unit.out$i';
    }
  }

  void name(LvRegion region, String prefix) {
    for (final (i, unit) in region.units.indexed) {
      final id = '$prefix$i';
      ports(id, unit);
      if (unit is LvStructUnit) {
        final frameIndex = {for (final (f, frame) in unit.frames.indexed) frame.frameOid: f};
        for (final (t, terminal) in unit.terminals.indexed) {
          for (final MapEntry(key: frame, value: port) in terminal.innerPorts.entries) {
            names[port] = '$id.t$t.f${frameIndex[frame] ?? '?'}';
          }
        }
        for (final (f, frame) in unit.frames.indexed) {
          name(frame, '$id.f$f.');
        }
      }
    }
  }

  void region(LvRegion r, String prefix, String pad) {
    for (final (i, unit) in r.units.indexed) {
      final id = '$prefix$i';
      switch (unit) {
        case LvPrimUnit():
          out.writeln('$pad$id prim ${unit.op?.name ?? unit.primResId} ${unit.label ?? ''}'.trimRight());
        case LvSubViUnit():
          out.writeln('$pad$id call ${unit.calleeName ?? ''} pane ${unit.panePorts.length}'.trimRight());
        case LvConstUnit():
          final record = unit.record;
          final value = record.constText ?? record.constNumeric ?? record.constBool ?? record.constArray;
          out.writeln('$pad$id const ${record.dataType?.name ?? ''} ${unit.label ?? ''} = $value'.trimRight());
        case LvInterfaceUnit():
          out.writeln('$pad$id ${unit.isIndicator ? 'indicator' : 'control'} ${unit.name ?? ''}'.trimRight());
        case LvStructUnit():
          out.writeln('$pad$id ${unit.kind.name} displayed ${unit.displayedFrame} default ${unit.defaultFrame}');
          for (final (t, terminal) in unit.terminals.indexed) {
            final outer = terminal.outerPort == null ? '-' : names[terminal.outerPort] ?? '?';
            final frames = {for (final (f, frame) in unit.frames.indexed) frame.frameOid: f};
            final inner = [
              for (final MapEntry(key: f, value: p) in terminal.innerPorts.entries)
                'f${frames[f] ?? '?'}:${names[p] ?? '?'}',
            ];
            out.writeln(
              '$pad  t$t ${terminal.role.name}${terminal.autoIndexing ? ' indexing' : ''}${terminal.outerIsSink ? ' in' : ' out'} '
                      '${terminal.polarity?.name ?? ''} outer $outer inner ${inner.join(',')}'
                  .replaceAll('  ', ' '),
            );
          }
          for (final (f, frame) in unit.frames.indexed) {
            out.writeln('$pad  frame $f');
            region(frame, '$id.f$f.', '$pad    ');
          }
      }
    }
    final edges = [
      for (final edge in r.edges)
        '${names[edge.source] ?? '?'} -> ${[for (final sink in edge.sinks) names[sink] ?? '?'].join(',')} : ${edge.type.dartType ?? edge.type.carrier?.name ?? '?'}',
    ]..sort();
    for (final edge in edges) {
      out.writeln('$pad$edge');
    }
  }

  name(flow.root, 'u');
  region(flow.root, 'u', '');
  return out.toString();
}
