#!/usr/bin/env bash
#
# Fetch "Rosetta" .seq pairs — the same NI example measurement saved in different
# encodings across NI's own public repos — into the (gitignored) corpus at
# corpus/seq/rosetta/. These pair a BINARY (TOF1) file with an XML "twin" of the
# same NI example, so the binary record grammar can be attacked differentially:
# the XML side gives the known PropertyObject tree; the binary side gives the
# byte layout to align against it. The binaries are also *small* (4-step, ~7.5KB)
# — the controlled-minimal inputs the binary decode was blocked on.
#
# Clean-room: only the fetch recipe is committed; the .seq data is NOT (corpus/
# is gitignored, same as fetch_seq_corpus.dart). Requires an authenticated `gh`.
#
# Sources (NI's official, public measurement-plugin example repos):
#   ni/measurement-plugin-labview  — ships some examples BINARY, some XML
#   ni/measurement-plugin-python   — ships the same examples as XML
#
# Run: bash packages/labwright_teststand/tool/fetch_rosetta_pairs.sh
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
