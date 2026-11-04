#!/bin/bash
# build-standalone.sh OUTDIR [TOOL...]: each built-in tool as a program of its own, without Qt.  CXX picks the compiler
# (runs/.../rv32g-g++ for the board), CXXFLAGS adds to -std=c++17 -O2.  Default tools: the partial-reconfiguration set.
set -e
cd "$(dirname "$0")/.."
out=${1:?usage: build-standalone.sh OUTDIR [TOOL...]}; shift
[ $# -gt 0 ] || set -- fasm2frames pr-partial pr-block-json pin-cells at-gen at-decode
mkdir -p "$out"
for tool in "$@"; do
    u=${tool//-/_}
    ${CXX:-c++} -std=c++17 -O2 ${CXXFLAGS:-} -DTOOL_MAIN="${u}_main" tools/common/standalone_main.cpp "tools/$u/$u.cpp" -o "$out/$tool"
done
