// This is a generated file - do not edit.
//
// Generated from session.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

/// How the server should treat a session name on creation.
class SessionInitializationBehavior extends $pb.ProtobufEnum {
  static const SessionInitializationBehavior SESSION_INITIALIZATION_BEHAVIOR_UNSPECIFIED =
      SessionInitializationBehavior._(0, _omitEnumNames ? '' : 'SESSION_INITIALIZATION_BEHAVIOR_UNSPECIFIED');
  static const SessionInitializationBehavior SESSION_INITIALIZATION_BEHAVIOR_INITIALIZE_NEW =
      SessionInitializationBehavior._(1, _omitEnumNames ? '' : 'SESSION_INITIALIZATION_BEHAVIOR_INITIALIZE_NEW');
  static const SessionInitializationBehavior SESSION_INITIALIZATION_BEHAVIOR_ATTACH_TO_EXISTING =
      SessionInitializationBehavior._(2, _omitEnumNames ? '' : 'SESSION_INITIALIZATION_BEHAVIOR_ATTACH_TO_EXISTING');

  static const $core.List<SessionInitializationBehavior> values = <SessionInitializationBehavior>[
    SESSION_INITIALIZATION_BEHAVIOR_UNSPECIFIED,
    SESSION_INITIALIZATION_BEHAVIOR_INITIALIZE_NEW,
    SESSION_INITIALIZATION_BEHAVIOR_ATTACH_TO_EXISTING,
  ];

  static final $core.List<SessionInitializationBehavior?> _byValue = $pb.ProtobufEnum.$_initByValueList(values, 2);
  static SessionInitializationBehavior? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const SessionInitializationBehavior._(super.value, super.name);
}

const $core.bool _omitEnumNames = $core.bool.fromEnvironment('protobuf.omit_enum_names');
