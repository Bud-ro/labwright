// This is a generated file - do not edit.
//
// Generated from data_moniker.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use sidebandStrategyDescriptor instead')
const SidebandStrategy$json = {
  '1': 'SidebandStrategy',
  '2': [
    {'1': 'UNKNOWN', '2': 0},
    {'1': 'GRPC', '2': 1},
    {'1': 'SHARED_MEMORY', '2': 2},
    {'1': 'DOUBLE_BUFFERED_SHARED_MEMORY', '2': 3},
    {'1': 'SOCKETS', '2': 4},
    {'1': 'SOCKETS_LOW_LATENCY', '2': 5},
    {'1': 'HYPERVISOR_SOCKETS', '2': 6},
    {'1': 'RDMA', '2': 7},
    {'1': 'RDMA_LOW_LATENCY', '2': 8},
  ],
};

/// Descriptor for `SidebandStrategy`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List sidebandStrategyDescriptor = $convert.base64Decode(
    'ChBTaWRlYmFuZFN0cmF0ZWd5EgsKB1VOS05PV04QABIICgRHUlBDEAESEQoNU0hBUkVEX01FTU'
    '9SWRACEiEKHURPVUJMRV9CVUZGRVJFRF9TSEFSRURfTUVNT1JZEAMSCwoHU09DS0VUUxAEEhcK'
    'E1NPQ0tFVFNfTE9XX0xBVEVOQ1kQBRIWChJIWVBFUlZJU09SX1NPQ0tFVFMQBhIICgRSRE1BEA'
    'cSFAoQUkRNQV9MT1dfTEFURU5DWRAI');

@$core.Deprecated('Use monikerDescriptor instead')
const Moniker$json = {
  '1': 'Moniker',
  '2': [
    {'1': 'service_location', '3': 1, '4': 1, '5': 9, '10': 'serviceLocation'},
    {'1': 'data_source', '3': 2, '4': 1, '5': 9, '10': 'dataSource'},
    {'1': 'data_instance', '3': 3, '4': 1, '5': 3, '10': 'dataInstance'},
  ],
};

/// Descriptor for `Moniker`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List monikerDescriptor = $convert.base64Decode(
    'CgdNb25pa2VyEikKEHNlcnZpY2VfbG9jYXRpb24YASABKAlSD3NlcnZpY2VMb2NhdGlvbhIfCg'
    'tkYXRhX3NvdXJjZRgCIAEoCVIKZGF0YVNvdXJjZRIjCg1kYXRhX2luc3RhbmNlGAMgASgDUgxk'
    'YXRhSW5zdGFuY2U=');

@$core.Deprecated('Use monikerListDescriptor instead')
const MonikerList$json = {
  '1': 'MonikerList',
  '2': [
    {
      '1': 'read_monikers',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.ni.data_monikers.Moniker',
      '10': 'readMonikers'
    },
    {
      '1': 'write_monikers',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.ni.data_monikers.Moniker',
      '10': 'writeMonikers'
    },
  ],
};

/// Descriptor for `MonikerList`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List monikerListDescriptor = $convert.base64Decode(
    'CgtNb25pa2VyTGlzdBI+Cg1yZWFkX21vbmlrZXJzGAIgAygLMhkubmkuZGF0YV9tb25pa2Vycy'
    '5Nb25pa2VyUgxyZWFkTW9uaWtlcnMSQAoOd3JpdGVfbW9uaWtlcnMYAyADKAsyGS5uaS5kYXRh'
    'X21vbmlrZXJzLk1vbmlrZXJSDXdyaXRlTW9uaWtlcnM=');

@$core.Deprecated('Use monikerValuesDescriptor instead')
const MonikerValues$json = {
  '1': 'MonikerValues',
  '2': [
    {
      '1': 'values',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.google.protobuf.Any',
      '10': 'values'
    },
  ],
};

/// Descriptor for `MonikerValues`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List monikerValuesDescriptor = $convert.base64Decode(
    'Cg1Nb25pa2VyVmFsdWVzEiwKBnZhbHVlcxgBIAMoCzIULmdvb2dsZS5wcm90b2J1Zi5BbnlSBn'
    'ZhbHVlcw==');

@$core.Deprecated('Use monikerReadResponseDescriptor instead')
const MonikerReadResponse$json = {
  '1': 'MonikerReadResponse',
  '2': [
    {
      '1': 'data',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.ni.data_monikers.MonikerValues',
      '10': 'data'
    },
  ],
};

/// Descriptor for `MonikerReadResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List monikerReadResponseDescriptor = $convert.base64Decode(
    'ChNNb25pa2VyUmVhZFJlc3BvbnNlEjMKBGRhdGEYASABKAsyHy5uaS5kYXRhX21vbmlrZXJzLk'
    '1vbmlrZXJWYWx1ZXNSBGRhdGE=');

@$core.Deprecated('Use beginMonikerSidebandStreamRequestDescriptor instead')
const BeginMonikerSidebandStreamRequest$json = {
  '1': 'BeginMonikerSidebandStreamRequest',
  '2': [
    {
      '1': 'strategy',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.ni.data_monikers.SidebandStrategy',
      '10': 'strategy'
    },
    {
      '1': 'monikers',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.ni.data_monikers.MonikerList',
      '10': 'monikers'
    },
  ],
};

/// Descriptor for `BeginMonikerSidebandStreamRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List beginMonikerSidebandStreamRequestDescriptor =
    $convert.base64Decode(
        'CiFCZWdpbk1vbmlrZXJTaWRlYmFuZFN0cmVhbVJlcXVlc3QSPgoIc3RyYXRlZ3kYASABKA4yIi'
        '5uaS5kYXRhX21vbmlrZXJzLlNpZGViYW5kU3RyYXRlZ3lSCHN0cmF0ZWd5EjkKCG1vbmlrZXJz'
        'GAIgASgLMh0ubmkuZGF0YV9tb25pa2Vycy5Nb25pa2VyTGlzdFIIbW9uaWtlcnM=');

@$core.Deprecated('Use beginMonikerSidebandStreamResponseDescriptor instead')
const BeginMonikerSidebandStreamResponse$json = {
  '1': 'BeginMonikerSidebandStreamResponse',
  '2': [
    {
      '1': 'strategy',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.ni.data_monikers.SidebandStrategy',
      '10': 'strategy'
    },
    {'1': 'connection_url', '3': 2, '4': 1, '5': 9, '10': 'connectionUrl'},
    {
      '1': 'sideband_identifier',
      '3': 3,
      '4': 1,
      '5': 9,
      '10': 'sidebandIdentifier'
    },
    {'1': 'buffer_size', '3': 4, '4': 1, '5': 18, '10': 'bufferSize'},
  ],
};

/// Descriptor for `BeginMonikerSidebandStreamResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List beginMonikerSidebandStreamResponseDescriptor =
    $convert.base64Decode(
        'CiJCZWdpbk1vbmlrZXJTaWRlYmFuZFN0cmVhbVJlc3BvbnNlEj4KCHN0cmF0ZWd5GAEgASgOMi'
        'IubmkuZGF0YV9tb25pa2Vycy5TaWRlYmFuZFN0cmF0ZWd5UghzdHJhdGVneRIlCg5jb25uZWN0'
        'aW9uX3VybBgCIAEoCVINY29ubmVjdGlvblVybBIvChNzaWRlYmFuZF9pZGVudGlmaWVyGAMgAS'
        'gJUhJzaWRlYmFuZElkZW50aWZpZXISHwoLYnVmZmVyX3NpemUYBCABKBJSCmJ1ZmZlclNpemU=');
