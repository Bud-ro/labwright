import 'dart:io';
import 'dart:typed_data';

/// A curated open-source `.vi` with a distinctive feature, fetched from GitHub on
/// demand (not bundled) so the viewer has quick access to rare/interesting files.
///
/// The file lives in a pinned public repo at [repo] (`owner/name`), commit
/// [commit]; [pathSegments] is its repo-relative path split into segments (so
/// spaces and other characters are percent-encoded correctly). See [rawUrl].
class RepresentativeVi {
  const RepresentativeVi({
    required this.name,
    required this.feature,
    required this.repo,
    required this.commit,
    required this.pathSegments,
  });

  /// Display name (the file's basename).
  final String name;

  /// One-line description of what makes this VI interesting.
  final String feature;

  /// GitHub `owner/name` of the source repository.
  final String repo;

  /// The pinned commit SHA the file is fetched at.
  final String commit;

  /// The file's repo-relative path, split into segments.
  final List<String> pathSegments;

  /// The `raw.githubusercontent.com` URL of the file at its pinned commit. Path
  /// segments are percent-encoded (the paths contain spaces).
  Uri get rawUrl => Uri.https(
    'raw.githubusercontent.com',
    [repo, commit, ...pathSegments].join('/'),
  );
}

/// Pinned commit SHAs of the source repositories.
const _tuftsBaxter = 'cef95f1742ad6ce9ef6b733523317750b7a81296';
const _picotech = 'dceb711c8a7878d64ef5993dc5706644ef397ad0';

/// The curated set of representative VIs, chosen for distinctive, verified
/// features (an embedded raw QuickTime image; graphs with many recovered plot
/// colours; a large block diagram).
const List<RepresentativeVi> kRepresentativeVis = [
  RepresentativeVi(
    name: 'OriginalTest.vi',
    feature:
        'Embedded QuickTime raw image (411×489, 24-bit) in a QuickDraw PICT',
    repo: 'tuftsBaxter/ROS-for-LabVIEW-Software',
    commit: _tuftsBaxter,
    pathSegments: [
      'ROS for LabVIEW Software',
      'PlayArea',
      'Controls',
      'OriginalTest.vi',
    ],
  ),
  RepresentativeVi(
    name: '3DBaxter.vi',
    feature: 'Embedded QuickTime raw image (912×504, 32-bit RGBA) in a PICT',
    repo: 'tuftsBaxter/ROS-for-LabVIEW-Software',
    commit: _tuftsBaxter,
    pathSegments: [
      'ROS for LabVIEW Software',
      'PlayArea',
      'subsForTest',
      '3DBaxter.vi',
    ],
  ),
  RepresentativeVi(
    name: 'USBDrDAQExampleStreaming.vi',
    feature:
        'Streaming DAQ front panel with a many-plot graph (74 plot colours)',
    repo: 'picotech/picosdk-ni-labview-examples',
    commit: _picotech,
    pathSegments: ['usbdrdaq', 'USBDrDAQExampleStreaming.vi'],
  ),
  RepresentativeVi(
    name: 'PicoScope2000aExampleStreamingMSO.vi',
    feature:
        'Mixed-signal scope example: multi-plot graph + large block diagram',
    repo: 'picotech/picosdk-ni-labview-examples',
    commit: _picotech,
    pathSegments: ['ps2000a', 'PicoScope2000aExampleStreamingMSO.vi'],
  ),
];

/// Fetches the bytes of a `.vi` at [url] over HTTPS (no caching — a fresh GET each
/// time). Throws [HttpException] on a non-200 response. Uses [dart:io]'s
/// [HttpClient] so no HTTP package dependency is needed.
Future<Uint8List> fetchViBytes(Uri url) async {
  final client = HttpClient();
  try {
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
  } finally {
    client.close();
  }
}
