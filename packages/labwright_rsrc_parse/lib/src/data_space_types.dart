/// The join between a VI's heaps and its type pool: every object's `typeDescIndex` names an
/// entry of the data-space type map (`TM80`), which names a pool type; a block-diagram
/// terminal without one takes the type of the data object its `dcoRef` names, which may sit on
/// the front panel.
library;

import 'block_diagram/bd_build.dart';
import 'block_diagram/bd_diagram.dart';
import 'blocks/VCTP_type_pool.dart';
import 'front_panel/fp_object.dart';
import 'front_panel/fp_panel.dart';
import 'heap/heap.dart';
import 'heap/heap_object.dart';

/// The data-space type map over a pool: resolves a `typeDescIndex` to its pool type.
class ViDataSpaceTypes {
  const ViDataSpaceTypes({required this.pool, required this.table, required this.typeIndexBase});

  final List<ViType> pool;

  /// The data-space type map, one pool index per entry.
  final List<int> table;

  /// What `DTHP` adds to a `typeDescIndex` before it indexes [table]; null leaves every
  /// index unresolved.
  final int? typeIndexBase;

  bool get resolvable => pool.isNotEmpty && table.isNotEmpty && typeIndexBase != null;

  ViResolvedType? resolve(int typeDescIdx) {
    final base = typeIndexBase;
    if (base == null) return null;
    final ti = base + typeDescIdx;
    if (ti < 0 || ti >= table.length) return null;
    final pi = table[ti];
    return pi >= 0 && pi < pool.length ? ViResolvedType.inPool(pool[pi], pool) : null;
  }
}

void _resolveOwn(HeapObject object, ViDataSpaceTypes types) {
  final index = object.typeDescIdx;
  if (index == null) return;
  final resolved = types.resolve(index);
  if (resolved == null) return;
  final kind = typeKindOfDataType(resolved.kind);
  if (kind != null) object.typeKind = kind;
  object.resolvedType = resolved;
}

/// Resolves every panel object's own type index.
void resolvePanelTypes(List<FpPanel> panels, ViDataSpaceTypes types) {
  if (!types.resolvable) return;
  for (final panel in panels) {
    for (final object in panel.objects) {
      _resolveOwn(object, types);
    }
  }
}

/// Resolves every diagram object's own type index, copies a data object's type and direction
/// to the terminals that reference it through `dcoRef`, on the diagram or the panels, then
/// decodes constant values.
void resolveDiagramTypes(List<BdDiagram> diagrams, List<FpPanel> panels, ViDataSpaceTypes types) {
  HeapObject? findDco(BdDiagram own, int oid) {
    final local = own.byId[oid];
    if (local != null) return local;
    for (final panel in panels) {
      final hit = panel.byId[oid];
      if (hit != null) return hit;
    }
    for (final diagram in diagrams) {
      if (identical(diagram, own)) continue;
      final hit = diagram.byId[oid];
      if (hit != null) return hit;
    }
    return null;
  }

  if (types.resolvable) {
    for (final diagram in diagrams) {
      for (final object in diagram.objects) {
        _resolveOwn(object, types);
      }
    }
  }
  for (final diagram in diagrams) {
    for (final object in diagram.objects) {
      final dcoRefs = object.refsOf(HeapRefKind.dcoRef);
      if (dcoRefs == null || dcoRefs.isEmpty) continue;
      final dco = findDco(diagram, dcoRefs.first);
      if (dco == null) continue;
      if (object.panelTerminal case final terminal? when dco is FpObject) {
        terminal.isIndicator ??= dco.dataObject?.isIndicator;
      }
      if (!types.resolvable || object.typeDescIdx != null) continue;
      if (dco.typeKind != ViTypeKind.unknown) object.typeKind = dco.typeKind;
      object.resolvedType ??= dco.resolvedType;
    }
  }
  for (final diagram in diagrams) {
    decodeBdConstValues(diagram);
  }
}
