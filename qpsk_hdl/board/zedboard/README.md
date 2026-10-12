# QPSK loopback on the ZedBoard

The transmitter and receiver from `rtl/` running together in the
programmable logic of a ZedBoard (xc7z020clg484-1). An on-chip channel sits
between them and adds carrier frequency and phase offset, Gaussian noise and
attenuation. A checker counts bit errors and lost packets. No processor
software is involved.

```
  bit source ──► qpsk_tx ──► channel ──► qpsk_rx ──► BER monitor ──► LEDs, VIO
  (packet no.                (freq, phase,                (exact errors,
   + PRBS-15)                 AWGN, level)                 lost packets)
```

An MMCM derives a 20 MHz design clock from the 100 MHz board clock. There
is one sample every 16 clocks, so the sample rate is 1.25 MS/s and the
symbol rate is 312.5 kBd.

The clock is that low because of how the core RTL in `rtl/` is written. It
forms each filter output and loop update in a single clock: the receiver's
matched filter, for example, is a 21-deep DSP cascade that takes about 38 ns
on this -1 speed grade part. At 100 MHz the design misses timing by 29 ns.
Pipelining those datapaths would let it run several times faster, but that
is a change to the verified core, not to this board wrapper.

## Controls

| switch | setting |
|---|---|
| SW1–SW0 | carrier frequency offset: 0, +0.02, −0.04, +0.06 turns/symbol |
| SW3–SW2 | noise: off, Eb/N0 10, 8, 6 dB |
| SW5–SW4 | carrier phase offset: 37° + 0, 90, 180, 270° |
| SW7–SW6 | receive level: 1, ½, ¼, ⅛ (level 1 is ¼ of full scale) |

| button | action |
|---|---|
| BTNC | reset everything |
| BTNU | hold the BER counters at zero |

Changing any switch restarts the receiver, as on a new link. The counters
are then held at zero for 105 ms (about 120 packets) while it acquires.

| LED | meaning |
|---|---|
| LD0 | heartbeat |
| LD1 | link: a packet was decoded in the last 6.6 ms |
| LD2 | bit errors seen recently |
| LD3 | a packet was lost or slipped recently |
| LD4–LD7 | BER bar, over windows of 2¹⁸ bits (about 0.44 s): LD4 any error, LD5 > 1e-4, LD6 > 1e-3, LD7 > 1e-2 |

What you should see: with the noise off (SW3–SW2 = 00), LD1 is steady and
LD2–LD7 are dark, whatever the frequency, phase and level. At Eb/N0 6 dB
(SW3–SW2 = 11), LD2, LD4, LD5 and LD6 light up. That corresponds to a BER of
about 3e-3, the same as the bit-exact model gives.

## Building and running

From Git Bash, with Vivado 2025.2 installed under `C:\AMDDesignTools` (set
`VIVADO_BIN` otherwise):

```bash
./sim_board.sh        # simulate the whole board design (~1.5 min)
./build.sh            # bitstream with VIO + ILA debug cores
./build.sh -nodebug   # bitstream without them
./hw.sh               # program, print BER, capture a constellation
./hw.sh ber           # print the BER counters again
python plot_ila.py    # plot build/ila_symbols.csv
```

`build.sh` regenerates `rtl/qpsk_defs.vh` and `rtl/board_defs.vh` from the
Python model first. The outputs go to `build/`: `zed_qpsk.bit`,
`zed_qpsk.ltx`, `utilization.rpt` and `timing.rpt`. If timing is not met the
build stops with an error and writes no bitstream: a design that misses
timing fails in ways no simulation shows.

`hw.sh` needs the board connected through the PROG micro-USB port (J17). It
reads the counters through the VIO: bits checked, bit errors, packets
checked, packets with errors, packets lost and packets slipped. In the
Hardware Manager the same counters can be watched live in the VIO dashboard.

The I/O standards in `zedboard.xdc` assume the VADJ jumper J18 is at 1.8 V,
which is Digilent's default. The switches and buttons are on the VADJ banks.
If J18 is set to 2.5 V or 3.3 V, change the two `LVCMOS18` lines to match.

## Files

| file | what it does |
|---|---|
| `rtl/zed_qpsk_top.v` | top level: 20 MHz MMCM, bit source, settings, reset and settle, LEDs, debug cores |
| `rtl/qpsk_channel.v` | attenuation, rotation (reuses `cordic_rot`), AWGN, receive level |
| `rtl/awgn_gen.v` | Gaussian noise: sum of 16 uniforms from xorshift64 |
| `rtl/ber_monitor.v` | exact bit error, packet loss and slip counting |
| `rtl/board_defs.vh` | **generated** by `gen_board_defs.py`: frequency increments, noise levels calibrated to Eb/N0 |
| `tb/tb_zed_top.v` | drives the switches through six channel conditions and checks the counters |
| `zedboard.xdc` | pins and I/O standards |
| `build.tcl`, `hw.tcl` | Vivado batch flows behind `build.sh` and `hw.sh` |

The noise levels are calibrated with the same Eb/N0 definition as the
Python channel model. The signal power is measured on the bit-exact
transmitter model, so a given switch setting means the same Eb/N0 as in the
BER table of the top-level README.

## Two receiver findings from bringing this up

**The transmitter `en` input only worked held high.** `fir_interp_rrc`
requests the next symbol in phase 2 and takes it in on the following clock.
With `en` pulsed once per sample, that clock is usually not an enabled one,
so the symbol was dropped. The fix holds the symbol until the delay line
next shifts; with `en` held high the hold register is never used. The output
is unchanged in that case: `tb_qpsk_tx` now runs a second pass with a random
enable, and both passes are bit-exact against the model.

**A payload that repeats identically in every packet can lock the packet
detector onto a false peak permanently.** If the receiver restarts at the
wrong moment, a correlation sidelobe of the payload can cross the detection
threshold before the true preamble does. In one case its |c| was 124k,
against 206k for the true peak. The detector's inhibit window then hides the
true preamble in every following packet. With identical packets, the
sidelobe comes back at the same place every time, so the lock never breaks.
The bit-exact Python model fails in exactly the same way: every packet
detected, but about half the bits wrong. Random payloads, as in the
repository's own tests, never show it.

The demo avoids this by giving each packet different data: a packet number,
then a PRBS seeded from it. That is the same idea as the counter in the
MathWorks reference application's "Hello world" messages. A link that might
send repeated identical frames would need a fix in the detector itself. For
example, a detection could be accepted only after a second peak arrives one
packet length later, or the inhibit could be released early when a much
stronger peak turns up.
