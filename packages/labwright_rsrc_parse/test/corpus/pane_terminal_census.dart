import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../corpus_dirs.dart';

const _laws = {'unbound', 'typeDiff', 'labelDiff', 'conNumDisagrees', 'unnumberedMany'};

Map<String, int> _census(CorpusVi vi) {
  final c = <String, int>{};
  void bump(String k) => c[k] = (c[k] ?? 0) + 1;
  final model = vi.model;
  final pane = model?.connectorPaneType;
  if (model == null || pane is! ViFunctionType) return c;
  final conp = ViConnectorPane(vi.decoded!.firstWhere((s) => s.tag == 'CONP').bytes);
  final paneTypes = conp is ViConnectorPaneInline ? conp.pool.types : model.types;
  final terminals = model.paneTerminals;
  final controls = [for (final panel in model.frontPanels) ...panel.controls];
  final hasMap = vi.decoded!.any((s) => s.tag == 'CPMp');
  for (var i = 0; i < pane.parameterCount; i++) {
    final parameter = paneTypes[pane.parameterIndexAt(i)];
    if (parameter is ViVoidType) continue;
    final control = terminals[i];
    if (control == null) {
      bump('unbound');
      continue;
    }
    if (conp is! ViConnectorPaneInline && control.resolvedType?.type.offset != parameter.offset) bump('typeDiff');
    if (control.typeName != parameter.label) bump('labelDiff');
    if (hasMap) {
      final numbered = controls.where((o) => o.dataObject?.conNum == i).toList();
      if (numbered.length == 1 && numbered.single != control) bump('conNumDisagrees');
    }
  }
  if (!hasMap && controls.where((o) => o.dataObject?.conNum == null).length > 1) bump('unnumberedMany');
  return c;
}

const paneTerminalCensusLaw = CorpusLaw('pane_terminal_census', _census);

void paneTerminalCensusTests() {
  test('every wired connector-pane terminal names its panel control by type and label', () async {
    expect(await paneTerminalCensusLaw.nonzero(_laws), kPaneTerminalBreaks);
  });
}

const kPaneTerminalBreaks = <String, Map<String, int>>{
  'vi-corpus/sources/EliMattingly22__Simple_Impedance_Analyzer/LabView/CurveTrace_Single.vi': {'unbound': 1},
  'vi-corpus/sources/EliMattingly22__Simple_Impedance_Analyzer/LabView/Impedance_SingleStats.vi': {'unbound': 1},
  'vi-corpus/sources/EliMattingly22__Simple_Impedance_Analyzer/LabView/Impedance_Sweep_Freq.vi': {'unbound': 1},
  'vi-corpus/sources/KurtDing__LabVIEW_Pong/LV_Pong LV8.6 Folder/VI_Module/beep_pc.vi': {'unbound': 1},
  'vi-corpus/sources/KurtDing__LabVIEW_Pong/src/VI_Module/beep_pc.vi': {'unbound': 1},
  'vi-corpus/sources/LabVIEW-DCAF__calcs/src/editor node/Add Channel to Objects.vi': {'labelDiff': 1},
  'vi-corpus/sources/LabVIEW-DCAF__calcs/src/editor node/Register For Events.vi': {'labelDiff': 1},
  'vi-corpus/sources/LabVIEW-Open-Source__LV-MQTT-Broker/source/Server class/Send SessionDisconnectMessage.vi': {
    'typeDiff': 1,
  },
  'vi-corpus/sources/LabVIEW-Open-Source__LV-MQTT-Broker/source/TopicFilter/Evaluate.vi': {'labelDiff': 1},
  'vi-corpus/sources/MikaylaFischler__Mekanism-Sim/Machines/Isotopic Centrifuge.vi': {'unbound': 1},
  'vi-corpus/sources/MikaylaFischler__Mekanism-Sim/Simulator/ChemicalTank.vi': {'unbound': 1},
  'vi-corpus/sources/MikaylaFischler__Mekanism-Sim/Simulator/EnergyContainer.vi': {'unbound': 1},
  'vi-corpus/sources/NEVSTOP-LAB__Communicable-State-Machine/src/user.lib/_NEVSTOP/Communicable State Machine(CSM)/Utility/Global Log To String(Periodic Check).vi':
      {'labelDiff': 1},
  'vi-corpus/sources/NEVSTOP-LAB__Communicable-State-Machine/src/user.lib/_NEVSTOP/Communicable State Machine(CSM)/Utility/_support/PeriodicFilter-Format L1 Info String.vi':
      {'labelDiff': 1},
  'vi-corpus/sources/NEVSTOP-LAB__Communicable-State-Machine/src/user.lib/_NEVSTOP/Communicable State Machine(CSM)/Utility/_support/PeriodicFilter-Format Normal Info String.vi':
      {'labelDiff': 1},
  'vi-corpus/sources/NEVSTOP-LAB__Communicable-State-Machine/src/user.lib/_NEVSTOP/Communicable State Machine(CSM)/Utility/_support/PeriodicFilter-Format Result.vi':
      {'labelDiff': 1},
  'vi-corpus/sources/NEVSTOP-LAB__Communicable-State-Machine/src/user.lib/_NEVSTOP/Communicable State Machine(CSM)/Utility/_support/PeriodicFilter-Format Stop Filter Entrys.vi':
      {'labelDiff': 1},
  'vi-corpus/sources/NEVSTOP-LAB__Communicable-State-Machine/src/user.lib/_NEVSTOP/Communicable State Machine(CSM)/_Support/Message/Parse Register Message.vi':
      {'labelDiff': 1},
  'vi-corpus/sources/NEVSTOP-LAB__Communicable-State-Machine/src/user.lib/_NEVSTOP/Communicable State Machine(CSM)/_Support/Message/Parse Unregister Message.vi':
      {'labelDiff': 1},
  'vi-corpus/sources/NEVSTOP-LAB__LabVIEW-UI-XCtl/LabVIEW-UI-DisplayTable/UI-DisplayTable/Method/Highlight Item.vi': {
    'labelDiff': 1,
  },
  'vi-corpus/sources/PRIrvin__XY-Utilities/src/Private/X Array Index to Range.vi': {'labelDiff': 1},
  'vi-corpus/sources/PRIrvin__XY-Utilities/tests/CISS Data.vi': {'unbound': 1},
  'vi-corpus/sources/adam8687__2024-LED-lights/LED/source files/ApplyColorGain.vi': {'labelDiff': 1},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/abort.vi': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/add.vi': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/bd.vi': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/brokenwires.vi': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/create.vi': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/del.vi': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/drop.vi': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/exit.vi': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/fp.vi': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/grow.vi': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/move.vi': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/rename.vi': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/renamecase.vi': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/run.vi': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/scroll.vi': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/valchg.vi': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/wire.vi': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Commands/wireinner.vi': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Support/GoCommando Command Template.vit': {'unbound': 7},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Support/GoCommando Get Terms for Wiring.vi': {'unbound': 6},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Support/GoCommando Parse Drop Arguments.vi': {'unbound': 4},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Support/GoCommando Set Window Title.vi': {'unbound': 6},
  'vi-corpus/sources/dnattinger__GoCommando/_GoCommando/Support/GoCommando Wire CORE.vi': {'unbound': 6},
  'vi-corpus/sources/ni__grpc-labview/examples/helloworld/helloworld_server/RPC Service/Greeter/Accessor/Read Server RPC Methods.vi':
      {'typeDiff': 1},
  'vi-corpus/sources/ni__grpc-labview/examples/helloworld/helloworld_server/RPC Service/Greeter/Accessor/Write Server RPC Methods.vi':
      {'typeDiff': 1},
  'vi-corpus/sources/ni__grpc-labview/examples/query_server/Query_server/RPC Service/QueryServer/Accessor/Read Server RPC Methods.vi':
      {'typeDiff': 1},
  'vi-corpus/sources/ni__grpc-labview/examples/query_server/Query_server/RPC Service/QueryServer/Accessor/Write Server RPC Methods.vi':
      {'typeDiff': 1},
  'vi-corpus/sources/ni__grpc-labview/examples/route_guide/route_guide_server/RPC Service/RouteGuide/Accessor/Read Server RPC Methods.vi':
      {'typeDiff': 1},
  'vi-corpus/sources/ni__grpc-labview/examples/route_guide/route_guide_server/RPC Service/RouteGuide/Accessor/Write Server RPC Methods.vi':
      {'typeDiff': 1},
  'vi-corpus/sources/ni__grpc-labview/labview source/Client Server Support New/gRPC Scripting Tools/Oneof API/Get Typedef Name.vi':
      {'unbound': 1},
  'vi-corpus/sources/ni__grpc-labview/labview source/Client Server Support New/gRPC Scripting Tools/Proto Parser API/LabVIEW API/Load ProtoFile.vi':
      {'unbound': 1},
  'vi-corpus/sources/ni__grpc-labview/labview source/Client Server Support New/gRPC Scripting Tools/Proto Parser API/LabVIEW API/Serialize Proto.vi':
      {'unbound': 1},
  'vi-corpus/sources/ni__grpc-labview/labview source/Client Server Support New/gRPC Scripting Tools/VI API/Front Panel API/Create Cluster Control.vi':
      {'labelDiff': 1},
  'vi-corpus/sources/ni__grpc-labview/labview source/gRPC lv Support/Client API/Client Begin Bidirectional Streaming Call.vi':
      {'labelDiff': 1},
  'vi-corpus/sources/ni__grpc-labview/tests/AutoTests/ClientCancellationTests/route_guide_server/RPC Service/RouteGuide/Accessor/Read Server RPC Methods.vi':
      {'typeDiff': 1},
  'vi-corpus/sources/ni__grpc-labview/tests/AutoTests/ClientCancellationTests/route_guide_server/RPC Service/RouteGuide/Accessor/Write Server RPC Methods.vi':
      {'typeDiff': 1},
  'vi-corpus/sources/ni__grpc-labview/tests/Deprecated/Servers/TestDataMarshal/TestDataMarshal Class/Accessors/Server State/State Ref/Get Server State Ref.vi':
      {'typeDiff': 1},
  'vi-corpus/sources/ni__grpc-labview/tests/Deprecated/Servers/TestDataMarshal/TestDataMarshal Class/Accessors/Server State/State Ref/Set Server State Ref.vi':
      {'typeDiff': 1},
  'vi-corpus/sources/ni__grpc-labview/tests/Deprecated/Servers/TestDataMarshal/TestDataMarshal Class/Accessors/Server State/State UE/Get Server State UE.vi':
      {'typeDiff': 1},
  'vi-corpus/sources/ni__grpc-labview/tests/Deprecated/Servers/TestDataMarshal/TestDataMarshal Class/Accessors/Server State/State UE/Set Server State UE.vi':
      {'typeDiff': 1},
  'vi-corpus/sources/ni__grpc-labview/tests/Deprecated/Servers/TestDataMarshal/gRPC lvSupport/Server API/Message Requests/Complete Call.vi':
      {'unbound': 1},
  'vi-corpus/sources/ni__grpc-labview/tests/gRPC_ATS/SubVIs/FormatOutput.vi': {'unbound': 1},
  'vi-corpus/sources/ni__grpc-labview/tests/gRPC_ATS/SubVIs/OutputWrapper.vi': {'unbound': 1},
  'vi-corpus/sources/ni__grpc-labview/tests/gRPC_ATS/SubVIs/RunVI.vi': {'unbound': 1},
  'vi-corpus/sources/opengds__OpenGDS/resource/Framework/Providers/Open_GDS/ClassProviders/Common/CommonVIs/CommonVIs_AttributeToDataType.vi':
      {'unbound': 1},
  'vi-corpus/sources/opengds__OpenGDS/resource/Framework/Providers/Open_GDS/ClassProviders/Common/CommonVIs/CommonVIs_ClassWireSelection.vi':
      {'typeDiff': 1},
  'vi-corpus/sources/opengds__OpenGDS/resource/Framework/Providers/Open_GDS/ClassProviders/Common/PictureControl/PictureControl_Draw Text at Point.vi':
      {'labelDiff': 1},
  'vi-corpus/sources/opengds__OpenGDS/resource/Framework/Providers/Open_GDS/UML/DesignPattern/SubVIs/DesignPatterns_DrawNodesAndLinks.vi':
      {'labelDiff': 1},
  'vi-corpus/sources/opengds__OpenGDS/resource/Framework/Providers/Open_GDS/UML/DqmhModuleDiagramGraph_class/utils/DqmhModuleDiagramGraph_New.vi':
      {'typeDiff': 1},
  'vi-corpus/sources/opengds__OpenGDS/resource/Framework/Providers/Open_GDS/UML/Graph_class/AddItemsToGraph.vi': {
    'labelDiff': 1,
  },
  'vi-corpus/sources/opengds__OpenGDS/resource/Framework/Providers/Open_GDS/UML/ReversedEngineering/ReversedEngineering FindStateIndexToJumpTo.vi':
      {'unbound': 1},
  'vi-corpus/sources/opengds__OpenGDS/resource/Framework/Providers/Open_GDS/UML/UMLEditor/UMLEditor RoundToNearestN.vi':
      {'unbound': 1},
  'vi-corpus/sources/opengds__OpenGDS/resource/Framework/Providers/Open_GDS/UML/UMLEditor/UMLEditor reversedEngineering.vi':
      {'conNumDisagrees': 1},
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/picohrdl/PicohrdlLib/Picohrdlerrorhandler.vi': {
    'unbound': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps2000/PicoScope2000Lib/PicoScope2000Errorhandler.vi': {
    'unbound': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps2000/PicoScope2000Lib/PicoScope2000GetStreamingValues.vi':
      {'labelDiff': 1},
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps2000/PicoScope2000Lib/PicoScope2000GetValues.vi': {
    'labelDiff': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps2000a/PicoScope2000aLib/PicoScope2000aGetValues.vi': {
    'labelDiff': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps2000a/PicoScope2000aLib/PicoScope2000aUnitInfo.vi': {
    'unbound': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps3000a/PicoScope3000aLib/PicoScope3000aGetValues.vi': {
    'labelDiff': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps3000a/PicoScope3000aLib/PicoScope3000aSettings.vi': {
    'labelDiff': 2,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps4000/PicoScope4000Lib/PicoScope4000GetBlock.vi': {
    'labelDiff': 3,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps4000/PicoScope4000Lib/PicoScope4000GetValues.vi': {
    'labelDiff': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps4000/PicoScope4000Lib/PicoScope4000GetValuesOverlapped.vi':
      {'labelDiff': 1},
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps4000/PicoScope4000Lib/PicoScope4000Settings.vi': {
    'labelDiff': 4,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps4000/PicoScope4000Lib/PicoScope4000WrapSettings.vi': {
    'labelDiff': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps4000/PicoScope4000Lib/PicoScope4000aGetValuesOverlappedBulk.vi':
      {'labelDiff': 1},
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps4000a/PicoScope4000aLib/PicoScope4000aClose.vi': {
    'unbound': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps4000a/PicoScope4000aLib/PicoScope4000aGetValues.vi': {
    'labelDiff': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps4000a/PicoScope4000aLib/PicoScope4000aGetValuesOverlapped.vi':
      {'labelDiff': 1},
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps4000a/PicoScope4000aLib/PicoScope4000aProbeSettings.vi': {
    'labelDiff': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps4000a/PicoScope4000aLib/PicoScope4000aSettings.vi': {
    'labelDiff': 5,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps4000a/PicoScope4000aLib/PicoScope4000aWrapSettings.vi': {
    'labelDiff': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps5000a/PicoScope5000aLib/PicoScope5000aGetValues.vi': {
    'labelDiff': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps5000a/PicoScope5000aLib/PicoScope5000aGetValuesOverlapped.vi':
      {'labelDiff': 1},
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps6000/PicoScope6000Lib/PicoScope6000GetValues.vi': {
    'labelDiff': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps6000/PicoScope6000Lib/PicoScope6000GetValuesBulk.vi': {
    'labelDiff': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps6000/PicoScope6000Lib/PicoScope6000GetValuesOverlapped.vi':
      {'labelDiff': 1},
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps6000/PicoScope6000Lib/PicoScope6000GetValuesOverlappedBulk.vi':
      {'labelDiff': 1},
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps6000a/PicoScope6000aLib/PicoScope6000aGetValues.vi': {
    'labelDiff': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/ps6000a/PicoScope6000aLib/PicoScope6000aaGetValuesBulk.vi': {
    'labelDiff': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/psospa/PicoScopepsospaLib/PicoScopeospaGetValues.vi': {
    'labelDiff': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/psospa/PicoScopepsospaLib/PicoScopeospaGetValuesBulk.vi': {
    'labelDiff': 1,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/usbdrdaq/USBDrDAQLib/USBDrDAQChannelScaling.vi': {
    'labelDiff': 9,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/usbdrdaq/USBDrDAQLib/USBDrDAQClose.vi': {'labelDiff': 1},
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/usbdrdaq/USBDrDAQLib/USBDrDAQGPIO.vi': {'labelDiff': 12},
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/usbdrdaq/USBDrDAQLib/USBDrDAQGetBlock.vi': {'labelDiff': 10},
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/usbdrdaq/USBDrDAQLib/USBDrDAQGetStreamingData.vi': {
    'labelDiff': 10,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/usbdrdaq/USBDrDAQLib/USBDrDAQLEDControl.vi': {
    'labelDiff': 8,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/usbdrdaq/USBDrDAQLib/USBDrDAQOpen.vi': {'labelDiff': 3},
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/usbdrdaq/USBDrDAQLib/USBDrDAQSettings.vi': {'labelDiff': 6},
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/usbdrdaq/USBDrDAQLib/USBDrDAQSigGen.vi': {'labelDiff': 6},
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/usbdrdaq/USBDrDAQLib/USBDrDAQStartStreaming.vi': {
    'unbound': 1,
    'labelDiff': 4,
  },
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/usbpt104/usbpt104Lib/usbpt104GetValue.vi': {'labelDiff': 9},
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/usbtc08/USBTC08Lib/GetReadings.vi': {'labelDiff': 18},
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/usbtc08/USBTC08Lib/SelectUnit.vi': {'labelDiff': 6},
  'vi-corpus/sources/picotech__picosdk-ni-labview-examples/usbtc08/USBTC08Lib/USBTC08StreamingGetTemp.vi': {
    'labelDiff': 10,
  },
  'vi-corpus/sources/rfporter__FP-Equal/AlmostEqual_Abs_DBL.vi': {'unbound': 4},
  'vi-corpus/sources/rfporter__FP-Equal/AlmostEqual_Abs_EXT.vi': {'unbound': 4},
  'vi-corpus/sources/rfporter__FP-Equal/AlmostEqual_Abs_SGL.vi': {'unbound': 4},
  'vi-corpus/sources/rfporter__FP-Equal/AlmostEqual_DBL Parts.vi': {'unbound': 7},
  'vi-corpus/sources/rfporter__FP-Equal/AlmostEqual_Rel_DBL.vi': {'unbound': 4},
  'vi-corpus/sources/rfporter__FP-Equal/AlmostEqual_Rel_EXT.vi': {'unbound': 4},
  'vi-corpus/sources/rfporter__FP-Equal/AlmostEqual_Rel_SGL.vi': {'unbound': 4},
  'vi-corpus/sources/rfporter__FP-Equal/AlmostEqual_SGL Parts.vi': {'unbound': 7},
  'vi-corpus/sources/rfporter__FP-Equal/AlmostEqual_ULPs_DBL.vi': {'unbound': 4},
  'vi-corpus/sources/rfporter__FP-Equal/AlmostEqual_ULPs_SGL.vi': {'unbound': 4},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clFile/clFile_contentLen.vi': {'unbound': 2},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clFile/clFile_readFromFile.vi': {'unbound': 3},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clFile/clFile_readFromString.vi': {'unbound': 3},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clFile/clFile_readStr.vi': {'unbound': 4},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clFile/clFile_writeStr.vi': {'unbound': 4},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clFile/clFile_writeToFile.vi': {'unbound': 3},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clFileReader/clFileReader_getLenght.vi': {'unbound': 3},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clFileReader/clFileReader_getNewReader.vi': {'unbound': 4},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clFileReader/clFileReader_initReader.vi': {'unbound': 4},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clFileReader/clFileReader_readInt.vi': {'unbound': 7},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clFileReader/clFileReader_setReaderPropertys.vi': {'unbound': 5},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clFileReader/clFileReader_writeStr.vi': {'unbound': 5},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clFileReader/clFileReader_writeToFile.vi': {'unbound': 3},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clFileReader/clfilereader_readStr.vi': {'unbound': 7},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clLabview/MD5Checksum_format_output.vi': {'unbound': 6},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clLabview/MD5Checksum_string.vi': {'unbound': 3},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clLabview/clLabview_BDPW.vi': {'unbound': 10},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clLabview/clLabview_BDPW_SaltFormat.vi': {'unbound': 4},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clLabview/clLabview_BDPW_calc.vi': {'unbound': 8},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clLabview/clLabview_BDPW_calcSalt.vi': {'unbound': 5},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clLabview/clLabview_LVSR.vi': {'unbound': 11},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clLabview/clLabview_blockUncompress.vi': {'unbound': 3},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clLabview/clLabview_getBlockIdByName.vi': {'unbound': 6},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clLabview/clLabview_icon.vi': {'unbound': 2},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clLabview/clLabview_readVI.vi': {'unbound': 2},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clLabview/clLabview_updateFileReader.vi': {'unbound': 3},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clLabview/clLabview_version.vi': {'unbound': 9},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clLabview/clLabview_writeLVSR.vi': {'unbound': 3},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clLabview/clLabview_writeToFile.vi': {'unbound': 4},
  'vi-corpus/sources/tomsoftware__VI-Explorer-VI/clLabview/clLabview_writeVI.vi': {'unbound': 5},
};
