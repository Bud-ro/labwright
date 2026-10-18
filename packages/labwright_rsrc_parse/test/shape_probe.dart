import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// The nullable view of a heap object the tests probe with: each getter answers for the shapes
/// that carry the field and is null, empty or unknown for the rest.
extension HeapObjectProbe on HeapObject {
  HeapRect? get absBounds => this is HeapPlaced ? (this as HeapPlaced).absBounds : null;

  HeapRect? get bounds => this is HeapPlaced ? (this as HeapPlaced).bounds : null;

  int? get boundsOffset => this is HeapPlaced ? (this as HeapPlaced).boundsOffset : null;

  HeapCaption? get caption => this is HeapCaptioned ? (this as HeapCaptioned).caption : null;

  String? get label => caption?.text;

  int? get labelOffset => caption?.recordOffset;

  int get labelLength => caption?.recordLength ?? 0;

  ViTypeKind get typeKind => this is HeapTypeBearer ? (this as HeapTypeBearer).typeKind : ViTypeKind.unknown;

  ViResolvedType? get resolvedType => this is HeapTypeBearer ? (this as HeapTypeBearer).resolvedType : null;

  ViDataType? get dataType => resolvedType?.kind;

  String? get typeName => resolvedType?.name;

  int? get typeDescIdx => this is HeapTyped ? (this as HeapTyped).typeDescIdx : null;

  List<String> get items => this is HeapItems ? (this as HeapItems).items : const [];

  bool get isLabelHidden => this is HeapTextLabel && (this as HeapTextLabel).isHidden;

  List<HeapFontRun> get textStyleRuns => this is HeapFontRuns ? (this as HeapFontRuns).fontRuns : const [];

  ViFontEntry? get labelFont => this is HeapFontRuns ? (this as HeapFontRuns).font : null;

  int get termCount => switch (this) {
    BdPlaced(:final termCount) || FpPlaced(:final termCount) => termCount,
    _ => 0,
  };

  int? get bgRgb => switch (this) {
    BdFrame(:final bgRgb) ||
    BdStructure(:final bgRgb) ||
    BdControlBody(:final bgRgb) ||
    BdText(:final bgRgb) ||
    BdPart(:final bgRgb) ||
    BdScriptNode(:final bgRgb) ||
    BdScriptTerminal(:final bgRgb) ||
    FpControl(:final bgRgb) ||
    FpText(:final bgRgb) ||
    FpPart(:final bgRgb) => bgRgb,
    _ => null,
  };

  int? get fgRgb => switch (this) {
    BdFrame(:final fgRgb) ||
    BdStructure(:final fgRgb) ||
    BdControlBody(:final fgRgb) ||
    BdText(:final fgRgb) ||
    BdPart(:final fgRgb) ||
    BdScriptNode(:final fgRgb) ||
    BdScriptTerminal(:final fgRgb) ||
    FpControl(:final fgRgb) ||
    FpText(:final fgRgb) ||
    FpPart(:final fgRgb) => fgRgb,
    _ => null,
  };

  int? get contentRgb => switch (this) {
    BdFrame(:final contentRgb) ||
    BdStructure(:final contentRgb) ||
    BdControlBody(:final contentRgb) ||
    BdText(:final contentRgb) ||
    BdPart(:final contentRgb) ||
    BdScriptNode(:final contentRgb) ||
    BdScriptTerminal(:final contentRgb) ||
    FpControl(:final contentRgb) ||
    FpText(:final contentRgb) ||
    FpPart(:final contentRgb) => contentRgb,
    _ => null,
  };
}

extension BdObjectProbe on BdObject {
  BdConstant? get constant => this is BdConstant ? this as BdConstant : null;

  BdMultiFrameStructure? get frames => this is BdMultiFrameStructure ? this as BdMultiFrameStructure : null;

  BdCaseStructure? get caseFrames => this is BdCaseStructure ? this as BdCaseStructure : null;

  BdSignal? get signal => this is BdSignal ? this as BdSignal : null;

  BdPrimitive? get primitive => this is BdPrimitive ? this as BdPrimitive : null;

  BdPanelTerminal? get panelTerminal => this is BdPanelTerminal ? this as BdPanelTerminal : null;

  int? get structRgb => this is BdStructure ? (this as BdStructure).structRgb : null;

  HeapRect? get termBounds => this is BdTerminal ? (this as BdTerminal).termBounds : null;

  int? get termBmp => this is BdTerminal ? (this as BdTerminal).termBmp : null;

  int? get arrayIndex => this is BdContainer ? (this as BdContainer).arrayIndex : null;

  String? get displayFormat => this is BdNumericDisplay ? (this as BdNumericDisplay).displayFormat : null;
}

extension FpObjectProbe on FpObject {
  FpGraph? get graph => this is FpGraph ? this as FpGraph : null;

  FpNumericControl? get numericRange => this is FpNumericControl ? this as FpNumericControl : null;

  int? get borderRgb => switch (this) {
    FpControl(:final borderRgb) || FpPart(:final borderRgb) => borderRgb,
    _ => null,
  };

  String? get displayFormat => this is FpPart ? (this as FpPart).displayFormat : null;
}
