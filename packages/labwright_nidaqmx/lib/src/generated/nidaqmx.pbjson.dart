// This is a generated file - do not edit.
//
// Generated from nidaqmx.proto.

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

@$core.Deprecated('Use inputTermCfgWithDefaultDescriptor instead')
const InputTermCfgWithDefault$json = {
  '1': 'InputTermCfgWithDefault',
  '2': [
    {'1': 'INPUT_TERM_CFG_WITH_DEFAULT_UNSPECIFIED', '2': 0},
    {'1': 'INPUT_TERM_CFG_WITH_DEFAULT_CFG_DEFAULT', '2': -1},
    {'1': 'INPUT_TERM_CFG_WITH_DEFAULT_RSE', '2': 10083},
    {'1': 'INPUT_TERM_CFG_WITH_DEFAULT_NRSE', '2': 10078},
    {'1': 'INPUT_TERM_CFG_WITH_DEFAULT_DIFF', '2': 10106},
    {'1': 'INPUT_TERM_CFG_WITH_DEFAULT_PSEUDO_DIFF', '2': 12529},
  ],
};

/// Descriptor for `InputTermCfgWithDefault`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List inputTermCfgWithDefaultDescriptor = $convert.base64Decode(
    'ChdJbnB1dFRlcm1DZmdXaXRoRGVmYXVsdBIrCidJTlBVVF9URVJNX0NGR19XSVRIX0RFRkFVTF'
    'RfVU5TUEVDSUZJRUQQABI0CidJTlBVVF9URVJNX0NGR19XSVRIX0RFRkFVTFRfQ0ZHX0RFRkFV'
    'TFQQ////////////ARIkCh9JTlBVVF9URVJNX0NGR19XSVRIX0RFRkFVTFRfUlNFEONOEiUKIE'
    'lOUFVUX1RFUk1fQ0ZHX1dJVEhfREVGQVVMVF9OUlNFEN5OEiUKIElOUFVUX1RFUk1fQ0ZHX1dJ'
    'VEhfREVGQVVMVF9ESUZGEPpOEiwKJ0lOUFVUX1RFUk1fQ0ZHX1dJVEhfREVGQVVMVF9QU0VVRE'
    '9fRElGRhDxYQ==');

@$core.Deprecated('Use voltageUnits2Descriptor instead')
const VoltageUnits2$json = {
  '1': 'VoltageUnits2',
  '2': [
    {'1': 'VOLTAGE_UNITS2_UNSPECIFIED', '2': 0},
    {'1': 'VOLTAGE_UNITS2_VOLTS', '2': 10348},
    {'1': 'VOLTAGE_UNITS2_FROM_CUSTOM_SCALE', '2': 10065},
  ],
};

/// Descriptor for `VoltageUnits2`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List voltageUnits2Descriptor = $convert.base64Decode(
    'Cg1Wb2x0YWdlVW5pdHMyEh4KGlZPTFRBR0VfVU5JVFMyX1VOU1BFQ0lGSUVEEAASGQoUVk9MVE'
    'FHRV9VTklUUzJfVk9MVFMQ7FASJQogVk9MVEFHRV9VTklUUzJfRlJPTV9DVVNUT01fU0NBTEUQ'
    '0U4=');

@$core.Deprecated('Use createTaskRequestDescriptor instead')
const CreateTaskRequest$json = {
  '1': 'CreateTaskRequest',
  '2': [
    {'1': 'session_name', '3': 1, '4': 1, '5': 9, '10': 'sessionName'},
    {
      '1': 'initialization_behavior',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.nidevice_grpc.SessionInitializationBehavior',
      '10': 'initializationBehavior'
    },
  ],
};

/// Descriptor for `CreateTaskRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createTaskRequestDescriptor = $convert.base64Decode(
    'ChFDcmVhdGVUYXNrUmVxdWVzdBIhCgxzZXNzaW9uX25hbWUYASABKAlSC3Nlc3Npb25OYW1lEm'
    'UKF2luaXRpYWxpemF0aW9uX2JlaGF2aW9yGAIgASgOMiwubmlkZXZpY2VfZ3JwYy5TZXNzaW9u'
    'SW5pdGlhbGl6YXRpb25CZWhhdmlvclIWaW5pdGlhbGl6YXRpb25CZWhhdmlvcg==');

@$core.Deprecated('Use createTaskResponseDescriptor instead')
const CreateTaskResponse$json = {
  '1': 'CreateTaskResponse',
  '2': [
    {'1': 'status', '3': 1, '4': 1, '5': 5, '10': 'status'},
    {
      '1': 'task',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.nidevice_grpc.Session',
      '10': 'task'
    },
    {
      '1': 'new_session_initialized',
      '3': 3,
      '4': 1,
      '5': 8,
      '10': 'newSessionInitialized'
    },
  ],
};

/// Descriptor for `CreateTaskResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createTaskResponseDescriptor = $convert.base64Decode(
    'ChJDcmVhdGVUYXNrUmVzcG9uc2USFgoGc3RhdHVzGAEgASgFUgZzdGF0dXMSKgoEdGFzaxgCIA'
    'EoCzIWLm5pZGV2aWNlX2dycGMuU2Vzc2lvblIEdGFzaxI2ChduZXdfc2Vzc2lvbl9pbml0aWFs'
    'aXplZBgDIAEoCFIVbmV3U2Vzc2lvbkluaXRpYWxpemVk');

@$core.Deprecated('Use createAIVoltageChanRequestDescriptor instead')
const CreateAIVoltageChanRequest$json = {
  '1': 'CreateAIVoltageChanRequest',
  '2': [
    {
      '1': 'task',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.nidevice_grpc.Session',
      '10': 'task'
    },
    {'1': 'physical_channel', '3': 2, '4': 1, '5': 9, '10': 'physicalChannel'},
    {
      '1': 'name_to_assign_to_channel',
      '3': 3,
      '4': 1,
      '5': 9,
      '10': 'nameToAssignToChannel'
    },
    {
      '1': 'terminal_config',
      '3': 4,
      '4': 1,
      '5': 14,
      '6': '.nidaqmx_grpc.InputTermCfgWithDefault',
      '9': 0,
      '10': 'terminalConfig'
    },
    {
      '1': 'terminal_config_raw',
      '3': 5,
      '4': 1,
      '5': 5,
      '9': 0,
      '10': 'terminalConfigRaw'
    },
    {'1': 'min_val', '3': 6, '4': 1, '5': 1, '10': 'minVal'},
    {'1': 'max_val', '3': 7, '4': 1, '5': 1, '10': 'maxVal'},
    {
      '1': 'units',
      '3': 8,
      '4': 1,
      '5': 14,
      '6': '.nidaqmx_grpc.VoltageUnits2',
      '9': 1,
      '10': 'units'
    },
    {'1': 'units_raw', '3': 9, '4': 1, '5': 5, '9': 1, '10': 'unitsRaw'},
    {
      '1': 'custom_scale_name',
      '3': 10,
      '4': 1,
      '5': 9,
      '10': 'customScaleName'
    },
  ],
  '8': [
    {'1': 'terminal_config_enum'},
    {'1': 'units_enum'},
  ],
};

/// Descriptor for `CreateAIVoltageChanRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createAIVoltageChanRequestDescriptor = $convert.base64Decode(
    'ChpDcmVhdGVBSVZvbHRhZ2VDaGFuUmVxdWVzdBIqCgR0YXNrGAEgASgLMhYubmlkZXZpY2VfZ3'
    'JwYy5TZXNzaW9uUgR0YXNrEikKEHBoeXNpY2FsX2NoYW5uZWwYAiABKAlSD3BoeXNpY2FsQ2hh'
    'bm5lbBI4ChluYW1lX3RvX2Fzc2lnbl90b19jaGFubmVsGAMgASgJUhVuYW1lVG9Bc3NpZ25Ub0'
    'NoYW5uZWwSUAoPdGVybWluYWxfY29uZmlnGAQgASgOMiUubmlkYXFteF9ncnBjLklucHV0VGVy'
    'bUNmZ1dpdGhEZWZhdWx0SABSDnRlcm1pbmFsQ29uZmlnEjAKE3Rlcm1pbmFsX2NvbmZpZ19yYX'
    'cYBSABKAVIAFIRdGVybWluYWxDb25maWdSYXcSFwoHbWluX3ZhbBgGIAEoAVIGbWluVmFsEhcK'
    'B21heF92YWwYByABKAFSBm1heFZhbBIzCgV1bml0cxgIIAEoDjIbLm5pZGFxbXhfZ3JwYy5Wb2'
    'x0YWdlVW5pdHMySAFSBXVuaXRzEh0KCXVuaXRzX3JhdxgJIAEoBUgBUgh1bml0c1JhdxIqChFj'
    'dXN0b21fc2NhbGVfbmFtZRgKIAEoCVIPY3VzdG9tU2NhbGVOYW1lQhYKFHRlcm1pbmFsX2Nvbm'
    'ZpZ19lbnVtQgwKCnVuaXRzX2VudW0=');

@$core.Deprecated('Use createAIVoltageChanResponseDescriptor instead')
const CreateAIVoltageChanResponse$json = {
  '1': 'CreateAIVoltageChanResponse',
  '2': [
    {'1': 'status', '3': 1, '4': 1, '5': 5, '10': 'status'},
  ],
};

/// Descriptor for `CreateAIVoltageChanResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createAIVoltageChanResponseDescriptor =
    $convert.base64Decode(
        'ChtDcmVhdGVBSVZvbHRhZ2VDaGFuUmVzcG9uc2USFgoGc3RhdHVzGAEgASgFUgZzdGF0dXM=');

@$core.Deprecated('Use createAOVoltageChanRequestDescriptor instead')
const CreateAOVoltageChanRequest$json = {
  '1': 'CreateAOVoltageChanRequest',
  '2': [
    {
      '1': 'task',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.nidevice_grpc.Session',
      '10': 'task'
    },
    {'1': 'physical_channel', '3': 2, '4': 1, '5': 9, '10': 'physicalChannel'},
    {
      '1': 'name_to_assign_to_channel',
      '3': 3,
      '4': 1,
      '5': 9,
      '10': 'nameToAssignToChannel'
    },
    {'1': 'min_val', '3': 4, '4': 1, '5': 1, '10': 'minVal'},
    {'1': 'max_val', '3': 5, '4': 1, '5': 1, '10': 'maxVal'},
    {
      '1': 'units',
      '3': 6,
      '4': 1,
      '5': 14,
      '6': '.nidaqmx_grpc.VoltageUnits2',
      '9': 0,
      '10': 'units'
    },
    {'1': 'units_raw', '3': 7, '4': 1, '5': 5, '9': 0, '10': 'unitsRaw'},
    {'1': 'custom_scale_name', '3': 8, '4': 1, '5': 9, '10': 'customScaleName'},
  ],
  '8': [
    {'1': 'units_enum'},
  ],
};

/// Descriptor for `CreateAOVoltageChanRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createAOVoltageChanRequestDescriptor = $convert.base64Decode(
    'ChpDcmVhdGVBT1ZvbHRhZ2VDaGFuUmVxdWVzdBIqCgR0YXNrGAEgASgLMhYubmlkZXZpY2VfZ3'
    'JwYy5TZXNzaW9uUgR0YXNrEikKEHBoeXNpY2FsX2NoYW5uZWwYAiABKAlSD3BoeXNpY2FsQ2hh'
    'bm5lbBI4ChluYW1lX3RvX2Fzc2lnbl90b19jaGFubmVsGAMgASgJUhVuYW1lVG9Bc3NpZ25Ub0'
    'NoYW5uZWwSFwoHbWluX3ZhbBgEIAEoAVIGbWluVmFsEhcKB21heF92YWwYBSABKAFSBm1heFZh'
    'bBIzCgV1bml0cxgGIAEoDjIbLm5pZGFxbXhfZ3JwYy5Wb2x0YWdlVW5pdHMySABSBXVuaXRzEh'
    '0KCXVuaXRzX3JhdxgHIAEoBUgAUgh1bml0c1JhdxIqChFjdXN0b21fc2NhbGVfbmFtZRgIIAEo'
    'CVIPY3VzdG9tU2NhbGVOYW1lQgwKCnVuaXRzX2VudW0=');

@$core.Deprecated('Use createAOVoltageChanResponseDescriptor instead')
const CreateAOVoltageChanResponse$json = {
  '1': 'CreateAOVoltageChanResponse',
  '2': [
    {'1': 'status', '3': 1, '4': 1, '5': 5, '10': 'status'},
  ],
};

/// Descriptor for `CreateAOVoltageChanResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createAOVoltageChanResponseDescriptor =
    $convert.base64Decode(
        'ChtDcmVhdGVBT1ZvbHRhZ2VDaGFuUmVzcG9uc2USFgoGc3RhdHVzGAEgASgFUgZzdGF0dXM=');

@$core.Deprecated('Use startTaskRequestDescriptor instead')
const StartTaskRequest$json = {
  '1': 'StartTaskRequest',
  '2': [
    {
      '1': 'task',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.nidevice_grpc.Session',
      '10': 'task'
    },
  ],
};

/// Descriptor for `StartTaskRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List startTaskRequestDescriptor = $convert.base64Decode(
    'ChBTdGFydFRhc2tSZXF1ZXN0EioKBHRhc2sYASABKAsyFi5uaWRldmljZV9ncnBjLlNlc3Npb2'
    '5SBHRhc2s=');

@$core.Deprecated('Use startTaskResponseDescriptor instead')
const StartTaskResponse$json = {
  '1': 'StartTaskResponse',
  '2': [
    {'1': 'status', '3': 1, '4': 1, '5': 5, '10': 'status'},
  ],
};

/// Descriptor for `StartTaskResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List startTaskResponseDescriptor = $convert.base64Decode(
    'ChFTdGFydFRhc2tSZXNwb25zZRIWCgZzdGF0dXMYASABKAVSBnN0YXR1cw==');

@$core.Deprecated('Use stopTaskRequestDescriptor instead')
const StopTaskRequest$json = {
  '1': 'StopTaskRequest',
  '2': [
    {
      '1': 'task',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.nidevice_grpc.Session',
      '10': 'task'
    },
  ],
};

/// Descriptor for `StopTaskRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List stopTaskRequestDescriptor = $convert.base64Decode(
    'Cg9TdG9wVGFza1JlcXVlc3QSKgoEdGFzaxgBIAEoCzIWLm5pZGV2aWNlX2dycGMuU2Vzc2lvbl'
    'IEdGFzaw==');

@$core.Deprecated('Use stopTaskResponseDescriptor instead')
const StopTaskResponse$json = {
  '1': 'StopTaskResponse',
  '2': [
    {'1': 'status', '3': 1, '4': 1, '5': 5, '10': 'status'},
  ],
};

/// Descriptor for `StopTaskResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List stopTaskResponseDescriptor = $convert
    .base64Decode('ChBTdG9wVGFza1Jlc3BvbnNlEhYKBnN0YXR1cxgBIAEoBVIGc3RhdHVz');

@$core.Deprecated('Use clearTaskRequestDescriptor instead')
const ClearTaskRequest$json = {
  '1': 'ClearTaskRequest',
  '2': [
    {
      '1': 'task',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.nidevice_grpc.Session',
      '10': 'task'
    },
  ],
};

/// Descriptor for `ClearTaskRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List clearTaskRequestDescriptor = $convert.base64Decode(
    'ChBDbGVhclRhc2tSZXF1ZXN0EioKBHRhc2sYASABKAsyFi5uaWRldmljZV9ncnBjLlNlc3Npb2'
    '5SBHRhc2s=');

@$core.Deprecated('Use clearTaskResponseDescriptor instead')
const ClearTaskResponse$json = {
  '1': 'ClearTaskResponse',
  '2': [
    {'1': 'status', '3': 1, '4': 1, '5': 5, '10': 'status'},
  ],
};

/// Descriptor for `ClearTaskResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List clearTaskResponseDescriptor = $convert.base64Decode(
    'ChFDbGVhclRhc2tSZXNwb25zZRIWCgZzdGF0dXMYASABKAVSBnN0YXR1cw==');

@$core.Deprecated('Use readAnalogScalarF64RequestDescriptor instead')
const ReadAnalogScalarF64Request$json = {
  '1': 'ReadAnalogScalarF64Request',
  '2': [
    {
      '1': 'task',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.nidevice_grpc.Session',
      '10': 'task'
    },
    {'1': 'timeout', '3': 2, '4': 1, '5': 1, '10': 'timeout'},
  ],
};

/// Descriptor for `ReadAnalogScalarF64Request`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List readAnalogScalarF64RequestDescriptor =
    $convert.base64Decode(
        'ChpSZWFkQW5hbG9nU2NhbGFyRjY0UmVxdWVzdBIqCgR0YXNrGAEgASgLMhYubmlkZXZpY2VfZ3'
        'JwYy5TZXNzaW9uUgR0YXNrEhgKB3RpbWVvdXQYAiABKAFSB3RpbWVvdXQ=');

@$core.Deprecated('Use readAnalogScalarF64ResponseDescriptor instead')
const ReadAnalogScalarF64Response$json = {
  '1': 'ReadAnalogScalarF64Response',
  '2': [
    {'1': 'status', '3': 1, '4': 1, '5': 5, '10': 'status'},
    {'1': 'value', '3': 2, '4': 1, '5': 1, '10': 'value'},
  ],
};

/// Descriptor for `ReadAnalogScalarF64Response`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List readAnalogScalarF64ResponseDescriptor =
    $convert.base64Decode(
        'ChtSZWFkQW5hbG9nU2NhbGFyRjY0UmVzcG9uc2USFgoGc3RhdHVzGAEgASgFUgZzdGF0dXMSFA'
        'oFdmFsdWUYAiABKAFSBXZhbHVl');

@$core.Deprecated('Use writeAnalogScalarF64RequestDescriptor instead')
const WriteAnalogScalarF64Request$json = {
  '1': 'WriteAnalogScalarF64Request',
  '2': [
    {
      '1': 'task',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.nidevice_grpc.Session',
      '10': 'task'
    },
    {'1': 'auto_start', '3': 2, '4': 1, '5': 8, '10': 'autoStart'},
    {'1': 'timeout', '3': 3, '4': 1, '5': 1, '10': 'timeout'},
    {'1': 'value', '3': 4, '4': 1, '5': 1, '10': 'value'},
  ],
};

/// Descriptor for `WriteAnalogScalarF64Request`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List writeAnalogScalarF64RequestDescriptor =
    $convert.base64Decode(
        'ChtXcml0ZUFuYWxvZ1NjYWxhckY2NFJlcXVlc3QSKgoEdGFzaxgBIAEoCzIWLm5pZGV2aWNlX2'
        'dycGMuU2Vzc2lvblIEdGFzaxIdCgphdXRvX3N0YXJ0GAIgASgIUglhdXRvU3RhcnQSGAoHdGlt'
        'ZW91dBgDIAEoAVIHdGltZW91dBIUCgV2YWx1ZRgEIAEoAVIFdmFsdWU=');

@$core.Deprecated('Use writeAnalogScalarF64ResponseDescriptor instead')
const WriteAnalogScalarF64Response$json = {
  '1': 'WriteAnalogScalarF64Response',
  '2': [
    {'1': 'status', '3': 1, '4': 1, '5': 5, '10': 'status'},
  ],
};

/// Descriptor for `WriteAnalogScalarF64Response`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List writeAnalogScalarF64ResponseDescriptor =
    $convert.base64Decode(
        'ChxXcml0ZUFuYWxvZ1NjYWxhckY2NFJlc3BvbnNlEhYKBnN0YXR1cxgBIAEoBVIGc3RhdHVz');

@$core.Deprecated('Use getErrorStringRequestDescriptor instead')
const GetErrorStringRequest$json = {
  '1': 'GetErrorStringRequest',
  '2': [
    {'1': 'error_code', '3': 1, '4': 1, '5': 5, '10': 'errorCode'},
  ],
};

/// Descriptor for `GetErrorStringRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getErrorStringRequestDescriptor = $convert.base64Decode(
    'ChVHZXRFcnJvclN0cmluZ1JlcXVlc3QSHQoKZXJyb3JfY29kZRgBIAEoBVIJZXJyb3JDb2Rl');

@$core.Deprecated('Use getErrorStringResponseDescriptor instead')
const GetErrorStringResponse$json = {
  '1': 'GetErrorStringResponse',
  '2': [
    {'1': 'status', '3': 1, '4': 1, '5': 5, '10': 'status'},
    {'1': 'error_string', '3': 2, '4': 1, '5': 9, '10': 'errorString'},
  ],
};

/// Descriptor for `GetErrorStringResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getErrorStringResponseDescriptor =
    $convert.base64Decode(
        'ChZHZXRFcnJvclN0cmluZ1Jlc3BvbnNlEhYKBnN0YXR1cxgBIAEoBVIGc3RhdHVzEiEKDGVycm'
        '9yX3N0cmluZxgCIAEoCVILZXJyb3JTdHJpbmc=');
