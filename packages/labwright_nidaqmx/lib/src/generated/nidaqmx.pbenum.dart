// This is a generated file - do not edit.
//
// Generated from nidaqmx.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

/// AI terminal configuration (mirrors DAQmx_Val_* — kept for fidelity; this package
/// passes the raw int32 form instead so the existing DaqmxVal constants flow through).
class InputTermCfgWithDefault extends $pb.ProtobufEnum {
  static const InputTermCfgWithDefault INPUT_TERM_CFG_WITH_DEFAULT_UNSPECIFIED =
      InputTermCfgWithDefault._(0, _omitEnumNames ? '' : 'INPUT_TERM_CFG_WITH_DEFAULT_UNSPECIFIED');
  static const InputTermCfgWithDefault INPUT_TERM_CFG_WITH_DEFAULT_CFG_DEFAULT =
      InputTermCfgWithDefault._(-1, _omitEnumNames ? '' : 'INPUT_TERM_CFG_WITH_DEFAULT_CFG_DEFAULT');
  static const InputTermCfgWithDefault INPUT_TERM_CFG_WITH_DEFAULT_RSE =
      InputTermCfgWithDefault._(10083, _omitEnumNames ? '' : 'INPUT_TERM_CFG_WITH_DEFAULT_RSE');
  static const InputTermCfgWithDefault INPUT_TERM_CFG_WITH_DEFAULT_NRSE =
      InputTermCfgWithDefault._(10078, _omitEnumNames ? '' : 'INPUT_TERM_CFG_WITH_DEFAULT_NRSE');
  static const InputTermCfgWithDefault INPUT_TERM_CFG_WITH_DEFAULT_DIFF =
      InputTermCfgWithDefault._(10106, _omitEnumNames ? '' : 'INPUT_TERM_CFG_WITH_DEFAULT_DIFF');
  static const InputTermCfgWithDefault INPUT_TERM_CFG_WITH_DEFAULT_PSEUDO_DIFF =
      InputTermCfgWithDefault._(12529, _omitEnumNames ? '' : 'INPUT_TERM_CFG_WITH_DEFAULT_PSEUDO_DIFF');

  static const $core.List<InputTermCfgWithDefault> values = <InputTermCfgWithDefault>[
    INPUT_TERM_CFG_WITH_DEFAULT_UNSPECIFIED,
    INPUT_TERM_CFG_WITH_DEFAULT_CFG_DEFAULT,
    INPUT_TERM_CFG_WITH_DEFAULT_RSE,
    INPUT_TERM_CFG_WITH_DEFAULT_NRSE,
    INPUT_TERM_CFG_WITH_DEFAULT_DIFF,
    INPUT_TERM_CFG_WITH_DEFAULT_PSEUDO_DIFF,
  ];

  static final $core.Map<$core.int, InputTermCfgWithDefault> _byValue = $pb.ProtobufEnum.initByValue(values);
  static InputTermCfgWithDefault? valueOf($core.int value) => _byValue[value];

  const InputTermCfgWithDefault._(super.value, super.name);
}

class VoltageUnits2 extends $pb.ProtobufEnum {
  static const VoltageUnits2 VOLTAGE_UNITS2_UNSPECIFIED =
      VoltageUnits2._(0, _omitEnumNames ? '' : 'VOLTAGE_UNITS2_UNSPECIFIED');
  static const VoltageUnits2 VOLTAGE_UNITS2_VOLTS =
      VoltageUnits2._(10348, _omitEnumNames ? '' : 'VOLTAGE_UNITS2_VOLTS');
  static const VoltageUnits2 VOLTAGE_UNITS2_FROM_CUSTOM_SCALE =
      VoltageUnits2._(10065, _omitEnumNames ? '' : 'VOLTAGE_UNITS2_FROM_CUSTOM_SCALE');

  static const $core.List<VoltageUnits2> values = <VoltageUnits2>[
    VOLTAGE_UNITS2_UNSPECIFIED,
    VOLTAGE_UNITS2_VOLTS,
    VOLTAGE_UNITS2_FROM_CUSTOM_SCALE,
  ];

  static final $core.Map<$core.int, VoltageUnits2> _byValue = $pb.ProtobufEnum.initByValue(values);
  static VoltageUnits2? valueOf($core.int value) => _byValue[value];

  const VoltageUnits2._(super.value, super.name);
}

const $core.bool _omitEnumNames = $core.bool.fromEnvironment('protobuf.omit_enum_names');
