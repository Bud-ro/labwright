import 'numeric.dart';
import 'type_map.dart';
import 'wire_type.dart';

/// How a stock terminal's wire value becomes the runtime call's argument, or its result the
/// wire's value; [LvStockTerminal.enumIndex] carries a caller-declared enum as its index.
enum LvStockCoercion { none, enumIndex }

/// One connector-pane terminal of a stock VI, at [pane] in pane order.
class LvStockTerminal {
  const LvStockTerminal(
    this.pane,
    this.name, {
    required this.type,
    required this.isInput,
    this.coercion = LvStockCoercion.none,
  });

  final int pane;

  final String name;

  final LvTypeMapping type;

  final bool isInput;

  final LvStockCoercion coercion;

  bool get isErrorCluster => type.carrier == LvCarrier.error;
}

/// A VI of LabVIEW's own library (`<vilib>`), implemented by a runtime function: its file name,
/// the function, its terminals by pane index, and the Dart type the function returns when it
/// yields more than one result (a record of the result names).
class LvStockVi {
  const LvStockVi(this.fileName, this.function, this.terminals, {this.enumType});

  final String fileName;

  final String function;

  final List<LvStockTerminal> terminals;

  /// The runtime enum a [LvStockCoercion.enumIndex] terminal indexes into.
  final String? enumType;

  int get paneWidth => terminals.fold(0, (width, terminal) => terminal.pane >= width ? terminal.pane + 1 : width);

  LvStockTerminal? terminalAt(int pane) {
    for (final terminal in terminals) {
      if (terminal.pane == pane) return terminal;
    }
    return null;
  }
}

const _text = LvTypeMapping.mapped(LvCarrier.text);
const _boolean = LvTypeMapping.mapped(LvCarrier.boolean);
const _error = LvTypeMapping.mapped(LvCarrier.error);
const _path = LvTypeMapping.mapped(LvCarrier.path);
const _u8 = LvTypeMapping.mapped(LvCarrier.integer, numeric: LvNumericKind.u8);
const _u32 = LvTypeMapping.mapped(LvCarrier.integer, numeric: LvNumericKind.u32);
const _i32 = LvTypeMapping.mapped(LvCarrier.integer, numeric: LvNumericKind.i32);

/// The stock VIs the runtime implements, by lower-cased file name. Each terminal's pane index,
/// direction and type are those every corpus call of the VI draws and wires.
const Map<String, LvStockVi> kLvStockVis = {
  'space constant.vi': LvStockVi('Space Constant.vi', 'lvSpaceConstant', [
    LvStockTerminal(0, 'space', type: _text, isInput: false),
  ]),
  'application directory.vi': LvStockVi('Application Directory.vi', 'lvApplicationDirectory', [
    LvStockTerminal(0, 'path', type: _path, isInput: false),
  ]),
  'trim whitespace.vi': LvStockVi(
    'Trim Whitespace.vi',
    'lvTrimWhitespace',
    [
      LvStockTerminal(0, 'string', type: _text, isInput: true),
      LvStockTerminal(1, 'location', type: _u32, isInput: true, coercion: LvStockCoercion.enumIndex),
      LvStockTerminal(2, 'trimmed string', type: _text, isInput: false),
    ],
    enumType: 'LvTrimLocation',
  ),
  'color to rgb.vi': LvStockVi('Color to RGB.vi', 'lvColorToRgb', [
    LvStockTerminal(0, 'color', type: _u32, isInput: true),
    LvStockTerminal(2, 'red', type: _u8, isInput: false),
    LvStockTerminal(3, 'green', type: _u8, isInput: false),
    LvStockTerminal(4, 'blue', type: _u8, isInput: false),
  ]),
  'error cluster from error code.vi': LvStockVi('Error Cluster From Error Code.vi', 'lvErrorClusterFromErrorCode', [
    LvStockTerminal(0, 'error out', type: _error, isInput: false),
    LvStockTerminal(5, 'show call chain?', type: _boolean, isInput: true),
    LvStockTerminal(6, 'error in', type: _error, isInput: true),
    LvStockTerminal(8, 'message', type: _text, isInput: true),
    LvStockTerminal(9, 'error code', type: _i32, isInput: true),
  ]),
};

/// The wire type a stock terminal carries.
LvWireType lvStockWireType(LvStockTerminal terminal) => LvWireType.scalarOf(terminal.type);
