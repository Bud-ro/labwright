/// `LVSR` - LabVIEW Save Record: [ViSaveRecord]
///
/// General information about a saved VI file: the saving version, the VI's kind, its settings
/// and saved status as bit sets, and a few digests. The record grows with the saving version
/// (96 bytes in LabVIEW 7.1, 120 by 8.6, 136 by 10, 137 by 14, 144 by 15, 160 after), so every
/// field past 96 is optional. The bit names follow pylabview's reading of the record; the
/// corpus attests the ones the bit-set docs mark. It contradicts two of pylabview's claims: the
/// digest at 96 is `MD5("")` in every file including the five whose block diagram is
/// password-protected, so it is not the block-diagram password (`BDPW` holds that), and the
/// priority word takes the value 5 in the 207 files whose subroutine bit is set.
///
/// ```text
/// offset  size  field            type   meaning
/// 0       4     versionWord      u32    Saving LabVIEW version; repeats the numeric part of `vers`.
/// 4       4     statusFlags      u32    Bit set named by ViStatusFlag.
/// 8       4     optionFlags      u32    Bit set named by ViOptionFlag.
/// 12      4     flags12          u32    Bit 2 is `autoHandlesMenus`; the others are clear in all but two
///                                       files.
/// 16      2     unknown16        u16    3, or 1 in 35 files; role TODO.
/// 18      2     windowFlags      u16    Bit set named by ViWindowFlag.
/// 20      2     hiddenButtons    u16    Bit set named by ViToolbarButton: the toolbar buttons hidden while
///                                       the VI runs.
/// 22      2     frontPanelFlags  u16    Bit set named by ViFrontPanelFlag.
/// 24      4     stateFlags       u32    Bit set named by ViStateFlag.
/// 28      4     unknown28        u32    0 to 5, 1 in all but 586 files; role TODO.
/// 32      2     priority         u16    The priority the VI runs at.
/// 34      2     viType           u16    The kind of VI the file holds.
/// 36      4     executionSystem  i32    The execution system the VI prefers.
/// 40      12    unknown40               Zero in all but 5 files, where two four-character codes repeat and a
///                                       2 or 3 follows; roles TODO.
/// 52      16    unknown52               Digest-like: distinct in 8048 of 8316 files; role TODO.
/// 68      4     frontPanelGrid   u32    Front-panel alignment grid in pixels, 12 by default.
/// 72      4     blockDiagramGrid u32    Block-diagram alignment grid in pixels, 16 by default.
/// 76      2     unknown76        u16    Zero in all but 53 files; role TODO.
/// 78      2     controlStyle     u16    The palette style new controls and indicators take.
/// 80      16    unknown80               Digest-like: distinct in 8048 of 8316 files, equal to `unknown52` in
///                                       12; role TODO.
/// 96      16    unknown96        ?      `MD5("")` in every corpus file; role TODO.
/// 112     4     unknown112       u32?   0x1000, 0 or 0x4000; role TODO.
/// 116     4     unknown116       i32?   Zero in all but 16 files, where it is -2 to 2; role TODO.
/// 120     16    unknown120       ?      Digest-like: distinct in 7831 of 8065 files, zero in 207; role TODO.
/// 136     1     unknown136       u8?    0, 1 or 2; role TODO.
/// 137     3     unknown137       ?      Zero.
/// 140     4     unknown140       u32?   0xFFFFFFFF, or 0 in 403 files; role TODO.
/// 144     16    unknown144       ?      `MD5("")` in 5037 of 6158 files, zero in 409, 527 distinct values;
///                                       role TODO.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';
import 'vers_version.dart';

/// Bits of `statusFlags`: VI Properties settings, the broken-VI status recorded at save, and
/// the saving edition. The corpus sets every bit but 4, 9, 11, 12, 16, 19, 21, 23 and 28, whose
/// names follow pylabview and are unverified.
enum ViStatusFlag {
  badSignal(0),
  badNode(1),
  badSubViLink(2),
  badSubVi(3),
  notReservable(4),

  /// Several instances of the VI may run in parallel.
  reentrant(5),

  /// Close the front panel after the VI runs, if it was closed before the call.
  closeAfterCall(6),
  pooledReentrancy(7),
  loadFrontPanel(8),

  /// The block diagram is not available.
  noBlockDiagram(9),

  /// Show the front panel when the VI is loaded.
  showFrontPanelOnLoad(10),

  /// A dynamic-dispatch VI.
  dynamicDispatch(11),

  /// Suspend when called.
  breakpointSet(12),

  /// The owning library is locked against changes.
  libraryProtected(13),

  /// Run the VI when it opens.
  runOnOpen(14),

  /// Show the front panel when the VI is called.
  showFrontPanelOnCall(15),
  badCompile(16),

  /// A subroutine-priority VI; `priority` is then [ViPriority.subroutine].
  subroutine(17),
  recordDataSpace(18),
  compilerBug(19),

  /// A typedef control.
  typedef(20),

  /// A strict-typedef control.
  strictTypedef(21),
  badDataDisplayObject(22),
  controlEditChanged(23),
  saveParallel(24),

  /// The owning library has a problem that stops the VI running.
  libraryIssuesNoRun(25),
  allowAutoPreallocation(26),

  /// Last saved by an evaluation-license LabVIEW, whose block-diagram images carry the
  /// "LabVIEW Evaluation Software" watermark.
  evaluationWatermark(27),

  /// Last saved by a Home or Student edition, whose block-diagram images carry the "Student
  /// Edition" watermark.
  studentWatermark(28),
  hasInsaneItems(29),
  propertyTypeIssues(30),
  brokenPolymorphicVi(31);

  const ViStatusFlag(this.bit);

  final int bit;

  int get mask => 1 << bit;
}

/// Bits of `optionFlags`. The corpus sets bits 1, 2, 3, 6, 7, 9, 10, 16, 17, 22, 23, 24, 29 and 30
/// only; the names of the rest follow pylabview and are unverified.
enum ViOptionFlag {
  taggedAndNotEdited(0),
  hideInstanceViCaption(1),

  /// Hidden from the hierarchy window and the unopened-sub-VI lists.
  systemVi(2),
  visibleVi(3),
  debugWindowVi(4),
  templateMask(5),

  /// Transactions are disabled: the VI is a template.
  suppressTransaction(6),

  /// A dynamic-dispatch VI that always calls its parent.
  alwaysCallsParent(7),
  undoRedoChangedNoTypes(8),

  /// The diagram is safe to inline.
  inlinableDiagram(9),

  /// The compiled code is saved in a separate file; the corpus sets it in 468 files that carry
  /// `VICD` and clears it in 217 that do not.
  sourceOnly(10),

  /// Inline into static callers when the diagram allows.
  inlineIfPossible(11),
  transactionFailing(12),

  /// SSE optimisation disabled.
  sseOptimisationOff(13),
  studentOnly(14),
  evaluationOnly(15),

  /// A polymorphic VI that adapts to the wired type.
  allowPolymorphicTypeAdapt(16),

  /// Inlined into static callers.
  shouldInline(17),
  recalculateFrontPanelDataSpace(18),

  /// Never set in the corpus, whose 53 polymorphic VIs carry [ViKind.polymorphic] instead.
  polymorphicVi(19),
  canPassClassToDll(20),
  undoRedoInProgress(21),

  /// Draw the instance icon rather than the polymorphic VI's.
  drawInstanceIcon(22),

  /// Show the polymorphic selector when the VI is dropped on a diagram.
  showPolymorphicSelector(23),

  /// Clear charts and other indicators when called.
  clearIndicatorsOnCall(24),
  defaultGrownView(25),
  doNotClone(26),
  privateDataForClass(27),

  /// An instance VI of an Express VI.
  instanceVi(28),

  /// Automatic error handling.
  defaultErrorHandling(29),
  remotePanel(30),
  suppressInstanceHalo(31);

  const ViOptionFlag(this.bit);

  final int bit;

  int get mask => 1 << bit;
}

/// Bits of `windowFlags`; bits 0, 2, 7, 8 and 10 to 15 are not named.
enum ViWindowFlag {
  /// Floating, or hidden when LabVIEW is not the active application; bit 9 repeats it.
  floating(1),

  /// The user may close the window.
  canClose(3),

  /// The user may resize the window.
  canResize(4),

  /// The user may minimise the window.
  canMinimize(5),

  /// The window runs transparently.
  transparent(6),
  floating9(9);

  const ViWindowFlag(this.bit);

  final int bit;

  int get mask => 1 << bit;
}

/// Bits of `hiddenButtons`, the toolbar buttons hidden while the VI runs; the other bits are
/// not named.
enum ViToolbarButton {
  run(0),
  runContinuously(5),
  abort(7);

  const ViToolbarButton(this.bit);

  final int bit;

  int get mask => 1 << bit;
}

/// Bits of `frontPanelFlags`; bits 9 and 11 to 15 are not named.
enum ViFrontPanelFlag {
  verticalScrollBar(0),
  horizontalScrollBar(1),
  titleBar(2),

  /// Show the toolbar while the VI runs.
  toolbar(3),

  /// Show the menu bar while the VI runs.
  menuBar(4),

  /// Centre the window when the VI runs; deprecated in LabVIEW 2019.
  autoCenter(5),

  /// Maximise the window when the VI runs; deprecated in LabVIEW 2019.
  sizeToScreen(6),

  /// No default run-time shortcut menus on front-panel objects.
  noRuntimePopup(7),

  /// Highlight the Boolean control whose shortcut key is Enter.
  markReturnButton(8),

  /// Keep the window's proportions across monitor resolutions.
  scaleProportionally(10);

  const ViFrontPanelFlag(this.bit);

  final int bit;

  int get mask => 1 << bit;
}

/// Bits of `stateFlags`; the other bits, several of which the corpus sets, are not named.
enum ViStateFlag {
  /// Breakpoints, probes, highlighting and single-stepping are allowed.
  debugCapable(9),

  /// Print the front panel every time the VI completes.
  printAfterExecution(15);

  const ViStateFlag(this.bit);

  final int bit;

  int get mask => 1 << bit;
}

/// The `priority` word. The corpus carries normal, aboveNormal, timeCritical and subroutine.
enum ViPriority {
  background(0),
  normal(1),
  aboveNormal(2),
  high(3),
  timeCritical(4),

  /// Set together with [ViStatusFlag.subroutine].
  subroutine(5);

  const ViPriority(this.code);

  final int code;

  static final Map<int, ViPriority> _byCode = {for (final value in values) value.code: value};

  static ViPriority? ofCode(int code) => _byCode[code];
}

/// The kind of VI a file holds, the `viType` word. The corpus carries standard, global, control
/// and polymorphic, each with its own connector-pane type (see `CONP`); the other values follow
/// pylabview's reading of the word.
enum ViKind {
  /// A dialog-box VI.
  dialog(0),

  /// A custom-probe VI.
  probe(1),

  /// A VI with a front panel and block diagram.
  standard(2),

  /// A clipboard VI.
  clipboard(3),

  /// The VI behind a global variable.
  global(4),

  /// A hierarchy VI.
  hierarchy(5),

  /// A custom control or indicator.
  control(6),

  /// A configuration VI.
  config(7),

  /// A proxy-caller VI.
  proxyCaller(8),

  /// A proxy-callee VI.
  proxyCallee(9),

  /// A simulation subsystem.
  subsystem(10),

  /// A polymorphic VI, whose instances are standard VIs named by `CPST`.
  polymorphic(11),

  /// An XControl facade.
  facade(12),

  /// An XControl method.
  method(13);

  const ViKind(this.code);

  final int code;

  static final Map<int, ViKind> _byCode = {for (final kind in values) kind.code: kind};

  static ViKind? ofCode(int code) => _byCode[code];
}

/// The `executionSystem` word. The corpus carries sameAsCaller, userInterface, standard and
/// instrumentIo; the rest follow LabVIEW's execution-system list in menu order.
enum ViExecutionSystem {
  sameAsCaller(-1),
  userInterface(0),
  standard(1),
  instrumentIo(2),
  dataAcquisition(3),
  other1(4),
  other2(5);

  const ViExecutionSystem(this.code);

  final int code;

  static final Map<int, ViExecutionSystem> _byCode = {for (final value in values) value.code: value};

  static ViExecutionSystem? ofCode(int code) => _byCode[code];
}

/// The `controlStyle` word: the palette style the editor creates controls and indicators in.
enum ViControlStyle {
  modern(0),
  classic(1),
  system(2),
  silver(3),

  /// Presumably the NXG style added in LabVIEW 2017: 326 of the 327 files that carry it were
  /// saved by 2017 or later.
  nxg(4);

  const ViControlStyle(this.code);

  final int code;

  static final Map<int, ViControlStyle> _byCode = {for (final value in values) value.code: value};

  static ViControlStyle? ofCode(int code) => _byCode[code];
}

final class ViSaveRecord extends ByteRecord {
  ViSaveRecord(Uint8List bytes) : super(bytes, layout) {
    assert(ViPriority.ofCode(_priority.read(view)) != null, 'the priority word is a known priority');
    assert(ViKind.ofCode(_viType.read(view)) != null, 'the VI kind word is a known kind');
    assert(ViExecutionSystem.ofCode(_executionSystem.read(view)) != null, 'the execution system is a known one');
    assert(ViControlStyle.ofCode(_controlStyle.read(view)) != null, 'the control style is a known one');
  }

  /// Saving LabVIEW version; repeats the numeric part of `vers`.
  ViVersionWord get versionWord => ViVersionWord.at(view, _versionWord.offset);

  /// Bit set named by [ViStatusFlag].
  int get statusFlagWord => _statusFlags.read(view);

  Set<ViStatusFlag> get statusFlags => _flagsIn(statusFlagWord, ViStatusFlag.values, (f) => f.mask);

  /// Bit set named by [ViOptionFlag].
  int get optionFlagWord => _optionFlags.read(view);

  Set<ViOptionFlag> get optionFlags => _flagsIn(optionFlagWord, ViOptionFlag.values, (f) => f.mask);

  /// Automatically handle menu selections when the VI opens and runs.
  bool get autoHandlesMenus => _flags12.read(view) & _autoHandleMenusMask != 0;

  /// Bit set named by [ViWindowFlag].
  int get windowFlagWord => _windowFlags.read(view);

  Set<ViWindowFlag> get windowFlags => _flagsIn(windowFlagWord, ViWindowFlag.values, (f) => f.mask);

  /// Bit set named by [ViToolbarButton]: the toolbar buttons hidden while the VI runs.
  int get hiddenButtonWord => _hiddenButtons.read(view);

  Set<ViToolbarButton> get hiddenButtons => _flagsIn(hiddenButtonWord, ViToolbarButton.values, (f) => f.mask);

  /// Bit set named by [ViFrontPanelFlag].
  int get frontPanelFlagWord => _frontPanelFlags.read(view);

  Set<ViFrontPanelFlag> get frontPanelFlags => _flagsIn(frontPanelFlagWord, ViFrontPanelFlag.values, (f) => f.mask);

  /// Bit set named by [ViStateFlag].
  int get stateFlagWord => _stateFlags.read(view);

  Set<ViStateFlag> get stateFlags => _flagsIn(stateFlagWord, ViStateFlag.values, (f) => f.mask);

  /// The priority the VI runs at.
  ViPriority get priority => ViPriority.ofCode(_priority.read(view))!;

  /// The kind of VI the file holds.
  ViKind get kind => ViKind.ofCode(_viType.read(view))!;

  /// The execution system the VI prefers.
  ViExecutionSystem get executionSystem => ViExecutionSystem.ofCode(_executionSystem.read(view))!;

  /// Front-panel alignment grid in pixels, 12 by default.
  int get frontPanelGrid => _frontPanelGrid.read(view);

  /// Block-diagram alignment grid in pixels, 16 by default.
  int get blockDiagramGrid => _blockDiagramGrid.read(view);

  /// The palette style new controls and indicators take.
  ViControlStyle get controlStyle => ViControlStyle.ofCode(_controlStyle.read(view))!;

  /// Saving LabVIEW version as the word stores it.
  int get versionWordBits => _versionWord.read(view);

  /// Bit 2 is `autoHandlesMenus`; the others are clear in all but two files.
  int get flags12 => _flags12.read(view);

  /// 3, or 1 in 35 files; role TODO.
  int get unknown16 => _unknown16.read(view);

  /// 0 to 5, 1 in all but 586 files; role TODO.
  int get unknown28 => _unknown28.read(view);

  /// Zero in all but 5 files, where two four-character codes repeat and a 2 or 3 follows; roles
  /// TODO.
  Uint8List get unknown40 => _unknown40.read(view);

  /// Digest-like: distinct in 8048 of 8316 files; role TODO.
  Uint8List get unknown52 => _unknown52.read(view);

  /// Zero in all but 53 files; role TODO.
  int get unknown76 => _unknown76.read(view);

  /// Digest-like: distinct in 8048 of 8316 files, equal to `unknown52` in 12; role TODO.
  Uint8List get unknown80 => _unknown80.read(view);

  /// `MD5("")` in every corpus file; role TODO; null in a shorter record.
  Uint8List? get unknown96 => _unknown96.isIn(view) ? _unknown96.read(view) : null;

  /// 0x1000, 0 or 0x4000; role TODO; null in a shorter record.
  int? get unknown112 => _unknown112.isIn(view) ? _unknown112.read(view) : null;

  /// Zero in all but 16 files, where it is -2 to 2; role TODO; null in a shorter record.
  int? get unknown116 => _unknown116.isIn(view) ? _unknown116.read(view) : null;

  /// Digest-like: distinct in 7831 of 8065 files, zero in 207; role TODO; null in a shorter
  /// record.
  Uint8List? get unknown120 => _unknown120.isIn(view) ? _unknown120.read(view) : null;

  /// 0, 1 or 2; role TODO; null in a shorter record.
  int? get unknown136 => _unknown136.isIn(view) ? _unknown136.read(view) : null;

  /// Zero; null in a shorter record.
  Uint8List? get unknown137 => _unknown137.isIn(view) ? _unknown137.read(view) : null;

  /// 0xFFFFFFFF, or 0 in 403 files; role TODO; null in a shorter record.
  int? get unknown140 => _unknown140.isIn(view) ? _unknown140.read(view) : null;

  /// `MD5("")` in 5037 of 6158 files, zero in 409, 527 distinct values; role TODO; null in a
  /// shorter record.
  Uint8List? get unknown144 => _unknown144.isIn(view) ? _unknown144.read(view) : null;

  /// A record of the given fields, as long as the last optional one given.
  static Uint8List encode({
    required int versionWord,
    required int statusFlags,
    required int optionFlags,
    required int flags12,
    required int unknown16,
    required int windowFlags,
    required int hiddenButtons,
    required int frontPanelFlags,
    required int stateFlags,
    required int unknown28,
    required ViPriority priority,
    required ViKind viType,
    required ViExecutionSystem executionSystem,
    required List<int> unknown40,
    required List<int> unknown52,
    required int frontPanelGrid,
    required int blockDiagramGrid,
    required int unknown76,
    required ViControlStyle controlStyle,
    required List<int> unknown80,
    List<int>? unknown96,
    int? unknown112,
    int? unknown116,
    List<int>? unknown120,
    int? unknown136,
    List<int>? unknown137,
    int? unknown140,
    List<int>? unknown144,
  }) {
    final optional = [unknown96, unknown112, unknown116, unknown120, unknown136, unknown137, unknown140, unknown144];
    final present = optional.lastIndexWhere((field) => field != null) + 1;
    assert(optional.take(present).every((field) => field != null), 'the optional fields given are a prefix');
    final out = Uint8List(
      present == 0 ? _unknown80.end : layout.fields[layout.fields.indexOf(_unknown96) + present - 1].end,
    );
    final view = ByteData.sublistView(out);
    _versionWord.write(view, versionWord);
    _statusFlags.write(view, statusFlags);
    _optionFlags.write(view, optionFlags);
    _flags12.write(view, flags12);
    _unknown16.write(view, unknown16);
    _windowFlags.write(view, windowFlags);
    _hiddenButtons.write(view, hiddenButtons);
    _frontPanelFlags.write(view, frontPanelFlags);
    _stateFlags.write(view, stateFlags);
    _unknown28.write(view, unknown28);
    _priority.write(view, priority.code);
    _viType.write(view, viType.code);
    _executionSystem.write(view, executionSystem.code);
    _unknown40.write(view, unknown40);
    _unknown52.write(view, unknown52);
    _frontPanelGrid.write(view, frontPanelGrid);
    _blockDiagramGrid.write(view, blockDiagramGrid);
    _unknown76.write(view, unknown76);
    _controlStyle.write(view, controlStyle.code);
    _unknown80.write(view, unknown80);
    if (unknown96 != null) _unknown96.write(view, unknown96);
    if (unknown112 != null) _unknown112.write(view, unknown112);
    if (unknown116 != null) _unknown116.write(view, unknown116);
    if (unknown120 != null) _unknown120.write(view, unknown120);
    if (unknown136 != null) _unknown136.write(view, unknown136);
    if (unknown137 != null) _unknown137.write(view, unknown137);
    if (unknown140 != null) _unknown140.write(view, unknown140);
    if (unknown144 != null) _unknown144.write(view, unknown144);
    return out;
  }

  static const _autoHandleMenusMask = 1 << 2;

  // dart format off
  static const _versionWord = U32(0);
  static const _statusFlags = U32(4);
  static const _optionFlags = U32(8);
  static const _flags12 = U32(12); // Bit 2 is `autoHandlesMenus`; the others are clear in all but two files.
  static const _unknown16 = U16(16); // 3, or 1 in 35 files; role TODO.
  static const _windowFlags = U16(18);
  static const _hiddenButtons = U16(20);
  static const _frontPanelFlags = U16(22);
  static const _stateFlags = U32(24);
  static const _unknown28 = U32(28); // 0 to 5, 1 in all but 586 files; role TODO.
  static const _priority = U16(32);
  static const _viType = U16(34);
  static const _executionSystem = I32(36);
  static const _unknown40 = Unknown(40, size: 12); // Zero in all but 5 files, where two four-character codes repeat and a 2 or 3 follows; roles TODO.
  static const _unknown52 = Unknown(52, size: 16); // Digest-like: distinct in 8048 of 8316 files; role TODO.
  static const _frontPanelGrid = U32(68);
  static const _blockDiagramGrid = U32(72);
  static const _unknown76 = U16(76); // Zero in all but 53 files; role TODO.
  static const _controlStyle = U16(78);
  static const _unknown80 = Unknown(80, size: 16); // Digest-like: distinct in 8048 of 8316 files, equal to `unknown52` in 12; role TODO.
  static const _unknown96 = Unknown(96, size: 16, optional: true); // `MD5("")` in every corpus file; role TODO.
  static const _unknown112 = U32(112, optional: true); // 0x1000, 0 or 0x4000; role TODO.
  static const _unknown116 = I32(116, optional: true); // Zero in all but 16 files, where it is -2 to 2; role TODO.
  static const _unknown120 = Unknown(120, size: 16, optional: true); // Digest-like: distinct in 7831 of 8065 files, zero in 207; role TODO.
  static const _unknown136 = U8(136, optional: true); // 0, 1 or 2; role TODO.
  static const _unknown137 = Unknown(137, size: 3, optional: true); // Zero.
  static const _unknown140 = U32(140, optional: true); // 0xFFFFFFFF, or 0 in 403 files; role TODO.
  static const _unknown144 = Unknown(144, size: 16, optional: true); // `MD5("")` in 5037 of 6158 files, zero in 409, 527 distinct values; role TODO.

  static const layout = ByteLayout([_versionWord, _statusFlags, _optionFlags, _flags12, _unknown16, _windowFlags, _hiddenButtons, _frontPanelFlags, _stateFlags, _unknown28, _priority, _viType, _executionSystem, _unknown40, _unknown52, _frontPanelGrid, _blockDiagramGrid, _unknown76, _controlStyle, _unknown80, _unknown96, _unknown112, _unknown116, _unknown120, _unknown136, _unknown137, _unknown140, _unknown144]);
  // dart format on
}

Set<T> _flagsIn<T>(int word, List<T> values, int Function(T) maskOf) => {
  for (final value in values)
    if (word & maskOf(value) != 0) value,
};
