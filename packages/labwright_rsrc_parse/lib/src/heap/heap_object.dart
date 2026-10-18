/// What every object of a C4 record heap carries whichever heap it sits in, and the interfaces
/// the heaps' object shapes implement so the shared passes can read them: [HeapObject] is the
/// identity every object has, [HeapPlaced] an object with a bounds record, [HeapTextLabel] a
/// label, [HeapTyped] an object with a `typeDescIndex`. [HeapObjectTree] indexes a heap's
/// objects by oid and parent, [ViTypeKind] is the drawing kind of an object's data and
/// [ViResolvedType] its type once the data-space type map is joined.
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
/// it is an array, and the member types when it or its element is a cluster.
class ViResolvedType {
  const ViResolvedType({
    required this.type,
    this.elementType,
    this.members = const [],
    this.elementMembers = const [],
  });

  /// [type] with its element and members read out of [pool].
  factory ViResolvedType.inPool(ViType type, List<ViType> pool) {
    ViType? elementType;
    var elementMembers = const <ViType>[];
    if (type case ViArrayType(:final elementIndex) when elementIndex < pool.length) {
      elementType = pool[elementIndex];
      if (elementType.kind == ViDataType.cluster) elementMembers = clusterFields(elementType, pool);
    }
    return ViResolvedType(
      type: type,
      elementType: elementType,
      members: type.kind == ViDataType.cluster ? clusterFields(type, pool) : const [],
      elementMembers: elementMembers,
    );
  }

  final ViType type;

  final ViType? elementType;

  final List<ViType> members;

  final List<ViType> elementMembers;

  ViDataType get kind => type.kind;

  /// The pool type's label, trimmed; null when it has none.
  String? get name {
    final label = type.label?.trim();
    return label == null || label.isEmpty ? null : label;
  }
}

/// A font run of an object's text: it starts at a character index and names an `FTAB` font id.
typedef HeapFontRun = ({int start, int fontId});

/// An object's caption: the text of its caption record, or of its `shortText` attribute when
/// [recordOffset] is null.
final class HeapCaption {
  const HeapCaption(this.text, {this.recordOffset, this.recordLength = 0});

  final String text;

  /// Offset of the caption record, header included, when the text came from one.
  final int? recordOffset;

  final int recordLength;

  HeapCaption shifted(int delta) =>
      HeapCaption(text, recordOffset: recordOffset == null ? null : recordOffset! + delta, recordLength: recordLength);
}

/// One object of a record heap: its header's identity and where its records lie. Coordinates
/// are in pixels.
abstract class HeapObject {
  HeapObject({
    required this.oid,
    required this.kind,
    required this.offset,
    this.end = 0,
    this.parentOid,
    this.objFlags = 0,
    this.helpText,
  });

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
  int end;

  /// The enclosing object's oid, null for a root.
  final int? parentOid;

  /// The `objFlags` attribute, zero when absent; [ViObjFlag] names the decoded bits.
  final int objFlags;

  /// Whether every bit of [flag] is set in [objFlags].
  bool hasFlag(ViObjFlag flag) => objFlags & flag.mask == flag.mask;

  /// The description record, copied up to the nearest placed ancestor when the object has no
  /// bounds.
  String? helpText;
}

/// An object with a bounds record; [bounds] is relative to the parent's origin and [absBounds]
/// to the heap's.
abstract interface class HeapPlaced implements HeapObject {
  HeapRect get bounds;
  set bounds(HeapRect value);

  /// Offset of the bounds record's payload, its four `i16`s.
  int get boundsOffset;
  set boundsOffset(int value);

  HeapRect get absBounds;
  set absBounds(HeapRect value);
}

/// An object that may carry a caption.
abstract interface class HeapCaptioned implements HeapObject {
  HeapCaption? get caption;
  set caption(HeapCaption? value);
}

/// An object with text drawn in a font: a label, a numeric display, an item list.
abstract interface class HeapFontRuns implements HeapObject {
  // TODO: a font run's colour record (raw 0x029) is not captured.
  List<HeapFontRun> get fontRuns;

  /// The `FTAB` entry of the first font run, set by the model once the font table is read.
  ViFontEntry? get font;
  set font(ViFontEntry? value);
}

/// A text label: a placed, captioned object with font runs and a mode word.
abstract interface class HeapTextLabel implements HeapPlaced, HeapCaptioned, HeapFontRuns {
  /// The `cosmColorB` word read as a mode word: `0x20` centres the text, `0x800000` widens the
  /// text inset; zero when absent.
  int get modeWord;

  /// Whether the label is hidden ([ViObjFlag.labelHidden]).
  bool get isHidden;

  bool get isBold;

  bool get justifyCenter;
}

/// An object whose data has a type: resolved from its own type index or, for a block-diagram
/// terminal, copied from the data object it names.
abstract interface class HeapTypeBearer implements HeapObject {
  ViResolvedType? get resolvedType;
  set resolvedType(ViResolvedType? value);

  ViTypeKind get typeKind;
  set typeKind(ViTypeKind value);
}

/// An object with a `typeDescIndex` attribute: an index into the data-space type map.
abstract interface class HeapTyped implements HeapTypeBearer {
  int get typeDescIdx;
}

extension HeapTypeBearerNames on HeapTypeBearer {
  ViDataType? get dataType => resolvedType?.kind;

  String? get typeName => resolvedType?.name;
}

/// An object that lists enum or ring item names.
abstract interface class HeapItems implements HeapObject {
  List<String> get items;
}

/// A typed control body: the face of a control, indicator or constant.
abstract interface class HeapControlBody implements HeapPlaced, HeapTyped, HeapItems {
  set items(List<String> value);

  /// Whether the body carries a value of its own: numeric, boolean, enum or ring, path, string.
  bool get isValueControl;
}

/// A pane: a scrolled viewport whose controls are placed relative to it.
abstract interface class HeapPane implements HeapPlaced {}

/// The objects of one heap section, indexed by oid and parent.
abstract class HeapObjectTree<T extends HeapObject> {
  HeapObjectTree({required this.objects, this.version, this.sectionIndex = 0})
    : _slotByOid = Int32List(_oidCount(objects)),
      _childrenOf = List<List<T>?>.filled(objects.length, null) {
    for (var i = 0; i < objects.length; i++) {
      final object = objects[i];
      object.index = i;
      if (_slotByOid[object.oid] != 0) throw ViFormatException('heap declares oid ${object.oid} twice');
      _slotByOid[object.oid] = i + 1;
    }
    for (final object in objects) {
      final parent = parentOf(object);
      if (parent != null) (_childrenOf[parent.index] ??= <T>[]).add(object);
    }
  }

  static int _oidCount(List<HeapObject> objects) {
    var top = -1;
    for (final object in objects) {
      if (object.oid > top) top = object.oid;
    }
    return top + 1;
  }

  /// The section's index among its block's sections.
  final int sectionIndex;

  /// The saving LabVIEW version as `major.minor`, when the caller knows it.
  final String? version;

  /// Every object in heap order.
  final List<T> objects;

  /// One past the object's position in [objects]; zero where no object has the oid.
  final Int32List _slotByOid;

  final List<List<T>?> _childrenOf;

  /// The object with [oid], null for none.
  T? byOid(int? oid) {
    if (oid == null || oid < 0 || oid >= _slotByOid.length) return null;
    final slot = _slotByOid[oid];
    return slot == 0 ? null : objects[slot - 1];
  }

  /// The object [object]'s [HeapObject.parentOid] names, null for a root.
  T? parentOf(T object) => byOid(object.parentOid);

  /// The objects whose [HeapObject.parentOid] is [object]'s oid, in heap order.
  List<T> childrenOf(T object) => _childrenOf[object.index] ?? const [];

  /// The children of the object with [oid]; empty for none.
  List<T> children(int oid) {
    final object = byOid(oid);
    return object == null ? const [] : childrenOf(object);
  }

  /// The nearest of [start] and its ancestors that is placed.
  HeapPlaced? boundedOwnerOf(T start) {
    for (T? object = start; object != null; object = parentOf(object)) {
      if (object is HeapPlaced) return object;
    }
    return null;
  }

  /// The ancestors of [object], nearest first.
  Iterable<T> ancestorsOf(T object) sync* {
    for (var parent = parentOf(object); parent != null; parent = parentOf(parent)) {
      yield parent;
    }
  }

  /// How many ancestors [object] has.
  int depthOf(T object) {
    var depth = 0;
    for (var parent = parentOf(object); parent != null; parent = parentOf(parent)) {
      depth++;
    }
    return depth;
  }
}

/// Help text without its `<tag>` markup and runs of spaces.
String stripHelpMarkup(String helpText) {
  final out = helpText.replaceAll(_helpMarkupTag, '').replaceAll(_interiorSpaces, ' ').trim();
  return out.isEmpty ? helpText.trim() : out;
}

final RegExp _helpMarkupTag = RegExp(r'<\s*/?\s*[A-Za-z][A-Za-z0-9]*\s*>');
final RegExp _interiorSpaces = RegExp(r'[ \t]{2,}');
