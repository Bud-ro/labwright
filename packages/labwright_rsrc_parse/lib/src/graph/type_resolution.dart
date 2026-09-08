part of '../graph.dart';

void resolveDataSpaceTypes({
  required List<ViType> pool,
  required List<int> table,
  required int? typeIndexBase,
  required List<ViDiagram> blockDiagrams,
  required List<ViDiagram> frontPanelDiagrams,
}) {
  final diagrams = [...blockDiagrams, ...frontPanelDiagrams];

  ViHeapObject? findDco(ViDiagram own, int oid) {
    final local = own.byId[oid];
    if (local != null) return local;
    for (final diagram in diagrams) {
      if (identical(diagram, own)) continue;
      final hit = diagram.byId[oid];
      if (hit != null) return hit;
    }
    return null;
  }

  for (final diagram in diagrams) {
    for (final object in diagram.objects) {
      if (object.objectClass == HeapObjectClass.node && object.typeDescIdx != null) {
        object.isIndicator = ((object.objFlags ?? 0) & 1) != 0;
      }
    }
  }
  for (final diagram in diagrams) {
    for (final object in diagram.objects) {
      if (object.isIndicator != null) continue;
      final dcoRefs = object.typedRefs[HeapRefKind.dcoRef];
      if (dcoRefs == null || dcoRefs.isEmpty) continue;
      object.isIndicator = findDco(diagram, dcoRefs.first)?.isIndicator;
    }
  }

  _resolveTypeIndices(pool: pool, table: table, base: typeIndexBase, diagrams: diagrams, findDco: findDco);

  for (final diagram in diagrams) {
    decodeBdConstValues(diagram);
  }
}

void _resolveTypeIndices({
  required List<ViType> pool,
  required List<int> table,
  required int? base,
  required List<ViDiagram> diagrams,
  required ViHeapObject? Function(ViDiagram own, int oid) findDco,
}) {
  if (pool.isEmpty || table.isEmpty || base == null) return;

  ViType? resolve(int base, int index) {
    final tableIndex = base + index;
    if (tableIndex < 0 || tableIndex >= table.length) return null;
    final poolIndex = table[tableIndex];
    return poolIndex >= 0 && poolIndex < pool.length ? pool[poolIndex] : null;
  }

  for (final diagram in diagrams) {
    for (final object in diagram.objects) {
      final index = object.typeDescIdx;
      if (index == null) continue;
      final type = resolve(base, index);
      if (type == null) continue;
      final kind = typeKindOfDataType(type.kind);
      if (kind != null) object.typeKind = kind;
      object.dataType = type.kind;
      object.resolvedType = type;
      final elementIndex = type.elementIndex;
      if (type.kind == ViDataType.array && elementIndex != null && elementIndex >= 0 && elementIndex < pool.length) {
        object.resolvedElementType = pool[elementIndex];
        if (object.resolvedElementType!.kind == ViDataType.cluster) {
          object.resolvedElementMembers = clusterFields(object.resolvedElementType!, pool);
        }
      }
      if (type.kind == ViDataType.cluster) {
        object.resolvedMembers = clusterFields(type, pool);
      }
      if (type.name != null && type.name!.trim().isNotEmpty) {
        object.typeName ??= type.name!.trim();
      }
    }
  }
  for (final diagram in diagrams) {
    for (final object in diagram.objects) {
      if (object.typeDescIdx != null) continue;
      final dcoRefs = object.typedRefs[HeapRefKind.dcoRef];
      if (dcoRefs == null || dcoRefs.isEmpty) continue;
      final dco = findDco(diagram, dcoRefs.first);
      if (dco == null) continue;
      if (dco.typeKind != ViTypeKind.unknown) object.typeKind = dco.typeKind;
      object.dataType ??= dco.dataType;
      object.resolvedType ??= dco.resolvedType;
      object.resolvedElementType ??= dco.resolvedElementType;
      if (object.resolvedMembers.isEmpty) {
        object.resolvedMembers = dco.resolvedMembers;
      }
      if (object.resolvedElementMembers.isEmpty) {
        object.resolvedElementMembers = dco.resolvedElementMembers;
      }
      object.typeName ??= dco.typeName;
    }
  }
}
