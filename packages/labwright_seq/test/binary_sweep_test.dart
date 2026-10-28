@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// `(fileVersion, types, sequences, steps, steps with a module)` per corpus binary.
const _pinned = <String, (int, int, int, int, int)>{
  'seq-corpus/rosetta/DmmHAL_labview_BIN.seq': (1022, 28, 1, 4, 2),
  'seq-corpus/rosetta/NIDmm_labview_BIN.seq': (962, 28, 1, 4, 2),
  'seq-corpus/rosetta/NIFgen_labview_BIN.seq': (962, 28, 1, 4, 2),
  'seq-corpus/rosetta/NIScope_labview_BIN.seq': (962, 28, 1, 4, 2),
  'seq-corpus/rosetta/OutputVoltage_BIN.seq': (962, 26, 1, 6, 4),
  'seq-corpus/rosetta/SmuFAL_labview_BIN.seq': (1022, 28, 1, 4, 2),
  'seq-corpus/sources/425J__LayoutLoader/Installer/Install.seq': (962, 34, 4, 27, 15),
  'seq-corpus/sources/425J__LayoutLoader/Installer/Resources/FrontEnd/FrontEndCallbacks.seq': (962, 32, 2, 12, 6),
  'seq-corpus/sources/425J__SeqEditQuickDrop/Installer/Install.seq': (962, 34, 4, 28, 16),
  'seq-corpus/sources/425J__SeqEditQuickDrop/Installer/Resources/FrontEnd/FrontEndCallbacks.seq': (962, 24, 1, 8, 5),
  'seq-corpus/sources/425J__SeqEditQuickDrop/Installer/Resources/QuickDrop/QuickDrop.seq': (962, 17, 3, 4, 4),
  'seq-corpus/sources/425J__TemplatesGenerator/Installer/Install.seq': (962, 27, 2, 9, 5),
  'seq-corpus/sources/425J__TemplatesGenerator/Installer/Resources/TemplatesGenerator.seq': (962, 25, 2, 19, 1),
  'seq-corpus/sources/425J__TestStandMiscellaneous/Is Process Running/Is Process Running.seq': (941, 26, 1, 6, 2),
  'seq-corpus/sources/425J__TestStandMiscellaneous/LabVIEW Compiled Object Cache Preparation/LabVIEW Compiled Object Cache Preparation.seq':
      (941, 38, 3, 22, 8),
  'seq-corpus/sources/425J__TestStandMiscellaneous/Output to Stream/Output to Stream.seq': (941, 22, 2, 5, 0),
  'seq-corpus/sources/425J__TestStandMiscellaneous/Sequence Progress Station Callback/StationCallbacks.seq': (
    941,
    17,
    3,
    3,
    0,
  ),
  'seq-corpus/sources/425J__TestStandMiscellaneous/XML to HTML Report Converter/XML To HTML.seq': (941, 26, 1, 13, 11),
  'seq-corpus/sources/Aldo633__TestStandLock-API/Lock Test.seq': (894, 27, 2, 7, 3),
  'seq-corpus/sources/FloresFelipe__csv-doc-gen-tool-teststand/src/docgen.seq': (1022, 16, 1, 3, 3),
  'seq-corpus/sources/FloresFelipe__csv-doc-gen-tool-teststand/src/docgen_csv.seq': (1022, 33, 6, 39, 9),
  'seq-corpus/sources/FloresFelipe__csv-doc-gen-tool-teststand/src/docgen_html.seq': (1022, 33, 8, 177, 47),
  'seq-corpus/sources/FloresFelipe__csv-doc-gen-tool-teststand/src/docgen_txt.seq': (1022, 33, 8, 173, 56),
  'seq-corpus/sources/FloresFelipe__custom-teststand-computer-motherboard-example/TestStand Project/Callbacks/FrontEnd/FrontEndCallbacks.seq':
      (1022, 18, 1, 3, 2),
  'seq-corpus/sources/FloresFelipe__custom-teststand-computer-motherboard-example/TestStand Project/Computer Motherboard Test Sequence.seq':
      (1022, 33, 6, 31, 23),
  'seq-corpus/sources/ItsMeAshiq__TestStand-OutputMessage/OutputMessage/OutputMessage Demo.seq': (941, 28, 1, 6, 0),
  'seq-corpus/sources/JMETestSolutions__VideoBlog/Front End Callback Example/FrontEnd/FrontEndCallbacks.seq': (
    941,
    36,
    4,
    68,
    4,
  ),
  'seq-corpus/sources/JMETestSolutions__VideoBlog/Patching Process Models/Outputs/CustomATESequentialModel.seq': (
    941,
    58,
    27,
    51,
    44,
  ),
  'seq-corpus/sources/JMETestSolutions__VideoBlog/Patching Process Models/Sequence File Patcher.seq': (
    941,
    21,
    1,
    18,
    0,
  ),
  'seq-corpus/sources/JMETestSolutions__VideoBlog/Patching Process Models/SequentialModel Patches.seq': (
    941,
    41,
    3,
    3,
    1,
  ),
  'seq-corpus/sources/JMETestSolutions__VideoBlog/Patching Process Models/SequentialModel.seq': (941, 59, 27, 49, 44),
  'seq-corpus/sources/JMETestSolutions__VideoBlog/SequenceAnalyzerRules/Example Requirements Sequence File.seq': (
    941,
    17,
    1,
    3,
    0,
  ),
  'seq-corpus/sources/JavierABH__Elatch-Bench-Programming/Sequence/Elatch-programming-batch.seq': (982, 66, 9, 218, 57),
  'seq-corpus/sources/JavierABH__Elatch-Bench-Programming/Sequence/Elatch-programming.seq': (982, 56, 5, 42, 10),
  'seq-corpus/sources/KMurphs__labview-client-for-micropython/Examples/TestStand/Micropython.seq': (920, 23, 1, 4, 4),
  'seq-corpus/sources/KarthikAbiram__tsxml/tools/teststand/get_xml_string_of_variable.seq': (920, 21, 1, 2, 0),
  'seq-corpus/sources/NI-Measurement-Plug-Ins__class-d-amplifier/demo/InstrStudio/TAS6424 Class D Amp.seq': (
    1022,
    41,
    2,
    4,
    0,
  ),
  'seq-corpus/sources/NI-Measurement-Plug-Ins__class-d-amplifier/demo/TestStand/TAS6424.seq': (1022, 37, 1, 6, 0),
  'seq-corpus/sources/NI-Measurement-Plug-Ins__device-power-sequencer/demo/TestStand/Powerup Validation.seq': (
    962,
    32,
    3,
    7,
    1,
  ),
  'seq-corpus/sources/NI-Measurement-Plug-Ins__digital-microphone/demo/TestStand/Digital-Mic-Validation.seq': (
    1022,
    37,
    1,
    6,
    0,
  ),
  'seq-corpus/sources/NI-Measurement-Plug-Ins__pcba-fct/test/TestStand/NIDmmDCRmsMeasurement/NIDmmDCRmsMeasurement.seq':
      (1022, 28, 1, 4, 2),
  'seq-corpus/sources/NI-Measurement-Plug-Ins__pcba-fct/test/TestStand/NIFgenSignalVoltageGeneration/NIFgenSignalVoltageGeneration.seq':
      (1022, 28, 1, 4, 2),
  'seq-corpus/sources/NI-Measurement-Plug-Ins__pcba-fct/test/TestStand/NIScopeDigitalMeasurement/NIScopeDigitalMeasurement.seq':
      (1022, 28, 1, 4, 2),
  'seq-corpus/sources/NI-Measurement-Plug-Ins__pcba-fct/test/TestStand/NIScopeFrequencyDomain/NIScopeFrequencyDomain.seq':
      (1022, 28, 1, 4, 2),
  'seq-corpus/sources/NI-Measurement-Plug-Ins__pcba-fct/test/TestStand/NIScopeTimeDomain/NIScopeTimeDomain.seq': (
    1022,
    28,
    1,
    4,
    2,
  ),
  'seq-corpus/sources/NISystemsEngineering__rfic-reference-design-libraries-csharp/Automation/TestStand_5GNR_DPD_AMPM_EVM_ACP_DL/TestStand_5GNR_DPD_AMPM_EVM_ACP_DL.seq':
      (920, 90, 4, 75, 33),
  'seq-corpus/sources/NISystemsEngineering__rfic-reference-design-libraries-csharp/Automation/TestStand_5GNR_DPD_AMPM_EVM_ACP_UL/TestStand_5GNR_DPD_AMPM_EVM_ACP_UL.seq':
      (920, 91, 4, 75, 33),
  'seq-corpus/sources/NISystemsEngineering__rfic-reference-design-libraries-csharp/Automation/TestStand_LTE_DPD_AMPM_EVM_ACP_DL/TestStand_LTE_DPD_AMPM_EVM_ACP_DL.seq':
      (920, 83, 4, 75, 33),
  'seq-corpus/sources/NISystemsEngineering__rfic-reference-design-libraries-csharp/Automation/TestStand_LTE_DPD_AMPM_EVM_ACP_UL/TestStand_LTE_DPD_AMPM_EVM_ACP_UL.seq':
      (920, 84, 4, 75, 33),
  'seq-corpus/sources/NISystemsEngineering__rfic-reference-design-libraries-csharp/Automation/TestStand_SPECAN_TXP_LOADPULL/TestStand_SPECAN_TXP_LOADPULL.seq':
      (920, 96, 4, 47, 23),
  'seq-corpus/sources/NISystemsEngineering__rfic-reference-design-libraries-csharp/Automation/TestStand_WLAN_AMPM_DEVM_SEM/TestStand_WLAN_AMPM_DEVM_SEM.seq':
      (920, 71, 4, 68, 29),
  'seq-corpus/sources/NISystemsEngineering__rfic-reference-design-libraries-csharp/Automation/TestStand_WLAN_DPD_AMPM_EVM_SEM/TestStand_WLAN_DPD_AMPM_EVM_SEM.seq':
      (920, 77, 4, 76, 33),
  'seq-corpus/sources/NISystemsEngineering__rfic-reference-design-libraries-labview/Automation/TestStand_5GNR_DPD_AMPM_EVM_ACP_DL/TestStand_5GNR_DPD_AMPM_EVM_ACP_DL.seq':
      (920, 89, 4, 74, 33),
  'seq-corpus/sources/NISystemsEngineering__rfic-reference-design-libraries-labview/Automation/TestStand_5GNR_DPD_AMPM_EVM_ACP_UL/TestStand_5GNR_DPD_AMPM_EVM_ACP_UL.seq':
      (920, 89, 4, 74, 33),
  'seq-corpus/sources/NISystemsEngineering__rfic-reference-design-libraries-labview/Automation/TestStand_LTE_DPD_AMPM_EVM_ACP_DL/TestStand_LTE_DPD_AMPM_EVM_ACP_DL.seq':
      (920, 90, 4, 76, 34),
  'seq-corpus/sources/NISystemsEngineering__rfic-reference-design-libraries-labview/Automation/TestStand_LTE_DPD_AMPM_EVM_ACP_UL/TestStand_LTE_DPD_AMPM_EVM_ACP_UL.seq':
      (920, 90, 4, 76, 34),
  'seq-corpus/sources/NISystemsEngineering__rfic-reference-design-libraries-labview/Automation/TestStand_SPECAN_TXP_LOADPULL/TestStand_SPECAN_TXP_LOADPULL.seq':
      (920, 95, 4, 47, 23),
  'seq-corpus/sources/NISystemsEngineering__rfic-reference-design-libraries-labview/Automation/TestStand_WLAN_AMPM_DEVM_SEM/TestStand_WLAN_AMPM_DEVM_SEM.seq':
      (920, 78, 4, 69, 30),
  'seq-corpus/sources/NISystemsEngineering__rfic-reference-design-libraries-labview/Automation/TestStand_WLAN_DPD_AMPM_EVM_SEM/TestStand_WLAN_AMPM_EVM_SEM.seq':
      (920, 83, 4, 76, 34),
  'seq-corpus/sources/NIVeriStandAdd-Ons__ECU-HIL-Demo/TestStand Scripts/APP fault(clear).seq': (755, 33, 1, 5, 0),
  'seq-corpus/sources/NIVeriStandAdd-Ons__ECU-HIL-Demo/TestStand Scripts/APP fault(detection).seq': (755, 33, 1, 5, 0),
  'seq-corpus/sources/NIVeriStandAdd-Ons__ECU-HIL-Demo/TestStand Scripts/APP fault(response).seq': (755, 33, 1, 5, 0),
  'seq-corpus/sources/NIVeriStandAdd-Ons__ECU-HIL-Demo/TestStand Scripts/CC Tests.seq': (755, 43, 1, 19, 0),
  'seq-corpus/sources/NIVeriStandAdd-Ons__ECU-HIL-Demo/TestStand Scripts/Cruise Control(brake).seq': (755, 43, 1, 9, 0),
  'seq-corpus/sources/NIVeriStandAdd-Ons__ECU-HIL-Demo/TestStand Scripts/Cruise Control(disable).seq': (
    755,
    43,
    1,
    9,
    0,
  ),
  'seq-corpus/sources/NIVeriStandAdd-Ons__ECU-HIL-Demo/TestStand Scripts/Cruise Control(ramp down).seq': (
    755,
    43,
    1,
    9,
    0,
  ),
  'seq-corpus/sources/NIVeriStandAdd-Ons__ECU-HIL-Demo/TestStand Scripts/Cruise Control(ramp up and down).seq': (
    755,
    43,
    1,
    9,
    0,
  ),
  'seq-corpus/sources/NIVeriStandAdd-Ons__ECU-HIL-Demo/TestStand Scripts/Cruise Control(ramp up).seq': (
    755,
    43,
    1,
    9,
    0,
  ),
  'seq-corpus/sources/NIVeriStandAdd-Ons__ECU-HIL-Demo/TestStand Scripts/Cruise Control(resume).seq': (
    755,
    43,
    1,
    9,
    0,
  ),
  'seq-corpus/sources/NIVeriStandAdd-Ons__ECU-HIL-Demo/TestStand Scripts/Fault_Tests.seq': (755, 33, 1, 15, 0),
  'seq-corpus/sources/NIVeriStandAdd-Ons__ECU-HIL-Demo/TestStand Scripts/IMP fault(clear).seq': (755, 33, 1, 5, 0),
  'seq-corpus/sources/NIVeriStandAdd-Ons__ECU-HIL-Demo/TestStand Scripts/IMP fault(detection).seq': (755, 33, 1, 5, 0),
  'seq-corpus/sources/NIVeriStandAdd-Ons__ECU-HIL-Demo/TestStand Scripts/IMP fault(response).seq': (755, 33, 1, 5, 0),
  'seq-corpus/sources/NIVeriStandAdd-Ons__ECU-HIL-Demo/TestStand Scripts/Knock response.seq': (755, 33, 1, 5, 0),
  'seq-corpus/sources/NIVeriStandAdd-Ons__ECU-HIL-Demo/TestStand Scripts/Test1/test_sequence1.seq': (755, 17, 1, 2, 2),
  'seq-corpus/sources/NIVeriStandAdd-Ons__Real-Time-Test-Automation-RTTA-Demo/Source/Demos/EngineController/Working Directory/Engine Test Script.rtts.seq':
      (577, 42, 1, 29, 12),
  'seq-corpus/sources/NIVeriStandAdd-Ons__Real-Time-Test-Automation-RTTA-Demo/Source/Executable/GetNIVSTokens.seq': (
    577,
    23,
    1,
    14,
    13,
  ),
  'seq-corpus/sources/NIVeriStandAdd-Ons__VeriStand-steps-for-TestStand/Documentation/Examples/Asynchronous Tasks/Monitor Engine Temp.seq':
      (797, 49, 4, 33, 3),
  'seq-corpus/sources/NIVeriStandAdd-Ons__VeriStand-steps-for-TestStand/Documentation/Examples/NIVS Engine Demo.seq': (
    773,
    41,
    1,
    9,
    0,
  ),
  'seq-corpus/sources/NIVeriStandAdd-Ons__VeriStand-steps-for-TestStand/Documentation/Examples/References and Subsequences/Child Sequence.seq':
      (773, 32, 1, 3, 0),
  'seq-corpus/sources/NIVeriStandAdd-Ons__VeriStand-steps-for-TestStand/Documentation/Examples/References and Subsequences/Parent Sequence.seq':
      (773, 37, 2, 7, 2),
  'seq-corpus/sources/NIVeriStandAdd-Ons__VeriStand-steps-for-TestStand/Tests/Sequences/Looping Test Get Channel Timing.seq':
      (773, 36, 1, 4, 0),
  'seq-corpus/sources/NIVeriStandAdd-Ons__VeriStand-steps-for-TestStand/Tests/Sequences/Looping Test RT Sequence Extended.seq':
      (773, 36, 1, 5, 0),
  'seq-corpus/sources/NIVeriStandAdd-Ons__VeriStand-steps-for-TestStand/Tests/Sequences/Looping Test Set Channel Timing.seq':
      (773, 36, 1, 4, 0),
  'seq-corpus/sources/NIVeriStandAdd-Ons__VeriStand-steps-for-TestStand/Tests/Sequences/Main.seq': (773, 79, 4, 91, 11),
  'seq-corpus/sources/NIVeriStandAdd-Ons__VeriStand-steps-for-TestStand/Tests/Sequences/MainSub.seq': (
    773,
    59,
    1,
    41,
    3,
  ),
  'seq-corpus/sources/NIVeriStandAdd-Ons__VeriStand-steps-for-TestStand/Tests/Sequences/Subtest Logging.seq': (
    797,
    32,
    1,
    6,
    0,
  ),
  'seq-corpus/sources/NIVeriStandAdd-Ons__VeriStand-steps-for-TestStand/Tests/Sequences/Subtest Project Control.seq': (
    773,
    35,
    1,
    15,
    0,
  ),
  'seq-corpus/sources/NIVeriStandAdd-Ons__VeriStand-steps-for-TestStand/Tests/Sequences/Subtest RT Sequence Parameter & Return Test.seq':
      (773, 32, 1, 6, 0),
  'seq-corpus/sources/NIVeriStandAdd-Ons__VeriStand-steps-for-TestStand/Tests/Sequences/Subtest RT Sequence without Timeout Property (for legacy).seq':
      (773, 33, 1, 3, 0),
  'seq-corpus/sources/NIVeriStandAdd-Ons__VeriStand-steps-for-TestStand/Tests/Sequences/Subtest Set Channel Timeout.seq':
      (773, 36, 1, 6, 0),
  'seq-corpus/sources/NIVeriStandAdd-Ons__VeriStand-steps-for-TestStand/Tests/Sequences/Subtest Silent Disconnect.seq':
      (773, 37, 1, 7, 0),
  'seq-corpus/sources/Sub-Zero-Group-Inc__HILisForEveryone/veristand-automation/teststand/engine-demo-ts.seq': (
    1022,
    23,
    1,
    4,
    0,
  ),
  'seq-corpus/sources/astemes__astemes-csv-report-teststand-plugin/sandbox/Test Sequence.seq': (920, 20, 2, 4, 0),
  'seq-corpus/sources/astemes__astemes-csv-report-teststand-plugin/source/Astemes_CSVReportGenerator.seq': (
    920,
    61,
    15,
    39,
    6,
  ),
  'seq-corpus/sources/bihackercs__BUDLUG2025/BUDLUG.seq': (1022, 24, 5, 17, 0),
  'seq-corpus/sources/hongcc1__TsmPerformanceLogger/Code/ModelPlugins/PerformanceMeasurementLogger.seq': (
    962,
    59,
    15,
    54,
    13,
  ),
  'seq-corpus/sources/illuminated-g__tss/Test/Sequences/Delay.seq': (920, 22, 1, 2, 0),
  'seq-corpus/sources/illuminated-g__tss/Test/Sequences/DisplaySerialNo.seq': (920, 26, 1, 2, 1),
  'seq-corpus/sources/joshuaprewitt__battery-tester/Cycle Test/Battery Cycle Test.seq': (941, 39, 2, 15, 2),
  'seq-corpus/sources/joshuaprewitt__battery-tester/Cycle Test/Battery Cycle Test_Old.seq': (920, 39, 2, 15, 2),
  'seq-corpus/sources/joshuaprewitt__battery-tester/Cycle Test/Packages/Battery Test/data/ProgramFiles_64/Battery Test/Battery Cycle Test.seq':
      (941, 39, 2, 15, 2),
  'seq-corpus/sources/joshuaprewitt__battery-tester/Cycle Test/ProcessingStage/ProgramFiles_64/Battery Test/Battery Cycle Test.seq':
      (941, 39, 2, 15, 2),
  'seq-corpus/sources/levylabpitt__TestStand/seq/Sequence File 1.seq': (920, 17, 1, 4, 4),
  'seq-corpus/sources/ni__measurement-plugin-labview/Source/Example Measurements/NI-DMM Measurement/NIDmmMeasurement_example.seq':
      (962, 28, 1, 4, 2),
  'seq-corpus/sources/ni__measurement-plugin-labview/Source/Example Measurements/NI-FGEN Standard Function/NIFgenStandardFunction_example.seq':
      (962, 28, 1, 4, 2),
  'seq-corpus/sources/ni__measurement-plugin-labview/Source/Example Measurements/NI-SCOPE Acquire Waveform/NIScopeAcquireWaveform_example.seq':
      (962, 28, 1, 4, 2),
  'seq-corpus/sources/ni__nipcbatt-labview/source/Automation/Action Button Tests/Action Button Test.seq': (
    962,
    33,
    6,
    31,
    14,
  ),
  'seq-corpus/sources/ni__nipcbatt-labview/source/Automation/Audio Tests/Audio Test.seq': (962, 34, 7, 40, 21),
  'seq-corpus/sources/ni__nipcbatt-labview/source/Automation/Communication Tests/Communication Test.seq': (
    962,
    31,
    6,
    27,
    8,
  ),
  'seq-corpus/sources/ni__nipcbatt-labview/source/Automation/Digital IO Tests/Digital IO Tests.seq': (
    962,
    36,
    10,
    101,
    55,
  ),
  'seq-corpus/sources/ni__nipcbatt-labview/source/Automation/LEDs Tests/LEDs Tests.seq': (962, 33, 7, 32, 17),
  'seq-corpus/sources/ni__nipcbatt-labview/source/Automation/Microphone Tests/Microphone Test.seq': (
    962,
    34,
    6,
    26,
    13,
  ),
  'seq-corpus/sources/ni__nipcbatt-labview/source/Automation/Power Supply Tests/Power Supply Test.seq': (
    962,
    33,
    8,
    47,
    24,
  ),
  'seq-corpus/sources/ni__nipcbatt-labview/source/Automation/Sensor Tests/Sensor Test.seq': (962, 34, 10, 60, 31),
  'seq-corpus/sources/ni__nipcbatt-labview/source/Automation/Synchronization Example/Synchronization Example.seq': (
    962,
    43,
    10,
    75,
    37,
  ),
  'seq-corpus/sources/ni__nipcbatt-labview/source/PCBA FT Demo/PCBA FT Demo.seq': (962, 42, 11, 81, 47),
  'seq-corpus/sources/ni__nitsm-python/systemtests/SystemTestFixture.seq': (941, 28, 1, 26, 8),
  'seq-corpus/sources/ni__nitsm-python/systemtests/custom_instruments.seq': (941, 53, 4, 5, 3),
  'seq-corpus/sources/ni__nitsm-python/systemtests/nidaqmx.seq': (941, 53, 4, 5, 3),
  'seq-corpus/sources/ni__nitsm-python/systemtests/nidcpower.seq': (941, 53, 4, 5, 3),
  'seq-corpus/sources/ni__nitsm-python/systemtests/nidigital.seq': (941, 56, 4, 13, 11),
  'seq-corpus/sources/ni__nitsm-python/systemtests/nidmm.seq': (941, 53, 4, 5, 3),
  'seq-corpus/sources/ni__nitsm-python/systemtests/nifgen.seq': (941, 53, 4, 5, 3),
  'seq-corpus/sources/ni__nitsm-python/systemtests/nirelaydriver.seq': (941, 53, 4, 5, 3),
  'seq-corpus/sources/ni__nitsm-python/systemtests/niscope.seq': (941, 53, 4, 5, 3),
  'seq-corpus/sources/ni__nitsm-python/systemtests/site_and_global_data.seq': (941, 53, 3, 8, 6),
  'seq-corpus/sources/ni__nitsm-python/systemtests/specifications.seq': (941, 52, 3, 4, 2),
  'seq-corpus/sources/ni__nitsm-python/systemtests/switch.seq': (941, 53, 4, 5, 3),
  'seq-corpus/sources/ni__semi-test-library-dotnet/Examples/source/Sequence/CustomInstrument.RSeries/STLExample.CustomInstrument.RSeries.seq':
      (1022, 38, 4, 5, 3),
  'seq-corpus/sources/ni__semi-test-library-dotnet/Examples/source/Sequence/CustomInstrument/STLExample.CustomInstrument.seq':
      (1022, 38, 4, 7, 5),
  'seq-corpus/sources/ni__semi-test-library-dotnet/Examples/source/Sequence/MultiplexedConnection/STLExample.MultiplexedConnection.seq':
      (1022, 34, 4, 8, 3),
  'seq-corpus/sources/ni__semi-test-library-dotnet/Examples/source/Sequence/SMUGangPinGroup/STLExample.SMUGangPinGroup.seq':
      (1022, 43, 4, 19, 9),
  'seq-corpus/sources/ni__semi-test-library-dotnet/Examples/source/Sequence/SMUHardwareLevelSequence/STLExample.SMUHardwareLevelSequence.seq':
      (1022, 40, 4, 10, 7),
  'seq-corpus/sources/ni__semi-test-library-dotnet/Examples/source/Sequence/SMUMergePinGroup/STLExample.SMUMergePinGroup.seq':
      (1022, 43, 4, 19, 9),
  'seq-corpus/sources/ni__semi-test-library-dotnet/Examples/source/TestPrograms/Accelerometer/Accelerometer.STSSoftware24.5Compatible.seq':
      (1022, 48, 4, 43, 22),
  'seq-corpus/sources/ni__semi-test-library-dotnet/Examples/source/TestPrograms/Accelerometer/Accelerometer.seq': (
    1022,
    48,
    4,
    43,
    22,
  ),
  'seq-corpus/sources/ni__stsmemsapt/Example/TestProgram/AppNoteMEMS_TestProgram_Example.seq': (1022, 61, 4, 68, 46),
  'seq-corpus/sources/pranay001__STS-Live-Test-Result-Viewer/Source/STS_LiveTestResultViewer.seq': (920, 50, 11, 16, 4),
  'seq-corpus/sources/prestwick__systemlink-hands-on/test-monitoring/Attach Test Files.seq': (894, 21, 1, 1, 1),
};

/// Scalars the lift synthesizes without a pool string behind them.
const _synthesizedScalars = {'', '0', 'true', 'false'};

void main() {
  final files = corpusSeqDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.seq')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('whole corpus: every binary decodes end to end, counts are pinned, nothing is fabricated', () {
    final seen = <String>{};
    final offenders = <String>[];
    final generations = <Tof1Generation, int>{};
    final undecodedFields = <BinaryUndecodedField, int>{};
    var coverage = const BinaryByteCoverage(
      bodyBytes: 0,
      poolBytes: 0,
      recordSemanticBytes: 0,
      recordStructuralBytes: 0,
    );
    var steps = 0, filesWithSteps = 0, unnamedSteps = 0;
    final sw = Stopwatch()..start();
    for (final f in files) {
      final bytes = f.readAsBytesSync();
      if (detectSeqFormat(bytes) != SeqFormat.binary) continue;
      final rel = corpusSeqRelativePath(f.path);
      seen.add(rel);

      final header = Tof1Header.parse(bytes)!;
      expect(header.hasBodyMarker, isTrue, reason: rel);
      expect(header.inflatedLength, inflateBinaryBody(bytes)!.length, reason: rel);
      generations.update(header.generation, (n) => n + 1, ifAbsent: () => 1);

      final decode = decodeTof1(bytes)!;
      final grammar = decode.grammar;
      expect(grammar, isNotNull, reason: '$rel: ${decode.error}');
      grammar!;
      expect(grammar.data.end + 8, grammar.recordRegionLength, reason: '$rel: the data root must end at the pool');
      expect(grammar.tailWord, 0, reason: rel);
      for (final type in grammar.types) {
        expect(type.entryWord, 1, reason: '$rel: ${type.name}');
      }

      final file = parseSeqFile(bytes);
      final n = file.sequences.fold(0, (a, s) => a + s.steps.length);
      final modules = file.sequences.fold(
        0,
        (a, s) => a + s.steps.where((t) => t.module.adapter != SeqAdapter.none).length,
      );
      steps += n;
      if (n > 0) filesWithSteps++;
      final pin = _pinned[rel];
      if (pin == null) {
        offenders.add('$rel: not pinned ($n steps)');
      } else {
        expect(
          (header.fileVersion, file.types.length, file.sequences.length, n, modules),
          pin,
          reason: '$rel: (version, types, sequences, steps, module steps)',
        );
      }

      final pool = grammar.pool.toSet();
      void checkNames(SeqProperty p, String path) {
        if (p.name.isNotEmpty && !p.name.startsWith('%BIN') && !pool.contains(p.name)) {
          offenders.add('$rel: name "${p.name}" at $path is not in the pool');
        }
        if (p.typeName case final type? when !pool.contains(type)) offenders.add('$rel: type $type at $path');
        final cls = p.className;
        if (cls != null && !pool.contains(cls)) offenders.add('$rel: class $cls at $path');
        if (p.valueClass?.isText ?? false) {
          final scalar = p.scalar;
          if (scalar != null && scalar.isNotEmpty && !pool.contains(scalar)) {
            offenders.add('$rel: text value "$scalar" at $path');
          }
        }
        if (p.valueClass == SeqValueClass.boolean && p.scalar != null && !_synthesizedScalars.contains(p.scalar)) {
          offenders.add('$rel: boolean "${p.scalar}" at $path');
        }
        for (final child in p.subProps) {
          checkNames(child, '$path/${child.name}');
        }
        for (final (i, element) in (p.array ?? const <SeqProperty>[]).indexed) {
          checkNames(element, '$path[$i]');
        }
        if (p.elemProto case final proto?) checkNames(proto, '$path/<proto>');
      }

      for (final type in file.types) {
        checkNames(type, 'type/${type.name}');
      }
      checkNames(file.data, 'Data');
      for (final sequence in file.sequences) {
        for (final step in sequence.steps) {
          if (step.name.isEmpty) {
            unnamedSteps++;
            expect(step.type, 'Label', reason: '$rel: only Label steps go unnamed');
          }
          expect(step.type, isNotNull, reason: '$rel: ${sequence.name}/${step.name} has no step type');
          expect(file.types.map((t) => t.name), contains(step.type), reason: '$rel: ${step.name}');
          final id = step.id;
          if (id != null) expect(id, startsWith('ID#:'), reason: '$rel: ${step.name}');
        }
      }

      final cov = bodyByteCoverage(grammar);
      coverage = coverage + cov;
      var spanned = 0;
      for (final span in binaryUndecodedSpans(grammar)) {
        spanned += span.end - span.start;
        undecodedFields.update(span.field, (n) => n + 1, ifAbsent: () => 1);
        for (var i = span.start; i < span.end; i++) {
          if (grammar.tiers[i] != BinaryByteTier.undecoded.index) {
            offenders.add('$rel: ${span.field} span at $i is tiered ${grammar.tiers[i]}');
            break;
          }
        }
      }
      expect(spanned, cov.recordUndecodedBytes, reason: '$rel: every undecoded byte belongs to a named field');
      for (var i = 0; i < grammar.recordRegionLength; i++) {
        if (grammar.tiers[i] == BinaryByteTier.pool.index) {
          offenders.add('$rel: pool tier inside the record region at $i');
          break;
        }
      }

      final model = parseBinarySeqWriteModel(bytes)!;
      expect(_sameBytes(model.writeBody(), decode.body), isTrue, reason: '$rel: the body must write back byte-exactly');
    }
    final elapsed = sw.elapsedMilliseconds;
    expect(offenders, isEmpty, reason: offenders.take(12).join('\n'));
    expect(seen, _pinned.keys.toSet(), reason: 'the pinned binary set drifted');
    expect(filesWithSteps, _pinned.length, reason: 'every corpus binary carries steps');
    expect(steps, _pinned.values.fold(0, (a, p) => a + p.$4));
    expect(unnamedSteps, 167, reason: 'unnamed Label steps');
    expect(generations.keys.toSet(), Tof1Generation.values.toSet(), reason: 'every generation is exercised');
    expect(undecodedFields.keys.toSet(), BinaryUndecodedField.values.toSet());
    expect(coverage.recordAccountedRatio, greaterThan(0.84));
    expect(coverage.recordSemanticRatio, greaterThan(0.53));
    print(
      'binary corpus: ${seen.length} files · $steps steps · generations ${generations.map((g, n) => MapEntry(g.name, n))} · '
      'record semantic ${(coverage.recordSemanticRatio * 100).toStringAsFixed(1)}% accounted '
      '${(coverage.recordAccountedRatio * 100).toStringAsFixed(1)}% · body accounted '
      '${(coverage.bodyAccountedRatio * 100).toStringAsFixed(1)}% · undecoded ${coverage.recordUndecodedBytes} B in '
      '${undecodedFields.map((f, n) => MapEntry(f.name, n))} · $elapsed ms',
    );
  });

  group('pinned files', () {
    File? pin(String suffix) => files.where((f) => f.path.replaceAll(r'\', '/').endsWith(suffix)).firstOrNull;
    SeqFile load(String suffix) => parseSeqFile(pin(suffix)!.readAsBytesSync());

    test('PCBA FT Demo.seq: eleven sequences with their steps, modules and expression arrays', () {
      final file = load('PCBA FT Demo/PCBA FT Demo.seq');
      expect(file.sequences, hasLength(11));
      final power = file.sequence('Power Diagnostics')!;
      expect(power.main, hasLength(4));
      final sources = power.main.map((s) => s.raw.prop('DataSourceArray')).whereType<SeqProperty>().toList();
      expect(sources, hasLength(3));
      expect(sources.first.array!.single.scalar, 'Locals.PS_Meas_Data.Max_Current');
      expect(sources.first.array!.single.className, 'ExprValue');
    });

    test('SequentialModel.seq: the process model with its callbacks and entry points', () {
      final file = load('Patching Process Models/SequentialModel.seq');
      expect(file.sequences, hasLength(27));
      final testUuts = file.sequence('Test UUTs')!;
      expect(testUuts.steps, isNotEmpty);
      expect(testUuts.runtimeSettings?.entryPointNameExpression, isNotNull);
      expect(file.sequences.where((s) => s.steps.any((t) => t.module.adapter == SeqAdapter.sequenceCall)), isNotEmpty);
    });

    test('Test Sequence.seq: a sequence named `Sequence` with a typed sub-step', () {
      final seq = load('sandbox/Test Sequence.seq').sequence('Sequence')!;
      final step = seq.main.single;
      expect((step.name, step.type), ('Subseq', 'DanfossStringValueTest'));
      expect(step.raw.prop('Limits')!.prop('String')!.scalar, 'String Limit');
    });

    test('PCBA FT Demo.seq: a pool that starts with Obj still roots the data at SequenceFileData', () {
      final file = load('PCBA FT Demo/PCBA FT Demo.seq');
      expect(file.binary!.pool.first, 'Obj');
      expect(file.binary!.data.classIndex, greaterThan(0));
      expect(file.data.className, 'SequenceFileData');
    });

    test('LabVIEW Compiled Object Cache Preparation.seq: a substep typedef decodes through its substeps', () {
      final file = load('LabVIEW Compiled Object Cache Preparation.seq');
      final wait = file.types.firstWhere((t) => t.name == 'NI_Wait');
      final substeps = wait.prop('Substeps')!;
      expect([for (final s in substeps.array!) s.name], ['OnNewStep', 'Post', 'Edit']);
      final edit = substeps.array![2];
      expect(edit.prop('MenuName')!.scalar, 'ResStr("NI_WAIT_STEP_TYPE", "EDIT_STEP_MENU_NAME")');
      expect(edit.prop('HasEditPanel')!.scalar, 'true');
      expect([for (final c in edit.prop('Result')!.subProps) c.name], ['Error', 'Status', 'ReportText', 'Common']);
      expect(edit.prop('Result')!.prop('Status')!.attributes[BinAttr.inherited], 'true');
    });

    test('PerformanceMeasurementLogger.seq: Ref parameters and locals with their value flags', () {
      final log = load('ModelPlugins/PerformanceMeasurementLogger.seq').sequence('Log Data to File')!;
      final params = log.raw.prop('Parameters')!;
      expect(params.attributes['valueflags'], '4456448');
      expect([for (final c in params.subProps) c.name], ['PerformanceMeasurementLogger']);
      final ref = params.subProps.single;
      expect(ref.className, 'Ref');
      expect(ref.scalar, isNull);
      final locals = log.raw.prop('Locals')!;
      expect(locals.attributes['valueflags'], '4194304');
      expect([for (final c in locals.subProps) c.name], ['SocketTime', 'ResultList']);
    });

    test('GetNIVSTokens.seq: the TestStand 4.5 generation', () {
      final file = load('Executable/GetNIVSTokens.seq');
      expect(file.binary!.generation, Tof1Generation.ts4);
      expect(file.sequences.single.main, hasLength(14));
      expect(file.sequences.single.main.first.type, isNotNull);
    });

    test('CC Tests.seq: the TestStand 2013 generation', () {
      final file = load('TestStand Scripts/CC Tests.seq');
      expect(file.binary!.generation, Tof1Generation.ts2013);
      expect(file.binary!.types.where((t) => t.isProtected), isEmpty);
      expect(file.sequences.single.steps.length, greaterThan(10));
    });

    test('specifications.seq: protected types carry their digests and lift with their content', () {
      final file = load('systemtests/specifications.seq');
      final protectedTypes = file.binary!.types.where((t) => t.isProtected).toList();
      expect(protectedTypes, hasLength(8));
      expect(protectedTypes.where((t) => t.hasSecondaryDigest), hasLength(1));
      for (final type in protectedTypes) {
        expect(type.protectionDigest, isNotEmpty);
        final root = file.types.firstWhere((t) => t.name == type.name);
        expect(root.attributes[BinAttr.protected], type.protectionDigest);
        expect(root.subProps.isNotEmpty || root.array != null, isTrue, reason: type.name);
      }
    });

    test('Accelerometer.seq: enum typedefs decode with their enumerators', () {
      final file = load('TestPrograms/Accelerometer/Accelerometer.seq');
      final enums = file.binary!.types.where((t) => t.root.kind == SeqValueClass.enumeration).toList();
      expect(enums, isNotEmpty);
      final items = enums.first.root.enumItems!;
      expect(items.elements, isNotEmpty);
      final first = items.elements!.first as BinaryRecord;
      expect(first.child('EnumeratorName')!.value, isA<String>());
      expect(first.child('EnumeratorValue')!.value, isA<double>());
      expect(enums.first.root.enumValueName, isNotNull);
    });
  });
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
