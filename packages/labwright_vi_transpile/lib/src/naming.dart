import 'numeric.dart';
import 'type_map.dart';
import 'wire_type.dart';

enum LvNameRole {
  parameter('input'),

  result('result'),

  constant('constant'),

  flag('flag'),

  text('text'),

  bytes('bytes'),

  items('items'),

  value('value'),

  element('element'),

  carried('carried'),

  branch('branch'),

  builder('builder'),

  count('count'),

  member('member'),

  item('item')
  ;

  const LvNameRole(this.stem);

  final String stem;
}

/// Generated loop indices are the one place a one-character name is allowed.
const List<String> kLvLoopIndexNames = ['i', 'j', 'k', 'm', 'n', 'p'];

const Set<String> kLvReservedMemberNames = {
  'hashCode',
  'index',
  'name',
  'noSuchMethod',
  'runtimeType',
  'toString',
  'values',
};

class LvNaming {
  final Set<String> _used = <String>{};
  final Set<String> _fields = <String>{};

  String parameter(String? decoded) => _local(decoded, LvNameRole.parameter);

  String resultField(String? decoded) {
    final stem = _sanitize(decoded) ?? LvNameRole.result.stem;
    return _unique(stem, _fields);
  }

  String wire(LvWireType type, {String? decoded}) => _local(decoded, roleOfType(type));

  String role(LvNameRole role, {String? decoded}) => _local(decoded, role);

  String loopIndex() {
    for (final name in kLvLoopIndexNames) {
      if (_used.add(name)) return name;
    }
    return _unique(kLvLoopIndexNames.first, _used);
  }

  String fileConstant(String? decoded) {
    final stem = decoded == null ? '' : lvClassName(decoded);
    return _unique('_k${stem.isEmpty ? 'Constant' : stem}', _used);
  }

  static List<String> declarationFields(List<String?> labels) => _declarationNames(labels, LvNameRole.member);

  static List<String> declarationItems(List<String> labels) => _declarationNames(labels, LvNameRole.item);

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

  static String? _sanitize(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (_isVerbatim(trimmed)) return trimmed;
    final name = lvFieldName(trimmed);
    return name.isEmpty ? null : (name.length < 3 ? '${name}Value' : name);
  }

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
