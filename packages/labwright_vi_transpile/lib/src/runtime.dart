import 'numeric.dart';

const String kLvRuntimePackage = 'labwright_lv_runtime';

const String kLvRuntimeImport = 'package:$kLvRuntimePackage/$kLvRuntimePackage.dart';

abstract final class LvRuntimeCall {
  static const String iterationCount = 'lvIterationCount';

  static const String rotateLeftWithCarry = 'lvRotateLeftWithCarry';
  static const String rotateRightWithCarry = 'lvRotateRightWithCarry';
  static const String swapBytes = 'lvSwapBytes';
  static const String swapWords = 'lvSwapWords';
  static const String quotientRemainder = 'lvQuotientRemainder';
  static const String logicalShift = 'lvLogicalShift';
  static const String rotate = 'lvRotate';
  static const String toLowerCase = 'lvToLowerCase';
  static const String stringSubset = 'lvStringSubset';
  static const String hexString = 'lvHexString';
  static const String initializeArray = 'lvInitializeArray';
  static const String mergeErrors = 'lvMergeErrors';
  static const String waitMs = 'lvWaitMs';

  static const String flatOfInt = 'lvFlatOfInt';
  static const String flatOfFloat = 'lvFlatOfFloat';
  static const String flatOfString = 'lvFlatOfString';
  static const String flatOfIntList = 'lvFlatOfIntList';

  static const String intOfFlat = 'lvIntOfFlat';
  static const String floatOfFlat = 'lvFloatOfFlat';
  static const String stringOfFlat = 'lvStringOfFlat';
  static const String intListOfFlat = 'lvIntListOfFlat';

  static String integerConversion(LvNumericKind kind) => 'lvTo${kind.glyph}';
}
