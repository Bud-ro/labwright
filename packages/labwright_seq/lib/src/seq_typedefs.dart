import 'scalar_read.dart';
import 'seq_property.dart';

/// A step **type** definition as embedded next to a step in a TestStand
/// text/INI (and some XML) export — the metadata that defines the *kind* of step
/// rather than this instance's configuration. TestStand inlines the whole type
/// definition with each step, so the same fields repeat across every step of a
/// type; this lens reads the meaningful ones. Every getter is null/empty when
/// its field is absent.
class StepTypeInfo {
  StepTypeInfo(this.raw);

  /// The step property object — the type-definition fields are flat siblings of
  /// `TS` directly under the step.
  final SeqProperty raw;

  String? _str(String key) => nonEmpty(raw.prop(key)?.scalar);

  /// The code-template names the step type offers (`CodeTemplates`), split from
  /// the stored `|`-delimited list (e.g. `PassFailLabVIEW|PassFailCVI|…`). These
  /// name the per-language module skeletons the editor can generate. Empty when
  /// the type defines none.
  List<String> get codeTemplates => _split('CodeTemplates', '|');

  /// The expression that formats the step's editor description
  /// (`DescriptionFormat`, e.g. `ResStr("NI_STEPTYPES","PASSFAIL_DESCRIPTION…")`
  /// or `"%ModuleDescription"`); null when unset.
  String? get descriptionFormat => _str('DescriptionFormat');

  /// The expression that formats a new step's default name (`DefaultNameFormat`);
  /// null when unset.
  String? get defaultNameFormat => _str('DefaultNameFormat');

  /// For a flow-control step type, the step types that open / close a block this
  /// type participates in (`BlockStartTypes` / `BlockEndTypes`), each split from
  /// the stored comma-delimited list of `NI_Flow_*` type names. Empty for a
  /// non-block type.
  List<String> get blockStartTypes => _split('BlockStartTypes', ',');
  List<String> get blockEndTypes => _split('BlockEndTypes', ',');

  List<String> _split(String key, String sep) {
    final text = _str(key);
    if (text == null) return const [];
    return text.split(sep).map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
  }

  /// Whether this step type participates in a block structure
  /// (`AppliesToBlockStructure`) / may encapsulate other steps (`CanEncapsulate`).
  /// Each null when unset.
  bool? get appliesToBlockStructure => parseFlag(raw.prop('AppliesToBlockStructure')?.scalar);
  bool? get canEncapsulate => parseFlag(raw.prop('CanEncapsulate')?.scalar);

  /// The editor edit-panel class names the step type registers
  /// (`NI_Data.EditPanels`) — the configuration tabs shown for the step. Empty
  /// when the type defines none.
  List<String> get editPanels => scalarValues(raw.prop('NI_Data')?.prop('EditPanels'));

  /// The step type's Insertion-menu placement (`Menu`), or null when it carries
  /// none. See [StepTypeMenu].
  StepTypeMenu? get menu {
    final menu = raw.prop('Menu');
    return menu == null ? null : StepTypeMenu(menu);
  }
}

/// A step type's Insertion Palette / menu placement (`Menu`) — where the type
/// appears in the editor's "Insert Step" menu and how it is labelled.
class StepTypeMenu {
  StepTypeMenu(this.raw);

  /// The underlying `Menu` property object.
  final SeqProperty raw;

  String? _str(String key) => nonEmpty(raw.prop(key)?.scalar);

  /// The menu group the step type is filed under (`Group`, e.g. `Tests`,
  /// `NI_FlowControl`); null when unset.
  String? get group => _str('Group');

  /// The menu sub-category within [group] (`Category`); null/empty when unset.
  String? get category => _str('Category');

  /// The menu item label (`ItemName`) — usually a `ResStr(...)` localization
  /// expression or a literal name; null when unset.
  String? get itemName => _str('ItemName');

  /// The singular form of [itemName] (`SingularItemName`); null/empty when unset.
  String? get singularItemName => _str('SingularItemName');

  /// The module adapter the menu entry creates the step with (`Adapter`, e.g.
  /// `Sequence Adapter`, `None Adapter`); null when unset.
  String? get adapter => _str('Adapter');

  /// Whether the type may be used as a substep type (`CanBeSubstepType`) / may
  /// *only* be a substep type (`CanOnlyBeSubstepType`). Each null when unset.
  bool? get canBeSubstepType => parseFlag(raw.prop('CanBeSubstepType')?.scalar);
  bool? get canOnlyBeSubstepType => parseFlag(raw.prop('CanOnlyBeSubstepType')?.scalar);
}

/// A `<typelist>` type definition: a named type and the fields it declares.
///
/// This is **recovered structure only** — the type's [name], its base class
/// ([baseClass], the root's `classname`), and the ordered list of declared
/// [fields] (each a name + its own `classname` type token). TestStand's
/// `<typelist>` is NI's internal type system (mostly built-in machinery such as
/// `NI_PropertyObjectType`, `CommonResults`, step-type definitions, alongside
/// any user/cluster types); the *semantics* of an individual field's internal
/// attributes are NI-internal and not claimed here. Surfacing names/structure
/// makes the typedef table — previously hidden behind a bare count — visible.
class SeqType {
  SeqType(this.raw);

  /// The type root property object (one entry from [SeqFile.types]).
  final SeqProperty raw;

  /// The type's name (e.g. `NI_CustomResult`, `CommonResults`, a step type).
  String get name => raw.name;

  /// The type's base class — the root's `classname` token (null when absent).
  String? get baseClass => raw.className;

  /// The directly-declared fields, in document order. Each is a `(name, type)`
  /// pair where `type` is the field's own `classname` token (may be null).
  /// Empty for a leaf/scalar type that declares no sub-fields.
  List<({String name, String? type})> get fields => [
    for (final child in [...raw.subProps, ...?raw.array]) (name: child.name, type: child.className),
  ];
}

/// The Semiconductor-Test-System (STS) measurement plug-in resource set a
/// sequence file declares under `FileGlobalDefaults > MeasurementPlugIns` — the
/// external test-program files the sequence depends on: the **pin map** and the
/// **specifications / levels / timing / pattern** file lists. All clean file
/// paths (self-evident); `EnableMonitoring` is a plain flag. Surfacing these
/// answers "what external resources does this sequence need".
class MeasurementPlugIns {
  MeasurementPlugIns(this.raw);

  /// The raw `MeasurementPlugIns` property object — full access to its details.
  final SeqProperty raw;

  /// The pin-map file the test program loads (`PinMapPath`), e.g.
  /// `PinMap.pinmap`; null when the file declares none.
  String? get pinMapPath => nonEmpty(raw.prop('PinMapPath')?.scalar);

  /// Whether result monitoring is enabled (`EnableMonitoring`). false when absent.
  bool get monitoringEnabled => raw.prop('EnableMonitoring')?.scalar == 'true';

  /// Specification files (`SpecificationsFilePaths`), in order; empty when none.
  List<String> get specificationFiles => _paths('SpecificationsFilePaths');

  /// Pin-levels files (`LevelsFilePaths`), in order; empty when none.
  List<String> get levelsFiles => _paths('LevelsFilePaths');

  /// Timing files (`TimingFilePaths`), in order; empty when none.
  List<String> get timingFiles => _paths('TimingFilePaths');

  /// Pattern files (`PatternFilePaths`), in order; empty when none.
  List<String> get patternFiles => _paths('PatternFilePaths');

  List<String> _paths(String key) => scalarValues(raw.prop(key));

  /// True when the file actually declares any STS resource (a pin map or any
  /// file list) — i.e. the block carries more than a bare monitoring flag.
  bool get isNotEmpty =>
      pinMapPath != null ||
      specificationFiles.isNotEmpty ||
      levelsFiles.isNotEmpty ||
      timingFiles.isNotEmpty ||
      patternFiles.isNotEmpty;
}
