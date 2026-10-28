import 'dart:typed_data';

import 'flat_ops.dart';
import 'references.dart';
import 'values.dart';

/// To Variant.
LvVariant lvToVariant(Object? anything) => anything is LvVariant ? anything : LvVariant(anything);

/// Variant To Data: the value as a [T], or [defaultValue] with
/// [LvErrorCode.variantTypeMismatch] when the variant holds something else.
({T data, LvError errorOut}) lvVariantToData<T>(
  LvVariant variant, {
  required T defaultValue,
  LvError errorIn = LvError.none,
}) {
  if (errorIn.status) return (data: defaultValue, errorOut: errorIn);
  final value = variant.value;
  if (value is T) return (data: value, errorOut: LvError.none);
  return (
    data: defaultValue,
    errorOut: LvErrorCode.variantTypeMismatch.error(
      'Variant To Data: the variant holds ${value.runtimeType}, not $T',
    ),
  );
}

/// Set Variant Attribute: [variant] with [name] set to [value]; `replaced` says whether the
/// attribute already existed. An empty name is [LvErrorCode.invalidArgument].
({LvVariant variant, bool replaced, LvError errorOut}) lvSetVariantAttribute(
  LvVariant variant,
  String name,
  Object? value, {
  LvError errorIn = LvError.none,
}) {
  if (errorIn.status) return (variant: variant, replaced: false, errorOut: errorIn);
  if (name.isEmpty) {
    return (variant: variant, replaced: false, errorOut: LvErrorCode.invalidArgument.error('Set Variant Attribute'));
  }
  final replaced = variant.attributes.containsKey(name);
  return (
    variant: variant.withAttributes({...variant.attributes, name: lvToVariant(value)}),
    replaced: replaced,
    errorOut: LvError.none,
  );
}

/// Get Variant Attribute with a name: the attribute's value as a [T], or [defaultValue] when
/// the attribute is absent or holds another type; `found` says whether it was there.
({LvVariant variant, bool found, T value, LvError errorOut}) lvGetVariantAttribute<T>(
  LvVariant variant,
  String name, {
  required T defaultValue,
  LvError errorIn = LvError.none,
}) {
  if (errorIn.status) return (variant: variant, found: false, value: defaultValue, errorOut: errorIn);
  final attribute = variant.attributes[name];
  if (attribute == null) return (variant: variant, found: false, value: defaultValue, errorOut: LvError.none);
  final value = attribute.value;
  return (variant: variant, found: true, value: value is T ? value : defaultValue, errorOut: LvError.none);
}

/// Get Variant Attribute without a name: every attribute, names in the ascending order
/// Sort 1D Array gives strings, with the values in the same order.
({LvVariant variant, List<String> names, List<LvVariant> values, LvError errorOut}) lvGetVariantAttributes(
  LvVariant variant, {
  LvError errorIn = LvError.none,
}) {
  if (errorIn.status) return (variant: variant, names: const [], values: const [], errorOut: errorIn);
  final names = variant.attributes.keys.toList()..sort(lvCompareStrings);
  return (
    variant: variant,
    names: names,
    values: [for (final name in names) variant.attributes[name]!],
    errorOut: LvError.none,
  );
}

/// Delete Variant Attribute: without [name], every attribute goes; with one, that attribute.
({LvVariant variant, bool found, LvError errorOut}) lvDeleteVariantAttribute(
  LvVariant variant, {
  String name = '',
  LvError errorIn = LvError.none,
}) {
  if (errorIn.status) return (variant: variant, found: false, errorOut: errorIn);
  if (name.isEmpty) {
    return (variant: variant.withAttributes(const {}), found: variant.attributes.isNotEmpty, errorOut: LvError.none);
  }
  final found = variant.attributes.containsKey(name);
  final remaining = {...variant.attributes}..remove(name);
  return (variant: variant.withAttributes(remaining), found: found, errorOut: LvError.none);
}

/// LabVIEW's string ordering, which compares code units from the first character.
int lvCompareStrings(String a, String b) {
  final length = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    final difference = a.codeUnitAt(i) - b.codeUnitAt(i);
    if (difference != 0) return difference;
  }
  return a.length - b.length;
}

/// Variant To Flattened String's data string: the variant's value in LabVIEW's flat form, a
/// number or boolean unframed, a string or a 1-D integer list size-prefixed; a value of another
/// kind is not flattened here and throws.
String lvFlattenVariantData(LvVariant variant) {
  final value = variant.value;
  final Uint8List flat;
  switch (value) {
    case bool():
      flat = lvFlatOfInt(value ? 1 : 0, 8);
    case int():
      flat = lvFlatOfInt(value, 64);
    case double():
      flat = lvFlatOfFloat(value, 64);
    case String():
      flat = lvFlatOfString(value, prependSize: true);
    case List<int>():
      flat = lvFlatOfIntList(value, 64, prependSize: true);
    case _:
      throw UnsupportedError(
        'Variant To Flattened String of a ${value.runtimeType}: its flat form is not produced here',
      );
  }
  return lvStringOfFlat(flat);
}
