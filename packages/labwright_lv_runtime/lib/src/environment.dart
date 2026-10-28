import 'references.dart';
import 'values.dart';

/// The operations a translated VI can only perform through its host: VI Server, the front
/// panel, dialogs, event registration on panel objects, instrument and network sessions.
/// Every method has the terminals of the LabVIEW node it stands for; the default
/// implementation, [LvUnavailableEnvironment], raises [LvEnvironmentUnavailable] naming the
/// operation. A host installs its own by assigning [lvEnvironment].
abstract class LvEnvironment {
  const LvEnvironment();

  /// Open VI Reference.
  ({LvRefnum viReference, LvError errorOut}) openViReference({
    LvRefnum applicationReference = LvRefnum.none,
    required Object viPath,
    int options = 0,
    String password = '',
    LvRefnum typeSpecifier = LvRefnum.none,
    LvError errorIn = LvError.none,
  });

  /// Close Reference on a refnum the runtime's own reference table does not hold.
  LvError closeReference(LvRefnum reference, LvError errorIn);

  /// To More Specific Class.
  ({LvRefnum reference, LvError errorOut}) toMoreSpecificClass(
    LvRefnum reference,
    LvRefnum targetClass,
    LvError errorIn,
  );

  /// To More Generic Class.
  LvRefnum toMoreGenericClass(LvRefnum reference, LvRefnum targetClass);

  /// Preserve Run-Time Class.
  ({LvRefnum object, LvError errorOut}) preserveRunTimeClass(LvRefnum object, LvRefnum target, LvError errorIn);

  /// New VI Object.
  ({LvRefnum object, LvError errorOut}) newViObject({
    required LvRefnum owner,
    required LvRefnum viObjectClass,
    required int style,
    required Object? location,
    bool autoWire = false,
    Object? path,
    Object? bounds,
    LvError errorIn = LvError.none,
  });

  /// Property Node: reads [reads] and writes [writes] on [reference], in node order reads then
  /// writes; the values read come back in the order of [reads].
  ({LvRefnum reference, List<Object?> values, LvError errorOut}) propertyNode(
    LvRefnum reference,
    LvError errorIn, {
    List<String> reads = const [],
    Map<String, Object?> writes = const {},
  });

  /// Invoke Node: calls [method] on [reference] with [inputs] in parameter order; the return
  /// value and the output parameters come back in parameter order.
  ({LvRefnum reference, Object? returnValue, List<Object?> outputs, LvError errorOut}) invokeNode(
    LvRefnum reference,
    LvError errorIn,
    String method,
    List<Object?> inputs,
  );

  /// Call Chain: the callers from the current VI to the top-level VI.
  List<String> callChain();

  /// Current VI's Path.
  LvPath currentVisPath();

  /// VI Library.
  LvPath viLibrary();

  /// Current VI's Menubar.
  LvRefnum currentVisMenubar();

  /// First Call?: true the first time the section holding [site] runs since the top-level VI
  /// started.
  bool firstCall(int site);

  /// A local variable read of the panel control named [name].
  Object? readLocalVariable(String name);

  /// A local variable write to the panel control named [name].
  void writeLocalVariable(String name, Object? value);

  /// One Button Dialog; the function's output is always true.
  bool oneButtonDialog(String message, String buttonName);

  /// Two Button Dialog: true when the T button was pressed.
  bool twoButtonDialog(String message, String tButtonName, String fButtonName);

  /// File Dialog.
  ({LvPath path, bool exists, bool cancelled, LvError errorOut}) fileDialog({
    LvPath startPath = const LvPath(components: [], absolute: false),
    String prompt = '',
    String pattern = '',
    String defaultName = '',
    String buttonLabel = '',
    String patternLabel = '',
    int selectMode = 0,
    LvError errorIn = LvError.none,
  });

  /// Stop: halts the top-level VI when [stop].
  void stop(bool stop);

  /// Quit LabVIEW: ends the application when [quit].
  void quitLabview(bool quit);

  /// Register For Events on sources that are not user events (panel objects, VIs, the
  /// application).
  ({LvRefnum registration, LvError errorOut}) registerForEvents(
    List<({String event, LvRefnum source})> sources,
    LvRefnum existing,
    LvError errorIn,
  );

  /// Get Permissions and Set Permissions.
  ({int permissions, String owner, String group, LvError errorOut}) getPermissions(LvPath path, LvError errorIn);

  LvError setPermissions(LvPath path, int permissions, String newOwner, String newGroup, LvError errorIn);

  /// Any instrument, network or external-session primitive ([operation] is its name) with its
  /// wired inputs in terminal order; the outputs come back in terminal order.
  List<Object?> session(String operation, List<Object?> inputs);
}

/// Raised by [LvUnavailableEnvironment] for every operation.
final class LvEnvironmentUnavailable extends Error {
  LvEnvironmentUnavailable(this.operation);

  final String operation;

  @override
  String toString() => 'LabVIEW operation "$operation" needs an LvEnvironment, and none is installed';
}

/// The environment a program runs in until a host installs one: every operation raises.
final class LvUnavailableEnvironment extends LvEnvironment {
  const LvUnavailableEnvironment();

  Never _raise(String operation) => throw LvEnvironmentUnavailable(operation);

  @override
  ({LvRefnum viReference, LvError errorOut}) openViReference({
    LvRefnum applicationReference = LvRefnum.none,
    required Object viPath,
    int options = 0,
    String password = '',
    LvRefnum typeSpecifier = LvRefnum.none,
    LvError errorIn = LvError.none,
  }) => _raise('Open VI Reference');

  @override
  LvError closeReference(LvRefnum reference, LvError errorIn) => _raise('Close Reference');

  @override
  ({LvRefnum reference, LvError errorOut}) toMoreSpecificClass(
    LvRefnum reference,
    LvRefnum targetClass,
    LvError errorIn,
  ) => _raise('To More Specific Class');

  @override
  LvRefnum toMoreGenericClass(LvRefnum reference, LvRefnum targetClass) => _raise('To More Generic Class');

  @override
  ({LvRefnum object, LvError errorOut}) preserveRunTimeClass(LvRefnum object, LvRefnum target, LvError errorIn) =>
      _raise('Preserve Run-Time Class');

  @override
  ({LvRefnum object, LvError errorOut}) newViObject({
    required LvRefnum owner,
    required LvRefnum viObjectClass,
    required int style,
    required Object? location,
    bool autoWire = false,
    Object? path,
    Object? bounds,
    LvError errorIn = LvError.none,
  }) => _raise('New VI Object');

  @override
  ({LvRefnum reference, List<Object?> values, LvError errorOut}) propertyNode(
    LvRefnum reference,
    LvError errorIn, {
    List<String> reads = const [],
    Map<String, Object?> writes = const {},
  }) => _raise('Property Node ${[...reads, ...writes.keys].join(', ')}');

  @override
  ({LvRefnum reference, Object? returnValue, List<Object?> outputs, LvError errorOut}) invokeNode(
    LvRefnum reference,
    LvError errorIn,
    String method,
    List<Object?> inputs,
  ) => _raise('Invoke Node $method');

  @override
  List<String> callChain() => _raise('Call Chain');

  @override
  LvPath currentVisPath() => _raise("Current VI's Path");

  @override
  LvPath viLibrary() => _raise('VI Library');

  @override
  LvRefnum currentVisMenubar() => _raise("Current VI's Menubar");

  @override
  bool firstCall(int site) => _raise('First Call?');

  @override
  Object? readLocalVariable(String name) => _raise('local variable "$name"');

  @override
  void writeLocalVariable(String name, Object? value) => _raise('local variable "$name"');

  @override
  bool oneButtonDialog(String message, String buttonName) => _raise('One Button Dialog');

  @override
  bool twoButtonDialog(String message, String tButtonName, String fButtonName) => _raise('Two Button Dialog');

  @override
  ({LvPath path, bool exists, bool cancelled, LvError errorOut}) fileDialog({
    LvPath startPath = const LvPath(components: [], absolute: false),
    String prompt = '',
    String pattern = '',
    String defaultName = '',
    String buttonLabel = '',
    String patternLabel = '',
    int selectMode = 0,
    LvError errorIn = LvError.none,
  }) => _raise('File Dialog');

  @override
  void stop(bool stop) => _raise('Stop');

  @override
  void quitLabview(bool quit) => _raise('Quit LabVIEW');

  @override
  ({LvRefnum registration, LvError errorOut}) registerForEvents(
    List<({String event, LvRefnum source})> sources,
    LvRefnum existing,
    LvError errorIn,
  ) => _raise('Register For Events ${sources.map((source) => source.event).join(', ')}');

  @override
  ({int permissions, String owner, String group, LvError errorOut}) getPermissions(LvPath path, LvError errorIn) =>
      _raise('Get Permissions');

  @override
  LvError setPermissions(LvPath path, int permissions, String newOwner, String newGroup, LvError errorIn) =>
      _raise('Set Permissions');

  @override
  List<Object?> session(String operation, List<Object?> inputs) => _raise(operation);
}

/// The environment translated code calls; [LvUnavailableEnvironment] until a host installs one.
LvEnvironment lvEnvironment = const LvUnavailableEnvironment();

/// Close Reference on any refnum: the runtime's own table first, then the environment.
LvError lvCloseAnyReference(LvRefnum reference, [LvError errorIn = LvError.none]) {
  if (lvReferenceIsLive(reference)) return lvCloseReference(reference, errorIn);
  return lvEnvironment.closeReference(reference, errorIn);
}
