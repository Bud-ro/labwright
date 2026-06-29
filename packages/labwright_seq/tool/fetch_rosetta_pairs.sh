#!/usr/bin/env bash
#
# Fetch "Rosetta" .seq pairs. Instead of forging these ourselves with NI tools (likely a EULA breach?) 
# we instead scour the internet for `.seq` pairs that perform the same sequence. In this case
# NI provides examples for both LabVIEW and Python under the MIT license. These can be used 
# to correlate the easier to understand XML format with the harder binary format. 
# Additional sources may be discovered later.
#
# Two kinds of pair are fetched:
#  1. STRUCTURAL twins — the same NI measurement workflow saved by the LabVIEW
#     (binary) vs Python (XML) toolchains. Same structure, but different step
#     content/names, so they validate structure only (counts, standard props).
#  2. CONTENT-EXACT twin — one file (OutputVoltageMeasurement_example.seq, in
#     ni/measurement-plugin-python) that git history shows re-saved binary->XML in
#     a single commit (PR #1258, 2025-11-04). The binary PARENT blob and the XML
#     CHILD blob are the *same sequence*, so they validate exact per-field content.
#     The only known content delta is a bundled Python version bump (3.9 vs 3.10).
#     This is the decode oracle. Found via the rosetta-twin research sweep.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
dest="$root/corpus/seq/rosetta"
mkdir -p "$dest"

get() { # repo  path-in-repo  outfile
  gh api "repos/$1/contents/$2" --jq .content | base64 -d > "$dest/$3"
  printf '  %8d  %s\n' "$(stat -c%s "$dest/$3" 2>/dev/null || stat -f%z "$dest/$3")" "$3"
}

getref() { # repo  path-in-repo  commit-sha  outfile  (fetch a path at a pinned commit)
  gh api "repos/$1/contents/$2?ref=$3" --jq .content | base64 -d > "$dest/$4"
  printf '  %8d  %s\n' "$(stat -c%s "$dest/$4" 2>/dev/null || stat -f%z "$dest/$4")" "$4"
}

echo "fetching Rosetta pairs into $dest"
# NI-DMM measurement: BINARY (labview) <-> XML (python). Confirmed same example
# (update pin map / register sessions / measure / cleanup).
get ni/measurement-plugin-labview "Source/Example Measurements/NI-DMM Measurement/NIDmmMeasurement_example.seq" "NIDmm_labview_BIN.seq"
get ni/measurement-plugin-python  "examples/nidmm_measurement/NIDmmMeasurement_example.seq"                      "NIDmm_python_XML.seq"
# NI-FGEN standard function: BINARY (labview) <-> XML (python).
get ni/measurement-plugin-labview "Source/Example Measurements/NI-FGEN Standard Function/NIFgenStandardFunction_example.seq" "NIFgen_labview_BIN.seq"
get ni/measurement-plugin-python  "examples/nifgen_standard_function/NIFgenStandardFunction_example.seq"                       "NIFgen_python_XML.seq"
# NI-SCOPE acquire waveform: BINARY (labview) <-> XML (python).
get ni/measurement-plugin-labview "Source/Example Measurements/NI-SCOPE Acquire Waveform/NIScopeAcquireWaveform_example.seq" "NIScope_labview_BIN.seq"
get ni/measurement-plugin-python  "examples/niscope_acquire_waveform/NIScopeAcquireWaveform_example.seq"                       "NIScope_python_XML.seq"
# Same-repo XML examples (labview) — structural template for the labview binaries
# (same author / TS version / conventions). NB: not every labview-repo .seq is
# binary — NIDCPower and NIDigitalSPI are stored as XML in BOTH repos, so they are
# XML-only references, not binary<->XML twins.
get ni/measurement-plugin-labview "Source/Example Measurements/NI-DCPower Source DC Voltage/NIDCPowerSourceDCVoltage_example.seq" "NIDCPower_labview_XML.seq"

# Second structural-twin family, at a DIFFERENT TestStand version (2023) for version
# coverage: NI's abstraction-layer plugin, binary (labview) <-> XML (python). Both
# repos MIT. (NI-Measurement-Plug-Ins org.)
get NI-Measurement-Plug-Ins/abstraction-layer-labview "Source/HAL Implementation/DmmMeasurementHAL.seq" "DmmHAL_labview_BIN.seq"
get NI-Measurement-Plug-Ins/abstraction-layer-python  "source/demo_files/DmmMeasurementHAL.seq"          "DmmHAL_python_XML.seq"
get NI-Measurement-Plug-Ins/abstraction-layer-labview "Source/FAL Implementation/SourceMeasureDCVoltageFAL.seq" "SmuFAL_labview_BIN.seq"
get NI-Measurement-Plug-Ins/abstraction-layer-python  "source/demo_files/SourceMeasureDCVoltageFAL.seq"          "SmuFAL_python_XML.seq"

# Deliberately NOT fetched (clean-room / licensing): one large third-party repo is a
# verbatim dump of a TestStand product install's example folder (801 .seq), and other
# third-party/production repos (caizikun/Teststand_Git, 425J/SeqEditQuickDrop's
# NI-shipped FrontEndCallbacks/QuickDrop, noffz-mbokcic FCT, Arxtron CICDUtility) are
# either NI product files or unlicensed real test programs. We only use NI's own
# MIT-licensed open-source example repos. (Pure single-format NI specimens such as
# ni/nitsm-python systemtests belong in the general corpus, not this twin set.)

# CONTENT-EXACT twin (the decode oracle): the same OutputVoltage example file as the
# binary version (parent commit, before the re-save) and the XML it was re-saved to
# one commit later. Pinned to the two commit SHAs so the exact bytes are reproduced
# regardless of later edits.
ovpath="examples/output_voltage_measurement/OutputVoltageMeasurement_example.seq"
getref ni/measurement-plugin-python "$ovpath" 1eea63096f4638eee77eb840adea85763c94286b "OutputVoltage_BIN.seq"
getref ni/measurement-plugin-python "$ovpath" 8ec585046ca31d5a56c33f2a1b80f84d031be5a1 "OutputVoltage_XML.seq"
echo "done."
