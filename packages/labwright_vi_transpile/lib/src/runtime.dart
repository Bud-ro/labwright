/// The **runtime seam**: the one place this package spells the names it emits
/// calls to.
///
/// A translated VI links against `package:labwright_lv_runtime`, which owns
/// the implementations and their documentation. The transpiler only names
/// them, so the two cannot disagree about a signature by accident and a
/// generated file never carries a private copy of a primitive.
library;

import 'numeric.dart';

/// The package a generated file depends on to reach the runtime.
const String kLvRuntimePackage = 'labwright_lv_runtime';

/// The import a generated file declares to reach the runtime.
const String kLvRuntimeImport = 'package:$kLvRuntimePackage/$kLvRuntimePackage.dart';

/// The runtime functions a lowering calls.
abstract final class LvRuntimeCall {
  /// The For loop iteration count over several bounds.
  static const String iterationCount = 'lvIterationCount';

  /// Rotate Left With Carry.
  static const String rotateLeftWithCarry = 'lvRotateLeftWithCarry';

  /// Rotate Right With Carry.
  static const String rotateRightWithCarry = 'lvRotateRightWithCarry';

  /// Swap Bytes.
  static const String swapBytes = 'lvSwapBytes';

  /// Swap Words.
  static const String swapWords = 'lvSwapWords';

  /// Quotient & Remainder.
  static const String quotientRemainder = 'lvQuotientRemainder';

  /// Logical Shift.
  static const String logicalShift = 'lvLogicalShift';

  /// Merge Errors.
  static const String mergeErrors = 'lvMergeErrors';

  /// The flat bytes of a scalar integer, of a scalar float, of a string and of
  /// a 1-D integer array — the Type Cast operand side.
  static const String flatOfInt = 'lvFlatOfInt';
  static const String flatOfFloat = 'lvFlatOfFloat';
  static const String flatOfString = 'lvFlatOfString';
  static const String flatOfIntList = 'lvFlatOfIntList';

  /// The scalar integer, scalar float, string and 1-D integer array flat bytes
  /// hold — the Type Cast result side.
  static const String intOfFlat = 'lvIntOfFlat';
  static const String floatOfFlat = 'lvFloatOfFlat';
  static const String stringOfFlat = 'lvStringOfFlat';
  static const String intListOfFlat = 'lvIntListOfFlat';

  /// The To-Integer conversion that renormalizes a value to [kind]'s width.
  static String integerConversion(LvNumericKind kind) => 'lvTo${kind.glyph}';
}
