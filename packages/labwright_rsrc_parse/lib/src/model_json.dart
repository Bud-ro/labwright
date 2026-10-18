import 'block_diagram/bd_diagram.dart';
import 'block_diagram/bd_object.dart';
import 'blocks/VCTP_type_pool.dart';
import 'front_panel/fp_object.dart';
import 'front_panel/fp_panel.dart';
import 'heap/heap.dart';
import 'heap/heap_object.dart';
import 'model.dart';

Map<String, Object?> bdDiagramToJson(BdDiagram diagram) => {
  'objects': [for (final object in diagram.objects) _bdObjectToJson(object)],
};

Map<String, Object?> fpPanelToJson(FpPanel panel) => {
  'objects': [for (final object in panel.objects) _fpObjectToJson(object)],
};

Map<String, Object?> _heapObjectToJson(HeapObject object, {required String? label, required Iterable<int> memberOids}) {
  final typed = object is HeapTypeBearer ? object : null;
  final items = object is HeapItems ? object.items : const <String>[];
  return {
    'oid': object.oid,
    'kindCode': object.kind,
    'typeKind': (typed?.typeKind ?? ViTypeKind.unknown).name,
    if (typed?.dataType != null) 'dataType': typed!.dataType!.name,
    if (typed?.typeName != null) 'typeName': typed!.typeName,
    if (object.parentOid != null) 'parentOid': object.parentOid,
    if (label != null) 'label': label,
    if (object case HeapTextLabel(isHidden: true)) 'labelHidden': true,
    if (object case HeapPlaced(:final bounds, :final absBounds)) ...{
      'bounds': _rectToJson(bounds),
      'absBounds': _rectToJson(absBounds),
    },
    if (items.isNotEmpty) 'items': items,
    if (object case BdPlaced(:final termCount) || FpPlaced(:final termCount) when termCount != 0)
      'termCount': termCount,
    if (memberOids.isNotEmpty) 'memberOids': memberOids.toList(),
    if (object.helpText != null) 'helpText': object.helpText,
  };
}

Map<String, Object?> _bdObjectToJson(BdObject object) {
  final cls = object.objectClass;
  return {
    ..._heapObjectToJson(object, label: object.label, memberOids: object.memberOids),
    'class': {'label': cls.label, 'category': cls.category.name, 'confidence': cls.confidence.name},
    'objectKind': object.category.name,
    if (object case BdPrimitive(:final primResId, :final primName)) ...{
      'primResId': primResId,
      if (primName != null) 'primName': primName,
    },
    if (object case BdMultiFrameStructure(dIdx: final dIdx?)) 'visibleFrameIndex': dIdx,
    if (object case BdConstant(:final text, :final numeric, :final boolValue)) ...{
      if (text != null) 'constText': text,
      if (numeric != null) 'constNumeric': numeric,
      if (boolValue != null) 'constBool': boolValue,
    },
  };
}

Map<String, Object?> _fpObjectToJson(FpObject object) {
  final cls = object.objectClass;
  return {
    ..._heapObjectToJson(object, label: object.label, memberOids: object.refs),
    'class': {'label': cls.label, 'category': cls.category.name, 'confidence': cls.confidence.name},
    'objectKind': object.category.name,
    if (object case FpNumericControl(:final min, :final max)) ...{
      if (min?.isFinite ?? false) 'controlMin': min,
      if (max?.isFinite ?? false) 'controlMax': max,
    },
  };
}

Map<String, Object?> _rectToJson(HeapRect r) => {
  'top': r.top,
  'left': r.left,
  'bottom': r.bottom,
  'right': r.right,
};

List<Map<String, Object?>>? _conpaneTerminals(ViModel m) {
  final pane = m.connectorPaneType;
  if (pane is! ViFunctionType) return null;
  for (var i = 0; i < pane.parameterCount; i++) {
    if (pane.parameterIndexAt(i) >= m.types.length) return null;
  }
  return [for (var i = 0; i < pane.parameterCount; i++) _termJson(m.types[pane.parameterIndexAt(i)], m.types)];
}

Map<String, Object?> _termJson(ViType t, List<ViType> types) => {
  'kind': typeLabel(t, types),
  if (t.label != null) 'name': t.label,
};

Map<String, Object?> viModelToJson(ViModel m) {
  final terminals = _conpaneTerminals(m);
  final named = namedTypes(m.types);
  final symbolNames = _dedupe([
    for (final d in m.blockDiagrams)
      for (final o in d.nodes)
        if (o is BdForeignCall) o.entryPoint,
  ]);
  final libraryPaths = _dedupe([
    for (final d in m.blockDiagrams)
      for (final o in d.nodes)
        if (o is BdForeignCall) o.libraryPath,
  ]);
  return {
    if (m.version != null) 'labviewVersion': m.version,
    if (m.title != null) 'title': m.title,
    if (symbolNames.isNotEmpty) 'symbolNames': symbolNames,
    if (libraryPaths.isNotEmpty) 'libraryPaths': libraryPaths,
    if (m.subViNames.isNotEmpty) 'subViNames': m.subViNames,
    if (terminals != null) 'connectorPaneTerminals': terminals,
    if (m.types.isNotEmpty) ...{
      'typeCount': m.types.length,
      'typeHistogram': typeKindHistogram(m.types),
    },
    if (named.isNotEmpty)
      'namedTypes': [
        for (final type in named.take(200))
          {
            'index': m.types.indexOf(type),
            'kind': typeLabel(type, m.types),
            'name': type.label,
            if (type is ViClusterType)
              'members': [
                for (final field in clusterFields(type, m.types)) _termJson(field, m.types),
              ],
            if (type is ViEnumType) 'items': type.items,
          },
      ],
    'blockDiagrams': [for (final diagram in m.blockDiagrams) bdDiagramToJson(diagram)],
    'frontPanels': [for (final panel in m.frontPanels) fpPanelToJson(panel)],
  };
}

List<String> _dedupe(Iterable<String?> values) {
  final seen = <String>{};
  return [
    for (final value in values)
      if (value != null && seen.add(value)) value,
  ];
}
