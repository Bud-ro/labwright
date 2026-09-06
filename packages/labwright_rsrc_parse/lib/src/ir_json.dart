import 'blocks/type_pool.dart';
import 'graph.dart';
import 'heap.dart';
import 'ir.dart';

Map<String, Object?> viDiagramToJson(ViDiagram d) => {
  'sectionTag': d.sectionTag,
  'objects': d.objects.map(_objectToJson).toList(),
};

Map<String, Object?> _objectToJson(ViHeapObject object) {
  final cls = object.objectClass;
  final primName = object.primName;
  return {
    'oid': object.oid,
    'kindCode': object.kind,
    'class': {
      'label': cls.label,
      'category': cls.category.name,
      'confidence': cls.confidence.name,
    },
    'objectKind': object.category.name,
    'typeKind': object.typeKind.name,
    if (object.dataType != null) 'dataType': object.dataType!.name,
    if (object.typeName != null) 'typeName': object.typeName,
    if (object.primResId != null) 'primResId': object.primResId,
    if (primName != null) 'primName': primName,
    if (object.parentOid != null) 'parentOid': object.parentOid,
    if (object.label != null) 'label': object.label,
    if (object.isLabelHidden) 'labelHidden': true,
    if (object.dIdx != null) 'visibleFrameIndex': object.visibleFrameIndex,
    if (object.bounds != null) 'bounds': _rectToJson(object.bounds!),
    if (object.absBounds != null) 'absBounds': _rectToJson(object.absBounds!),
    if (object.items.isNotEmpty) 'items': object.items,
    if (object.termCount != 0) 'termCount': object.termCount,
    if (object.memberOids.isNotEmpty) 'memberOids': object.memberOids.toList(),
    if (object.controlMin?.isFinite ?? false) 'controlMin': object.controlMin,
    if (object.controlMax?.isFinite ?? false) 'controlMax': object.controlMax,
    if (object.helpText != null) 'helpText': object.helpText,
    if (object.constText != null) 'constText': object.constText,
    if (object.constNumeric != null) 'constNumeric': object.constNumeric,
    if (object.constBool != null) 'constBool': object.constBool,
  };
}

Map<String, Object?> _rectToJson(HeapRect r) => {
  'top': r.top,
  'left': r.left,
  'bottom': r.bottom,
  'right': r.right,
};

List<Map<String, Object?>>? _conpaneTerminals(ViModel m) {
  final typeIndex = m.connectorPaneTypeIndex;
  if (typeIndex == null || typeIndex < 1 || typeIndex > m.types.length) return null;
  final conpaneType = m.types[typeIndex - 1];
  final terms = conpaneType.kind == ViDataType.cluster ? clusterFields(conpaneType, m.types) : <ViType>[conpaneType];
  return [for (final term in terms) _termJson(term, m.types)];
}

Map<String, Object?> _termJson(ViType t, List<ViType> types) => {
  'kind': typeLabel(t, types),
  if (t.name != null) 'name': t.name,
};

Map<String, Object?> viModelToJson(ViModel m) {
  final terminals = _conpaneTerminals(m);
  final named = namedTypes(m.types);
  return {
    if (m.version != null) 'labviewVersion': m.version,
    if (m.title != null) 'title': m.title,
    if (m.description != null) 'description': m.description,
    if (m.symbolNames.isNotEmpty) 'symbolNames': m.symbolNames,
    if (m.paths.isNotEmpty) 'libraryPaths': m.paths,
    if (m.subViNames.isNotEmpty) 'subViNames': m.subViNames,
    if (m.connectorPaneTypeIndex != null) 'connectorPaneTypeIndex': m.connectorPaneTypeIndex,
    if (terminals != null) 'connectorPaneTerminals': terminals,
    if (m.types.isNotEmpty) ...{
      'typeCount': m.types.length,
      'typeHistogram': typeKindHistogram(m.types),
    },
    if (named.isNotEmpty)
      'namedTypes': [
        for (final type in named.take(200))
          {
            'index': type.index,
            'kind': typeLabel(type, m.types),
            'name': type.name,
            if (type.members.isNotEmpty)
              'members': [
                for (final field in clusterFields(type, m.types)) _termJson(field, m.types),
              ],
            if (type.enumItems.isNotEmpty) 'items': type.enumItems,
          },
      ],
    'blockDiagrams': [for (final diagram in m.blockDiagrams) viDiagramToJson(diagram)],
    'frontPanelDiagrams': [for (final diagram in m.frontPanelDiagrams) viDiagramToJson(diagram)],
  };
}
