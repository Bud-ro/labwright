#!/usr/bin/env bash
#
# Fetch "Rosetta" .seq pairs. Instead of forging these ourselves with NI tools (likely a EULA breach?) 
# we instead scour the internet for `.seq` pairs that perform the same sequence. In this case
# NI provides examples for both LabVIEW and Python under the MIT license. These can be used 
# to correlate the easier to understand XML format with the harder binary format. 
# Additional sources may be discovered later.
#
# TODO: Additional accuracy/pairs can be created by correlating commits and ensuring cross-repo
#   files indeed have the same content. These sequence files have dozens of commits since they
#   were initially introduced.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
dest="$root/corpus/seq/rosetta"
mkdir -p "$dest"

get() { # repo  path-in-repo  outfile
  gh api "repos/$1/contents/$2" --jq .content | base64 -d > "$dest/$3"
  printf '  %8d  %s\n' "$(stat -c%s "$dest/$3" 2>/dev/null || stat -f%z "$dest/$3")" "$3"
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
# (same author / TS version / conventions).
get ni/measurement-plugin-labview "Source/Example Measurements/NI-DCPower Source DC Voltage/NIDCPowerSourceDCVoltage_example.seq" "NIDCPower_labview_XML.seq"
echo "done."
