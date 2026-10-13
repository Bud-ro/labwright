@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'snippets.dart';

const Map<String, String> kSnippetLoweringOutcomes = {
  'ClassChildren': 'wireType',
  'ClassesInMemory': 'subViCall',
  'Config_Dump': 'tunnelIndexing',
  'Config_Dump2': 'wireType',
  'Config_Escape': 'primitive',
  'Config_Load': 'wireType',
  'Config_Load2': 'foreignCall',
  'Excel_Cell_to_RowCol': 'primitive',
  'Excel_Cell_to_Value': 'wireType',
  'Excel_Read_XLSX': 'wireType',
  'Excel_Variant_Elements': 'wireType',
  'Export Palette Image WMF': 'wireType',
  'FileReadOnly': 'wireType',
  'GenerateTree': 'wireType',
  'GetCurrentDirectory': 'wireType',
  'IconHeader': 'wireType',
  'MD5': 'lowered',
  'PNG CRC32': 'lowered',
  'Page1': 'wireType',
  'Pages': 'wireType',
  'ProjectItems': 'wireType',
  'Read Library Version': 'wireType',
  'Read VI Blocks': 'wireType',
  'Resolve Library Path': 'wireType',
  'Resolve Path': 'primitive',
  'ReverseBitsVim': 'lowered',
  'Symbols1Bit': 'wireType',
  'Tokenize URL': 'primitive',
  'VI Tree': 'lowered',
  'VISA_InterfaceType': 'wireType',
  'VISA_Open2': 'wireType',
  'VISA_Query': 'wireType',
  'WriteConsole': 'wireType',
  'basic': 'lowered',
  'broken_wires_only': 'wireDirection',
  'crc16': 'primitive',
  'crc32': 'primitive',
  'crc32_lookup_table': 'lowered',
  'crc8': 'lowered',
  'decorations_only': 'lowered',
  'example': 'primitive',
  'fg': 'structure',
  'large': 'wireType',
  'missing_terminal': 'wireDirection',
  'sub_vi_missing': 'subViCall',
  'vi_lib_dependency': 'subViCall',
};

const int kLvInPlaceElementClass = 0x14d;

const Set<int> kLvInPlaceElementBorderClasses = {kLvDataValueRefBorderClass, 0x150, 0x14f, 0x152};

const int kLvDataValueRefBorderClass = 0x153;

const Map<String, int> kCorpusInPlaceElement = {
  'ipe.blocked': 68,
  'ipe.blocked.identifiedOnly': 63,
  'ipe.blocked.undecodedAccess': 5,
  'ipe.border.0x14f': 164,
  'ipe.border.0x150': 428,
  'ipe.border.0x152': 98,
  'ipe.border.0x153': 1424,
  'ipe.structures': 915,
  'ipe.vis': 716,
};

const Map<String, int> kSnippetPrimReviewList = {
  'node class 0x150': 12,
  'primResID 1171 (name not decoded)': 11,
  'node class 0x105': 16,
  'node class 0x6a': 12,
  'primResID 1534 (name not decoded)': 11,
  'node class 0xa9': 15,
  'primResID 8051 (name not decoded)': 11,
};

const Map<String, int> kMd5Blockers = <String, int>{};

const ({int signals, int resolved, int disagreeing, int unresolved}) kSnippetClusterWires = (
  signals: 729,
  resolved: 525,
  disagreeing: 32,
  unresolved: 172,
);

const Map<String, String> kSnippetThreadedDifferences = <String, String>{};

const Map<String, int> kCorpusLoweringSweep = {
  'call': 4875,
  'call.calleeMissing': 544,
  'call.noPane': 112,
  'call.paneMatched': 3845,
  'call.paneWidthMismatch': 78,
  'call.unnamed': 139,
  'call.via.link': 2937,
  'call.via.name': 1098,
  'call.via.stock': 157,
  'clus': 135446,
  'clus.kid.many': 265,
  'clus.kid.none': 19906,
  'clus.kid.one': 71781,
  'clus.kidAgrees': 47432,
  'clus.kidDisagrees': 24349,
  'clus.kidNameOnly': 23943,
  'clus.many': 1507,
  'clus.none': 39856,
  'clus.noneNoIndex': 41,
  'clus.noneUntyped': 378,
  'clus.one': 94083,
  'clus.pane.many': 48,
  'clus.pane.none': 9797,
  'clus.pane.one': 12776,
  'clus.paneAgrees': 5367,
  'clus.paneDisagrees': 7409,
  'clus.paneNameOnly': 7322,
  'clus.typedefContradicts': 6,
  'clus.viaTypedef': 19118,
  'clus.why.member.0x33': 299,
  'clus.why.member.0x37': 27,
  'clus.why.member.0x74': 25,
  'clus.why.member.0xb': 24,
  'clus.why.member.0xd': 6,
  'clus.why.noneNoCluster': 39437,
  'clus.why.noneNoIndex': 41,
  'clus.why.noneUntyped': 378,
  'clus.why.typed': 95172,
  'clus.why.typesDisagree': 37,
  'clusType.kidAgrees': 72314,
  'clusType.kidChecked': 13757,
  'clusType.kidDisagrees': 711,
  'clusType.kidLabelOnly': 639,
  'clusType.kidShapeDiffers': 72,
  'clusType.kidUnchecked': 24633,
  'clusType.kidWouldDecide': 38390,
  'clusType.kidWouldNotMap': 158,
  'clusType.many': 37,
  'clusType.none': 39856,
  'clusType.one': 95553,
  'clusType.pane.agrees.plain.ownPlain': 10675,
  'clusType.pane.agrees.typedef.ownTypedef': 1983,
  'clusType.pane.disagrees.plain.ownPlain': 130,
  'clusType.pane.disagrees.plain.ownTypedef': 19,
  'clusType.pane.disagrees.typedef.ownPlain': 14,
  'clusType.pane.disagrees.typedef.ownTypedef': 42,
  'clusType.pane.none': 13946,
  'clusType.pane.one': 12863,
  'clusType.paneAgrees': 12658,
  'clusType.paneAtCallAgrees': 26644,
  'clusType.paneAtCallDisagrees': 163,
  'clusType.paneDisagrees': 205,
  'clusType.paneLabelOnly': 176,
  'clusType.paneOffCallAgrees': 10513,
  'clusType.paneOffCallDisagrees': 297,
  'clusType.paneOffCallLabelOnly': 206,
  'clusType.paneOffCallShapeDiffers': 91,
  'clusType.paneShapeDiffers': 29,
  'clusType.paneWouldDecide': 13860,
  'clusType.paneWouldDecide.plain': 11313,
  'clusType.paneWouldDecide.typedef': 2547,
  'clusType.paneWouldNotMap': 86,
  'cond': 2210,
  'cond.dcoBit0': 324,
  'cond.dcoBit12': 143,
  'cond.glyph192': 1841,
  'cond.glyphNone': 369,
  'decl': 9794,
  'decl.anonymous': 3,
  'decl.cluster': 8208,
  'decl.displacedMember': 58,
  'decl.enum': 1586,
  'decl.suffixed': 571,
  'decl.unnamedMember': 65,
  'decl.vi': 3240,
  'exceptions.caseSelector': 26,
  'exceptions.constantValue': 206,
  'exceptions.foreignCall': 114,
  'exceptions.lowered': 795,
  'exceptions.primitive': 685,
  'exceptions.structure': 250,
  'exceptions.subViCall': 323,
  'exceptions.tunnelCoercion': 1,
  'exceptions.tunnelIndexing': 6,
  'exceptions.unboundValue': 8,
  'exceptions.unwiredTerminal': 102,
  'exceptions.wireDirection': 5,
  'exceptions.wireType': 4873,
  'flag0.array': 24551,
  'flag0.scalar': 149919,
  'flag12.array': 931,
  'flag12.scalar': 6632,
  'flag4.array': 4699,
  'flag4.scalar': 57668,
  'flag8.array': 9612,
  'flag8.scalar': 109993,
  'foreign.noEntryPoint': 2,
  'foreign.noLibrary': 55,
  'foreign.node': 905,
  'foreign.vi': 429,
  'idx': 3476,
  'idx.groupFirstIndex': 107,
  'idx.groupLastIndex': 130,
  'idx.irregular': 1,
  'idx.rank1Index': 2264,
  'idx.regular': 3475,
  'modes.differ': 376,
  'modes.same': 419,
  'pane.0x103.differs': 129,
  'pane.0x103.equal': 15,
  'pane.0x104.differs': 297,
  'pane.0x104.equal': 1460,
  'pane.0x124.differs': 43,
  'pane.0x124.equal': 171,
  'pane.0x31.differs': 76,
  'pane.0x31.equal': 19653,
  'pane.0x32.differs': 1858,
  'pane.0x32.equal': 43,
  'pane.0xc5.equal': 162,
  'ref': 67373,
  'ref.ep.agrees': 13174,
  'ref.ep.contradicts': 1345,
  'ref.ep.split': 15,
  'ref.pane.contraCell.70_d2.agrees': 557,
  'ref.pane.contraCell.70_d3.agrees': 8834,
  'ref.pane.contraCell.70_d3.contradicts': 1,
  'ref.pane.contraCell.70_d4.agrees': 284,
  'ref.pane.contraCell.70_d4.contradicts': 10,
  'ref.pane.contraCell.71_d4.agrees': 92,
  'ref.pane.contraCell.71_d5.agrees': 1054,
  'ref.pane.contraCell.71_d6.agrees': 9,
  'ref.pane.dims0': 10315,
  'ref.pane.dims1': 526,
  'ref.pane.lawAgrees': 3908,
  'ref.pane.vsAgrees': 10830,
  'ref.pane.vsContradicts': 11,
  'ref.pane.vsInvented': 10,
  'ref.pane.vsMissed': 1,
  'ref.part.agrees': 26570,
  'ref.part.base1': 4057,
  'ref.part.base2': 835,
  'ref.part.base3': 23184,
  'ref.part.base4': 1214,
  'ref.part.base5': 4351,
  'ref.part.base6': 14,
  'ref.part.base7': 2,
  'ref.part.contradictedCell': 1763,
  'ref.part.decides': 33657,
  'ref.part.dims0': 27956,
  'ref.part.dims1': 5701,
  'ref.part.read': 31894,
  'ref.part.silent': 5597,
  'ref.scalar': 28119,
  'ref.undecided': 39254,
  'render.lawSilent.styleMute': 34210,
  'render.lawSilent.styleSpeaks': 6013,
  'render.refUndecided.styleMute': 33925,
  'render.refUndecided.styleSpeaks': 5329,
  'term.calleeUntyped': 6608,
  'term.dirAgree': 12944,
  'term.resolved': 12944,
  'term.typeAgree': 5906,
  'term.typeDisagree': 430,
  'term.unresolved': 88,
  'term.wired': 13032,
  'threaded.caseSelector': 26,
  'threaded.constantValue': 206,
  'threaded.foreignCall': 114,
  'threaded.lowered': 795,
  'threaded.primitive': 685,
  'threaded.structure': 250,
  'threaded.subViCall': 323,
  'threaded.tunnelCoercion': 1,
  'threaded.tunnelIndexing': 6,
  'threaded.unboundValue': 8,
  'threaded.unwiredTerminal': 102,
  'threaded.wireDirection': 5,
  'threaded.wireType': 4873,
  'vi': 7394,
  'wt.cause.member.0x33': 22,
  'wt.cause.member.0x37': 4,
  'wt.cause.member.0xd': 2,
  'wt.cause.noneNoCluster': 3372,
  'wt.cause.noneUntyped': 24,
  'wt.cause.typesDisagree': 22,
  'wt.cluster': 3455,
  'wt.code0x0': 7,
  'wt.code0x33': 55,
  'wt.code0x37': 29,
  'wt.code0x54': 109,
  'wt.code0x73': 1,
  'wt.code0x74': 15,
  'wt.code0xb': 25,
  'wt.code0xc': 2,
  'wt.code0xd': 6,
  'wt.code0xff': 103,
  'wt.refnum': 619,
  'wt.sole.cluster': 1338,
  'wt.sole.code0x33': 4,
  'wt.sole.code0x37': 3,
  'wt.sole.code0x54': 24,
  'wt.sole.code0x74': 2,
  'wt.sole.code0xb': 16,
  'wt.sole.code0xd': 4,
  'wt.sole.code0xff': 5,
  'wt.sole.refnum': 178,
};

const Map<String, ({int vis, int nodes, int sole})> kCorpusPrimReviewList = {
  'node class 0x34': (vis: 823, nodes: 1746, sole: 98),
  'Close Reference (primResID 8011)': (vis: 780, nodes: 3083, sole: 49),
  'node class 0xa9': (vis: 697, nodes: 2673, sole: 70),
  'node class 0x153': (vis: 534, nodes: 1424, sole: 327),
  'node class 0xd6': (vis: 415, nodes: 2657, sole: 29),
  'To More Specific Class (primResID 8016)': (vis: 364, nodes: 859, sole: 68),
  'Strip Path (primResID 1420)': (vis: 360, nodes: 841, sole: 16),
  'node class 0xbd': (vis: 318, nodes: 628, sole: 22),
  'node class 0xb6': (vis: 316, nodes: 760, sole: 19),
  'Variant To Data (primResID 8003)': (vis: 272, nodes: 530, sole: 26),
  'Open VI Reference (primResID 8010)': (vis: 253, nodes: 449, sole: 8),
  'node class 0x14a': (vis: 225, nodes: 385, sole: 0),
  'node class 0x170': (vis: 225, nodes: 385, sole: 0),
  'node class 0xeb': (vis: 206, nodes: 234, sole: 8),
  'Unregister For Events (primResID 2076)': (vis: 188, nodes: 210, sole: 0),
  'Call Chain (primResID 1999)': (vis: 166, nodes: 167, sole: 77),
  'node class 0x150': (vis: 164, nodes: 428, sole: 29),
  'Search and Replace String (primResID 3914)': (vis: 156, nodes: 263, sole: 18),
  'Enqueue Element (primResID 9111)': (vis: 153, nodes: 319, sole: 6),
  'Get Variant Attribute (primResID 8205)': (vis: 153, nodes: 307, sole: 32),
  'primResID 1103 (name not decoded)': (vis: 152, nodes: 213, sole: 18),
  'Boolean To (0,1) (primResID 1167)': (vis: 151, nodes: 555, sole: 33),
};

const ({int libraries, int entryPoints}) kCorpusForeignCalls = (libraries: 51, entryPoints: 481);

const int kCorpusReviewListFloor = 150;

const ({int identities, int nodes, int vis}) kCorpusPrimTotals = (identities: 243, nodes: 28843, vis: 13115);

const int kReviewListFloor = 10;

const ({int identities, int nodes}) kReviewListTotals = (identities: 82, nodes: 295);

const ({int vis, int sources}) kEmittedSources = (vis: 795, sources: 534);

({Map<String, int> tally, Set<String> sources, Map<String, int> prims, Set<String> foreign}) sweepLoweringChunk(
  (List<String>, Map<String, String>) input,
) {
  final (paths, index) = input;
  final tally = <String, int>{};
  final emitted = <String>{};
  final prims = <String, int>{};
  final foreign = <String>{};
  void bump(String key) => tally[key] = (tally[key] ?? 0) + 1;
  final units = <String, LvViUnit?>{};
  var builds = <LvViUnit, ({LvDataflow? dataflow, LvRefusal? refusal})>{};
  var registry = LvDeclarations();
  var clusterWireCause = <int, String>{};
  var untypedFamilies = <String>{};
  final libraries = LvProjectIndex.scan(corpusVi);
  LvViUnit? load(String path, String fileName) => units.putIfAbsent(path, () {
    try {
      return LvViUnit.fromSections(decodeSections(File(path).readAsBytesSync()), fileName: fileName, path: path);
    } catch (_) {
      return null;
    }
  });
  LvViUnit? resolveByName(String name) {
    final path = index[name.toLowerCase()];
    return path == null ? null : load(path, name);
  }

  /// The callee's file through the caller's link entry, else the corpus-wide file name index.
  ({LvViUnit? unit, String how}) resolveCallee(LvCallee callee) {
    if ((callee.link, callee.caller.path) case (final link?, final viPath?)) {
      final linked = libraries.fileOfLink(link, viPath: viPath);
      if (linked != null && File(linked).existsSync()) return (unit: load(linked, callee.fileName), how: 'link');
    }
    return (unit: resolveByName(callee.fileName), how: 'name');
  }

  LvViUnit? resolve(LvCallee callee) => resolveCallee(callee).unit;

  final classData = <String, ViModel?>{};
  ViModel? resolveClass(List<String> qualifiedName) => classData.putIfAbsent(qualifiedName.join(':'), () {
    final path = libraries.fileOf(qualifiedName);
    if (path == null) return null;
    try {
      final control = LvLibraryFile.parse(
        File(path).readAsStringSync(),
        fileName: qualifiedName.last,
      ).privateDataControl;
      return control == null ? null : buildViModel(control);
    } catch (_) {
      return null;
    }
  });

  final paneWidths = <String, int?>{};
  int? paneWidth(String name) => paneWidths.putIfAbsent(name.toLowerCase(), () {
    final path = index[name.toLowerCase()];
    if (path == null) return null;
    try {
      return buildViModelFromDecoded(decodeSections(File(path).readAsBytesSync())).paneTerminals.length;
    } catch (_) {
      return null;
    }
  });

  ({LvDataflow? dataflow, LvRefusal? refusal}) buildOf(LvViUnit unit) => builds.putIfAbsent(
    unit,
    () => buildLvDataflow(
      unit.diagram,
      pool: unit.pool,
      declarations: registry,
      caller: unit,
      resolve: resolve,
      resolveClass: resolveClass,
    ),
  );

  LvDataflow? flowOf(LvViUnit unit) => buildOf(unit).dataflow;

  void bindCall(LvDataflow flow, LvViUnit caller, LvSubViUnit call) {
    bump('call');
    if (call.calleeName == null) return bump('call.unnamed');
    final name = call.calleeName!;
    final link = caller.linkTo(name);
    if (link == null && caller.links.any((l) => l.qualifiedName.lastOrNull?.toLowerCase() == name.toLowerCase())) {
      return bump('call.ambiguousLink');
    }
    if (kLvStockVis.containsKey(name.toLowerCase()) &&
        (link?.path?.text.startsWith('<vilib>') ?? caller.links.isEmpty)) {
      return bump('call.via.stock');
    }
    final resolved = resolveCallee(LvCallee(caller: caller, fileName: name, link: link));
    final callee = resolved.unit;
    if (callee == null) return bump('call.calleeMissing');
    bump('call.via.${resolved.how}');
    if (callee.paneTerminals.isEmpty) return bump('call.noPane');
    if (callee.paneTerminals.length != call.panePorts.length) return bump('call.paneWidthMismatch');
    bump('call.paneMatched');
    final calleeFlow = flowOf(callee);
    for (var pane = 0; pane < call.panePorts.length; pane++) {
      final holder = call.panePorts[pane];
      final into = flow.into(holder), outOf = flow.outOf(holder);
      if (into == null && outOf == null) continue;
      bump('term.wired');
      final terminal = callee.paneTerminal(pane);
      if (terminal == null) {
        bump('term.unresolved');
        continue;
      }
      bump('term.resolved');
      bump((into != null) == !lvEndpointIsSink(terminal) ? 'term.dirAgree' : 'term.dirDisagree');
      final declared = calleeFlow == null
          ? null
          : (calleeFlow.into(terminal.oid) ?? calleeFlow.outOf(terminal.oid))?.type;
      if (declared == null) {
        bump('term.calleeUntyped');
        continue;
      }
      bump(declared.dartType == (into ?? outOf)!.type.dartType ? 'term.typeAgree' : 'term.typeDisagree');
    }
  }

  void censusInPlaceElement(ViDiagram diagram, LvRefusal? refusal) {
    var structures = 0;
    final border = <int>[];
    for (final object in diagram.objects) {
      if (object.kind == kLvInPlaceElementClass) structures++;
      if (kLvInPlaceElementBorderClasses.contains(object.kind)) border.add(object.kind);
    }
    if (structures == 0) return;
    bump('ipe.vis');
    for (var i = 0; i < structures; i++) {
      bump('ipe.structures');
    }
    for (final code in border) {
      bump('ipe.border.0x${code.toRadixString(16)}');
    }
    final blocked =
        refusal != null &&
        refusal.kind == LvRefusalKind.structure &&
        diagram.byId[refusal.oid]?.kind == kLvInPlaceElementClass;
    if (!blocked) return;
    bump('ipe.blocked');
    bump(
      border.every((code) => code == kLvDataValueRefBorderClass)
          ? 'ipe.blocked.identifiedOnly'
          : 'ipe.blocked.undecodedAccess',
    );
  }

  void censusConditionals(ViDiagram diagram) {
    for (final object in diagram.objects) {
      if (object.kind != LvTerminalRole.conditional.code) continue;
      bump('cond');
      bump('cond.glyph${object.termBmp ?? 'None'}');
      final dcoFlags = diagram.terminalDco(object.oid)?.objFlags ?? 0;
      if (dcoFlags & 0x1 != 0) bump('cond.dcoBit0');
      if (dcoFlags & 0x1000 != 0) bump('cond.dcoBit12');
    }
  }

  Map<int, (LvViUnit, int)> paneTerminalsOf(LvViUnit caller, Set<int> endpoints) {
    final diagram = caller.diagram;
    final paneOf = <int, (LvViUnit, int)>{};
    for (final node in diagram.objects) {
      if (!kSubViCallNodeCodes.contains(node.kind)) continue;
      final name = node.label?.trim();
      if (name == null) continue;
      final lower = name.toLowerCase();
      if (!lower.endsWith('.vi') && !lower.endsWith('.vim')) continue;
      final ports = [
        for (final holder in diagram.childrenOf(node))
          if (holder.kind == kNodeEndpointDcoKind) holder.oid,
      ];
      if (!ports.any(endpoints.contains)) continue;
      final callee = resolveCallee(LvCallee(caller: caller, fileName: name, link: caller.linkTo(name))).unit;
      if (callee == null || ports.length != callee.paneTerminals.length || callee.paneTerminals.isEmpty) continue;
      for (var pane = 0; pane < ports.length; pane++) {
        paneOf[ports[pane]] = (callee, pane);
      }
    }
    return paneOf;
  }

  void censusClusterWires(LvViUnit unit) {
    final diagram = unit.diagram;
    final pool = unit.pool;
    final clusterEndpoints = <int>{
      for (final wire in diagram.wires)
        if (kLvWireClusterCodes.contains(wire.signalType?.typeCode)) ...wire.endpointOids,
    };
    if (clusterEndpoints.isEmpty) return;
    final paneOf = paneTerminalsOf(unit, clusterEndpoints);
    final anyTyped = diagram.objects.any((object) => object.resolvedType != null);
    final registry = LvDeclarations();
    final mappingOf = <ViType, LvTypeMapping>{};
    LvTypeMapping typeOf(ViType type, List<ViType> owner) =>
        mappingOf.putIfAbsent(type, () => mapLvType(type, owner, 0, registry));
    for (final wire in diagram.wires) {
      final signal = wire.signalType;
      if (signal == null || !kLvWireClusterCodes.contains(signal.typeCode)) continue;
      bump('clus');
      final array = (signal.arrayDims ?? 0) > 0;
      final shapes = <String>{}, bare = <String>{}, viaPane = <String>{}, viaKid = <String>{};
      final ownTypes = <String?>{}, kidTypes = <String?>{}, paneTypes = <String?>{};
      var paneTypedef = false, ownTypedef = false;
      final kidAtCall = <String?>{}, kidOffCall = <String?>{}, kidOffCallShape = <String>{};
      LvTypeMapping? ownMapping;
      for (final endpoint in wire.endpointOids) {
        final type = lvClusterOfEndpoint(diagram, endpoint, array: array);
        if (type == null) continue;
        if (type is ViTypedefType && type.componentCount > 0) ownTypedef = true;
        final shape = lvClusterShape(type, pool);
        shapes.add(shape);
        if (type.kind == ViDataType.cluster) bare.add(shape);
        final mapping = typeOf(type, pool);
        ownMapping ??= mapping;
        ownTypes.add(mapping.dartType);
      }
      for (final endpoint in wire.endpointOids) {
        for (final part in diagram.children(endpoint)) {
          final type = array ? part.resolvedElementType : part.resolvedType;
          if (lvClusterBase(type) == null) continue;
          final shape = lvClusterShape(type!, pool);
          viaKid.add(shape);
          final mapped = typeOf(type, pool).dartType;
          kidTypes.add(mapped);
          if (paneOf.containsKey(endpoint)) {
            kidAtCall.add(mapped);
          } else {
            kidOffCall.add(mapped);
            kidOffCallShape.add(shape);
          }
        }
      }
      for (final endpoint in wire.endpointOids) {
        if (paneOf[endpoint] case (final callee, final pane)) {
          final terminal = callee.paneTerminal(pane);
          if (terminal == null) continue;
          final type = lvClusterOfEndpoint(callee.diagram, terminal.oid, array: array);
          if (type == null) continue;
          if (type is ViTypedefType && type.componentCount > 0) paneTypedef = true;
          viaPane.add(lvClusterShape(type, callee.pool));
          paneTypes.add(typeOf(type, callee.pool).dartType);
        }
      }
      final own = switch (shapes.length) {
        0 => 'none',
        1 => 'one',
        _ => 'many',
      };
      bump('clus.$own');
      if (shapes.length == 1 && bare.isEmpty) bump('clus.viaTypedef');
      if (bare.length == 1 && shapes.length > 1) bump('clus.typedefContradicts');
      if (viaPane.length == 1) bump('clus.pane.$own');
      if (shapes.length == 1 && viaPane.length == 1) {
        final agrees = shapes.single == viaPane.single;
        bump(agrees ? 'clus.paneAgrees' : 'clus.paneDisagrees');
        if (!agrees && shapes.single.split('|').last == viaPane.single.split('|').last) {
          bump('clus.paneNameOnly');
        }
      }
      if (viaKid.length == 1) bump('clus.kid.$own');
      if (shapes.length == 1 && viaKid.length == 1) {
        final agrees = shapes.single == viaKid.single;
        bump(agrees ? 'clus.kidAgrees' : 'clus.kidDisagrees');
        if (!agrees && shapes.single.split('|').last == viaKid.single.split('|').last) {
          bump('clus.kidNameOnly');
        }
      }
      final ownCount = switch (ownTypes.length) {
        0 => 'none',
        1 => 'one',
        _ => 'many',
      };
      bump('clusType.$ownCount');
      if (ownTypes.length == 1 && kidTypes.length == 1) {
        final agrees = ownTypes.single == kidTypes.single;
        bump(agrees ? 'clusType.kidAgrees' : 'clusType.kidDisagrees');
        if (!agrees && shapes.length == 1 && viaKid.length == 1) {
          bump(
            _clusterMemberCodes(shapes.single) == _clusterMemberCodes(viaKid.single)
                ? 'clusType.kidLabelOnly'
                : 'clusType.kidShapeDiffers',
          );
        }
      }
      if (ownTypes.isEmpty && kidTypes.length == 1) {
        if (kidTypes.single == null) {
          bump('clusType.kidWouldNotMap');
        } else {
          bump('clusType.kidWouldDecide');
          bump(paneTypes.length == 1 ? 'clusType.kidChecked' : 'clusType.kidUnchecked');
        }
      }
      if (paneTypes.length == 1) bump('clusType.pane.$ownCount');
      if (ownTypes.length == 1 && paneTypes.length == 1) {
        final agrees = ownTypes.single == paneTypes.single;
        bump(agrees ? 'clusType.paneAgrees' : 'clusType.paneDisagrees');
        bump(
          'clusType.pane.${agrees ? 'agrees' : 'disagrees'}.${paneTypedef ? 'typedef' : 'plain'}.${ownTypedef ? 'ownTypedef' : 'ownPlain'}',
        );
        if (!agrees && shapes.length == 1 && viaPane.length == 1) {
          bump(
            _clusterMemberCodes(shapes.single) == _clusterMemberCodes(viaPane.single)
                ? 'clusType.paneLabelOnly'
                : 'clusType.paneShapeDiffers',
          );
        }
      }
      if (ownTypes.isEmpty && paneTypes.length == 1) {
        bump(paneTypes.single == null ? 'clusType.paneWouldNotMap' : 'clusType.paneWouldDecide');
        if (paneTypes.single != null) bump('clusType.paneWouldDecide.${paneTypedef ? 'typedef' : 'plain'}');
      }
      if (paneTypes.length == 1 && kidAtCall.length == 1) {
        bump(kidAtCall.single == paneTypes.single ? 'clusType.paneAtCallAgrees' : 'clusType.paneAtCallDisagrees');
      }
      if (paneTypes.length == 1 && kidOffCall.length == 1) {
        final agrees = kidOffCall.single == paneTypes.single;
        bump(agrees ? 'clusType.paneOffCallAgrees' : 'clusType.paneOffCallDisagrees');
        if (!agrees && kidOffCallShape.length == 1 && viaPane.length == 1) {
          bump(
            _clusterMemberCodes(kidOffCallShape.single) == _clusterMemberCodes(viaPane.single)
                ? 'clusType.paneOffCallLabelOnly'
                : 'clusType.paneOffCallShapeDiffers',
          );
        }
      }
      String causeOfWire() {
        if (ownTypes.isEmpty) {
          if (!anyTyped) return 'noneUntyped';
          final anyIndex = wire.endpointOids.any(
            (endpoint) => [
              if (diagram.byId[endpoint] case final object?) object,
              ...diagram.children(endpoint),
            ].any((object) => object.typeDescIdx != null),
          );
          return anyIndex ? 'noneNoCluster' : 'noneNoIndex';
        }
        if (ownTypes.length > 1) return 'typesDisagree';
        final mapping = ownMapping!;
        if (mapping.dartType == null) {
          final code = mapping.unmappedCode;
          return code == null ? 'descriptor' : 'member.0x${code.toRadixString(16)}';
        }
        if (lvDeclarationClosure(mapping.declarations).any((declaration) => declaration.undeclarable != null)) {
          return 'undeclarable';
        }
        return 'typed';
      }

      final cause = causeOfWire();
      bump('clus.why.$cause');
      if (cause != 'typed') {
        clusterWireCause[wire.signalOid] = cause;
        untypedFamilies.add('cluster');
      }
      if (shapes.isNotEmpty) continue;
      if (cause == 'noneUntyped') bump('clus.noneUntyped');
      if (cause == 'noneNoIndex') bump('clus.noneNoIndex');
      for (final endpoint in wire.endpointOids) {
        if (diagram.byId[endpoint]?.typeDescIdx != null) bump('clus.epTypeIdx');
      }
    }
  }

  void censusDeclarations(ViDiagram diagram, List<ViType> pool) {
    final registry = LvDeclarations();
    for (final wire in diagram.wires) {
      final signal = wire.signalType;
      if (signal == null || !kLvWireClusterCodes.contains(signal.typeCode)) continue;
      if (mapLvWireType(signal).isMapped) continue;
      final array = (signal.arrayDims ?? 0) > 0;
      final resolved = <ViType>[
        for (final endpoint in wire.endpointOids)
          if (lvClusterOfEndpoint(diagram, endpoint, array: array) case final cluster?) cluster,
      ];
      if (resolved.isEmpty) continue;
      if ({for (final cluster in resolved) lvClusterShape(cluster, pool)}.length != 1) continue;
      lvClusterWireType(signal, resolved.first, pool, registry);
    }
    final declarations = registry.all.toList();
    if (declarations.isEmpty) return;
    bump('decl.vi');
    for (final declaration in declarations) {
      bump('decl');
      bump(declaration.isEnum ? 'decl.enum' : 'decl.cluster');
      if (declaration.name != declaration.preferredName) bump('decl.suffixed');
      if (declaration.label == null) bump('decl.anonymous');
      if (declaration.undeclarable != null) bump('decl.noItems');
      if (declaration.fields.any((field) => field.label == null)) bump('decl.unnamedMember');
      final labels = [for (final field in declaration.fields) field.label];
      final named = LvNaming.declarationFields(labels);
      for (var index = 0; index < labels.length; index++) {
        if (named[index] != LvNaming.declarationFields([labels[index]]).single) bump('decl.displacedMember');
      }
    }
  }

  void censusIndexArrays(ViDiagram diagram) {
    for (final node in diagram.objects) {
      if (node.kind != LvNodeClass.indexArray.code) continue;
      bump('idx');
      final roles = [
        for (final holder in diagram.childrenOf(node))
          if (holder.kind == kNodeEndpointDcoKind) diagram.childrenOf(holder).firstOrNull?.objFlags ?? 0,
      ];
      bump(_indexArrayShape(roles) ? 'idx.regular' : 'idx.irregular');
      for (final role in roles) {
        if (role == LvArrayTerminalRole.singleIndex) bump('idx.rank1Index');
        if (role == LvArrayTerminalRole.groupFirst) bump('idx.groupFirstIndex');
        if (role == LvArrayTerminalRole.groupLast) bump('idx.groupLastIndex');
      }
    }
  }

  void censusRefnumWires(LvViUnit unit) {
    final diagram = unit.diagram;
    final refnumEndpoints = <int>{
      for (final wire in diagram.wires)
        if (kLvWireRefnumCodes.contains(wire.signalType?.typeCode)) ...wire.endpointOids,
    };
    final paneOf = refnumEndpoints.isEmpty ? const <int, (LvViUnit, int)>{} : paneTerminalsOf(unit, refnumEndpoints);
    for (final wire in diagram.wires) {
      final signal = wire.signalType;
      if (signal == null) continue;
      final dims = signal.arrayDims;
      if (kLvWireRefnumCodes.contains(signal.typeCode)) {
        bump('ref');
        bump(dims == null ? 'ref.undecided' : 'ref.scalar');
        final viaEndpoint = <int>{}, viaPart = <int>{}, viaPane = <int>{};
        for (final endpoint in wire.endpointOids) {
          var walker = diagram.byId[endpoint];
          for (var depth = 0; walker != null && depth < 2; depth++) {
            if (_refnumDims(walker) case final answer?) {
              viaEndpoint.add(answer);
              break;
            }
            final parent = walker.parentOid;
            walker = parent == null ? null : diagram.byId[parent];
          }
          for (final part in diagram.children(endpoint)) {
            if (_refnumDims(part) case final answer?) viaPart.add(answer);
          }
          if (paneOf[endpoint] case (final callee, final pane)) {
            final terminal = callee.paneTerminal(pane);
            if (terminal == null) continue;
            var calleeWalker = callee.diagram.byId[terminal.oid];
            for (var depth = 0; calleeWalker != null && depth < 2; depth++) {
              if (_refnumDims(calleeWalker) case final answer?) {
                viaPane.add(answer);
                break;
              }
              final parent = calleeWalker.parentOid;
              calleeWalker = parent == null ? null : callee.diagram.byId[parent];
            }
          }
        }
        if (viaPart.length > 1) bump('ref.part.split');
        if (viaEndpoint.length > 1) bump('ref.ep.split');
        if (viaPane.length > 1) bump('ref.pane.split');
        if (dims != null) {
          if (viaPart.length == 1) bump(viaPart.single == dims ? 'ref.part.agrees' : 'ref.part.contradicts');
          if (viaEndpoint.length == 1) bump(viaEndpoint.single == dims ? 'ref.ep.agrees' : 'ref.ep.contradicts');
          if (viaPane.length == 1) bump(viaPane.single == dims ? 'ref.pane.lawAgrees' : 'ref.pane.lawContradicts');
        } else {
          if (viaPart.length == 1 && viaPane.length == 1) {
            final agrees = viaPart.single == viaPane.single;
            bump(agrees ? 'ref.pane.vsAgrees' : 'ref.pane.vsContradicts');
            if (!agrees) bump('ref.pane.vs${viaPart.single > viaPane.single ? 'Invented' : 'Missed'}');
            bump(
              'ref.pane.contraCell.${signal.typeCode.toRadixString(16)}_d${signal.depth}'
              '.${agrees ? 'agrees' : 'contradicts'}',
            );
          }
          if (viaPane.length == 1) bump('ref.pane.dims${viaPane.single}');
          if (viaPart.length == 1) {
            bump('ref.part.decides');
            bump('ref.part.dims${viaPart.single}');
            bump('ref.part.base${signal.depth - viaPart.single}');
            if (kLvRefnumContradictedCells.contains((signal.typeCode, signal.depth))) {
              bump('ref.part.contradictedCell');
            } else {
              bump('ref.part.read');
            }
          } else if (viaPart.isEmpty) {
            bump('ref.part.silent');
          }
          bump('render.refUndecided.${signal.renderStyle == null ? 'styleMute' : 'styleSpeaks'}');
        }
      } else if (dims != null) {
        bump('flag${signal.flags}.${dims > 0 ? 'array' : 'scalar'}');
      }
      if (dims == null) {
        bump('render.lawSilent.${signal.renderStyle == null ? 'styleMute' : 'styleSpeaks'}');
      }
      if (!kLvWireClusterCodes.contains(signal.typeCode) && !mapLvWireType(signal).isMapped) {
        untypedFamilies.add(_wireFamilyName(signal.typeCode));
      }
    }
  }

  void censusWireTypeRefusal(ViDiagram diagram, LvRefusal refusal) {
    final wire = diagram.wires.where((wire) => wire.signalOid == refusal.oid).firstOrNull;
    final signal = wire?.signalType;
    if (signal == null) return bump('wt.noSignalWord');
    final family = _wireFamilyName(signal.typeCode);
    bump('wt.$family');
    if (untypedFamilies.length == 1) bump('wt.sole.$family');
    if (clusterWireCause[wire!.signalOid] case final cause?) bump('wt.cause.$cause');
  }

  void walk(LvDataflow flow, LvViUnit caller, LvRegion region) {
    for (final unit in region.units) {
      if (unit is LvSubViUnit) bindCall(flow, caller, unit);
      if (unit is LvStructUnit) {
        for (final frame in unit.frames) {
          walk(flow, caller, frame);
        }
      }
    }
  }

  void censusPrimitives(ViDiagram diagram) {
    final here = <String, int>{};
    for (final object in diagram.objects) {
      if (object.category != ViObjectKind.node) continue;
      if (kSubViCallNodeCodes.contains(object.kind)) continue;
      if (object.kind == HeapObjectClass.bdCallLibrary.code) continue;
      final op = object.primResId == null ? null : PrimOp.fromId(object.primResId!);
      if (lvPrimHasRule(op: op, classCode: object.kind, primResId: object.primResId)) continue;
      final key = _reviewKey(op, object);
      here[key] = (here[key] ?? 0) + 1;
    }
    for (final entry in here.entries) {
      prims['nodes|${entry.key}'] = (prims['nodes|${entry.key}'] ?? 0) + entry.value;
      prims['vis|${entry.key}'] = (prims['vis|${entry.key}'] ?? 0) + 1;
    }
    if (here.length == 1) {
      prims['sole|${here.keys.single}'] = (prims['sole|${here.keys.single}'] ?? 0) + 1;
    }
  }

  void censusCallPaneWidths(ViDiagram diagram) {
    for (final node in diagram.objects) {
      if (!kSubViCallNodeCodes.contains(node.kind)) continue;
      final name = node.label?.trim().toLowerCase();
      if (name == null || !(name.endsWith('.vi') || name.endsWith('.vim'))) continue;
      final width = paneWidth(name);
      if (width == null || width == 0) continue;
      final holders = diagram.childrenOf(node).where((kid) => kid.kind == kNodeEndpointDcoKind).length;
      final tag = 'pane.0x${node.kind.toRadixString(16)}';
      bump(holders == width ? '$tag.equal' : '$tag.differs');
    }
  }

  void censusForeignCalls(ViDiagram diagram) {
    var here = 0;
    for (final object in diagram.objects) {
      if (object.kind != HeapObjectClass.bdCallLibrary.code) continue;
      here++;
      bump('foreign.node');
      final library = object.foreignLibraryPath;
      final entry = object.foreignEntryPoint;
      if (library == null) bump('foreign.noLibrary');
      if (entry == null) bump('foreign.noEntryPoint');
      if (library != null) foreign.add('lib|$library');
      if (entry != null) foreign.add('entry|$entry');
    }
    if (here > 0) bump('foreign.vi');
  }

  for (final path in paths) {
    final unit = load(path, path.split(Platform.pathSeparator).last);
    if (unit == null) continue;
    bump('vi');
    censusPrimitives(unit.diagram);
    censusCallPaneWidths(unit.diagram);
    censusForeignCalls(unit.diagram);
    builds = <LvViUnit, ({LvDataflow? dataflow, LvRefusal? refusal})>{};
    registry = LvDeclarations();
    clusterWireCause = <int, String>{};
    untypedFamilies = <String>{};
    censusConditionals(unit.diagram);
    censusClusterWires(unit);
    censusDeclarations(unit.diagram, unit.pool);
    censusIndexArrays(unit.diagram);
    censusRefnumWires(unit);
    final built = buildOf(unit);
    censusInPlaceElement(unit.diagram, built.refusal);
    if (built.dataflow case final flow?) walk(flow, unit, flow.root);
    if (built.refusal case final refusal? when refusal.kind == LvRefusalKind.wireType) {
      censusWireTypeRefusal(unit.diagram, refusal);
    }
    final sources = <String?>[];
    for (final mode in LvErrorMode.values) {
      final result = emitLvLibrary(
        unit,
        functionName: 'lowered',
        errorMode: mode,
        resolveSubVi: resolve,
        resolveClass: resolveClass,
      );
      bump('${mode.name}.${result.refusal?.kind.name ?? 'lowered'}');
      sources.add(result.source);
      if (mode == LvErrorMode.exceptions && result.source != null) emitted.add(result.source!);
    }
    if (sources.every((source) => source != null)) {
      bump(sources.first == sources.last ? 'modes.same' : 'modes.differ');
    }
  }
  return (tally: tally, sources: emitted, prims: prims, foreign: foreign);
}

Future<({Map<String, int> tally, Set<String> sources, Map<String, int> prims, Set<String> foreign})> corpusSweep(
  Directory corpus,
) => _corpusSweep ??= _runCorpusSweep(corpus);

Future<({Map<String, int> tally, Set<String> sources, Map<String, int> prims, Set<String> foreign})>? _corpusSweep;

Future<({Map<String, int> tally, Set<String> sources, Map<String, int> prims, Set<String> foreign})> _runCorpusSweep(
  Directory corpus,
) async {
  final paths = corpusViPaths();
  final index = <String, String>{};
  for (final path in paths) {
    index.putIfAbsent(path.split(Platform.pathSeparator).last.toLowerCase(), () => path);
  }
  final workers = (Platform.numberOfProcessors - 2).clamp(1, 16);
  final chunks = List.generate(workers, (_) => <String>[]);
  for (var i = 0; i < paths.length; i++) {
    chunks[i % workers].add(paths[i]);
  }
  final results = await Future.wait(chunks.map((chunk) => Isolate.run(() => sweepLoweringChunk((chunk, index)))));
  final tally = <String, int>{};
  final sources = <String>{};
  final prims = <String, int>{};
  final foreign = <String>{};
  for (final result in results) {
    result.tally.forEach((key, value) => tally[key] = (tally[key] ?? 0) + value);
    result.prims.forEach((key, value) => prims[key] = (prims[key] ?? 0) + value);
    sources.addAll(result.sources);
    foreign.addAll(result.foreign);
  }
  return (tally: tally, sources: sources, prims: prims, foreign: foreign);
}

void main() {
  final snippets = kSnippetLoweringOutcomes.keys.toList();

  test('every tracked snippet lowers, or refuses for its pinned reason', () {
    final measured = <String, String>{};
    for (final name in snippets) {
      final vi = snippetVi(name);
      final result = emitLvFunction(vi.diagram, functionName: 'lowered', sourceNote: name, pool: vi.pool);
      measured[name] = result.refusal?.kind.name ?? 'lowered';
      if (result.refusal == null) {
        expect(result.source, contains(' lowered('), reason: '$name emitted no function');
      }
    }
    expect(measured, kSnippetLoweringOutcomes);
    expect(
      measured.values.where((outcome) => outcome == 'lowered').length,
      kSnippetLoweringOutcomes.values.where((outcome) => outcome == 'lowered').length,
    );
  });

  test('the threaded error mode changes only the VIs that carry an error cluster', () {
    final measured = <String, String>{};
    for (final name in snippets) {
      final vi = snippetVi(name);
      final result = emitLvFunction(
        vi.diagram,
        functionName: 'lowered',
        sourceNote: name,
        pool: vi.pool,
        errorMode: LvErrorMode.threaded,
      );
      final outcome = result.refusal?.kind.name ?? 'lowered';
      if (outcome != kSnippetLoweringOutcomes[name]) measured[name] = outcome;
    }
    expect(measured, kSnippetThreadedDifferences);
  });

  test('MD5 refuses on exactly the nodes it is pinned to refuse on', () {
    final vi = snippetVi('MD5');
    final flow = buildLvDataflow(vi.diagram, pool: vi.pool).dataflow!;
    final measured = <String, int>{};
    void bump(String key) => measured[key] = (measured[key] ?? 0) + 1;
    void walk(LvRegion region) {
      for (final node in region.units) {
        switch (node) {
          case LvStructUnit():
            final selector = node.terminals.where((t) => t.role == LvTerminalRole.selector).firstOrNull;
            final outer = selector?.outerPort;
            final type = outer == null ? null : flow.into(outer)?.type;
            final twoWay = type != null && (type.isErrorCluster || type.carrier == LvCarrier.boolean);
            if (type != null && !twoWay && node.selectorRanges.isEmpty) {
              bump('caseSelector over ${type.dartType}');
            }
            for (final frame in node.frames) {
              walk(frame);
            }
          case LvPrimUnit():
            if (_loweringOf(node, flow) != null) continue;
            bump(_blockerKey(node));
          case LvConstUnit():
            final type = flow.outOf(node.port)?.type;
            if (type != null && !_constantHasValue(node, type)) bump('constantValue ${type.dartType}');
          case _:
            break;
        }
      }
    }

    walk(flow.root);
    printOnFailure(
      'measured:\n${[for (final key in measured.keys) "  '$key': ${measured[key]},"].join('\n')}',
    );
    expect(measured, kMd5Blockers);
  });

  test('cluster wires resolve their member shape through their endpoints', () {
    var signals = 0, resolved = 0, disagreeing = 0, unresolved = 0;
    for (final name in snippets) {
      final vi = snippetVi(name);
      final measured = _clusterWires(vi.diagram, vi.pool);
      signals += measured.signals;
      resolved += measured.resolved;
      disagreeing += measured.disagreeing;
      unresolved += measured.unresolved;
    }
    expect(
      (signals: signals, resolved: resolved, disagreeing: disagreeing, unresolved: unresolved),
      kSnippetClusterWires,
    );
  });

  test(
    'subVI calls bind through the connector pane, and both error modes sweep the corpus',
    () async {
      final measured = (await corpusSweep(corpusVi)).tally;
      printOnFailure(
        'measured:\n${[for (final key in measured.keys.toList()..sort()) "  '$key': ${measured[key]},"].join('\n')}',
      );
      expect(measured, {...kCorpusLoweringSweep, ...kCorpusInPlaceElement});
      expect(measured['term.dirDisagree'], isNull, reason: 'the pane binding contradicts the caller\'s own direction');
    },
  );

  test(
    'every emitted library analyzes clean at the recommended lint set, and compiles',
    () async {
      final swept = await corpusSweep(corpusVi);
      expect(
        (vis: swept.tally['exceptions.lowered'], sources: swept.sources.length),
        kEmittedSources,
        reason: 'the set of VIs that lower changed; re-pin it before reading the analyzer result',
      );
      final scratch = _scratchPackage(swept.sources);
      try {
        final analyzed = Process.runSync(_kDart, [
          'analyze',
          '--fatal-infos',
          '${scratch.path}/lib',
        ], workingDirectory: scratch.path);
        expect(analyzed.exitCode, 0, reason: 'the emitted code is not clean:\n${analyzed.stdout}${analyzed.stderr}');
        final compiled = Process.runSync(_kDart, [
          'compile',
          'kernel',
          'bin/all.dart',
          '-o',
          '${scratch.path}/all.dill',
        ], workingDirectory: scratch.path);
        expect(
          compiled.exitCode,
          0,
          reason: 'the emitted code does not compile:\n${compiled.stdout}${compiled.stderr}',
        );
      } finally {
        scratch.deleteSync(recursive: true);
      }
    },
  );

  test(
    'the corpus primitive review list is exactly what the whole corpus holds',
    () async {
      final prims = (await corpusSweep(corpusVi)).prims;
      final identities = <String>{for (final key in prims.keys) key.split('|').skip(1).join('|')};
      final measured = <String, ({int vis, int nodes, int sole})>{
        for (final identity in identities)
          identity: (
            vis: prims['vis|$identity'] ?? 0,
            nodes: prims['nodes|$identity'] ?? 0,
            sole: prims['sole|$identity'] ?? 0,
          ),
      };
      final ranked = identities.toList()
        ..sort((a, b) {
          final byVis = measured[b]!.vis.compareTo(measured[a]!.vis);
          return byVis != 0 ? byVis : a.compareTo(b);
        });
      final frequent = <String, ({int vis, int nodes, int sole})>{
        for (final identity in ranked)
          if (measured[identity]!.vis >= kCorpusReviewListFloor) identity: measured[identity]!,
      };
      printOnFailure(
        'measured:\n${[
          for (final identity in ranked) "  '$identity': (vis: ${measured[identity]!.vis}, "
                'nodes: ${measured[identity]!.nodes}, sole: ${measured[identity]!.sole}),',
        ].join('\n')}',
      );
      expect(frequent, kCorpusPrimReviewList);
      expect(
        (
          identities: identities.length,
          nodes: measured.values.fold(0, (sum, entry) => sum + entry.nodes),
          vis: measured.values.fold(0, (sum, entry) => sum + entry.vis),
        ),
        kCorpusPrimTotals,
        reason: 'the corpus review list moved; re-pin it against the measured corpus',
      );
    },
  );

  test(
    'every Call Library Function node names the library and entry point it calls',
    () async {
      final swept = await corpusSweep(corpusVi);
      final measured = (
        libraries: swept.foreign.where((entry) => entry.startsWith('lib|')).length,
        entryPoints: swept.foreign.where((entry) => entry.startsWith('entry|')).length,
      );
      printOnFailure('measured: $measured');
      expect(measured, kCorpusForeignCalls);
    },
  );

  test('the primitive review list is exactly what the snippet corpus holds', () {
    final counts = <String, int>{};
    for (final name in snippets) {
      for (final object in snippetDiagram(name).objects) {
        if (object.category != ViObjectKind.node) continue;
        if (kSubViCallNodeCodes.contains(object.kind)) continue;
        final op = object.primResId == null ? null : PrimOp.fromId(object.primResId!);
        if (lvPrimHasRule(op: op, classCode: object.kind, primResId: object.primResId)) continue;
        final key = _reviewKey(op, object);
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    final frequent = <String, int>{
      for (final entry in counts.entries)
        if (entry.value >= kReviewListFloor) entry.key: entry.value,
    };
    expect(frequent, kSnippetPrimReviewList);
    expect(
      (identities: counts.length, nodes: counts.values.fold(0, (sum, count) => sum + count)),
      kReviewListTotals,
      reason: 'the review list grew or shrank; re-pin it against the measured corpus',
    );
  });
}

final String _kDart = Platform.resolvedExecutable;

const String _kScratchPackageName = 'lv_emitted';

Directory _scratchPackage(Set<String> sources) {
  final dir = Directory.systemTemp.createTempSync('lv_emitted_');
  for (final sub in const ['lib', 'bin', '.dart_tool']) {
    Directory('${dir.path}/$sub').createSync();
  }
  final names = <String>[];
  for (final source in sources) {
    final name = 'vi_${names.length.toString().padLeft(4, '0')}.dart';
    File('${dir.path}/lib/$name').writeAsStringSync(source);
    names.add(name);
  }
  File('${dir.path}/bin/all.dart').writeAsStringSync(
    '${[
      for (var i = 0; i < names.length; i++) "import 'package:$_kScratchPackageName/${names[i]}' as vi$i;",
    ].join('\n')}\n\nvoid main() {}\n',
  );

  final configUri = Isolate.packageConfigSync!;
  final config = jsonDecode(File.fromUri(configUri).readAsStringSync()) as Map<String, dynamic>;
  final packages = (config['packages']! as List<dynamic>).cast<Map<String, dynamic>>();
  for (final package in packages) {
    package['rootUri'] = configUri.resolve(package['rootUri']! as String).toString();
  }
  final runtime = packages.firstWhere((package) => package['name'] == kLvRuntimePackage);
  packages.add({
    'name': _kScratchPackageName,
    'rootUri': dir.uri.toString(),
    'packageUri': 'lib/',
    'languageVersion': runtime['languageVersion'],
  });
  File('${dir.path}/.dart_tool/package_config.json').writeAsStringSync(jsonEncode(config));
  File('${dir.path}/pubspec.yaml').writeAsStringSync(
    'name: $_kScratchPackageName\n'
    'environment:\n  sdk: ^${runtime['languageVersion']}.0\n'
    'dependencies:\n  $kLvRuntimePackage: any\n',
  );
  File('${dir.path}/analysis_options.yaml').writeAsStringSync('include: package:lints/recommended.yaml\n');
  return dir;
}

List<String>? _loweringOf(LvPrimUnit node, LvDataflow flow) {
  List<LvPrimTerminal> terminals(List<int> ports, {required bool isInput}) => [
    for (final port in ports)
      if (isInput ? flow.into(port) : flow.outOf(port) case final edge?)
        LvPrimTerminal(
          port: port,
          type: edge.type,
          roleFlags: node.portRoleFlags[port] ?? 0,
          expression: 'x',
          memberName: node.portMemberName[port],
        ),
  ];
  return lvPrimLowering(
    LvPrimCall(
      op: node.op,
      primResId: node.primResId,
      classCode: node.classCode,
      inputs: terminals(node.inputPorts, isInput: true),
      outputs: terminals(node.outputPorts, isInput: false),
      outputPorts: node.outputPorts,
      portDrawnTop: node.portDrawnTop,
      requireImport: (_) {},
      names: LvNaming(),
      nodeFlags: node.nodeFlags,
    ),
  );
}

String _blockerKey(LvPrimUnit node) {
  if (node.op case final op?) return '${op.opName} (primResID ${op.id})';
  if (LvNodeClass.ofCode(node.classCode) case final nodeClass?) {
    return '${nodeClass.title} (class 0x${node.classCode.toRadixString(16)})';
  }
  if (node.primResId case final id?) return 'primResID $id';
  return 'node class 0x${node.classCode.toRadixString(16)}';
}

bool _constantHasValue(LvConstUnit node, LvWireType type) => type.dims == 0
    ? node.record.constBool != null || node.record.constText != null || node.record.constNumeric != null
    : node.record.constArray != null && node.record.constArrayDims != null;

({int signals, int resolved, int disagreeing, int unresolved}) _clusterWires(ViDiagram diagram, List<ViType> pool) {
  var signals = 0, resolved = 0, disagreeing = 0, unresolved = 0;
  for (final wire in diagram.wires) {
    final signal = wire.signalType;
    if (signal == null || !kLvWireClusterCodes.contains(signal.typeCode)) continue;
    signals++;
    final array = (signal.arrayDims ?? 0) > 0;
    final shapes = {
      for (final endpoint in wire.endpointOids)
        if (lvClusterOfEndpoint(diagram, endpoint, array: array) case final cluster?) lvClusterShape(cluster, pool),
    };
    if (shapes.isEmpty) {
      unresolved++;
    } else if (shapes.length == 1) {
      resolved++;
    } else {
      disagreeing++;
    }
  }
  return (signals: signals, resolved: resolved, disagreeing: disagreeing, unresolved: unresolved);
}

String _clusterMemberCodes(String shape) =>
    shape.split('|').last.split(',').map((member) => member.split(':').first).join(',');

bool _indexArrayShape(List<int> roles) {
  if (roles.isEmpty || roles.first != LvArrayTerminalRole.array) return false;
  var at = 1;
  while (at < roles.length) {
    final head = roles[at];
    if (head != LvArrayTerminalRole.output && head != LvArrayTerminalRole.grownOutput) {
      return false;
    }
    at++;
    var rank = 0;
    var opensGroup = false;
    while (at < roles.length &&
        roles[at] != LvArrayTerminalRole.output &&
        roles[at] != LvArrayTerminalRole.grownOutput) {
      final role = roles[at++];
      if (rank++ == 0) opensGroup = role & LvArrayTerminalRole.groupFirst != 0;
      if (role & LvArrayTerminalRole.groupLast != 0) break;
    }
    if (rank == 0 || !opensGroup) return false;
  }
  return true;
}

int? _refnumDims(ViHeapObject object) {
  ViType? unwrap(ViType? type) {
    for (var depth = 0; type != null && depth < kLvTypedefDepth; depth++) {
      if (type is! ViTypedefType) return type;
      type = type.base;
    }
    return null;
  }

  final own = unwrap(object.resolvedType);
  if (own == null) return null;
  if (own.kind == ViDataType.refnum) return 0;
  if (own is! ViArrayType || own.kind != ViDataType.array) return null;
  return unwrap(object.resolvedElementType)?.kind == ViDataType.refnum ? own.dimCount : null;
}

String _wireFamilyName(int code) {
  if (kLvWireClusterCodes.contains(code)) return 'cluster';
  if (kLvWireRefnumCodes.contains(code)) return 'refnum';
  return 'code0x${code.toRadixString(16)}';
}

String _reviewKey(PrimOp? op, ViHeapObject object) {
  if (op != null) return '${op.opName} (primResID ${op.id})';
  if (object.primResId case final id?) return 'primResID $id (name not decoded)';
  return 'node class 0x${object.kind.toRadixString(16)}';
}
