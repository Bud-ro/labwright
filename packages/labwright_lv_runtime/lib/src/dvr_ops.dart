import 'references.dart';
import 'values.dart';

/// A data value reference: one value of [T] that In Place Element structures read and write
/// through a refnum.
final class LvDataValueReference<T> {
  LvDataValueReference(this.value);

  T value;

  /// New Data Value Reference.
  static ({LvRefnum reference, LvError errorOut}) create<E>(E value, {LvError errorIn = LvError.none}) {
    if (errorIn.status) return (reference: LvRefnum.none, errorOut: errorIn);
    return (reference: lvRegisterReference(LvDataValueReference<E>(value)), errorOut: LvError.none);
  }

  /// Delete Data Value Reference: recovers the value and releases the reference. It runs even
  /// when an error came in, as the reference states, and passes that error on.
  static ({E value, LvError errorOut}) delete<E>(
    LvRefnum reference, {
    required E defaultValue,
    LvError errorIn = LvError.none,
  }) {
    final target = lvReferenceTarget<LvDataValueReference<E>>(reference);
    if (target == null) {
      return (
        value: defaultValue,
        errorOut: errorIn.status ? errorIn : LvErrorCode.invalidReference.error('Delete Data Value Reference'),
      );
    }
    LvReferenceTable.instance.release(reference);
    return (value: target.value, errorOut: errorIn);
  }

  /// The read border node of an In Place Element structure's Data Value Reference pair.
  static ({E value, LvError errorOut}) read<E>(
    LvRefnum reference, {
    required E defaultValue,
    LvError errorIn = LvError.none,
  }) {
    if (errorIn.status) return (value: defaultValue, errorOut: errorIn);
    final target = lvReferenceTarget<LvDataValueReference<E>>(reference);
    if (target == null) {
      return (value: defaultValue, errorOut: LvErrorCode.invalidReference.error('Data Value Reference Read'));
    }
    return (value: target.value, errorOut: LvError.none);
  }

  /// The write border node of the same pair: stores [value] unless an error came in.
  static LvError write<E>(LvRefnum reference, E value, {LvError errorIn = LvError.none}) {
    if (errorIn.status) return errorIn;
    final target = lvReferenceTarget<LvDataValueReference<E>>(reference);
    if (target == null) return LvErrorCode.invalidReference.error('Data Value Reference Write');
    target.value = value;
    return LvError.none;
  }
}
