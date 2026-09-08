import 'dart:io';
import 'dart:typed_data';

class RepresentativeVi {
  const RepresentativeVi({
    required this.name,
    required this.feature,
    required this.repo,
    required this.commit,
    required this.path,
    this.dependencies = const [],
    this.missingNote,
  });

  final String name;

  final String feature;

  final String repo;

  final String commit;

  final String path;

  final List<String> dependencies;

  final String? missingNote;

  Uri rawUrlOf(String relPath) => Uri.https(
    'raw.githubusercontent.com',
    [repo, commit, ...relPath.split('/')].join('/'),
  );

  Uri get rawUrl => rawUrlOf(path);
}

const _tuftsBaxter = 'cef95f1742ad6ce9ef6b733523317750b7a81296';
const _picotech = 'dceb711c8a7878d64ef5993dc5706644ef397ad0';
const _viSnippets = '1662bd7365317b0af87bf9f71f2431131231f03d';
const _labviewViSnippet = '017ab352e24e251c786ad6ff598eacb214e06d05';

const _ros = 'ROS for LabVIEW Software';

const List<RepresentativeVi> kRepresentativeVis = [
  RepresentativeVi(
    name: 'OriginalTest.vi',
    feature:
        'Embedded QuickTime raw image (411×489, 24-bit) in a QuickDraw PICT; '
        '89-file subVI closure',
    repo: 'tuftsBaxter/ROS-for-LabVIEW-Software',
    commit: _tuftsBaxter,
    path: '$_ros/PlayArea/Controls/OriginalTest.vi',
    missingNote:
        '3 deps are NI vi.lib files (Check if File or Folder Exists.vi, '
        'Dflt Data Dir.vi, Trim Whitespace.vi) — not fetchable',
    dependencies: [
      '$_ros/Devices/Baxter/BaxterVIs/AssemblyState.vi',
      '$_ros/Devices/Baxter/BaxterVIs/Calibrate Gripper.vi',
      '$_ros/Devices/Baxter/BaxterVIs/CheckBaxterEnabled.vi',
      '$_ros/Devices/Baxter/BaxterVIs/Command_Joint_Angles.vi',
      '$_ros/Devices/Baxter/BaxterVIs/Enable_Baxter.vi',
      '$_ros/Devices/Baxter/BaxterVIs/MovePosition_Primitive.vi',
      '$_ros/Devices/Baxter/BaxterVIs/Read_Joint_States.vi',
      '$_ros/PlayArea/Controls/ReadSingleJoint.vi',
      '$_ros/PlayArea/Controls/WriteSingleJoint.vi',
      '$_ros/ROS/Code/Console/GetAllPaths.vi',
      '$_ros/ROS/Code/Console/Servers/ServerSubs/ROSToQueue.vi',
      '$_ros/ROS/Code/ROS_Topic_Close.vi',
      '$_ros/ROS/Code/ROS_Topic_Close_Primitive.vi',
      '$_ros/ROS/Code/ROS_Topic_Init.vi',
      '$_ros/ROS/Code/ROS_Topic_Read.vi',
      '$_ros/ROS/Code/ROS_Topic_Read_Primative.vi',
      '$_ros/ROS/Code/ROS_Topic_Repeat.vi',
      '$_ros/ROS/Code/ROS_Topic_Write.vi',
      '$_ros/ROS/Code/ROS_Topic_Write_Continuous_Primitive.vi',
      '$_ros/ROS/Code/ROS_Topic_Write_Primitive.vi',
      '$_ros/ROS/Code/ROS_Topic_Write_Stop_Continuous_Primitive.vi',
      '$_ros/ROS/Code/SubVIs/AddToOldMasters.vi',
      '$_ros/ROS/Code/SubVIs/AddToQueue.vi',
      '$_ros/ROS/Code/SubVIs/CheckBuildFolder.vi',
      '$_ros/ROS/Code/SubVIs/CheckForNewTopic.vi',
      '$_ros/ROS/Code/SubVIs/CheckMasterConnection.vi',
      '$_ros/ROS/Code/SubVIs/CheckNodeName.vi',
      '$_ros/ROS/Code/SubVIs/CleanupString.vi',
      '$_ros/ROS/Code/SubVIs/ConvertVItoHTML.vi',
      '$_ros/ROS/Code/SubVIs/GetErrCodes.vi',
      '$_ros/ROS/Code/SubVIs/GetFIFOQueue.vi',
      '$_ros/ROS/Code/SubVIs/GetQueueValue.vi',
      '$_ros/ROS/Code/SubVIs/GetROSfromTopic.vi',
      '$_ros/ROS/Code/SubVIs/GetServerVIName.vi',
      '$_ros/ROS/Code/SubVIs/GetTagsForPreferences.vi',
      '$_ros/ROS/Code/SubVIs/GetTopicNode_etc.vi',
      '$_ros/ROS/Code/SubVIs/GetURI&Port.vi',
      '$_ros/ROS/Code/SubVIs/GetWriteQueue.vi',
      '$_ros/ROS/Code/SubVIs/LogFileCodes/GetLogFilePath.vi',
      '$_ros/ROS/Code/SubVIs/NodifyROS.vi',
      '$_ros/ROS/Code/SubVIs/RedefineMasterIP.vi',
      '$_ros/ROS/Code/SubVIs/SaveReadPrefs.vi',
      '$_ros/ROS/Code/SubVIs/StartSeparateServer.vi',
      '$_ros/ROS/Code/SubVIs/WaitForStartup.vi',
      '$_ros/ROS/Code/SubVIs/getOpenPort.vi',
      '$_ros/ROS/Code/_ROSDefinition.vi',
      '$_ros/ROS/MessageBuilding/baxter_core_msgs/add_EndEffectorCommand.vi',
      '$_ros/ROS/MessageBuilding/baxter_core_msgs/add_JointCommand.vi',
      '$_ros/ROS/MessageBuilding/prependLength.vi',
      '$_ros/ROS/MessageBuilding/std_msgs/add_bool.vi',
      '$_ros/ROS/MessageBuilding/std_msgs/add_float64.vi',
      '$_ros/ROS/MessageBuilding/std_msgs/add_int32.vi',
      '$_ros/ROS/MessageBuilding/std_msgs/add_string.vi',
      '$_ros/ROS/MessageBuilding/std_msgs/add_uint32.vi',
      '$_ros/ROS/MessageBuilding/std_msgs/subs/boolArray.vi',
      '$_ros/ROS/MessageBuilding/std_msgs/subs/boolScalar.vi',
      '$_ros/ROS/MessageBuilding/std_msgs/subs/float64Array.vi',
      '$_ros/ROS/MessageBuilding/std_msgs/subs/float64Scalar.vi',
      '$_ros/ROS/MessageBuilding/std_msgs/subs/i32Array.vi',
      '$_ros/ROS/MessageBuilding/std_msgs/subs/i32Scalar.vi',
      '$_ros/ROS/MessageBuilding/std_msgs/subs/stringArray.vi',
      '$_ros/ROS/MessageBuilding/std_msgs/subs/stringScalar.vi',
      '$_ros/ROS/MessageBuilding/std_msgs/subs/u32Array.vi',
      '$_ros/ROS/MessageBuilding/std_msgs/subs/u32Scalar.vi',
      '$_ros/ROS/MessageBuilding/subs/wrap_JointPositions.vi',
      '$_ros/ROS/MessageParsing/baxter_core_messages/parse_assembly_state.vi',
      '$_ros/ROS/MessageParsing/sensor_msgs/parse_joint_state.vi',
      '$_ros/ROS/MessageParsing/std_msgs/parse_bool.vi',
      '$_ros/ROS/MessageParsing/std_msgs/parse_float64.vi',
      '$_ros/ROS/MessageParsing/std_msgs/parse_header.vi',
      '$_ros/ROS/MessageParsing/std_msgs/parse_string.vi',
      '$_ros/ROS/MessageParsing/std_msgs/parse_time.vi',
      '$_ros/ROS/MessageParsing/std_msgs/parse_uint32.vi',
      '$_ros/ROS/MessageParsing/std_msgs/parse_uint8.vi',
      '$_ros/ROS/MessageParsing/std_msgs/subs/parse_bool_array.vi',
      '$_ros/ROS/MessageParsing/std_msgs/subs/parse_bool_scalar.vi',
      '$_ros/ROS/MessageParsing/std_msgs/subs/parse_float64_array.vi',
      '$_ros/ROS/MessageParsing/std_msgs/subs/parse_float64_scalar.vi',
      '$_ros/ROS/MessageParsing/std_msgs/subs/parse_string_array.vi',
      '$_ros/ROS/MessageParsing/std_msgs/subs/parse_string_scalar.vi',
      '$_ros/ROS/MessageParsing/std_msgs/subs/parse_time_array.vi',
      '$_ros/ROS/MessageParsing/std_msgs/subs/parse_time_scalar.vi',
      '$_ros/ROS/MessageParsing/std_msgs/subs/parse_u32_array.vi',
      '$_ros/ROS/MessageParsing/std_msgs/subs/parse_u32_scalar.vi',
      '$_ros/ROS/MessageParsing/std_msgs/subs/parse_u8_array.vi',
      '$_ros/ROS/MessageParsing/std_msgs/subs/parse_u8_scalar.vi',
      '$_ros/ROS/MessageParsing/subs/jointStatesUnits.vi',
      '$_ros/ROS/MessageParsing/subs/parseErrorCheck.vi',
    ],
  ),
  RepresentativeVi(
    name: '3DBaxter.vi',
    feature: 'Embedded QuickTime raw image (912×504, 32-bit) in a PICT',
    repo: 'tuftsBaxter/ROS-for-LabVIEW-Software',
    commit: _tuftsBaxter,
    path: '$_ros/PlayArea/subsForTest/3DBaxter.vi',
    missingNote:
        'All 6 subVIs (Rotate Object.vi et al.) are NI vi.lib 3D Picture '
        'Control files — not in the repo, not fetchable',
  ),
  RepresentativeVi(
    name: 'USBDrDAQExampleStreaming.vi',
    feature:
        'Streaming DAQ front panel with a many-plot graph (74 plot colours)',
    repo: 'picotech/picosdk-ni-labview-examples',
    commit: _picotech,
    path: 'usbdrdaq/USBDrDAQExampleStreaming.vi',
    missingNote:
        '4 deps are NI vi.lib / PicoSDK-installed files (not fetchable)',
    dependencies: [
      'usbdrdaq/USBDrDAQLib/USBDrDAQChannelScaling.vi',
      'usbdrdaq/USBDrDAQLib/USBDrDAQClose.vi',
      'usbdrdaq/USBDrDAQLib/USBDrDAQGPIO.vi',
      'usbdrdaq/USBDrDAQLib/USBDrDAQGetStreamingData.vi',
      'usbdrdaq/USBDrDAQLib/USBDrDAQLEDControl.vi',
      'usbdrdaq/USBDrDAQLib/USBDrDAQOpen.vi',
      'usbdrdaq/USBDrDAQLib/USBDrDAQSettings.vi',
      'usbdrdaq/USBDrDAQLib/USBDrDAQSigGen.vi',
      'usbdrdaq/USBDrDAQLib/USBDrDAQStartStreaming.vi',
    ],
  ),
  RepresentativeVi(
    name: 'PicoScope2000aExampleStreamingMSO.vi',
    feature:
        'Mixed-signal scope example: multi-plot graph + large block diagram',
    repo: 'picotech/picosdk-ni-labview-examples',
    commit: _picotech,
    path: 'ps2000a/PicoScope2000aExampleStreamingMSO.vi',
    missingNote:
        '12 deps are NI vi.lib / PicoSDK-installed files (not fetchable)',
    dependencies: [
      'ps2000a/PicoScope2000aLib/PicoScope2000aClose.vi',
      'ps2000a/PicoScope2000aLib/PicoScope2000aGetStreamingValues.vi',
      'ps2000a/PicoScope2000aLib/PicoScope2000aOpen.vi',
      'ps2000a/PicoScope2000aLib/PicoScope2000aSettings.vi',
      'ps2000a/PicoScope2000aLib/PicoScope2000aSetupStreaming.vi',
      'ps2000a/PicoScope2000aLib/PicoScope2000aStop.vi',
      'ps2000a/PicoScope2000aLib/PicoScope2000aUnitInfo.vi',
      'ps2000a/PicoScope2000aLib/PicoScope2000aWrapSettings.vi',
    ],
  ),
  RepresentativeVi(
    name: 'crc8.png (VI snippet)',
    feature:
        'CRC-8 snippet: for-loop, primitives and dense wiring, with '
        'LabVIEW\'s own render as the Oracle reference',
    repo: 'rcpacini/VI-Snippets',
    commit: _viSnippets,
    path: 'crc8.png',
  ),
  RepresentativeVi(
    name: 'fg.png (VI snippet)',
    feature:
        'Small case-structure snippet: nested structures + typed terminals, '
        'with LabVIEW\'s own render as the Oracle reference',
    repo: 'rcpacini/LabVIEW-VI-Snippet',
    commit: _labviewViSnippet,
    path: 'Examples/Snippets/fg.png',
  ),
];

Future<Uint8List> _get(HttpClient client, Uri url) async {
  final request = await client.getUrl(url);
  final response = await request.close();
  if (response.statusCode != 200) {
    throw HttpException('HTTP ${response.statusCode} for $url');
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<Uint8List> fetchViBytes(Uri url) async {
  final client = HttpClient();
  try {
    return await _get(client, url);
  } finally {
    client.close();
  }
}

class FetchedRepresentativeVi {
  const FetchedRepresentativeVi({
    required this.bytes,
    required this.mainPath,
    required this.projectDir,
    required this.fetchedDeps,
    required this.failedDeps,
  });

  final Uint8List bytes;

  final String mainPath;

  final Directory projectDir;
  final int fetchedDeps;
  final int failedDeps;
}

Future<FetchedRepresentativeVi> fetchRepresentativeVi(
  RepresentativeVi vi, {
  Future<Uint8List> Function(Uri)? fetch,
  int concurrency = 8,
}) async {
  if (fetch != null) return _fetchRepresentativeVi(vi, fetch, concurrency);
  final client = HttpClient();
  try {
    return await _fetchRepresentativeVi(
      vi,
      (url) => _get(client, url),
      concurrency,
    );
  } finally {
    client.close();
  }
}

Future<FetchedRepresentativeVi> _fetchRepresentativeVi(
  RepresentativeVi vi,
  Future<Uint8List> Function(Uri) get,
  int concurrency,
) async {
  final bytes = await get(vi.rawUrl);
  final dir = Directory.systemTemp.createTempSync('labwright_rep_vi_');
  File('${dir.path}/${vi.path}')
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  var ok = 0, failed = 0;
  final pending = [...vi.dependencies];
  Future<void> worker() async {
    while (pending.isNotEmpty) {
      final rel = pending.removeLast();
      try {
        final dep = await get(vi.rawUrlOf(rel));
        File('${dir.path}/$rel')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(dep);
        ok++;
      } catch (_) {
        failed++;
      }
    }
  }

  await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  return FetchedRepresentativeVi(
    bytes: bytes,
    mainPath: '${dir.path}/${vi.path}',
    projectDir: dir,
    fetchedDeps: ok,
    failedDeps: failed,
  );
}
