"""
QPSK Transmitter / Receiver  -  system parameters and filter design.

Mirrors the structure of the MathWorks Wireless HDL Toolbox reference
application "QPSK Transmitter and Receiver"
(https://in.mathworks.com/help/wireless-hdl/ug/qpsk-transmitter-receiver.html)

Everything the RTL needs (filter taps, Farrow matrix, loop gains, packet
structure) is derived here and emitted into rtl/qpsk_defs.vh so that the
Verilog and the Python model can never drift apart.
"""

import numpy as np

# ---------------------------------------------------------------------------
# 1. Packet / waveform structure
# ---------------------------------------------------------------------------
SPS            = 4            # samples per symbol (Fs = 4 * Rsym)
BARKER13       = np.array([1, 1, 1, 1, 1, -1, -1, 1, 1, -1, 1, -1, 1], dtype=int)
PREAMBLE_SYMS  = len(BARKER13)             # 13 QPSK symbols
DATA_BITS      = 512                       # payload bits per packet (ref default 4096)
DATA_SYMS      = DATA_BITS // 2
PKT_SYMS       = PREAMBLE_SYMS + DATA_SYMS

SCRAM_POLY     = 0b0010001   # x^7 + x^4 + 1, taps on stages 7 and 4
SCRAM_SEED     = 0b1111111

# ---------------------------------------------------------------------------
# 2. Fixed point formats
# ---------------------------------------------------------------------------
W           = 16     # sample word length            : s(16,15)   range [-1,1)
FRAC        = 15
CW          = 16     # coefficient word length       : s(16,15)
CFRAC       = 15
AW          = 16     # angle word length, unit = turns: s(16,15)  range [-0.5,0.5)
ANG_FRAC    = 15     # 1.0 turn == 2**15 ; +-pi == +-2**15

ONE         = 1 << FRAC
QPSK_A      = int(round((1 / np.sqrt(2)) * ONE))   # 23170 -> 0.70709

# ---------------------------------------------------------------------------
# 3. Root raised cosine pulse shape
# ---------------------------------------------------------------------------
RRC_BETA    = 0.5       # roll-off
RRC_SPAN    = 10        # symbols
RRC_NTAPS   = RRC_SPAN * SPS + 1        # 41


def rcosdesign_sqrt(beta, span, sps):
    """Unit-energy root raised cosine, equivalent to rcosdesign(beta,span,sps,'sqrt')."""
    n = np.arange(-span * sps / 2, span * sps / 2 + 1) / sps
    h = np.zeros_like(n, dtype=float)
    for i, t in enumerate(n):
        if abs(t) < 1e-12:
            h[i] = 1 - beta + 4 * beta / np.pi
        elif beta > 0 and abs(abs(t) - 1 / (4 * beta)) < 1e-12:
            h[i] = (beta / np.sqrt(2)) * (
                (1 + 2 / np.pi) * np.sin(np.pi / (4 * beta))
                + (1 - 2 / np.pi) * np.cos(np.pi / (4 * beta))
            )
        else:
            num = (np.sin(np.pi * t * (1 - beta))
                   + 4 * beta * t * np.cos(np.pi * t * (1 + beta)))
            den = np.pi * t * (1 - (4 * beta * t) ** 2)
            h[i] = num / den
    h = h / np.sqrt(np.sum(h ** 2))     # unit energy
    return h


RRC_FLOAT = rcosdesign_sqrt(RRC_BETA, RRC_SPAN, SPS)

# --- transmit filter -------------------------------------------------------
# The interpolate-by-4 filter is fed QPSK symbols of magnitude 1.0 (rails
# +-0.7071).  Scale the taps so the worst case interpolator output stays
# inside +-1.0 with headroom.  Worst case |output| for a polyphase branch is
# A*(sum|h_p,I| + sum|h_p,Q|) with A = 1/sqrt(2).
_phases = [RRC_FLOAT[p::SPS] for p in range(SPS)]
_worst = max(np.sum(np.abs(p)) for p in _phases) * np.sqrt(2) / np.sqrt(2)
# |s| = 1 spread over I and Q, each rail worst case = A * sum|h_p|
_worst_rail = (1 / np.sqrt(2)) * max(np.sum(np.abs(p)) for p in _phases)
TX_GAIN = 0.92 / _worst_rail            # leave ~8 % headroom
RRC_TX = RRC_FLOAT * TX_GAIN

# --- receive matched filter ------------------------------------------------
# The AGC in front of the matched filter holds the mean power at
# AGC_TARGET_POW, so the matched filter input level is known.  RX_GAIN was
# calibrated with model/calibrate.py so that the worst observed rail peak at
# the matched filter output (EbN0 13 dB, 0.05 .. 1.0 input scaling) is about
# 0.75 of full scale.
RX_GAIN = 0.50
RRC_RX = RRC_FLOAT * RX_GAIN

# ---------------------------------------------------------------------------
# 4. Farrow cubic (Lagrange) interpolator  -  y(mu) = ((C3*mu+C2)*mu+C1)*mu+C0
#    nodes x[n-1], x[n], x[n+1], x[n+2], mu in [0,1)
# ---------------------------------------------------------------------------
# Lagrange basis on t = -1,0,1,2 expanded into powers of mu:
FARROW = np.array([
    # x[n-1]   x[n]     x[n+1]   x[n+2]      power of mu
    [-1 / 6,  1 / 2,  -1 / 2,   1 / 6],   # mu^3
    [1 / 2,  -1.0,     1 / 2,   0.0],     # mu^2
    [-1 / 3, -1 / 2,   1.0,    -1 / 6],   # mu^1
    [0.0,     1.0,     0.0,     0.0],     # mu^0
])

# ---------------------------------------------------------------------------
# 5. Loop filters
# ---------------------------------------------------------------------------
def pi_gains(bn_t, zeta, kd, k0, n_per_update=1):
    """Proportional / integral gains for a 2nd order loop (Rice, Appendix C)."""
    theta = bn_t / n_per_update / (zeta + 0.25 / zeta)
    d = 1 + 2 * zeta * theta + theta * theta
    kp = (4 * zeta * theta / d) / (kd * k0)
    ki = (4 * theta * theta / d) / (kd * k0)
    return kp, ki


# --- symbol timing recovery: Gardner TED, 2 samples/symbol in the loop -----
# The AGC in front of the matched filter holds the symbol power at the TED
# within 1.26x over the whole EbN0 / input scaling range (measured with
# model/debug_norm.py), so the 1/power normalisation that a general purpose
# Gardner loop needs is folded into a constant and no divider is required.
STR_BNT    = 0.005         # normalised loop bandwidth
STR_ZETA   = 1.0
STR_KD     = 2.0           # Gardner detector gain at unit symbol power
STR_K0     = 1.0
STR_P_NOM  = 0.125         # symbol power the gains are calibrated for
_kp, _ki   = pi_gains(STR_BNT, STR_ZETA, STR_KD, STR_K0)
STR_KP     = _kp / STR_P_NOM
STR_KI     = _ki / STR_P_NOM

# --- fine frequency recovery ----------------------------------------------
# Phase error detector = angle of the symbol taken modulo 90 degrees, which
# is exact, amplitude independent and in hardware is just a subtract and a
# bit mask on the CORDIC angle output.  Detector gain is therefore 1 and the
# NCO gain is 1, both in units of turns.
FFR_BNT   = 0.008
FFR_ZETA  = 1.0
_kp, _ki  = pi_gains(FFR_BNT, FFR_ZETA, 1.0, 1.0)
FFR_KP    = _kp
FFR_KI    = _ki

# ---------------------------------------------------------------------------
# 6. AGC
# ---------------------------------------------------------------------------
AGC_TARGET_POW = 0.125      # mean |y|^2 at the AGC output (matched filter input)
AGC_AVG_SHIFT  = 6          # leaky integrator:  p += (x2 - p) >> 6
AGC_STEP_SHIFT = 6          # loop step size
AGC_GMIN       = 0.25
AGC_GMAX       = 64.0
AGC_GW         = 20         # gain word, s(20,12)  -> 0..127.9
AGC_GFRAC      = 12

# ---------------------------------------------------------------------------
# 7. Coarse frequency estimator
# ---------------------------------------------------------------------------
COARSE_BLK      = 256       # symbols per estimation block (ref uses 1024)
# The reference application notes that the step changes between successive
# coarse estimates are what limits the receiver at low EbN0, because the fine
# frequency loop has to re-acquire after every step.  The first few estimates
# are therefore applied in full for fast acquisition, after which the NCO rate
# is updated through a first order filter of gain 2**-COARSE_SLOW_SHIFT.  This
# keeps the acquisition time of the plain feed forward scheme and removes the
# estimate-to-estimate jitter that causes cycle slips.
COARSE_FAST_BLK  = 4
COARSE_SLOW_SHIFT = 3

# ---------------------------------------------------------------------------
# 8. Packet detector
# ---------------------------------------------------------------------------
DET_WIN_SHIFT  = 5          # running power window = 32 symbols
DET_WIN        = 1 << DET_WIN_SHIFT
DET_PEAK_WIN   = 8          # peak search window, symbols
# A perfectly received preamble gives |c|^2 = 2*N^2*Ps with N = 13 and Ps the
# mean symbol power, so |c|^2 / (sum of Ps over DET_WIN) = 2*N^2/DET_WIN.
# Declare a hit at DET_THR_FRAC of that ideal peak power.
DET_THR_FRAC   = 0.35
DET_THR_SHIFT  = 6
DET_THR_NUM    = int(round(DET_THR_FRAC * 2 * PREAMBLE_SYMS ** 2
                           / DET_WIN * (1 << DET_THR_SHIFT)))   # 237


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def q(x, frac=FRAC, width=W):
    """Round-to-nearest, saturate to a signed fixed point word."""
    v = np.round(np.asarray(x, dtype=float) * (1 << frac)).astype(np.int64)
    lo, hi = -(1 << (width - 1)), (1 << (width - 1)) - 1
    return np.clip(v, lo, hi)


def qf(x, frac=FRAC, width=W):
    """Quantise and return the float value actually represented."""
    return q(x, frac, width) / float(1 << frac)


def hexs(v, width):
    """Verilog style hex for a signed value of the given width."""
    return format(int(v) & ((1 << width) - 1), 'x').rjust((width + 3) // 4, '0')


def flat_hex(vals, width):
    """Concatenate values MSB-first into one big hex literal (vals[0] is LSB slice)."""
    acc = 0
    for i, v in enumerate(vals):
        acc |= (int(v) & ((1 << width) - 1)) << (i * width)
    n = len(vals) * width
    return "%d'h%s" % (n, format(acc, 'x').rjust((n + 3) // 4, '0'))


if __name__ == '__main__':
    print('RRC taps          :', RRC_NTAPS)
    print('TX gain           : %.5f  peak out %.4f' %
          (TX_GAIN, (1 / np.sqrt(2)) * max(np.sum(np.abs(p)) for p in
                                           [RRC_TX[p::SPS] for p in range(SPS)])))
    print('RX gain           : %.5f' % RX_GAIN)
    print('STR  Kp %.6g  Ki %.6g' % (STR_KP, STR_KI))
    print('FFR  Kp %.6g  Ki %.6g' % (FFR_KP, FFR_KI))
