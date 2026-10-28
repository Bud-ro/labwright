import 'references.dart';
import 'timing_ops.dart';
import 'values.dart';

/// A LabVIEW notifier: a single latest message of [T] with a name, shared by every reference
/// obtained under that name until the last one is released.
final class LvNotifier<T> {
  LvNotifier._(this.name);

  final String name;

  bool _hasMessage = false;

  T? _message;

  int _references = 0;

  static final Map<String, LvNotifier<Object?>> _byName = {};

  /// Obtain Notifier, as a queue is obtained.
  static ({LvRefnum notifier, bool createdNew, LvError errorOut}) obtain<E>({
    String name = '',
    bool createIfNotFound = true,
    LvError errorIn = LvError.none,
  }) {
    if (errorIn.status) return (notifier: LvRefnum.none, createdNew: false, errorOut: errorIn);
    if (name.isNotEmpty) {
      final existing = _byName[name];
      if (existing != null) {
        if (existing is! LvNotifier<E>) {
          return (
            notifier: LvRefnum.none,
            createdNew: false,
            errorOut: LvErrorCode.invalidArgument.error('Obtain Notifier: the notifier "$name" carries another type'),
          );
        }
        existing._references++;
        return (notifier: lvRegisterReference(existing), createdNew: false, errorOut: LvError.none);
      }
      if (!createIfNotFound) {
        return (
          notifier: LvRefnum.none,
          createdNew: false,
          errorOut: LvErrorCode.invalidArgument.error('Obtain Notifier: no notifier is named "$name"'),
        );
      }
    }
    final notifier = LvNotifier<E>._(name);
    notifier._references = 1;
    if (name.isNotEmpty) _byName[name] = notifier;
    return (notifier: lvRegisterReference(notifier), createdNew: true, errorOut: LvError.none);
  }

  /// Release Notifier, as a queue is released.
  static LvError release<E>(LvRefnum reference, {bool forceDestroy = false, LvError errorIn = LvError.none}) {
    final notifier = lvReferenceTarget<LvNotifier<E>>(reference);
    if (notifier == null) return errorIn.status ? errorIn : LvErrorCode.invalidReference.error('Release Notifier');
    LvReferenceTable.instance.release(reference);
    notifier._references--;
    if (forceDestroy || notifier._references <= 0) {
      notifier._hasMessage = false;
      notifier._message = null;
      if (notifier.name.isNotEmpty && identical(_byName[notifier.name], notifier)) _byName.remove(notifier.name);
    }
    return errorIn;
  }

  /// Send Notification: [notification] becomes the notifier's latest message.
  static LvError send<E>(LvRefnum reference, E notification, {LvError errorIn = LvError.none}) {
    if (errorIn.status) return errorIn;
    final notifier = lvReferenceTarget<LvNotifier<E>>(reference);
    if (notifier == null) return LvErrorCode.invalidReference.error('Send Notification');
    notifier._hasMessage = true;
    notifier._message = notification;
    return LvError.none;
  }

  /// Wait on Notification: the latest message, unless there is none or [ignorePrevious]; then
  /// the function waits as a queue does, and a timed-out wait yields [defaultValue] with
  /// `timedOut` set, as it does on an error.
  static ({E notification, bool timedOut, LvError errorOut}) wait<E>(
    LvRefnum reference, {
    required E defaultValue,
    bool ignorePrevious = false,
    int timeoutMs = -1,
    LvError errorIn = LvError.none,
  }) {
    if (errorIn.status) return (notification: defaultValue, timedOut: true, errorOut: errorIn);
    final notifier = lvReferenceTarget<LvNotifier<E>>(reference);
    if (notifier == null) {
      return (
        notification: defaultValue,
        timedOut: true,
        errorOut: LvErrorCode.invalidReference.error('Wait on Notification'),
      );
    }
    if (notifier._hasMessage && !ignorePrevious) {
      return (notification: notifier._message as E, timedOut: false, errorOut: LvError.none);
    }
    if (timeoutMs < 0) {
      return (
        notification: defaultValue,
        timedOut: true,
        errorOut: LvErrorCode.synchronousWait.error('Wait on Notification with no message pending'),
      );
    }
    lvWaitMs(timeoutMs);
    return (notification: defaultValue, timedOut: true, errorOut: LvError.none);
  }

  /// Get Notifier Status: the latest message when there is one.
  static ({String name, bool hasMessage, E? message, LvError errorOut}) status<E>(
    LvRefnum reference, {
    LvError errorIn = LvError.none,
  }) {
    final notifier = lvReferenceTarget<LvNotifier<E>>(reference);
    if (errorIn.status || notifier == null) {
      return (
        name: '',
        hasMessage: false,
        message: null,
        errorOut: errorIn.status ? errorIn : LvErrorCode.invalidReference.error('Get Notifier Status'),
      );
    }
    return (
      name: notifier.name,
      hasMessage: notifier._hasMessage,
      message: notifier._hasMessage ? notifier._message as E : null,
      errorOut: LvError.none,
    );
  }
}
