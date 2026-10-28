/// Lifts a decoded `TOF1` body into the [SeqFile] property model that XML files parse into.
///
/// The binary stores only the subproperties, values and flags an instance overrides; the type table holds
/// the rest. Expansion merges each record over its definition (its type's root, or the matching child of the
/// parent's definition) the way the XML writer materialises instances, so a binary step shows the same
/// settings tree as its XML twin. Nodes that come from the type rather than the record carry
/// [BinAttr.inherited].
library;

import 'dart:typed_data';

import 'seq_binary.dart';
import 'seq_binary_grammar.dart';
import 'seq_binary_header.dart';
import 'seq_file.dart';
import 'seq_property.dart';

/// `%BIN*` attribute keys synthesized by the binary decoder; they are not file attributes.
abstract final class BinAttr {
  /// The node was materialised from the type table, not stored in the record.
  static const inherited = '%BININHERITED';

  /// The typedef is protected; the value is its protection digest (derivation not yet decoded).
  static const protected = '%BINPROTECTED';

  /// The typedef's secondary digest (derivation not yet decoded).
  static const secondaryDigest = '%BINDIGEST2';

  /// The numeric value of an `Enum` property's current enumerator.
  static const enumValue = '%BINENUMVALUE';

  /// Name of the synthesized subproperty holding an `Enum` typedef's enumerator items array.
  static const enumItems = '%BINENUMITEMS';

  /// Name of the synthesized subproperty holding a record's `Attributes` block; the value is the block's class.
  static const attributeBlock = '%BINATTRIBUTES';

  /// Name of the synthesized subproperty holding a typedef's `TypeAttributes` block; the value is the block's class.
  static const typeAttributeBlock = '%BINTYPEATTRIBUTES';

  /// A type reference the record carries that points past the type table.
  static const danglingTypeRef = '%BINTYPEREF';

  /// The typedef child belongs to the type, not to its instances: its effective flags carry [structureFlagMask] bits.
  static const typeProperty = '%BINTYPEPROPERTY';
}

const _nameInAttribute = '_NAME_IN_ATTRIBUTE_';

/// The XML text of a TestStand double: integral values print without a fraction.
String formatSeqNumber(double value) {
  if (value.isNaN) return 'NaN';
  if (value.isInfinite) return value < 0 ? '-Inf' : 'Inf';
  if (value == value.truncateToDouble() && value.abs() < 1e15) return value.toInt().toString();
  return value.toString();
}

String _formatInteger(int value, BinaryNumericRepresentation representation) =>
    representation == BinaryNumericRepresentation.uint64 && value < 0
    ? BigInt.from(value).toUnsigned(64).toString()
    : value.toString();

/// Decodes a `TOF1` file into the full property model; throws [FormatException] when the body leaves the grammar.
SeqFile parseBinarySeqFile(Uint8List bytes, {Uint8List? body}) {
  final header = Tof1Header.parse(bytes);
  final inflated = body ?? inflateBinaryBody(bytes);
  if (inflated == null) throw const FormatException('binary .seq body does not inflate (not TOF1?)');
  if (header == null || !header.hasBodyMarker) {
    throw const FormatException('TOF1 header lacks the PMCZ body marker; the record region length is unknown');
  }
  final decoded = parseTof1Body(inflated, recordRegionLength: header.recordRegionLength, generation: header.generation);
  return tof1BodyToSeqFile(decoded, header);
}

/// Builds the [SeqFile] model from a decoded body.
SeqFile tof1BodyToSeqFile(Tof1Body body, Tof1Header header) {
  final expander = _Expander(body);
  final entries = <SeqTypelistEntry>[];
  final types = <SeqProperty>[];
  for (final type in body.types) {
    final root = expander.typeRoot(type);
    types.add(root);
    entries.add(SeqTypelistEntry(attributes: type.toXmlEntryAttributes(), root: root));
  }
  return SeqFile(
    header: header.toSeqFileHeader(),
    types: types,
    data: expander.expand(body.data, null, asElement: false),
    typelistEntries: entries,
    rootAttributes: header.rootAttributes,
    binary: body,
  );
}

final class _Expander {
  _Expander(this.body);

  final Tof1Body body;

  final Map<BinaryTypeEntry, SeqProperty> _roots = Map.identity();

  final Set<BinaryTypeEntry> _inProgress = Set.identity();

  SeqProperty typeRoot(BinaryTypeEntry type) {
    final cached = _roots[type];
    if (cached != null) return cached;
    _inProgress.add(type);
    final root = type.root;
    final expanded = _build(
      root,
      null,
      name: root.name ?? '',
      xmlTag: _tagFor(root.name ?? ''),
      leadingAttributes: {
        'classname': root.resolvedClassName,
        ...type.toXmlAttributes(),
      },
      trailingAttributes: {
        if (type.isProtected) BinAttr.protected: type.protectionDigest ?? '',
        if (type.hasSecondaryDigest) BinAttr.secondaryDigest: type.secondaryDigest ?? '',
      },
    );
    _inProgress.remove(type);
    _roots[type] = expanded;
    return expanded;
  }

  /// Expands [record] over [inherited], the expanded definition it overrides (null when it has none).
  SeqProperty expand(BinaryRecord record, SeqProperty? inherited, {required bool asElement}) {
    final name = record.name ?? '';
    final typeName = record.typeName;
    final danglingTypeRef = record.typeRef != null && typeName == null;
    final tag = asElement ? record.resolvedClassName : _tagFor(name);
    return _build(
      record,
      inherited,
      name: name,
      xmlTag: tag,
      leadingAttributes: {
        if (typeName != null) ...{'typename': typeName, 'xsi:type': typeName},
        if (tag != null) 'name': name,
        if (tag != record.resolvedClassName) 'classname': record.resolvedClassName,
      },
      trailingAttributes: {
        if (danglingTypeRef) BinAttr.danglingTypeRef: '${record.typeRef}',
      },
    );
  }

  SeqProperty _build(
    BinaryRecord record,
    SeqProperty? inherited, {
    required String name,
    required String? xmlTag,
    required Map<String, String> leadingAttributes,
    required Map<String, String> trailingAttributes,
  }) {
    SeqProperty? base = inherited != null && _isInstanceProperty(inherited) ? inherited : null;
    final typeRef = record.typeRef;
    if (typeRef != null && typeRef < body.types.length) {
      final type = body.types[typeRef];
      if (!_inProgress.contains(type)) base = typeRoot(type);
    }

    final attributes = <String, String>{
      ...leadingAttributes,
      if (record.flagsForInstances != null) 'flagsforinstances': '${record.flagsForInstances}',
      if (record.instanceOverrideFlags != null) 'instanceoverrideflags': '${record.instanceOverrideFlags}',
      if (record.valueFlags != null) 'valueflags': '${record.valueFlags}',
      if (record.structureFlags != null) 'structureflags': '${record.structureFlags}',
      if (_instanceStructureBits(record) != 0) BinAttr.typeProperty: 'true',
      ...trailingAttributes,
    };

    String? scalar;
    final valueAttributes = <String, String>{};
    List<SeqProperty>? array;
    SeqProperty? elemProto;
    if (record.isArray) {
      valueAttributes['lbound'] = record.lbound ?? '';
      valueAttributes['ubound'] = record.ubound ?? '';
      final ownProto = record.elemProto;
      final baseProto = base?.elemProto;
      elemProto = ownProto != null
          ? expand(ownProto, baseProto, asElement: false)
          : (baseProto == null ? null : _markInherited(baseProto));
      array = [
        for (final element in record.elements ?? const <Object?>[])
          switch (element) {
            BinaryRecord() => expand(element, elemProto, asElement: true),
            double() => SeqProperty(name: '', scalar: formatSeqNumber(element)),
            int() => SeqProperty(name: '', scalar: '$element'),
            bool() => SeqProperty(name: '', scalar: element ? 'true' : 'false'),
            String() => SeqProperty(name: '', scalar: element),
            _ => SeqProperty(name: '', scalar: ''),
          },
      ];
    } else if (record.isEnum) {
      scalar = record.enumValueName ?? base?.scalar;
      final enumValue = record.enumValue;
      if (enumValue != null) {
        attributes[BinAttr.enumValue] = formatSeqNumber(enumValue);
      } else if (base?.attributes[BinAttr.enumValue] case final inheritedValue?) {
        attributes[BinAttr.enumValue] = inheritedValue;
      }
    } else if (record.isLeaf) {
      final representation = BinaryNumericRepresentation.of(record.representation) ?? _inheritedRepresentation(base);
      final value = record.value;
      scalar = switch (value) {
        double() => formatSeqNumber(value),
        int() => _formatInteger(value, representation ?? BinaryNumericRepresentation.int64),
        bool() => value ? 'true' : 'false',
        String() => value,
        _ => base?.scalar ?? _defaultScalar(record.kind),
      };
      if (representation != null && scalar != null) valueAttributes['representation'] = representation.xmlName;
    }

    final children = <SeqProperty>[];
    final overridden = <String>{
      if (record.attributes != null) BinAttr.attributeBlock,
      if (record.typeAttributes != null) BinAttr.typeAttributeBlock,
    };
    if (base != null) {
      for (final baseChild in base.subProps) {
        if (overridden.contains(baseChild.name)) continue;
        final own = record.child(baseChild.name);
        if (own != null) {
          overridden.add(baseChild.name);
          children.add(expand(own, baseChild, asElement: false));
        } else if (_isInstanceProperty(baseChild)) {
          children.add(_markInherited(baseChild));
        }
      }
    }
    for (final own in record.children) {
      if (own.name != null && overridden.contains(own.name)) continue;
      children.add(expand(own, null, asElement: false));
    }
    final enumItems = record.enumItems;
    if (enumItems != null) {
      final items = expand(enumItems, null, asElement: false);
      children.add(
        items.copyWith(
          name: BinAttr.enumItems,
          xmlTag: _nameInAttribute,
          attributes: {...items.attributes, 'name': BinAttr.enumItems},
        ),
      );
    }
    for (final (block, key) in [
      (record.attributes, BinAttr.attributeBlock),
      (record.typeAttributes, BinAttr.typeAttributeBlock),
    ]) {
      if (block == null) continue;
      final expanded = expand(block, null, asElement: false);
      children.add(
        expanded.copyWith(
          name: key,
          xmlTag: _nameInAttribute,
          attributes: {...expanded.attributes, 'name': key, key: block.resolvedClassName},
        ),
      );
    }

    return SeqProperty(
      name: name,
      xmlTag: xmlTag,
      className: record.resolvedClassName,
      typeName: record.typeName,
      attributes: attributes,
      scalar: scalar,
      array: array,
      subProps: children,
      valueAttributes: valueAttributes,
      elemProto: elemProto,
      extData: [for (final ext in record.extData) ext.toXmlAttributes()],
      numericFormat: record.numericFormat,
      xmlComment: record.comment,
    );
  }

  BinaryNumericRepresentation? _inheritedRepresentation(SeqProperty? base) {
    final name = base?.valueAttributes['representation'];
    if (name == null) return null;
    for (final representation in BinaryNumericRepresentation.values) {
      if (representation.xmlName == name) return representation;
    }
    return null;
  }

  /// A node materialised from the type: XML keeps its name, class, value, bounds and children and drops the
  /// typename, flags attributes, numeric format, comment and extdata the typedef declared.
  SeqProperty _markInherited(SeqProperty node) {
    if (node.attributes.containsKey(BinAttr.inherited)) return node;
    return SeqProperty(
      name: node.name,
      xmlTag: node.xmlTag,
      className: node.className,
      attributes: {
        if (node.attributes['name'] case final name?) 'name': name,
        if (node.className case final className?) 'classname': className,
        BinAttr.inherited: 'true',
      },
      scalar: node.scalar,
      array: node.array == null ? null : [for (final element in node.array!) _markInherited(element)],
      subProps: [for (final child in node.subProps) _markInherited(child)],
      valueAttributes: node.valueAttributes,
      elemProto: node.elemProto == null ? null : _markInherited(node.elemProto!),
    );
  }

  /// A typedef child is copied into instances unless its effective flags carry [structureFlagMask] bits.
  static bool _isInstanceProperty(SeqProperty definition) => !definition.attributes.containsKey(BinAttr.typeProperty);

  /// The [structureFlagMask] bits of the flags an instance of [record] gets: its own valueflags word, else its
  /// flagsforinstances, else the flagsforinstances (then valueflags) of the type it instantiates.
  int _instanceStructureBits(BinaryRecord record) {
    final own = record.valueFlagsWord ?? record.flagsForInstances;
    if (own != null) return own & structureFlagMask;
    final typeRef = record.typeRef;
    if (typeRef != null && typeRef < body.types.length) {
      final root = body.types[typeRef].root;
      return (root.flagsForInstances ?? root.valueFlagsWord ?? 0) & structureFlagMask;
    }
    return 0;
  }

  /// The value XML prints for a leaf that stores none.
  static String? _defaultScalar(SeqValueClass kind) => switch (kind) {
    SeqValueClass.number => '0',
    SeqValueClass.boolean => 'false',
    SeqValueClass.string || SeqValueClass.expression || SeqValueClass.path => '',
    _ => null,
  };

  static String? _tagFor(String name) => _isXmlName(name) ? null : _nameInAttribute;

  static bool _isXmlName(String name) {
    if (name.isEmpty) return false;
    for (var i = 0; i < name.length; i++) {
      final c = name.codeUnitAt(i);
      final letter = (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f;
      final digit = c >= 0x30 && c <= 0x39;
      if (!(letter || (i > 0 && (digit || c == 0x2d || c == 0x2e)))) return false;
    }
    return true;
  }
}
