@Tags(['corpus'])
library;

import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Item types that name a member file a library owns, as opposed to a document or a binary it
/// ships alongside; a class's private data control is embedded in the class file itself.
const kLvMemberItemTypes = {'VI', 'LVClass', 'Library', 'XControl', 'Property Definition'};

/// Class files that carry no private data control: interface classes.
const kClassesWithoutPrivateData = <String>{
  'vi-corpus/sources/SoftwareMinimalist__LabVIEW-SOLID-Examples/SOLID-Dataflow-Template/IAction/IAction.lvclass',
  'vi-corpus/sources/SoftwareMinimalist__LabVIEW-SOLID-Examples/SOLID-Dataflow-Template/IConfig/IConfig.lvclass',
  'vi-corpus/sources/SoftwareMinimalist__LabVIEW-SOLID-Examples/SOLID-Dataflow-Template/IReference/IDMM.lvclass',
  'vi-corpus/sources/SoftwareMinimalist__LabVIEW-SOLID-Examples/SOLID-Dataflow-Template/IReference/IRef.lvclass',
  'vi-corpus/sources/SoftwareMinimalist__LabVIEW-SOLID-Examples/SOLID-Dataflow-Template/IResult/IResult.lvclass',
  'vi-corpus/sources/SoftwareMinimalist__LabVIEW-SOLID-Examples/Template-Logger/IAction/IAction.lvclass',
  'vi-corpus/sources/SoftwareMinimalist__LabVIEW-SOLID-Examples/Template-Logger/IConfig/IConfig.lvclass',
  'vi-corpus/sources/SoftwareMinimalist__LabVIEW-SOLID-Examples/Template-Logger/ILogger/ILogger.lvclass',
  'vi-corpus/sources/SoftwareMinimalist__LabVIEW-SOLID-Examples/Template-Logger/IResult/IResult.lvclass',
};

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

  test('every class file carries a private data control that parses to one typedef cluster', () {
    final without = <String>{};
    for (final file in files) {
      if (LvLibraryKind.ofPath(file.path) != LvLibraryKind.lvClass) continue;
      final library = LvLibraryFile.parse(file.readAsStringSync(), fileName: file.uri.pathSegments.last);
      final control = library.privateDataControl;
      if (control == null) {
        without.add(corpusRelativePath(file.path));
        continue;
      }
      final model = buildViModel(control);
      final item = library.items.where((item) => item.type == 'Class Private Data').single;
      final own = [
        for (final type in model.types.whereType<ViTypedefType>())
          if (type.componentCount >= 2 &&
              type.componentAt(type.componentCount - 1) == item.name &&
              type.componentAt(type.componentCount - 2) == library.fileName)
            type,
      ];
      expect(own, isNotEmpty, reason: '${file.path}: the typedef named ${item.name} under the class');
      final shapes = {for (final type in own) clusterFields(type.base, model.types).map((m) => m.code).join(',')};
      expect(own.every((type) => type.base.kind == ViDataType.cluster), isTrue, reason: file.path);
      expect(shapes, hasLength(1), reason: '${file.path}: every copy of the private data agrees');
    }
    expect(without, kClassesWithoutPrivateData);
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
