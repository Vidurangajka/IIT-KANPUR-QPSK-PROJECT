"""Validate the channel model: an ideal coherent receiver (perfect timing,
no frequency/phase offset) must sit on the theoretical QPSK BER curve."""
import numpy as np
from scipy.special import erfc
import qpsk_params as P
import qpsk_float as F


def theory(e):
    return 0.5 * erfc(np.sqrt(10 ** (e / 10)))


rng = np.random.default_rng(5)
NPKT = 60
bits = rng.integers(0, 2, NPKT * P.DATA_BITS)
syms, sig = F.tx(bits, NPKT)
gd = (P.RRC_NTAPS - 1) // 2          # group delay of each RRC, in samples

print('%-6s %-12s %-12s %-8s' % ('EbN0', 'measured', 'theory', 'ratio'))
for e in (0, 2, 4, 6, 8, 10):
    x = F.channel(sig, ebn0_db=e, fo=0.0, phase_deg=0, timing_off=0.0, seed=99)
    mf = np.convolve(x, P.RRC_FLOAT)          # unit energy matched filter
    y = mf[2 * gd::P.SPS][:len(syms)]         # perfect symbol timing
    rb = np.empty(2 * len(y), dtype=int)
    rb[0::2] = (y.real < 0).astype(int)
    rb[1::2] = (y.imag < 0).astype(int)
    # undo scrambling is irrelevant for BER: compare against the transmitted
    # symbol decisions instead
    tb = np.empty(2 * len(syms), dtype=int)
    tb[0::2] = (syms.real < 0).astype(int)
    tb[1::2] = (syms.imag < 0).astype(int)
    n = min(len(rb), len(tb))
    ber = np.mean(rb[:n] != tb[:n])
    print('%-6d %-12.3e %-12.3e %-8.2f' % (e, ber, theory(e),
                                           ber / max(theory(e), 1e-30)))
