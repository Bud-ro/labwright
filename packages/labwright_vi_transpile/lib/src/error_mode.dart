/// How a translated VI carries LabVIEW's **error cluster** — the one modelling
/// choice that changes generated function signatures, so both modes are part
/// of the type model rather than a late switch.
///
/// A LabVIEW VI threads errors as data: an `error in` terminal and an
/// `error out` terminal on the connector pane, with each node short-circuiting
/// when the incoming cluster's `status` is true. Dart's idiom is an exception.
/// The two shapes cannot both be the default, and they produce different
/// signatures for the same VI, so [LvErrorMode] names the choice and
/// [lvSignature] states exactly what each does to a terminal list.
///
/// Scope: connector-pane terminal **direction** (which terminal is an input
/// and which an output) is not recovered by the reader yet, so this models the
/// carrier transformation over an ordered terminal list — which terminals
/// survive into the Dart signature and how the error travels — not the
/// input/output split.
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'type_map.dart';

/// The two error-carrying shapes.
enum LvErrorMode {
  /// **Default.** Error clusters are elided from the signature entirely: a VI
  /// with `error in`/`error out` and one real output translates to a function
  /// returning that output, and a cluster whose `status` is true becomes a
  /// thrown [LvRuntimeType.error]. Chosen as the default because it is what a
  /// Dart caller expects, and because a diagram's error-case structures
  /// collapse into ordinary control flow instead of a conditional threaded
  /// through every node.
  exceptions,

  /// **Opt-in.** Error clusters stay first-class values: an `error in`
  /// terminal remains a parameter and an `error out` terminal remains part of
  /// the result, both typed [LvRuntimeType.error]. Chosen when a translation
  /// must stay observationally identical to the VI — including the LabVIEW
  /// behaviour that a node with an incoming error does nothing and passes the
  /// error through unchanged.
  threaded,
}

/// One connector-pane terminal, already type-mapped.
class LvTerminal {
  const LvTerminal(this.name, this.type, {this.isErrorCluster = false});

  /// The terminal's recovered name (`error in (no error)`, `Message String`).
  final String name;

  /// The terminal's Dart representation ([mapLvType]).
  final LvTypeMapping type;

  /// Whether the terminal carries an error cluster ([isLvErrorCluster]).
  final bool isErrorCluster;
}

/// A VI's terminal list after the [LvErrorMode] transformation.
class LvSignature {
  const LvSignature({required this.carried, required this.throwsLvError, required this.elided});

  /// The terminals that survive into the Dart signature, in pool order.
  final List<LvTerminal> carried;

  /// Whether the function propagates errors by throwing
  /// [LvRuntimeType.error] — true exactly when [LvErrorMode.exceptions] left
  /// an error cluster behind.
  final bool throwsLvError;

  /// The error-cluster terminals removed from the signature. Empty under
  /// [LvErrorMode.threaded].
  final List<LvTerminal> elided;
}

/// [terminals] transformed for [mode]: under [LvErrorMode.exceptions] every
/// error-cluster terminal is dropped and the function throws instead; under
/// [LvErrorMode.threaded] the list is unchanged. Pure.
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

/// The terminals of the VI whose connector-pane type is [conpaneIndex] in
/// [pool] — the cluster the connector pane resolves to, one terminal per
/// member, each type-mapped and flagged when it is an error cluster.
///
/// Returns `const []` when the VI has no connector-pane index, when the index
/// is out of range, or when the referenced type is not a cluster. Terminal
/// **direction is not recovered**, so the order here is the connector pane's
/// member order and nothing more.
List<LvTerminal> lvTerminals(List<ViType> pool, int? conpaneIndex) {
  if (conpaneIndex == null || conpaneIndex < 1 || conpaneIndex > pool.length) return const [];
  final conpane = pool[conpaneIndex - 1];
  if (conpane.kind != ViDataType.cluster) return const [];
  return [
    for (final member in clusterFields(conpane, pool))
      LvTerminal(member.name ?? '', mapLvType(member, pool), isErrorCluster: isLvErrorCluster(member, pool)),
  ];
}
