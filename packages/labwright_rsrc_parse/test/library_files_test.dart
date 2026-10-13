@Tags(['corpus'])
library;

import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Item types that name a member file a library owns, as opposed to a document or a binary it
/// ships alongside; a class's private data control is embedded in the class file itself.
const kLvMemberItemTypes = {'VI', 'LVClass', 'Library', 'XControl', 'Property Definition'};

const kLibraryMembersMissing = <String, int>{
  'vi-corpus/sources/JKISoftware__JKI-State-Machine/examples/3 Button Dialog/3 Button Dialog.lvproj': 1,
  'vi-corpus/sources/NEVSTOP-LAB__Communicable-State-Machine/.github/CSMHelper.lvproj': 2,
  'vi-corpus/sources/NEVSTOP-LAB__Communicable-State-Machine/.github/zzzz - CSM - Shortcut Menu Plug-In.lvproj': 6,
  'vi-corpus/sources/NEVSTOP-LAB__Communicable-State-Machine/testcases/CSM-New-Testcases.lvproj': 9,
  'vi-corpus/sources/NJKirchner__LabVIEW-Evaluation-Hands-On/Dimensions of Evaluation.lvproj': 2,
  'vi-corpus/sources/ThatsTheEnd__LabviewPipelineSampleProject/Source/LabVIEW/CICD/VIs/00_CICD.lvproj': 1,
  'vi-corpus/sources/chrylarson__LabVIEW-HMI/HMI.lvproj': 2,
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/GoCommando.lvproj': 1,
  'vi-corpus/sources/ni__grpc-labview/build-it/LV Build/GRPCVIPMBuild.lvproj': 1,
  'vi-corpus/sources/ni__grpc-labview/tests/Deprecated/Tests.lvproj': 1,
  'vi-corpus/sources/opengds__OpenGDS/Open_GDS_Tools/OpenGDS_Relative.lvproj': 53,
  'vi-corpus/sources/opengds__OpenGDS/resource/Framework/Providers/Open_GDS/UML/UMLEditor.lvproj': 20,
};

void main() {
  final files =
      corpusVi.listSync(recursive: true).whereType<File>().where((f) => LvLibraryKind.ofPath(f.path) != null).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('every library, class, XControl and project file parses, and its member files exist', () {
    final missing = <String, int>{};
    for (final file in files) {
      final library = LvLibraryFile.parse(file.readAsStringSync(), fileName: file.uri.pathSegments.last);
      for (final item in library.items) {
        final url = item.url;
        if (url == null || !kLvMemberItemTypes.contains(item.type) || url.startsWith('/')) continue;
        if (!File(resolveLibraryUrl(file.path, url)).existsSync()) {
          final key = corpusRelativePath(file.path);
          missing[key] = (missing[key] ?? 0) + 1;
        }
      }
    }
    expect(missing, kLibraryMembersMissing);
  });

  test('the project index names every library member uniquely within its repository', () {
    final index = LvProjectIndex.scan(corpusVi);
    expect(index.libraries.length, files.where((f) => LvLibraryKind.ofPath(f.path) != LvLibraryKind.project).length);
    expect(
      index.fileOf(['MB Master.lvlib', 'Read Coils.vi']),
      endsWith('/rfporter__Modbus-Master/MB_Master/Read Coils.vi'),
    );
  });
}
