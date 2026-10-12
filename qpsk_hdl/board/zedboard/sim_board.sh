#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Simulate the ZedBoard loopback top level with Vivado xsim.
#
#   ./sim_board.sh
#
# VIVADO_BIN  Vivado bin directory (default: 2025.2 under C:\AMDDesignTools)
# ---------------------------------------------------------------------------
set -u
cd "$(dirname "$0")"

VIVADO_BIN=${VIVADO_BIN:-/c/AMDDesignTools/2025.2/Vivado/bin}
if python3 -c "" 2>/dev/null; then PY=python3; else PY=python; fi
if [ -x "$VIVADO_BIN/xvlog.bat" ]; then EXT=.bat; else EXT=; fi

CORE=../../rtl
SRC="tb/tb_zed_top.v rtl/zed_qpsk_top.v rtl/qpsk_channel.v rtl/awgn_gen.v \
     rtl/ber_monitor.v \
     $CORE/qpsk_tx.v $CORE/qpsk_tx_sym.v $CORE/fir_interp_rrc.v \
     $CORE/qpsk_rx.v $CORE/rx_agc.v $CORE/fir_rrc_rx.v \
     $CORE/symbol_timing_recovery.v $CORE/coarse_freq_rec.v \
     $CORE/fine_freq_rec.v $CORE/packet_detector.v $CORE/rx_extract.v \
     $CORE/cordic_rot.v $CORE/cordic_vec.v"

(cd ../../model && $PY qpsk_fxparams.py > /dev/null) || exit 1
$PY gen_board_defs.py || exit 1

mkdir -p sim_work
cd sim_work
SRC=$(for f in $SRC; do echo ../$f; done)
"$VIVADO_BIN/xvlog$EXT" -nolog -i ../rtl -i ../$CORE $SRC > xvlog.out 2>&1 \
    || { cat xvlog.out; echo "xvlog FAILED"; exit 1; }
"$VIVADO_BIN/xelab$EXT" -nolog --timescale 1ns/1ps --debug off -s tb_zed_snap tb_zed_top \
    > xelab.out 2>&1 || { cat xelab.out; echo "xelab FAILED"; exit 1; }
"$VIVADO_BIN/xsim$EXT" -nolog tb_zed_snap -R 2>&1 | tr -d '\r' | grep -E "tb_zed|pkts|FAIL|ERROR"
