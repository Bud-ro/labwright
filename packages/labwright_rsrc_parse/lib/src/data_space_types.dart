/// The join between a VI's heaps and its type pool: every typed object's `typeDescIndex`
/// names an entry of the data-space type map (`TM80`), which names a pool type; a
/// block-diagram panel terminal takes the type of the data object its `dcoRef` names, which
/// sits on the front panel.
library;

import 'block_diagram/bd_build.dart';
import 'block_diagram/bd_diagram.dart';
import 'block_diagram/bd_object.dart';
import 'blocks/VCTP_type_pool.dart';
import 'front_panel/fp_object.dart';
import 'front_panel/fp_panel.dart';
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

void _resolveOwn(HeapTyped object, ViDataSpaceTypes types) {
  final resolved = types.resolve(object.typeDescIdx);
  if (resolved == null) return;
  final kind = typeKindOfDataType(resolved.kind);
  if (kind != null) object.typeKind = kind;
  object.resolvedType = resolved;
}

/// Resolves every typed object's own type index, copies a data object's type (and, to a panel
/// terminal, its direction) to the terminal holders and panel terminals that name it through
/// `dcoRef` (on the same diagram, another diagram or a panel, searched in that order), then
/// decodes constant values.
void resolveDataSpaceTypes(List<BdDiagram> diagrams, List<FpPanel> panels, ViDataSpaceTypes types) {
  HeapObject? findDco(BdDiagram own, int oid) {
    final local = own.byOid(oid);
    if (local != null) return local;
    for (final diagram in diagrams) {
      if (identical(diagram, own)) continue;
      final hit = diagram.byOid(oid);
      if (hit != null) return hit;
    }
    for (final panel in panels) {
      final hit = panel.byOid(oid);
      if (hit != null) return hit;
    }
    return null;
  }

  if (types.resolvable) {
    for (final heap in <HeapObjectTree>[...panels, ...diagrams]) {
      for (final object in heap.objects) {
        if (object case final HeapTyped typed) _resolveOwn(typed, types);
      }
    }
  }
  for (final diagram in diagrams) {
    for (final object in diagram.objects) {
      final HeapTypeBearer terminal;
      final int dcoRef;
      switch (object) {
        case BdPanelTerminal(dcoRef: final ref):
          terminal = object;
          dcoRef = ref;
        case BdTerminalHolder(dcoRef: final ref?):
          terminal = object;
          dcoRef = ref;
        default:
          continue;
      }
      final dco = findDco(diagram, dcoRef);
      if (dco == null) continue;
      if (object is BdPanelTerminal && dco is FpDataObject) object.isIndicator ??= dco.isIndicator;
      if (!types.resolvable || dco is! HeapTypeBearer) continue;
      if (dco.typeKind != ViTypeKind.unknown) terminal.typeKind = dco.typeKind;
      terminal.resolvedType ??= dco.resolvedType;
    }
  }
  for (final diagram in diagrams) {
    decodeBdConstValues(diagram);
  }
}
