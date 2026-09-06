import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'type_map.dart';

enum LvErrorMode {
  /// Error clusters leave the signature; a failing `error out` throws.
  exceptions,

  /// Error clusters stay values in the signature; nothing throws.
  threaded,
}

class LvTerminal {
  const LvTerminal(this.name, this.type, {this.isErrorCluster = false});

  final String name;

  final LvTypeMapping type;

  final bool isErrorCluster;
}

class LvSignature {
  const LvSignature({required this.carried, required this.throwsLvError, required this.elided});

  final List<LvTerminal> carried;

  final bool throwsLvError;

  final List<LvTerminal> elided;
}

LvSignature lvSignature(List<LvTerminal> terminals, LvErrorMode mode) {
  if (mode == LvErrorMode.threaded) {
    return LvSignature(carried: terminals, throwsLvError: false, elided: const []);
  }
  final elided = [
    for (final terminal in terminals)
      if (terminal.isErrorCluster) terminal,
  ];
  return LvSignature(
    carried: [
      for (final terminal in terminals)
        if (!terminal.isErrorCluster) terminal,
    ],
    throwsLvError: elided.isNotEmpty,
    elided: elided,
  );
}

List<LvTerminal> lvTerminals(List<ViType> pool, int? conpaneIndex) {
  if (conpaneIndex == null || conpaneIndex < 1 || conpaneIndex > pool.length) return const [];
  final conpane = pool[conpaneIndex - 1];
  if (conpane.kind != ViDataType.cluster) return const [];
  return [
    for (final member in clusterFields(conpane, pool))
      LvTerminal(member.name ?? '', mapLvType(member, pool), isErrorCluster: isLvErrorCluster(member, pool)),
  ];
}
