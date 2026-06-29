// This is a generated file - do not edit.
//
// Generated from data_moniker.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

/// Sideband transport options. GRPC = in-band (this client). The rest are NI's
/// higher-throughput transports and require native support (see README "Streaming").
class SidebandStrategy extends $pb.ProtobufEnum {
  static const SidebandStrategy UNKNOWN =
      SidebandStrategy._(0, _omitEnumNames ? '' : 'UNKNOWN');
  static const SidebandStrategy GRPC =
      SidebandStrategy._(1, _omitEnumNames ? '' : 'GRPC');
  static const SidebandStrategy SHARED_MEMORY =
      SidebandStrategy._(2, _omitEnumNames ? '' : 'SHARED_MEMORY');
  static const SidebandStrategy DOUBLE_BUFFERED_SHARED_MEMORY =
      SidebandStrategy._(
          3, _omitEnumNames ? '' : 'DOUBLE_BUFFERED_SHARED_MEMORY');
  static const SidebandStrategy SOCKETS =
      SidebandStrategy._(4, _omitEnumNames ? '' : 'SOCKETS');
  static const SidebandStrategy SOCKETS_LOW_LATENCY =
      SidebandStrategy._(5, _omitEnumNames ? '' : 'SOCKETS_LOW_LATENCY');
  static const SidebandStrategy HYPERVISOR_SOCKETS =
      SidebandStrategy._(6, _omitEnumNames ? '' : 'HYPERVISOR_SOCKETS');
  static const SidebandStrategy RDMA =
      SidebandStrategy._(7, _omitEnumNames ? '' : 'RDMA');
  static const SidebandStrategy RDMA_LOW_LATENCY =
      SidebandStrategy._(8, _omitEnumNames ? '' : 'RDMA_LOW_LATENCY');

  static const $core.List<SidebandStrategy> values = <SidebandStrategy>[
    UNKNOWN,
    GRPC,
    SHARED_MEMORY,
    DOUBLE_BUFFERED_SHARED_MEMORY,
    SOCKETS,
    SOCKETS_LOW_LATENCY,
    HYPERVISOR_SOCKETS,
    RDMA,
    RDMA_LOW_LATENCY,
  ];

  static final $core.List<SidebandStrategy?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 8);
  static SidebandStrategy? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const SidebandStrategy._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
