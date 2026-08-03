/// The **VI-to-Dart type model**: what a LabVIEW VI's data types become in
/// Dart, ahead of any code generation.
///
/// A VI's consolidated type pool ([ViType], decoded by `labwright_rsrc_parse`)
/// is the input; [mapLvType] is the answer for one entry, and every entry
/// resolves to exactly one of *mapped*, *not a value*, or *awaiting a decision*
/// ([LvMapStatus]) — so a corpus sweep can prove nothing is silently missing.
///
/// Three parts carry the weight:
///
/// - [LvNumericKind] — the width model. LabVIEW's integer widths are
///   load-bearing (a U32 `a + b` truncates at 32 bits; a digest that carries
///   into bit 32 is simply wrong), so every numeric kind states its Dart
///   carrier, the expression that renormalizes a result ([LvNumericKind.wrap]),
///   and the Dart operators that misread it ([LvArithmeticHazard]).
/// - [lvArrayDartType] and [lvArrayBuilderType] — arrays as exact-width typed
///   lists, with a stated rule for how a fixed-length list carries LabVIEW's
///   dynamically resizing arrays.
/// - [LvErrorMode] and [lvSignature] — error clusters as thrown exceptions
///   (default) or as threaded values (opt-in), the choice that changes
///   function signatures.
library;

export 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart'
    show
        DecodedSection,
        HeapRefKind,
        TypeCode,
        ViDataType,
        ViDiagram,
        ViHeapObject,
        ViModel,
        ViObjectKind,
        ViSignalType,
        ViType,
        buildViModelFromDecoded,
        clusterFields,
        decodeSections,
        decodeTypePool;

export 'src/dataflow_ir.dart';
export 'src/emit.dart';
export 'src/error_mode.dart';
export 'src/naming.dart';
export 'src/numeric.dart';
export 'src/prim_map.dart';
export 'src/runtime.dart';
export 'src/subvi.dart';
export 'src/type_map.dart';
export 'src/wire_type.dart';
