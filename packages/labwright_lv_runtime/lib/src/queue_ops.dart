import 'references.dart';
import 'timing_ops.dart';
import 'values.dart';

/// Where an element enters a queue.
enum LvQueueEnd { back, front }

/// A LabVIEW queue: a bounded FIFO of [T] with a name, shared by every reference obtained under
/// that name until the last one is released.
final class LvQueue<T> {
  LvQueue._(this.name, this.maxSize);

  final String name;

  /// The capacity; -1 is unlimited.
  final int maxSize;

  final List<T> _elements = [];

  /// The live refnums that point at this object.
  final Set<LvRefnum> _refnums = {};

  void _releaseAll() {
    for (final refnum in _refnums) {
      LvReferenceTable.instance.release(refnum);
    }
    _refnums.clear();
  }

  LvRefnum _reference() {
    final refnum = lvRegisterReference(this);
    _refnums.add(refnum);
    return refnum;
  }

  /// Named queues alive in this run, by name.
  static final Map<String, LvQueue<Object?>> _byName = {};

  List<T> get elements => List<T>.unmodifiable(_elements);

  int get length => _elements.length;

  bool get isFull => maxSize >= 0 && _elements.length >= maxSize;

  /// Obtain Queue: a reference to the queue named [name], created when none exists and
  /// [createIfNotFound]; an unnamed queue is always new. [createdNew] says which happened.
  static ({LvRefnum queue, bool createdNew, LvError errorOut}) obtain<E>({
    String name = '',
    int maxSize = -1,
    bool createIfNotFound = true,
    LvError errorIn = LvError.none,
  }) {
    if (errorIn.status) return (queue: LvRefnum.none, createdNew: false, errorOut: errorIn);
    if (name.isNotEmpty) {
      final existing = _byName[name];
      if (existing != null) {
        if (existing is! LvQueue<E>) {
          return (
            queue: LvRefnum.none,
            createdNew: false,
            errorOut: LvErrorCode.invalidArgument.error(
              'Obtain Queue: the queue "$name" holds ${existing.elementType}, not $E',
            ),
          );
        }
        return (queue: existing._reference(), createdNew: false, errorOut: LvError.none);
      }
      if (!createIfNotFound) {
        return (
          queue: LvRefnum.none,
          createdNew: false,
          errorOut: LvErrorCode.invalidArgument.error('Obtain Queue: no queue is named "$name"'),
        );
      }
    }
    final queue = LvQueue<E>._(name, maxSize);
    if (name.isNotEmpty) _byName[name] = queue;
    return (queue: queue._reference(), createdNew: true, errorOut: LvError.none);
  }

  Type get elementType => T;

  /// Release Queue: drops [reference]; the queue itself is destroyed when no reference remains
  /// or when [forceDestroy], and its remaining elements are returned then.
  static ({String name, List<E> remaining, LvError errorOut}) release<E>(
    LvRefnum reference, {
    bool forceDestroy = false,
    LvError errorIn = LvError.none,
  }) {
    final queue = lvReferenceTarget<LvQueue<E>>(reference);
    if (queue == null) {
      return (
        name: '',
        remaining: <E>[],
        errorOut: errorIn.status ? errorIn : LvErrorCode.invalidReference.error('Release Queue'),
      );
    }
    LvReferenceTable.instance.release(reference);
    queue._refnums.remove(reference);
    final destroyed = forceDestroy || queue._refnums.isEmpty;
    final remaining = destroyed ? List<E>.of(queue._elements) : <E>[];
    if (destroyed) {
      queue._releaseAll();
      queue._elements.clear();
      if (queue.name.isNotEmpty && identical(_byName[queue.name], queue)) _byName.remove(queue.name);
    }
    return (name: queue.name, remaining: remaining, errorOut: errorIn);
  }

  /// Enqueue Element (at the back) or Enqueue Element At Opposite End (at the front). A full
  /// queue waits [timeoutMs] milliseconds, or forever when it is -1; nothing can drain it
  /// meanwhile in a synchronous program, so a bounded wait times out and an unbounded one is
  /// [LvErrorCode.synchronousWait].
  static ({LvError errorOut, bool timedOut}) enqueue<E>(
    LvRefnum reference,
    E element, {
    LvQueueEnd end = LvQueueEnd.back,
    int timeoutMs = -1,
    LvError errorIn = LvError.none,
  }) {
    if (errorIn.status) return (errorOut: errorIn, timedOut: false);
    final queue = lvReferenceTarget<LvQueue<E>>(reference);
    if (queue == null) return (errorOut: LvErrorCode.invalidReference.error('Enqueue Element'), timedOut: false);
    if (queue.isFull) {
      if (timeoutMs < 0) {
        return (errorOut: LvErrorCode.synchronousWait.error('Enqueue Element on a full queue'), timedOut: true);
      }
      lvWaitMs(timeoutMs);
      return (errorOut: LvError.none, timedOut: true);
    }
    if (end == LvQueueEnd.back) {
      queue._elements.add(element);
    } else {
      queue._elements.insert(0, element);
    }
    return (errorOut: LvError.none, timedOut: false);
  }

  /// Lossy Enqueue Element: enqueues at the back, discarding the front element of a full queue.
  static ({E? overflow, LvError errorOut}) lossyEnqueue<E>(
    LvRefnum reference,
    E element, {
    LvError errorIn = LvError.none,
  }) {
    if (errorIn.status) return (overflow: null, errorOut: errorIn);
    final queue = lvReferenceTarget<LvQueue<E>>(reference);
    if (queue == null) return (overflow: null, errorOut: LvErrorCode.invalidReference.error('Lossy Enqueue Element'));
    E? overflow;
    if (queue.isFull && queue._elements.isNotEmpty) overflow = queue._elements.removeAt(0);
    queue._elements.add(element);
    return (overflow: overflow, errorOut: LvError.none);
  }

  /// Dequeue Element (removing the front element) or Preview Queue Element (leaving it). An
  /// empty queue waits as [enqueue] does, and a timed-out dequeue yields [defaultValue].
  static ({E element, bool timedOut, LvError errorOut}) dequeue<E>(
    LvRefnum reference, {
    required E defaultValue,
    bool remove = true,
    int timeoutMs = -1,
    LvError errorIn = LvError.none,
  }) {
    if (errorIn.status) return (element: defaultValue, timedOut: false, errorOut: errorIn);
    final queue = lvReferenceTarget<LvQueue<E>>(reference);
    if (queue == null) {
      return (element: defaultValue, timedOut: false, errorOut: LvErrorCode.invalidReference.error('Dequeue Element'));
    }
    if (queue._elements.isEmpty) {
      if (timeoutMs < 0) {
        return (
          element: defaultValue,
          timedOut: true,
          errorOut: LvErrorCode.synchronousWait.error('Dequeue Element on an empty queue'),
        );
      }
      lvWaitMs(timeoutMs);
      return (element: defaultValue, timedOut: true, errorOut: LvError.none);
    }
    final element = remove ? queue._elements.removeAt(0) : queue._elements.first;
    return (element: element, timedOut: false, errorOut: LvError.none);
  }

  /// Flush Queue: every element, front first, leaving the queue empty.
  static ({List<E> remaining, LvError errorOut}) flush<E>(LvRefnum reference, {LvError errorIn = LvError.none}) {
    if (errorIn.status) return (remaining: <E>[], errorOut: errorIn);
    final queue = lvReferenceTarget<LvQueue<E>>(reference);
    if (queue == null) return (remaining: <E>[], errorOut: LvErrorCode.invalidReference.error('Flush Queue'));
    final remaining = List<E>.of(queue._elements);
    queue._elements.clear();
    return (remaining: remaining, errorOut: LvError.none);
  }

  /// Get Queue Status: the queue's capacity, name, element count and, when [returnElements],
  /// its elements front first. Nothing waits in a synchronous program, so both pending counts
  /// are zero.
  static ({
    int maxSize,
    String name,
    int pendingRemove,
    int pendingInsert,
    int elementCount,
    List<E> elements,
    LvError errorOut,
  })
  status<E>(LvRefnum reference, {bool returnElements = false, LvError errorIn = LvError.none}) {
    final queue = lvReferenceTarget<LvQueue<E>>(reference);
    if (errorIn.status || queue == null) {
      return (
        maxSize: 0,
        name: '',
        pendingRemove: 0,
        pendingInsert: 0,
        elementCount: 0,
        elements: <E>[],
        errorOut: errorIn.status ? errorIn : LvErrorCode.invalidReference.error('Get Queue Status'),
      );
    }
    return (
      maxSize: queue.maxSize,
      name: queue.name,
      pendingRemove: 0,
      pendingInsert: 0,
      elementCount: queue._elements.length,
      elements: returnElements ? List<E>.of(queue._elements) : <E>[],
      errorOut: LvError.none,
    );
  }
}
