#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build the ZedBoard bitstream.
#
#   ./build.sh            with VIO + ILA debug cores
#   ./build.sh -nodebug   plain design
#
# VIVADO_BIN  Vivado bin directory (default: 2025.2 under C:\AMDDesignTools)
# ---------------------------------------------------------------------------
set -eu
cd "$(dirname "$0")"

VIVADO_BIN=${VIVADO_BIN:-/c/AMDDesignTools/2025.2/Vivado/bin}
if python3 -c "" 2>/dev/null; then PY=python3; else PY=python; fi
if [ -x "$VIVADO_BIN/vivado.bat" ]; then VIVADO="$VIVADO_BIN/vivado.bat"; else VIVADO="$VIVADO_BIN/vivado"; fi

(cd ../../model && $PY qpsk_fxparams.py > /dev/null)
$PY gen_board_defs.py

mkdir -p build
"$VIVADO" -mode batch -nojournal -log build/vivado.log -source build.tcl -tclargs "$@"
