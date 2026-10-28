import 'values.dart';

/// Error codes LabVIEW publishes in its general error table, for the conditions the runtime
/// raises itself.
enum LvErrorCode {
  /// An input parameter is invalid.
  invalidArgument(1),

  /// End of file encountered.
  endOfFile(4),

  /// File not found.
  fileNotFound(7),

  /// File permission error.
  filePermission(8),

  /// Disk full, or the operating system refused the write.
  diskFull(9),

  /// Duplicate path: the target already exists.
  duplicatePath(10),

  /// Not a path, or an invalid path.
  invalidPath(1430),

  /// The data type of the variant is not compatible with the data type wired to the type input.
  variantTypeMismatch(91),

  /// The refnum became invalid while the node waited for it.
  refnumBecameInvalid(1122),

  /// The reference is invalid: it was deleted, or never pointed at a live object.
  invalidReference(1556),

  /// A function waited for a queue or notifier that no concurrent producer can satisfy, which
  /// only this synchronous runtime raises.
  synchronousWait(-1),

  /// An operation this program's environment does not provide.
  environmentUnavailable(-2);

  const LvErrorCode(this.code);

  final int code;

  LvError error(String source) => LvError(status: true, code: code, source: source);
}

/// The live objects a program's references point at, by refnum id. A refnum is a `u32` other
/// than zero (Not A Refnum); ids are handed out in order and never reused within a run.
final class LvReferenceTable {
  LvReferenceTable._();

  static final LvReferenceTable instance = LvReferenceTable._();

  final Map<int, Object> _targets = {};

  int _next = 1;

  LvRefnum register(Object target) {
    final refnum = LvRefnum(_next++);
    _targets[refnum.id] = target;
    return refnum;
  }

  /// The object [refnum] points at when it is a live [T]; null for Not A Refnum, a released
  /// reference or an object of another type.
  T? target<T extends Object>(LvRefnum refnum) {
    final target = _targets[refnum.id];
    return target is T ? target : null;
  }

  bool isLive(LvRefnum refnum) => _targets.containsKey(refnum.id);

  Object? release(LvRefnum refnum) => _targets.remove(refnum.id);

  void clear() {
    _targets.clear();
    _next = 1;
  }
}

/// [LvReferenceTable.register] on the shared table.
LvRefnum lvRegisterReference(Object target) => LvReferenceTable.instance.register(target);

/// Whether [refnum] points at a live object of any kind.
bool lvReferenceIsLive(LvRefnum refnum) => LvReferenceTable.instance.isLive(refnum);

/// The live [T] behind [refnum], or null.
T? lvReferenceTarget<T extends Object>(LvRefnum refnum) => LvReferenceTable.instance.target<T>(refnum);

/// Close Reference: releases whatever [reference] points at. An incoming error passes through
/// untouched; a reference that points at nothing is [LvErrorCode.invalidReference].
LvError lvCloseReference(LvRefnum reference, [LvError errorIn = LvError.none]) {
  if (errorIn.status) return errorIn;
  if (LvReferenceTable.instance.release(reference) == null) {
    return LvErrorCode.invalidReference.error('Close Reference');
  }
  return LvError.none;
}
