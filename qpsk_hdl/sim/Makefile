# ---------------------------------------------------------------------------
# QPSK transmitter / receiver - simulation
#
#   make            run the whole regression
#   make cordic     CORDIC unit test
#   make tx         transmitter vs golden model
#   make rx         receiver, every stage vs golden model
#   make e2e        RTL transmitter -> channel -> RTL receiver, BER
#   make sweep      e2e over a range of channel conditions
#   make clean
# ---------------------------------------------------------------------------
IV      := iverilog -g2005 -Wall -I../rtl -I../vectors
VVP     := vvp
PY      := python3
MODEL   := ../model
RTL     := ../rtl

TX_SRC  := $(RTL)/qpsk_tx.v $(RTL)/qpsk_tx_sym.v $(RTL)/fir_interp_rrc.v
CORD    := $(RTL)/cordic_rot.v $(RTL)/cordic_vec.v
RX_SRC  := $(RTL)/qpsk_rx.v $(RTL)/rx_agc.v $(RTL)/fir_rrc_rx.v \
           $(RTL)/symbol_timing_recovery.v $(RTL)/coarse_freq_rec.v \
           $(RTL)/fine_freq_rec.v $(RTL)/packet_detector.v \
           $(RTL)/rx_extract.v $(CORD)

.PHONY: all defs cordic tx rx e2e sweep clean

all: cordic tx rx e2e

# regenerate the shared constants header from the model
defs:
	@cd $(MODEL) && $(PY) qpsk_fxparams.py > /dev/null && echo "qpsk_defs.vh regenerated"

cordic: defs
	@cd $(MODEL) && $(PY) gen_cordic_vectors.py
	@$(IV) -o tb_cordic.vvp ../tb/tb_cordic.v $(CORD)
	@$(VVP) tb_cordic.vvp | grep -E "PASS|FAIL|mismatch" || true

tx: defs
	@cd $(MODEL) && $(PY) gen_tx_vectors.py
	@$(IV) -o tb_qpsk_tx.vvp ../tb/tb_qpsk_tx.v $(TX_SRC)
	@$(VVP) tb_qpsk_tx.vvp | grep -E "PASS|FAIL|got" || true
	@$(VVP) tb_qpsk_tx.vvp +en_random | grep -E "PASS|FAIL|got" || true

rx: defs
	@cd $(MODEL) && $(PY) gen_rx_vectors.py
	@$(IV) -o tb_qpsk_rx.vvp ../tb/tb_qpsk_rx.v $(RX_SRC)
	@$(VVP) tb_qpsk_rx.vvp

e2e: defs
	@cd $(MODEL) && $(PY) e2e.py prepare npkt=20 seed=11
	@$(IV) -o tb_tx_dump.vvp ../tb/tb_tx_dump.v $(TX_SRC)
	@$(VVP) tb_tx_dump.vvp | grep -v finish
	@cd $(MODEL) && $(PY) e2e.py channel ebn0=20 fo=0.025 ph=37 toff=0.51 seed=12
	@$(IV) -o tb_rx_ber.vvp ../tb/tb_rx_ber.v $(RX_SRC)
	@$(VVP) tb_rx_ber.vvp | grep -v finish
	@cd $(MODEL) && $(PY) e2e.py check npkt=20 ignore=6 ebn0=20

sweep: defs
	@./sweep_rtl.sh

clean:
	@rm -f *.vvp *.vcd
	@echo cleaned
