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

Map<String, Object?> _heapObjectToJson(HeapObject object) => {
  'oid': object.oid,
  'kindCode': object.kind,
  'typeKind': object.typeKind.name,
  if (object.dataType != null) 'dataType': object.dataType!.name,
  if (object.typeName != null) 'typeName': object.typeName,
  if (object.parentOid != null) 'parentOid': object.parentOid,
  if (object.label != null) 'label': object.label,
  if (object.isLabelHidden) 'labelHidden': true,
  if (object.bounds != null) 'bounds': _rectToJson(object.bounds!),
  if (object.absBounds != null) 'absBounds': _rectToJson(object.absBounds!),
  if (object.items.isNotEmpty) 'items': object.items,
  if (object.termCount != 0) 'termCount': object.termCount,
  if (object.memberOids.isNotEmpty) 'memberOids': object.memberOids.toList(),
  if (object.helpText != null) 'helpText': object.helpText,
};

Map<String, Object?> _bdObjectToJson(BdObject object) {
  final cls = object.objectClass;
  final primitive = object.primitive;
  final constant = object.constant;
  return {
    ..._heapObjectToJson(object),
    'class': {'label': cls.label, 'category': cls.category.name, 'confidence': cls.confidence.name},
    'objectKind': object.category.name,
    if (primitive?.primResId != null) 'primResId': primitive!.primResId,
    if (primitive?.primName != null) 'primName': primitive!.primName,
    if (object.frames?.dIdx != null) 'visibleFrameIndex': object.frames!.visibleFrameIndex,
    if (constant?.text != null) 'constText': constant!.text,
    if (constant?.numeric != null) 'constNumeric': constant!.numeric,
    if (constant?.boolValue != null) 'constBool': constant!.boolValue,
  };
}

Map<String, Object?> _fpObjectToJson(FpObject object) {
  final cls = object.objectClass;
  final range = object.numericRange;
  return {
    ..._heapObjectToJson(object),
    'class': {'label': cls.label, 'category': cls.category.name, 'confidence': cls.confidence.name},
    'objectKind': object.category.name,
    if (range?.min?.isFinite ?? false) 'controlMin': range!.min,
    if (range?.max?.isFinite ?? false) 'controlMax': range!.max,
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
      for (final o in d.objects) o.foreignCall?.entryPoint,
  ]);
  final libraryPaths = _dedupe([
    for (final d in m.blockDiagrams)
      for (final o in d.objects) o.foreignCall?.libraryPath,
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
