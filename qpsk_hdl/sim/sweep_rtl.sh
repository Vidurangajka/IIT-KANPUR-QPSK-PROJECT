#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Run the full RTL transmitter -> channel -> RTL receiver chain over a range
# of channel conditions and report the BER for each.
# ---------------------------------------------------------------------------
set -u
cd "$(dirname "$0")"

NPKT=${NPKT:-16}
IGNORE=${IGNORE:-6}
RTL=../rtl
MODEL=../model

CORD="$RTL/cordic_rot.v $RTL/cordic_vec.v"
TX_SRC="$RTL/qpsk_tx.v $RTL/qpsk_tx_sym.v $RTL/fir_interp_rrc.v"
RX_SRC="$RTL/qpsk_rx.v $RTL/rx_agc.v $RTL/fir_rrc_rx.v \
        $RTL/symbol_timing_recovery.v $RTL/coarse_freq_rec.v \
        $RTL/fine_freq_rec.v $RTL/packet_detector.v $RTL/rx_extract.v $CORD"

echo "building..."
(cd $MODEL && python3 e2e.py prepare npkt=$NPKT seed=11) >/dev/null
iverilog -g2005 -I$RTL -I../vectors -o tb_tx_dump.vvp ../tb/tb_tx_dump.v $TX_SRC || exit 1
iverilog -g2005 -I$RTL -I../vectors -o tb_rx_ber.vvp  ../tb/tb_rx_ber.v  $RX_SRC || exit 1

echo "transmitting $NPKT packets through the RTL transmitter..."
vvp tb_tx_dump.vvp | grep wrote

run_case () {
    local label="$1"; shift
    (cd $MODEL && python3 e2e.py channel "$@" seed=12) >/dev/null
    vvp tb_rx_ber.vvp >/dev/null 2>&1
    local ebn0
    ebn0=$(echo "$@" | tr ' ' '\n' | grep '^ebn0=' | cut -d= -f2)
    [ -z "$ebn0" ] && ebn0=20
    local out
    out=$(cd $MODEL && python3 e2e.py check npkt=$NPKT ignore=$IGNORE ebn0="$ebn0")
    local dec ber res
    dec=$(echo "$out" | grep 'packets decoded' | awk '{print $4}')
    ber=$(echo "$out" | grep '  BER' | awk '{print $3}')
    res=$(echo "$out" | grep 'RESULT' | cut -d: -f2- | sed 's/^ *//')
    printf "  %-34s decoded %-3s  BER %-10s  %s\n" "$label" "$dec" "$ber" "$res"
}

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
