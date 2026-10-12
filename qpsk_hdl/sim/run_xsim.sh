#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# QPSK transmitter / receiver - simulation with Vivado xsim
#
# Same targets as the Makefile, for machines that have Vivado but not
# Icarus Verilog or make (e.g. Windows with Git Bash).
#
#   ./run_xsim.sh           run the whole regression
#   ./run_xsim.sh cordic    CORDIC unit test
#   ./run_xsim.sh tx        transmitter vs golden model
#   ./run_xsim.sh rx        receiver, every stage vs golden model
#   ./run_xsim.sh e2e       RTL transmitter -> channel -> RTL receiver, BER
#   ./run_xsim.sh sweep     e2e over a range of channel conditions
#   ./run_xsim.sh clean
#
# VIVADO_BIN   Vivado bin directory (default: 2025.2 under C:\AMDDesignTools)
# PY           Python interpreter    (default: python3, else python)
# NPKT, IGNORE packet counts for sweep (default 16, 6)
# ---------------------------------------------------------------------------
set -u
cd "$(dirname "$0")"

VIVADO_BIN=${VIVADO_BIN:-/c/AMDDesignTools/2025.2/Vivado/bin}
if [ -z "${PY:-}" ]; then
    if python3 -c "" 2>/dev/null; then PY=python3; else PY=python; fi
fi
if [ -x "$VIVADO_BIN/xvlog.bat" ]; then EXT=.bat; else EXT=; fi
XVLOG="$VIVADO_BIN/xvlog$EXT"
XELAB="$VIVADO_BIN/xelab$EXT"
XSIM="$VIVADO_BIN/xsim$EXT"

MODEL=../model
RTL=../rtl
TX_SRC="$RTL/qpsk_tx.v $RTL/qpsk_tx_sym.v $RTL/fir_interp_rrc.v"
CORD="$RTL/cordic_rot.v $RTL/cordic_vec.v"
RX_SRC="$RTL/qpsk_rx.v $RTL/rx_agc.v $RTL/fir_rrc_rx.v \
        $RTL/symbol_timing_recovery.v $RTL/coarse_freq_rec.v \
        $RTL/fine_freq_rec.v $RTL/packet_detector.v $RTL/rx_extract.v $CORD"

# build <top> <sources...>: compile and elaborate into snapshot <top>_snap
build () {
    local top=$1; shift
    "$XVLOG" -nolog -i $RTL -i ../vectors "$@" > xvlog_$top.out 2>&1 \
        || { cat xvlog_$top.out; echo "xvlog FAILED ($top)"; exit 1; }
    "$XELAB" -nolog --timescale 1ns/1ps --debug off -s ${top}_snap $top > xelab_$top.out 2>&1 \
        || { cat xelab_$top.out; echo "xelab FAILED ($top)"; exit 1; }
}
sim () { local top=$1; shift; "$XSIM" -nolog ${top}_snap -R "$@" 2>&1 | tr -d '\r'; }

# regenerate the shared constants header from the model
defs () { (cd $MODEL && $PY qpsk_fxparams.py > /dev/null) && echo "qpsk_defs.vh regenerated"; }

do_cordic () {
    (cd $MODEL && $PY gen_cordic_vectors.py)
    build tb_cordic ../tb/tb_cordic.v $CORD
    sim tb_cordic | grep -E "PASS|FAIL|mismatch|ERROR"
}

do_tx () {
    (cd $MODEL && $PY gen_tx_vectors.py)
    build tb_qpsk_tx ../tb/tb_qpsk_tx.v $TX_SRC
    sim tb_qpsk_tx | grep -E "PASS|FAIL|got|ERROR"
    # same vectors again with a randomised sample enable
    sim tb_qpsk_tx -testplusarg en_random | grep -E "PASS|FAIL|got|ERROR"
}

do_rx () {
    (cd $MODEL && $PY gen_rx_vectors.py)
    build tb_qpsk_rx ../tb/tb_qpsk_rx.v $RX_SRC
    # drop the xsim banner and Tcl chatter, keep the testbench report
    sim tb_qpsk_rx | grep -vE "^ *(\*\*|#|Vivado Simulator|Time resolution|source |INFO:|run -all|exit|quit|\\\$finish)" \
                   | grep -v "^$"
}

do_e2e () {
    (cd $MODEL && $PY e2e.py prepare npkt=20 seed=11)
    build tb_tx_dump ../tb/tb_tx_dump.v $TX_SRC
    sim tb_tx_dump | grep -E "wrote|ERROR"
    (cd $MODEL && $PY e2e.py channel ebn0=20 fo=0.025 ph=37 toff=0.51 seed=12)
    build tb_rx_ber ../tb/tb_rx_ber.v $RX_SRC
    sim tb_rx_ber | grep -E "ERROR"
    (cd $MODEL && $PY e2e.py check npkt=20 ignore=6 ebn0=20)
}

# ---- sweep: same cases as sweep_rtl.sh ------------------------------------
run_case () {
    local label="$1"; shift
    (cd $MODEL && $PY e2e.py channel "$@" seed=12) >/dev/null
    sim tb_rx_ber >/dev/null
    local ebn0
    ebn0=$(echo "$@" | tr ' ' '\n' | grep '^ebn0=' | cut -d= -f2)
    [ -z "$ebn0" ] && ebn0=20
    local out
    out=$(cd $MODEL && $PY e2e.py check npkt=$NPKT ignore=$IGNORE ebn0="$ebn0")
    local dec ber res
    dec=$(echo "$out" | grep 'packets decoded' | awk '{print $4}')
    ber=$(echo "$out" | grep '  BER' | awk '{print $3}')
    res=$(echo "$out" | grep 'RESULT' | cut -d: -f2- | sed 's/^ *//')
    printf "  %-34s decoded %-3s  BER %-10s  %s\n" "$label" "$dec" "$ber" "$res"
}

do_sweep () {
    NPKT=${NPKT:-16}
    IGNORE=${IGNORE:-6}
    echo "building..."
    (cd $MODEL && $PY e2e.py prepare npkt=$NPKT seed=11) >/dev/null
    build tb_tx_dump ../tb/tb_tx_dump.v $TX_SRC
    build tb_rx_ber  ../tb/tb_rx_ber.v  $RX_SRC

    echo "transmitting $NPKT packets through the RTL transmitter..."
    sim tb_tx_dump | grep wrote

    echo
    echo "=== carrier frequency offset (turns/symbol) ==="
    for fo in -0.06 -0.02 0.0 0.02 0.06; do
        run_case "fo = $fo" ebn0=20 fo=$fo ph=37 toff=0.51
    done

    echo "=== carrier phase offset ==="
    for p in 0 90 180 270; do
        run_case "phase = $p deg" ebn0=20 fo=0.02 ph=$p toff=0.51
    done

    echo "=== timing offset and drift ==="
    for t in 0.0 0.35 0.75; do
        run_case "timing offset = $t" ebn0=20 fo=0.02 ph=37 toff=$t
    done
    for d in 100 200; do
        run_case "timing drift = $d ppm" ebn0=20 fo=0.02 ph=37 toff=0.51 drift=$d
    done

    echo "=== receiver input level ==="
    for s in 1.0 0.3 0.05; do
        run_case "input scale = $s" ebn0=20 fo=0.02 ph=37 toff=0.51 scale=$s
    done

    echo "=== EbN0 ==="
    for e in 20 12 9 7; do
        run_case "EbN0 = $e dB" ebn0=$e fo=0.02 ph=37 toff=0.51
    done
    echo
    echo "sweep complete"
}

do_clean () {
    rm -rf xsim.dir xelab.pb xvlog.pb xsim*.jou xsim*.log xelab_*.out xvlog_*.out .Xil
    echo cleaned
}

case "${1:-all}" in
    cordic) defs; do_cordic ;;
    tx)     defs; do_tx ;;
    rx)     defs; do_rx ;;
    e2e)    defs; do_e2e ;;
    sweep)  defs; do_sweep ;;
    all)    defs
            echo "== cordic =="; do_cordic
            echo "== tx ==";     do_tx
            echo "== rx ==";     do_rx
            echo "== e2e ==";    do_e2e ;;
    clean)  do_clean ;;
    *)      echo "usage: $0 [all|cordic|tx|rx|e2e|sweep|clean]"; exit 1 ;;
esac
