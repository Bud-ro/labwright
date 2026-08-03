/// The **runtime seam**: the one place this package spells the names it emits
/// calls to.
///
/// A translated VI links against `package:labwright_lv_runtime`, which owns
/// the implementations and their documentation. The transpiler only names
/// them, so the two cannot disagree about a signature by accident and a
/// generated file never carries a private copy of a primitive.
library;

import 'numeric.dart';

/// The import a generated file declares to reach the runtime.
const String kLvRuntimeImport = 'package:labwright_lv_runtime/labwright_lv_runtime.dart';

/// The runtime functions a lowering calls.
abstract final class LvRuntimeCall {
  /// The For loop iteration count over several bounds.
  static const String iterationCount = 'lvIterationCount';

  /// Rotate Left With Carry.
  static const String rotateLeftWithCarry = 'lvRotateLeftWithCarry';

  /// Rotate Right With Carry.
  static const String rotateRightWithCarry = 'lvRotateRightWithCarry';

  /// The To-Integer conversion that renormalizes a value to [kind]'s width.
  static String integerConversion(LvNumericKind kind) => 'lvTo${kind.glyph}';
}
