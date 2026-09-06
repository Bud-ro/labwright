import 'scalar_read.dart';
import 'seq_property.dart';

class StepTypeInfo {
  StepTypeInfo(this.raw);

  final SeqProperty raw;

  String? _str(String key) => nonEmpty(raw.prop(key)?.scalar);

  List<String> get codeTemplates => _split('CodeTemplates', '|');

  String? get descriptionFormat => _str('DescriptionFormat');

  String? get defaultNameFormat => _str('DefaultNameFormat');

  List<String> get blockStartTypes => _split('BlockStartTypes', ',');
  List<String> get blockEndTypes => _split('BlockEndTypes', ',');

  List<String> _split(String key, String sep) {
    final text = _str(key);
    if (text == null) return const [];
    return text.split(sep).map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
  }

  bool? get appliesToBlockStructure => parseFlag(raw.prop('AppliesToBlockStructure')?.scalar);
  bool? get canEncapsulate => parseFlag(raw.prop('CanEncapsulate')?.scalar);

  List<String> get editPanels => scalarValues(raw.prop('NI_Data')?.prop('EditPanels'));

  StepTypeMenu? get menu {
    final menu = raw.prop('Menu');
    return menu == null ? null : StepTypeMenu(menu);
  }
}

class StepTypeMenu {
  StepTypeMenu(this.raw);

  final SeqProperty raw;

  String? _str(String key) => nonEmpty(raw.prop(key)?.scalar);

  String? get group => _str('Group');

  String? get category => _str('Category');

  String? get itemName => _str('ItemName');

  String? get singularItemName => _str('SingularItemName');

  String? get adapter => _str('Adapter');

  bool? get canBeSubstepType => parseFlag(raw.prop('CanBeSubstepType')?.scalar);
  bool? get canOnlyBeSubstepType => parseFlag(raw.prop('CanOnlyBeSubstepType')?.scalar);
}

class SeqType {
  SeqType(this.raw);

  final SeqProperty raw;

  String get name => raw.name;

  String? get baseClass => raw.className;

  List<({String name, String? type})> get fields => [
    for (final child in [...raw.subProps, ...?raw.array]) (name: child.name, type: child.className),
  ];
}

class MeasurementPlugIns {
  MeasurementPlugIns(this.raw);

  final SeqProperty raw;

  String? get pinMapPath => nonEmpty(raw.prop('PinMapPath')?.scalar);

  bool get monitoringEnabled => raw.prop('EnableMonitoring')?.scalar == 'true';

  List<String> get specificationFiles => _paths('SpecificationsFilePaths');

  List<String> get levelsFiles => _paths('LevelsFilePaths');

  List<String> get timingFiles => _paths('TimingFilePaths');

  List<String> get patternFiles => _paths('PatternFilePaths');

  List<String> _paths(String key) => scalarValues(raw.prop(key));

  bool get isNotEmpty =>
      pinMapPath != null ||
      specificationFiles.isNotEmpty ||
      levelsFiles.isNotEmpty ||
      timingFiles.isNotEmpty ||
      patternFiles.isNotEmpty;
}
