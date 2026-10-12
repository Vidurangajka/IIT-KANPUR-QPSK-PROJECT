# QPSK Transmitter and Receiver in Verilog

A synthesizable Verilog implementation of the MathWorks Wireless HDL Toolbox
reference application
[*QPSK Transmitter and Receiver*](https://in.mathworks.com/help/wireless-hdl/ug/qpsk-transmitter-receiver.html),
built from scratch with a bit-exact Python golden model and self-checking
testbenches.

The reference application is a Simulink/HDL Coder design. This project
reproduces the same system — same packet structure, same processing chain —
in hand-written RTL, with the MATLAB/Simulink pair replaced by a Python
fixed-point model that the Verilog is verified against sample for sample.

---

## System

Continuous transmission of packets built from a 13-symbol Barker preamble and
a scrambled payload. Continuous data lets the receiver do blind timing and
frequency recovery and adapt across packets, which is what keeps the
synchroniser simple.

```
                     Rsym                           Fs = 4*Rsym
  bits ──► packetiser ──► scrambler ──► QPSK map ──► RRC interp x4 ──► I/Q
                                                     (41 taps, beta 0.5)

  I/Q ──► AGC ──► RRC matched ──► symbol timing ──► coarse freq ──► fine freq
                   filter          recovery         recovery        recovery
                                  (Gardner, /4)     (4th power)    (dec. dir.)
                                                                       │
        bits ◄── descrambler ◄── slicer ◄── phase ambiguity ◄── packet ┘
                                             removal            detector
```

| | |
|---|---|
| Modulation | QPSK, Gray mapped |
| Samples per symbol | 4 |
| Pulse shaping | Root raised cosine, roll-off 0.5, span 10 symbols, 41 taps |
| Preamble | Barker-13, carried as QPSK symbols on the I=Q diagonal |
| Payload | 512 bits per packet by default (parameterizable; reference default is 4096) |
| Scrambler | Additive LFSR, x⁷ + x⁴ + 1, reloaded every packet |
| Sample format | s(16,15), i.e. signed Q1.15 |
| Angle format | signed 16-bit, one turn = 2¹⁶ |

---

## Results

**Every receiver stage is bit-exact against the golden model**, not merely
close:

```
 stage      produced   expected   mismatches
 AGC           17216      17216          0
 matched       17216      17216          0
 timing         4305       4305          0
 coarse         4305       4305          0
 fine           4305       4305          0
 detections       16         16          0
 bits           8152       7680          0
 packets          15         15
tb_qpsk_rx: PASS
```

This is worth noting because the reference application explicitly does *not*
achieve it: it reports that its coarse frequency recovery is not a bit-true
match between MATLAB and Simulink. Here the block is scheduled so that the
estimate is applied at a symbol-aligned instant in both model and RTL, so the
whole chain matches exactly.

**BER against theory** (Python fixed-point model, which the RTL reproduces
bit for bit; 40 packets, 8 ignored for synchroniser warm-up, with a 0.025
turns/symbol frequency offset, 37° phase offset and 0.51 sample timing
offset):

| Eb/N0 (dB) | measured BER | theoretical QPSK BER | implementation loss |
|---|---|---|---|
| 12 | 0 | 9.0e-09 | — |
| 10 | 0 | 3.9e-06 | — |
| 9  | 0 | 3.4e-05 | — |
| 8  | 2.4e-04 | 1.9e-04 | 0.16 dB |
| 7  | 1.3e-03 | 7.7e-04 | 0.42 dB |
| 6  | 3.8e-03 | 2.4e-03 | 0.48 dB |
| 5  | 2.4e-02 | 6.0e-03 | 2.1 dB |

The receiver holds within about half a dB of theory down to Eb/N0 ≈ 6 dB and
breaks down below 5 dB. The channel model itself is validated separately
against the theoretical curve with an ideal coherent receiver
(`model/check_channel.py`), so the Eb/N0 axis is trustworthy.

**Operating range**, measured end to end through the RTL (`make sweep`,
16 packets, 6 ignored, 15 decoded in every case):

```
=== carrier frequency offset (turns/symbol) ===
  fo = -0.06          BER 0.000e+00   PASS        phase =   0 deg   BER 0  PASS
  fo = -0.02          BER 0.000e+00   PASS        phase =  90 deg   BER 0  PASS
  fo =  0.00          BER 0.000e+00   PASS        phase = 180 deg   BER 0  PASS
  fo =  0.02          BER 0.000e+00   PASS        phase = 270 deg   BER 0  PASS
  fo =  0.06          BER 0.000e+00   PASS
=== timing ===                                  === receiver input level ===
  timing offset = 0.00   BER 0  PASS              scale = 1.00   BER 0  PASS
  timing offset = 0.35   BER 0  PASS              scale = 0.30   BER 0  PASS
  timing offset = 0.75   BER 0  PASS              scale = 0.05   BER 0  PASS
  drift = 100 ppm        BER 0  PASS
  drift = 200 ppm        BER 0  PASS
=== EbN0 ===
  20 dB  BER 0.000e+00  PASS      9 dB  BER 0.000e+00  PASS
  12 dB  BER 0.000e+00  PASS      7 dB  BER 1.085e-03  PASS (consistent with noise)
```

All 21 cases pass. Summarised:

- Carrier frequency offset: ±0.06 turns/symbol verified in RTL; ±0.125 is the
  algorithmic limit of the fourth-power estimator
- Carrier phase offset: any — the 0/90/180/270° ambiguity is resolved from
  the preamble correlator phase
- Timing offset: any fraction of a sample; drift to 200 ppm in RTL, 400 ppm
  in the model
- Receiver input level: 1.0 down to 0.05 of full scale

---

## Repository layout

```
rtl/     synthesizable Verilog
tb/      self-checking testbenches
model/   Python: design, float reference, bit-exact fixed-point golden model
sim/     Makefile and regression scripts
vectors/ generated stimulus and expected results (not checked in by hand)
```

### RTL

| file | what it does |
|---|---|
| `qpsk_defs.vh` | all constants, **generated** from the model so the two cannot drift |
| `cordic_rot.v` | pipelined CORDIC rotation; `UNIT_INPUT` variant rotates (1,0) with no pre-scale multiplier |
| `cordic_vec.v` | pipelined CORDIC vectoring (atan2), angle only |
| `qpsk_tx_sym.v` | packetiser, scrambler, QPSK mapper, bit prefetch with valid/ready |
| `fir_interp_rrc.v` | polyphase interpolate-by-4 RRC |
| `qpsk_tx.v` | transmitter top |
| `rx_agc.v` | multiplicative AGC |
| `fir_rrc_rx.v` | symmetric (folded) matched filter |
| `symbol_timing_recovery.v` | Gardner TED, cubic Farrow interpolator, modulo-1 NCO |
| `coarse_freq_rec.v` | fourth-power frequency estimator, feed-forward NCO |
| `fine_freq_rec.v` | decision-directed phase tracking |
| `packet_detector.v` | Barker correlator, dynamic threshold, peak pick, inhibit |
| `rx_extract.v` | delay line, phase ambiguity removal, slicer, descrambler |
| `qpsk_rx.v` | receiver top |

---

## Running it

```bash
cd sim
make            # full regression: cordic, tx, rx, end-to-end
make cordic     # CORDIC vs model, 4096 vectors x 3 modes
make tx         # transmitter vs model, symbols and samples
make rx         # receiver, every stage vs model
make e2e        # RTL transmitter -> channel -> RTL receiver, BER
make sweep      # end-to-end over a range of channel conditions (~13 min)
```

With Vivado instead of Icarus (e.g. on Windows under Git Bash, no `make`
needed), `sim/run_xsim.sh` runs the same targets on xsim:
`./run_xsim.sh [all|cordic|tx|rx|e2e|sweep|clean]`. Set `VIVADO_BIN` if Vivado
is not in `C:\AMDDesignTools\2025.2\Vivado\bin`.

Needs Icarus Verilog (or Vivado), Python 3, NumPy and SciPy. The Python model regenerates
`rtl/qpsk_defs.vh` and all test vectors as part of every target, so the RTL
constants always match the model that verifies it.

To run the transmitter and receiver in hardware, see
[board/zedboard/README.md](board/zedboard/README.md). It describes an on-chip
loopback with a configurable channel and a BER readout on a ZedBoard.

The model can also be run on its own:

```bash
cd model
python3 run_float.py      # algorithm-level sweeps
python3 run_fixed.py      # bit-exact model, BER vs Eb/N0
python3 sweep_fixed.py    # bit-exact model over channel conditions
python3 check_channel.py  # validate the channel against theory
python3 check_farrow.py   # validate the Farrow interpolator
```

---

## Design notes

### Clocking

The receiver datapath is **sample-enabled**, not one-sample-per-clock: the
clock runs faster than the sample rate and `in_valid` marks each input
sample. The design needs at least 8 clocks between samples (the testbenches
use 16). This is how such a receiver is built in practice — the reference
application runs a 1.92 MHz symbol rate on a 350 MHz clock, about 45 clocks
per sample — and it gives the pipelined CORDICs and the timing loop filter
room to close inside one sample period.

### Keeping the CORDICs out of the feedback loops

A pipelined CORDIC is ~19 clocks deep. Put two of them in a control loop and
the loop delay dictates an absurd clock rate. Two restructurings avoid this:

- **Fine frequency recovery.** The obvious implementation derotates the
  symbol and then measures the angle of the result, which puts a rotation
  CORDIC *and* a vectoring CORDIC inside the loop. But rotation preserves
  angles, so the angle of the derotated symbol is just
  `angle(y) + rotation_angle`. Both CORDICs become feed-forward and the
  feedback path shrinks to a subtract, a mask and the loop filter.

- **Coarse frequency recovery.** Everything on the estimation side is already
  feed-forward; only the once-per-block rate update has latency. Model and
  RTL both hold the result and apply it at the symbol whose index is
  congruent to `CF_GUARD` modulo `CF_BLK`, which makes the update a
  symbol-aligned event in both and keeps them bit-identical.

### The phase error detector is a bit mask

QPSK constellation points sit at 45°, 135°, 225°, 315°. In the 16-bit turn
format that is 0.125 turns plus a multiple of 0.25. So the decision-directed
phase error is `(theta - 8192)` truncated to 14 bits and read as signed —
exact, amplitude-independent, and free.

### The preamble correlator has no multipliers

Preamble symbols are `A·b·(1+j)` with `b` the Barker code, so correlating
against their conjugate reduces to two 13-tap ±1 FIRs on `u = yI+yQ` and
`v = yQ-yI`. The constant `A` is absorbed into the detection threshold. Phase
ambiguity removal is likewise multiplier-free: the quadrant is read off the
signs and relative magnitudes of the correlator output and removed by
swapping and negating the rails.

### Why the AGC earns its place

With the AGC holding the mean power at the matched filter input, the symbol
power at the Gardner detector varies by only 1.26× across the whole Eb/N0 and
input-level range (measured). That means the timing loop can use constant
gains instead of dividing by a running power estimate — no divider, and
identical performance. The same argument lets the packet detector use a fixed
threshold ratio.

### Multiplier count

Counted from the RTL (one 16×16 multiply each):

| | multipliers |
|---|---|
| Transmitter | 22 |
| Receiver | 72 |

For scale, the reference application reports 18 and 106 DSP48s respectively
after place and route on a ZCU102. No synthesis tool was available in this
environment, so these are structural counts — **not** post-place-and-route
results, and no Fmax is claimed.

---

## Deviations from the reference application

Deliberate, and each for a reason:

1. **Coarse frequency update is smoothed.** The article notes that
   estimate-to-estimate steps are what limit the receiver at low Eb/N0,
   because the fine frequency loop has to re-acquire after each step, and
   suggests locking the estimate after acquisition as a mitigation. Instead,
   the first `CF_FAST_BLK` estimates are applied in full for fast
   acquisition, after which the NCO rate is updated through a first-order
   filter. This keeps the acquisition speed of the plain feed-forward scheme
   and removes the cycle slips. Without it, this design also fails at around
   the same point the reference does; with it, it runs several dB further.

2. **Angle-based phase detector** (see above) rather than a linear
   decision-directed detector.

3. **Additive scrambler reloaded per packet**, rather than
   `comm.Scrambler`. The packet detector already supplies the packet
   boundary, and an additive scrambler has no error propagation.

4. **AGC before the matched filter.** The newer reference application does
   not list an AGC (it parameterises input scaling instead); the older
   `hdlqpsktransmitterreceiver` example does. Including one is what lets the
   downstream loops use constant gains.

5. **Sample-enabled datapath** rather than one sample per clock.

6. **Default payload 512 bits** instead of 4096, purely to keep simulation
   times short. `DATA_BITS` in `model/qpsk_params.py` sets it; everything
   downstream, RTL included, follows.

Not implemented, matching the reference: no CRC, no error correction coding.

---

## Verification approach

The thing that makes this tractable is that there is exactly one source of
truth. `model/qpsk_params.py` holds the floating-point design;
`model/qpsk_fxparams.py` quantises it and **emits `rtl/qpsk_defs.vh`**;
`model/qpsk_fixed.py` implements every block in integer arithmetic with the
same word lengths, rounding and saturation the RTL uses. The testbenches then
compare the RTL against that model rather than against a tolerance.

The layers:

1. `check_farrow.py`, `check_channel.py` — validate the interpolator maths
   and the channel model against independent references (direct Lagrange
   evaluation, and the theoretical QPSK BER curve).
2. `run_float.py` — algorithm-level sweeps, used to pick loop gains and
   confirm the architecture before any fixed-point work.
3. `run_fixed.py`, `sweep_fixed.py` — the bit-exact model, confirming
   quantisation costs nothing measurable.
4. `tb_cordic.v` — 4096 vectors × 3 modes, including corner cases.
5. `tb_qpsk_tx.v` — transmitter symbols and samples, with randomised
   backpressure on the bit input so the valid/ready handshake is exercised,
   run once with the sample enable held high and once with it randomised.
6. `tb_qpsk_rx.v` — every receiver stage, plus detections and output bits.
7. `tb_tx_dump.v` + `tb_rx_ber.v` — RTL transmitter through a real channel
   into the RTL receiver, scored on BER against the originally transmitted
   bits.
