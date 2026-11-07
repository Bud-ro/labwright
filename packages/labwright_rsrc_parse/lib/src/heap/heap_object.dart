/// What every object of a C4 record heap carries whichever heap it sits in: [HeapObject] holds
/// the fields the shared walk fills ([walkHeap]), [HeapObjectTree] indexes a heap's objects by
/// oid and parent, [ViTypeKind] is the drawing kind of an object's data and [ViResolvedType]
/// its type once the data-space type map is joined.
library;

import 'dart:typed_data';

import '../blocks/FTAB_font_table.dart';
import '../blocks/VCTP_type_pool.dart';
import '../viparse.dart';
import 'heap.dart';
import 'obj_flags.dart';

/// The broad data type of an object or wire; [inferTypeKind] guesses it from the object's
/// records and the data-space join replaces the guess with the pool type's kind.
enum ViTypeKind {
  /// A signed or unsigned integer.
  numericInt,

  /// A floating-point or complex number.
  numericFloat,

  /// An enum or ring.
  enumRing,

  /// A file-system path.
  path,

  /// A Call Library node's symbol.
  clnNode,

  /// A string.
  string,

  /// A boolean.
  boolean,

  /// A cluster.
  cluster,

  /// An array of any element type.
  array,

  /// A refnum.
  refnum,

  /// Not established.
  unknown,
}

/// The drawing kind of a data type, or null for one the diagram does not classify.
ViTypeKind? typeKindOfDataType(ViDataType type) => switch (type) {
  ViDataType.i8 ||
  ViDataType.i16 ||
  ViDataType.i32 ||
  ViDataType.i64 ||
  ViDataType.u8 ||
  ViDataType.u16 ||
  ViDataType.u32 ||
  ViDataType.u64 => ViTypeKind.numericInt,
  ViDataType.sgl ||
  ViDataType.dbl ||
  ViDataType.ext ||
  ViDataType.complexSgl ||
  ViDataType.complexDbl ||
  ViDataType.complexExt => ViTypeKind.numericFloat,
  ViDataType.enumU8 || ViDataType.enumU16 || ViDataType.enumU32 => ViTypeKind.enumRing,
  ViDataType.boolean => ViTypeKind.boolean,
  ViDataType.string || ViDataType.cString || ViDataType.pascalString || ViDataType.subString => ViTypeKind.string,
  ViDataType.path => ViTypeKind.path,
  ViDataType.cluster => ViTypeKind.cluster,
  ViDataType.array || ViDataType.subArray || ViDataType.arrayDataPointer => ViTypeKind.array,
  ViDataType.refnum => ViTypeKind.refnum,
  _ => null,
};

const _intConvChars = {0x62, 0x64, 0x6f, 0x78, 0x58};

int? _formatConvChar(List<int> payload) {
  final pct = payload.indexOf(0x25);
  if (pct < 0) return null;
  for (final byte in payload.skip(pct + 1)) {
    if ((byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a)) return byte;
  }
  return null;
}

/// What an object's C4 records say about its [ViTypeKind]; [inferTypeKind] reads a set of these
/// as the bits [bit] names.
enum ViTypeKindEvidence {
  /// A `symbolName` record: a Call Library node.
  clnNode,

  /// A `path` record.
  path,

  /// A `stringTable` record: an enum or ring.
  enumRing,

  /// A `formatString` record: a number.
  numeric,

  /// The format string's conversion character is `b`, `d`, `o`, `x` or `X`: an integer.
  integerFormat;

  int get bit => 1 << index;

  /// The bit a record with [opcode] carries on its own; a format string needs [ofFormat].
  static int ofOpcode(int opcode) {
    if (opcode == HeapOpcode.symbolName.byte) return clnNode.bit;
    if (opcode == HeapOpcode.path.byte) return path.bit;
    if (opcode == HeapOpcode.stringTable.byte) return enumRing.bit;
    return 0;
  }

  /// The bits a `formatString` record's [payload] carries.
  static int ofFormat(List<int> payload) {
    final conv = _formatConvChar(payload);
    return numeric.bit | (conv != null && _intConvChars.contains(conv) ? integerFormat.bit : 0);
  }
}

/// The type kind the [ViTypeKindEvidence] bits in [evidence] support, strongest first.
ViTypeKind inferTypeKind(int evidence) {
  if (evidence & ViTypeKindEvidence.clnNode.bit != 0) return ViTypeKind.clnNode;
  if (evidence & ViTypeKindEvidence.path.bit != 0) return ViTypeKind.path;
  if (evidence & ViTypeKindEvidence.enumRing.bit != 0) return ViTypeKind.enumRing;
  if (evidence & ViTypeKindEvidence.numeric.bit != 0) {
    return evidence & ViTypeKindEvidence.integerFormat.bit != 0 ? ViTypeKind.numericInt : ViTypeKind.numericFloat;
  }
  return ViTypeKind.unknown;
}

/// An object's pool type once its `typeDescIndex` is resolved: the type, the element type when
/// it is an array, and the member types when it or its element is a cluster; each also seen
/// through any typedef as [base], [elementBase], [baseMembers] and [elementBaseMembers].
class ViResolvedType {
  const ViResolvedType({
    required this.type,
    ViType? base,
    this.elementType,
    this.elementBase,
    this.members = const [],
    this.baseMembers = const [],
    this.elementMembers = const [],
    this.elementBaseMembers = const [],
  }) : base = base ?? type;

  /// [type] with its element and members read out of [pool], as stored and through typedefs.
  factory ViResolvedType.inPool(ViType type, List<ViType> pool) {
    final base = typedefBase(type);
    ViType? elementType, elementBase;
    var elementMembers = const <ViType>[], elementBaseMembers = const <ViType>[];
    if (type case ViArrayType(:final elementIndex) when elementIndex < pool.length) {
      elementType = pool[elementIndex];
      if (elementType.kind == ViDataType.cluster) elementMembers = clusterFields(elementType, pool);
    }
    if (base case ViArrayType(:final elementIndex) when elementIndex < pool.length) {
      elementBase = typedefBase(pool[elementIndex]);
      if (elementBase.kind == ViDataType.cluster) elementBaseMembers = clusterBaseFields(elementBase, pool);
    }
    return ViResolvedType(
      type: type,
      base: base,
      elementType: elementType,
      elementBase: elementBase,
      members: type.kind == ViDataType.cluster ? clusterFields(type, pool) : const [],
      baseMembers: base.kind == ViDataType.cluster ? clusterBaseFields(base, pool) : const [],
      elementMembers: elementMembers,
      elementBaseMembers: elementBaseMembers,
    );
  }

  /// The pool entry itself, a typedef included.
  final ViType type;

  /// [type] with any typedef unwound to the type it defines.
  final ViType base;

  final ViType? elementType;

  /// [elementType] with any typedef unwound.
  final ViType? elementBase;

  final List<ViType> members;

  /// The members of [base], each with any typedef unwound.
  final List<ViType> baseMembers;

  final List<ViType> elementMembers;

  /// The members of [elementBase], each with any typedef unwound.
  final List<ViType> elementBaseMembers;

  ViDataType get kind => type.kind;

  /// The kind of [base].
  ViDataType get baseKind => base.kind;

  /// The pool type's label, trimmed; null when it has none.
  String? get name {
    final label = type.label?.trim();
    return label == null || label.isEmpty ? null : label;
  }
}

/// One object of a record heap with the fields every heap's walk decodes from its records;
/// unset fields are null, zero or empty. Coordinates are in pixels; [bounds] is relative to
/// the parent's origin and [absBounds] to the heap's.
abstract class HeapObject {
  HeapObject({required this.oid, required this.kind, required this.offset});

  /// Position in the heap's object list, heap order; the tree assigns it.
  int index = 0;

  /// The object id the header declares; references name objects by it.
  final int oid;

  /// The class code the header declares, also when no class names it.
  final int kind;

  /// Byte offset of the object header in the heap body.
  int offset;

  /// Where the object's records end: after its closing group, or the body's end when the walk
  /// left it open.
  int end = 0;

  /// Offset of the bounds record's payload, its four `i16`s, when the object has one.
  int? boundsOffset;

  /// Offset of the label record, header included, when the object has one, and its length.
  int? labelOffset;

  int labelLength = 0;

  /// The bounds record, relative to the parent object's origin.
  HeapRect? bounds;

  /// [bounds] shifted by every ancestor's origin; null for objects without a bounds record.
  HeapRect? absBounds;

  /// The enclosing object, null for a root.
  int? parentOid;

  /// The caption record, else the `shortText` attribute, else for a node the first child label.
  String? label;

  List<List<int>?>? _refsByKind;

  /// Targets of the object's references of [kind], in record order; null when it has none.
  List<int>? refsOf(HeapRefKind kind) => _refsByKind?[kind.index];

  void addRef(HeapRefKind kind, int target) {
    final byKind = _refsByKind ??= List<List<int>?>.filled(HeapRefKind.values.length, null);
    (byKind[kind.index] ??= <int>[]).add(target);
  }

  /// Targets of the object's `childRef` references, in record order; a signal's are its endpoints.
  List<int> get refs => refsOf(HeapRefKind.childRef) ?? const <int>[];

  /// The `childRef` and `dcoRef` targets together.
  Iterable<int> get memberOids => <int>{...?refsOf(HeapRefKind.childRef), ...?refsOf(HeapRefKind.dcoRef)};

  /// The number of size records ([HeapOpcode.size]) the object carries.
  int termCount = 0;

  // TODO: a font run's colour record (raw 0x029) is not captured.
  /// The font runs of the object's text: each starts at a character index and names an `FTAB`
  /// font id.
  List<({int start, int fontId})> textStyleRuns = const [];

  /// The `FTAB` entry of the label's first font run, set by the model once the font table is read.
  ViFontEntry? labelFont;

  bool get labelIsBold => labelFont?.isBold ?? false;

  ViTypeKind typeKind = ViTypeKind.unknown;

  /// Enum or ring item names from the string table record, copied up to the owning control.
  List<String> items = const [];

  /// The description record, copied up to the nearest bounded ancestor when the object has no bounds.
  String? helpText;

  /// The `cosmColorB` word of a label, read as a mode word: `0x20` centres the text, `0x800000`
  /// widens the text inset.
  int? labelModeWord;

  bool get labelJustifyCenter => ((labelModeWord ?? 0) & 0x20) != 0;

  /// The inset between a label's box and its text, in pixels.
  int get labelTextInset => ((labelModeWord ?? 0) & 0x800000) != 0 ? 2 : 1;

  /// The displayed element index of an array container, from its array index group.
  int? arrayIndex;

  /// The `formatStyle` attribute of a numeric display, a `%` format string.
  String? displayFormat;

  /// The `backgroundColor` attribute as `0xRRGGBB`; null when absent or transparent.
  int? bgRgb;

  /// The `fgColor` attribute as `0xRRGGBB`; null when absent or transparent.
  int? fgRgb;

  /// The `contentColor` attribute as `0xRRGGBB`; null when absent or transparent.
  int? contentRgb;

  /// The `objFlags` attribute; [ViObjFlag] names the decoded bits.
  int? objFlags;

  /// Whether every bit of [flag] is set in [objFlags].
  bool hasFlag(ViObjFlag flag) => ((objFlags ?? 0) & flag.mask) == flag.mask;

  /// The `typeDescIndex` attribute: an index into the data-space type map.
  int? typeDescIdx;

  /// The pool type [typeDescIdx] resolves to, else the one of the object's `dcoRef` target.
  ViResolvedType? resolvedType;

  ViDataType? get dataType => resolvedType?.kind;

  String? get typeName => resolvedType?.name;

  /// Whether the object is a text label.
  bool get isTextLabel;

  /// Whether the object is a typed control body that carries a value.
  bool get isControlTerminal;

  /// Whether the object is a pane: a scrolled viewport whose controls are placed relative to it.
  bool get isPane;

  bool get isLabelHidden => isTextLabel && hasFlag(ViObjFlag.labelHidden);
}

/// Every object of a heap by oid; a heap declares each oid once.
class HeapObjectsByOid<T extends HeapObject> {
  HeapObjectsByOid(this._objects) : _slotByOid = Int32List(_oidCount(_objects)) {
    for (var i = 0; i < _objects.length; i++) {
      final oid = _objects[i].oid;
      if (_slotByOid[oid] != 0) throw ViFormatException('heap declares oid $oid twice');
      _slotByOid[oid] = i + 1;
    }
  }

  static int _oidCount(List<HeapObject> objects) {
    var top = -1;
    for (final object in objects) {
      if (object.oid > top) top = object.oid;
    }
    return top + 1;
  }

  final List<T> _objects;

  /// One past the object's position in [_objects]; zero where no object has the oid.
  final Int32List _slotByOid;

  T? operator [](int? oid) {
    if (oid == null || oid < 0 || oid >= _slotByOid.length) return null;
    final slot = _slotByOid[oid];
    return slot == 0 ? null : _objects[slot - 1];
  }
}

/// The objects of one heap section, indexed by oid and parent.
abstract class HeapObjectTree<T extends HeapObject> {
  HeapObjectTree({required this.objects, this.version, this.sectionIndex = 0})
    : byId = HeapObjectsByOid(objects),
      _childrenOf = List<List<T>?>.filled(objects.length, null) {
    for (var i = 0; i < objects.length; i++) {
      objects[i].index = i;
    }
    for (final object in objects) {
      final parent = parentOf(object);
      if (parent != null) (_childrenOf[parent.index] ??= <T>[]).add(object);
    }
  }

  /// The section's index among its block's sections.
  final int sectionIndex;

  /// The saving LabVIEW version as `major.minor`, when the caller knows it.
  final String? version;

  /// Every object in heap order.
  final List<T> objects;

  final HeapObjectsByOid<T> byId;

  final List<List<T>?> _childrenOf;

  /// The object [object]'s [HeapObject.parentOid] names, null for a root.
  T? parentOf(T object) {
    final parentOid = object.parentOid;
    return parentOid == null ? null : byId[parentOid];
  }

  /// The objects whose [HeapObject.parentOid] is [object]'s oid, in heap order.
  List<T> childrenOf(T object) => _childrenOf[object.index] ?? const [];

  List<T> children(int oid) {
    final object = byId[oid];
    return object == null ? const [] : childrenOf(object);
  }

  /// The nearest of [start] and its ancestors with absolute bounds.
  T? boundedOwnerOf(T start) {
    for (T? object = start; object != null; object = parentOf(object)) {
      if (object.absBounds != null) return object;
    }
    return null;
  }
}

/// Help text without its `<tag>` markup and runs of spaces.
String stripHelpMarkup(String helpText) {
  final out = helpText.replaceAll(_helpMarkupTag, '').replaceAll(_interiorSpaces, ' ').trim();
  return out.isEmpty ? helpText.trim() : out;
}

final RegExp _helpMarkupTag = RegExp(r'<\s*/?\s*[A-Za-z][A-Za-z0-9]*\s*>');
final RegExp _interiorSpaces = RegExp(r'[ \t]{2,}');
