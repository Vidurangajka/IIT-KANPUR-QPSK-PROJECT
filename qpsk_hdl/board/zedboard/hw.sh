#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Program the ZedBoard and read the results through JTAG.
#
#   ./hw.sh                 program, read BER, capture constellation
#   ./hw.sh ber             just read the BER counters again
#   ./hw.sh ila             just capture another constellation
#
# VIVADO_BIN  Vivado bin directory (default: 2025.2 under C:\AMDDesignTools)
# ---------------------------------------------------------------------------
set -eu
cd "$(dirname "$0")"

VIVADO_BIN=${VIVADO_BIN:-/c/AMDDesignTools/2025.2/Vivado/bin}
if [ -x "$VIVADO_BIN/vivado.bat" ]; then VIVADO="$VIVADO_BIN/vivado.bat"; else VIVADO="$VIVADO_BIN/vivado"; fi

"$VIVADO" -mode batch -nojournal -log build/hw.log -source hw.tcl -tclargs "$@" \
    | tr -d '\r' | grep -E "^(programmed|packets|wrote|ERROR)" || true
