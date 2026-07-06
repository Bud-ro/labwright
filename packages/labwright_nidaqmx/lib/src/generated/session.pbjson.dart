// This is a generated file - do not edit.
//
// Generated from session.proto.

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

@$core.Deprecated('Use sessionInitializationBehaviorDescriptor instead')
const SessionInitializationBehavior$json = {
  '1': 'SessionInitializationBehavior',
  '2': [
    {'1': 'SESSION_INITIALIZATION_BEHAVIOR_UNSPECIFIED', '2': 0},
    {'1': 'SESSION_INITIALIZATION_BEHAVIOR_INITIALIZE_NEW', '2': 1},
    {'1': 'SESSION_INITIALIZATION_BEHAVIOR_ATTACH_TO_EXISTING', '2': 2},
  ],
};

/// Descriptor for `SessionInitializationBehavior`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List sessionInitializationBehaviorDescriptor =
    $convert.base64Decode('Ch1TZXNzaW9uSW5pdGlhbGl6YXRpb25CZWhhdmlvchIvCitTRVNTSU9OX0lOSVRJQUxJWkFUSU'
        '9OX0JFSEFWSU9SX1VOU1BFQ0lGSUVEEAASMgouU0VTU0lPTl9JTklUSUFMSVpBVElPTl9CRUhB'
        'VklPUl9JTklUSUFMSVpFX05FVxABEjYKMlNFU1NJT05fSU5JVElBTElaQVRJT05fQkVIQVZJT1'
        'JfQVRUQUNIX1RPX0VYSVNUSU5HEAI=');

@$core.Deprecated('Use sessionDescriptor instead')
const Session$json = {
  '1': 'Session',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
  ],
};

/// Descriptor for `Session`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List sessionDescriptor = $convert.base64Decode('CgdTZXNzaW9uEhIKBG5hbWUYASABKAlSBG5hbWU=');

@$core.Deprecated('Use enumerateDevicesRequestDescriptor instead')
const EnumerateDevicesRequest$json = {
  '1': 'EnumerateDevicesRequest',
};

/// Descriptor for `EnumerateDevicesRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List enumerateDevicesRequestDescriptor =
    $convert.base64Decode('ChdFbnVtZXJhdGVEZXZpY2VzUmVxdWVzdA==');

@$core.Deprecated('Use enumerateDevicesResponseDescriptor instead')
const EnumerateDevicesResponse$json = {
  '1': 'EnumerateDevicesResponse',
  '2': [
    {'1': 'devices', '3': 1, '4': 3, '5': 11, '6': '.nidevice_grpc.DeviceProperties', '10': 'devices'},
  ],
};

/// Descriptor for `EnumerateDevicesResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List enumerateDevicesResponseDescriptor =
    $convert.base64Decode('ChhFbnVtZXJhdGVEZXZpY2VzUmVzcG9uc2USOQoHZGV2aWNlcxgBIAMoCzIfLm5pZGV2aWNlX2'
        'dycGMuRGV2aWNlUHJvcGVydGllc1IHZGV2aWNlcw==');

@$core.Deprecated('Use devicePropertiesDescriptor instead')
const DeviceProperties$json = {
  '1': 'DeviceProperties',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'model', '3': 2, '4': 1, '5': 9, '10': 'model'},
    {'1': 'vendor', '3': 3, '4': 1, '5': 9, '10': 'vendor'},
    {'1': 'serial_number', '3': 4, '4': 1, '5': 9, '10': 'serialNumber'},
    {'1': 'product_id', '3': 5, '4': 1, '5': 13, '10': 'productId'},
  ],
};

/// Descriptor for `DeviceProperties`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List devicePropertiesDescriptor =
    $convert.base64Decode('ChBEZXZpY2VQcm9wZXJ0aWVzEhIKBG5hbWUYASABKAlSBG5hbWUSFAoFbW9kZWwYAiABKAlSBW'
        '1vZGVsEhYKBnZlbmRvchgDIAEoCVIGdmVuZG9yEiMKDXNlcmlhbF9udW1iZXIYBCABKAlSDHNl'
        'cmlhbE51bWJlchIdCgpwcm9kdWN0X2lkGAUgASgNUglwcm9kdWN0SWQ=');
