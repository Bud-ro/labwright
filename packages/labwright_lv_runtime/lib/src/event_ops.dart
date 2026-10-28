import 'environment.dart';
import 'references.dart';
import 'values.dart';

/// How a generated user event is queued relative to those already waiting.
enum LvEventPriority { normal, high }

/// One queued occurrence of a user event: the event's refnum and the data it carried.
typedef LvQueuedEvent = ({LvRefnum userEvent, Object? data});

/// A user event: a named source of [T] that registrations receive from.
final class LvUserEvent<T> {
  LvUserEvent(this.name);

  /// The label of the data type the event was created from.
  final String name;

  final Set<LvEventRegistration> _registrations = {};

  /// Create User Event.
  static ({LvRefnum userEvent, LvError errorOut}) create<E>(String name, {LvError errorIn = LvError.none}) {
    if (errorIn.status) return (userEvent: LvRefnum.none, errorOut: errorIn);
    return (userEvent: lvRegisterReference(LvUserEvent<E>(name)), errorOut: LvError.none);
  }

  /// Generate User Event: queues [data] on every registration of [reference].
  static LvError generate<E>(
    LvRefnum reference,
    E data, {
    LvEventPriority priority = LvEventPriority.normal,
    LvError errorIn = LvError.none,
  }) {
    if (errorIn.status) return errorIn;
    final event = lvReferenceTarget<LvUserEvent<E>>(reference);
    if (event == null) return LvErrorCode.invalidReference.error('Generate User Event');
    for (final registration in event._registrations) {
      registration._queue(reference, data, priority);
    }
    return LvError.none;
  }

  /// Destroy User Event: releases the event; registrations stop receiving it. It runs even
  /// when an error came in and passes that error on.
  static LvError destroy(LvRefnum reference, {LvError errorIn = LvError.none}) {
    final event = lvReferenceTarget<LvUserEvent<Object?>>(reference);
    if (event == null) return errorIn.status ? errorIn : LvErrorCode.invalidReference.error('Destroy User Event');
    for (final registration in event._registrations) {
      registration._sources.remove(reference);
    }
    LvReferenceTable.instance.release(reference);
    return errorIn;
  }
}

/// An event registration: the sources a Register For Events node subscribed and the events
/// queued for them, front first.
final class LvEventRegistration {
  LvEventRegistration._();

  final Set<LvRefnum> _sources = {};

  final List<LvQueuedEvent> _pending = [];

  List<LvQueuedEvent> get pending => List.unmodifiable(_pending);

  void _queue(LvRefnum source, Object? data, LvEventPriority priority) {
    final event = (userEvent: source, data: data);
    if (priority == LvEventPriority.high) {
      _pending.insert(0, event);
    } else {
      _pending.add(event);
    }
  }

  /// Register For Events over user events alone: a registration receiving each of [userEvents].
  /// Re-registering through [existing] replaces its sources.
  static ({LvRefnum registration, LvError errorOut}) register(
    List<LvRefnum> userEvents, {
    LvRefnum existing = LvRefnum.none,
    LvError errorIn = LvError.none,
  }) {
    if (errorIn.status) return (registration: LvRefnum.none, errorOut: errorIn);
    final registration = lvReferenceTarget<LvEventRegistration>(existing) ?? LvEventRegistration._();
    for (final source in registration._sources) {
      lvReferenceTarget<LvUserEvent<Object?>>(source)?._registrations.remove(registration);
    }
    registration._sources.clear();
    for (final source in userEvents) {
      final event = lvReferenceTarget<LvUserEvent<Object?>>(source);
      if (event == null) {
        return (registration: LvRefnum.none, errorOut: LvErrorCode.invalidReference.error('Register For Events'));
      }
      event._registrations.add(registration);
      registration._sources.add(source);
    }
    final refnum = lvReferenceIsLive(existing) ? existing : lvRegisterReference(registration);
    return (registration: refnum, errorOut: LvError.none);
  }

  /// Unregister For Events: drops the registration and the events queued on it. It runs even
  /// when an error came in and passes that error on.
  static LvError unregister(LvRefnum reference, {LvError errorIn = LvError.none}) {
    final registration = lvReferenceTarget<LvEventRegistration>(reference);
    if (registration == null) {
      return errorIn.status ? errorIn : LvErrorCode.invalidReference.error('Unregister For Events');
    }
    for (final source in registration._sources) {
      lvReferenceTarget<LvUserEvent<Object?>>(source)?._registrations.remove(registration);
    }
    registration._sources.clear();
    registration._pending.clear();
    LvReferenceTable.instance.release(reference);
    return errorIn;
  }

  /// The next queued event, removed, or null when none is pending.
  static LvQueuedEvent? next(LvRefnum reference) {
    final registration = lvReferenceTarget<LvEventRegistration>(reference);
    if (registration == null || registration._pending.isEmpty) return null;
    return registration._pending.removeAt(0);
  }
}

/// Register For Events over [sources]: user events register in the runtime; any other source
/// is a panel object, VI or application the environment registers.
({LvRefnum registration, LvError errorOut}) lvRegisterForEvents(
  List<LvRefnum> sources, {
  LvRefnum existing = LvRefnum.none,
  LvError errorIn = LvError.none,
}) {
  if (sources.every((source) => lvReferenceTarget<LvUserEvent<Object?>>(source) != null)) {
    return LvEventRegistration.register(sources, existing: existing, errorIn: errorIn);
  }
  return lvEnvironment.registerForEvents(
    [
      for (final source in sources) (event: '', source: source),
    ],
    existing,
    errorIn,
  );
}
