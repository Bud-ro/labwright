/// The **naming policy**: the single place a generated identifier's spelling
/// is decided.
///
/// Every name in a lowered function is allocated here — parameters, results,
/// wire locals, loop indices, file-scope constants — so the whole scheme can
/// be changed in one edit and a later symbol-renaming feature has one seam to
/// work through. The emitter never builds an identifier of its own.
///
/// The order of preference is fixed:
///
/// 1. the **decoded label** nearest the value — a connector-pane control's
///    name, a constant's caption, a node's own caption — sanitized to a Dart
///    identifier;
/// 2. otherwise a short [LvNameRole] stem chosen from the value's decoded
///    *type* (`flag` for a boolean wire, `text` for a string, `bytes` for a
///    byte array) or from the role it plays in a structure (`carried`,
///    `branch`);
/// 3. a numeric suffix, and only that, resolves a collision.
///
/// A primitive's English name is deliberately **not** a source of identifiers:
/// `rotateLeftWithCarry2` says what produced a value, where the point of the
/// name is what the value is.
///
/// A **free label placed beside a terminal** is not a source either, and the
/// corpus is why. Over 41 642 block-diagram interface terminals in 7 524 VIs:
/// 14 993 carry a resolved control name (which is preference 1 above) and NONE
/// carries a caption of its own. Reading the nearest free `0x0a` label instead
/// resolves nothing: within 24 px exactly one label lies near 4 959 terminals,
/// several lie near 3 099, and none lies near 33 584 — and the nearest-label
/// gap histogram has no cliff (4 384 at 0..7 px, then a flat 1 200..2 200 per
/// 8 px bucket out past 64 px), so no distance separates a label that names a
/// terminal from one that merely sits nearby. The association is therefore not
/// decoded, and this policy does not guess at it.
library;

import 'numeric.dart';
import 'type_map.dart';
import 'wire_type.dart';

/// The short stem a value takes when no decoded label names it.
enum LvNameRole {
  /// A connector-pane control with no recovered name.
  parameter('input'),

  /// A connector-pane indicator with no recovered name.
  result('result'),

  /// A diagram constant with no caption.
  constant('constant'),

  /// A boolean wire.
  flag('flag'),

  /// A string wire.
  text('text'),

  /// A byte-array wire.
  bytes('bytes'),

  /// An array wire of any other element.
  items('items'),

  /// A wire whose type suggests no better stem.
  value('value'),

  /// One element of an auto-indexed loop tunnel.
  element('element'),

  /// A loop-carried value — a shift register.
  carried('carried'),

  /// A value a Case or Diagram Disable structure defines in each branch.
  branch('branch'),

  /// The growable list an auto-indexing output tunnel appends to.
  builder('builder'),

  /// A For loop's computed iteration count.
  count('count'),

  /// A generated cluster class's field whose member carries no decoded name.
  member('member'),

  /// A generated enum's member whose item label sanitizes to nothing.
  item('item')
  ;

  const LvNameRole(this.stem);

  /// The identifier stem, before collision numbering.
  final String stem;
}

/// The identifiers a **loop induction variable** takes, in nesting order.
///
/// These are one character on purpose. The repo's style rule is that a
/// variable name is never one or two characters; generated loop indices are
/// the deliberate exception, because `for (var i = 0; i < n; i++)` is the form
/// every Dart reader parses without reading it. Do not "fix" these back to
/// long names.
const List<String> kLvLoopIndexNames = ['i', 'j', 'k', 'm', 'n', 'p'];

/// The member names a generated class or enum may **not** take: what every
/// object inherits from `Object`, and what an enum inherits from `Enum` or
/// gets as its own static `values`. A declaration that redeclared one would not
/// compile. Both kinds reserve the whole set, so one rule covers both, and the
/// numeric suffix resolves a member that wanted one.
const Set<String> kLvReservedMemberNames = {
  'hashCode',
  'index',
  'name',
  'noSuchMethod',
  'runtimeType',
  'toString',
  'values',
};

/// Allocates the identifiers of one generated function.
class LvNaming {
  final Set<String> _used = <String>{};
  final Set<String> _fields = <String>{};

  /// The parameter name for a connector-pane control whose decoded name is
  /// [decoded].
  String parameter(String? decoded) => _local(decoded, LvNameRole.parameter);

  /// The **record field** name a result is returned under. Field names live in
  /// their own scope, so they are made unique among themselves rather than
  /// against the function's locals.
  String resultField(String? decoded) {
    final stem = _sanitize(decoded) ?? LvNameRole.result.stem;
    return _unique(stem, _fields);
  }

  /// The local a value of [type] binds to, preferring the decoded label
  /// [decoded] and falling back to the type's own stem.
  String wire(LvWireType type, {String? decoded}) => _local(decoded, roleOfType(type));

  /// The local a value in the structural role [role] binds to.
  String role(LvNameRole role, {String? decoded}) => _local(decoded, role);

  /// The next free loop induction variable ([kLvLoopIndexNames]).
  String loopIndex() {
    for (final name in kLvLoopIndexNames) {
      if (_used.add(name)) return name;
    }
    return _unique(kLvLoopIndexNames.first, _used);
  }

  /// The file-scope constant name for a constant captioned [decoded] — the
  /// `_k` prefix the repo spells library-level constants with.
  String fileConstant(String? decoded) {
    final stem = decoded == null ? '' : lvClassName(decoded);
    return _unique('_k${stem.isEmpty ? 'Constant' : stem}', _used);
  }

  /// The field identifiers of a generated cluster class, one per member
  /// [labels] entry in descriptor order.
  ///
  /// A member with no decoded name, and a second member whose name sanitizes
  /// to one already used, both resolve the same way every other generated name
  /// does: a role stem, then a numeric suffix. Neither is a corner case worth
  /// refusing over — over the corpus's 8 583 cluster declarations, 1 213 hold a
  /// member the descriptor does not name and 1 594 members are displaced by an
  /// earlier member or an inherited name (the corpus sweep's
  /// `decl.unnamedMember` and `decl.displacedMember`).
  static List<String> declarationFields(List<String?> labels) => _declarationNames(labels, LvNameRole.member);

  /// The member identifiers of a generated enum, one per item label in ordinal
  /// order.
  static List<String> declarationItems(List<String> labels) => _declarationNames(labels, LvNameRole.item);

  /// A declaration's members are named from the descriptor's own labels
  /// without the short-name padding [_sanitize] gives a wire local: a member
  /// labelled `On` is `on`, where a two-character *local* says nothing about
  /// the value it holds and is padded to `onValue`.
  static List<String> _declarationNames(List<String?> labels, LvNameRole fallback) {
    final taken = <String>{...kLvReservedMemberNames};
    final names = <String>[];
    for (final label in labels) {
      final trimmed = label?.trim() ?? '';
      final name = _isVerbatim(trimmed) ? trimmed : lvFieldName(trimmed);
      names.add(_unique(name.isEmpty ? fallback.stem : name, taken));
    }
    return names;
  }

  /// The stem a wire of [type] takes when nothing names it: the decoded type
  /// is the only thing about the value the diagram states.
  static LvNameRole roleOfType(LvWireType type) {
    if (type.dims > 0) {
      return type.numeric == LvNumericKind.u8 ? LvNameRole.bytes : LvNameRole.items;
    }
    return switch (type.carrier) {
      LvCarrier.boolean => LvNameRole.flag,
      LvCarrier.text => LvNameRole.text,
      _ => LvNameRole.value,
    };
  }

  String _local(String? decoded, LvNameRole fallback) => _unique(_sanitize(decoded) ?? fallback.stem, _used);

  /// [raw] as a Dart identifier, or null when nothing usable remains. A label
  /// that is already lowerCamelCase is kept verbatim: re-casing it would
  /// discard the spelling its author chose.
  static String? _sanitize(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (_isVerbatim(trimmed)) return trimmed;
    final name = lvFieldName(trimmed);
    return name.isEmpty ? null : (name.length < 3 ? '${name}Value' : name);
  }

  /// Whether [raw] is already a lowerCamelCase Dart identifier that may be used
  /// as it stands — a Dart reserved word never may, however it is spelled.
  static bool _isVerbatim(String raw) => _lowerCamel.hasMatch(raw) && !kLvDartReservedWords.contains(raw);

  static String _unique(String stem, Set<String> taken) {
    if (taken.add(stem)) return stem;
    for (var index = 2; ; index++) {
      final candidate = '$stem$index';
      if (taken.add(candidate)) return candidate;
    }
  }

  static final RegExp _lowerCamel = RegExp(r'^[a-z][A-Za-z0-9]{2,}$');
}
