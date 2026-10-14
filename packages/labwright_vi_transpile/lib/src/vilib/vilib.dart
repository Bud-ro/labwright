/// The VIs of LabVIEW's own library (`<vilib>`) that the runtime implements, each with its
/// connector-pane terminals by pane index, direction and type, and the runtime function a
/// call to it lowers to.
library;

import '../numeric.dart';
import '../type_map.dart';
import '../wire_type.dart';
import 'application_directory.dart';
import 'color_to_rgb.dart';
import 'error_cluster_from_error_code.dart';
import 'space_constant.dart';
import 'trim_whitespace.dart';

export 'application_directory.dart';
export 'color_to_rgb.dart';
export 'error_cluster_from_error_code.dart';
export 'space_constant.dart';
export 'trim_whitespace.dart';

/// A VI the runtime implements: its file name, the runtime function and the identifier a call
/// to it lowers to, and its wired connector-pane terminals.
class LvVilibVi {
  const LvVilibVi(this.fileName, {required this.function, required this.dartName, required this.terminals});

  final String fileName;

  /// The runtime function, which [dartName] spells in emitted code.
  final Function function;

  final String dartName;

  final List<LvVilibTerminal> terminals;

  int get paneWidth => terminals.fold(0, (width, terminal) => terminal.pane >= width ? terminal.pane + 1 : width);

  LvVilibTerminal? terminalAt(int pane) {
    for (final terminal in terminals) {
      if (terminal.pane == pane) return terminal;
    }
    return null;
  }
}

/// One wired connector-pane terminal of a [LvVilibVi]: its pane index, its control's name and
/// type, and whether that control is an indicator.
class LvVilibTerminal {
  const LvVilibTerminal(this.pane, this.name, {required this.type, required this.isIndicator, this.runtimeEnum});

  final int pane;

  final String name;

  final LvTypeMapping type;

  final bool isIndicator;

  /// The runtime enum the value passes as, for a terminal that takes an enumeration.
  final String? runtimeEnum;

  LvWireType get wireType => LvWireType.scalarOf(type);

  bool get isErrorCluster => type.carrier == LvCarrier.error;
}

const LvTypeMapping lvVilibText = LvTypeMapping.mapped(LvCarrier.text);
const LvTypeMapping lvVilibBoolean = LvTypeMapping.mapped(LvCarrier.boolean);
const LvTypeMapping lvVilibError = LvTypeMapping.mapped(LvCarrier.error);
const LvTypeMapping lvVilibPath = LvTypeMapping.mapped(LvCarrier.path);
const LvTypeMapping lvVilibU8 = LvTypeMapping.mapped(LvCarrier.integer, numeric: LvNumericKind.u8);
const LvTypeMapping lvVilibU32 = LvTypeMapping.mapped(LvCarrier.integer, numeric: LvNumericKind.u32);
const LvTypeMapping lvVilibI32 = LvTypeMapping.mapped(LvCarrier.integer, numeric: LvNumericKind.i32);

/// The VIs the runtime implements, by lower-cased file name. Each terminal's pane index,
/// direction and type are those every corpus call of the VI draws and wires.
const Map<String, LvVilibVi> lvVilibVis = {
  'space constant.vi': lvSpaceConstantVi,
  'application directory.vi': lvApplicationDirectoryVi,
  'trim whitespace.vi': lvTrimWhitespaceVi,
  'color to rgb.vi': lvColorToRgbVi,
  'error cluster from error code.vi': lvErrorClusterFromErrorCodeVi,
};
