import sys
import numpy as np
from scipy.special import erfc
import qpsk_params as P
import qpsk_float as F


def theory(e):
    return 0.5 * erfc(np.sqrt(10 ** (e / 10)))


def run(ebn0, npkt=40, ignore=8, seed=7, **kw):
    rng = np.random.default_rng(seed)
    bits = rng.integers(0, 2, npkt * P.DATA_BITS)
    syms, sig = F.tx(bits, npkt)
    x = F.channel(sig, ebn0_db=ebn0, seed=seed + 1, **kw)
    r = F.rx(x)
    nerr = ntot = bad = 0
    for i, (s, rb, blk) in enumerate(r['pkts']):
        if i < ignore:
            continue
        e = min(int(np.sum(bits[q * P.DATA_BITS:(q + 1) * P.DATA_BITS] != rb))
                for q in range(npkt))
        nerr += e
        ntot += P.DATA_BITS
        bad += (e > 10)
    return (nerr / ntot if ntot else float('nan'), nerr, ntot, bad,
            len(r['pkts']))


if __name__ == '__main__':
    kw = dict(fo=0.025, phase_deg=37, timing_off=0.51)
    print('%-6s %-10s %-10s %-9s %-7s %-6s %-6s'
          % ('EbN0', 'BER', 'theory', 'errs/bits', 'badpkt', 'dets', 'loss'))
    for e in (12, 10, 9, 8, 7, 6, 5, 4):
        ber, ne, nt, bad, nd = run(e, **kw)
        # implementation loss: EbN0 that theory needs for the measured BER
        if ber > 0:
            lo, hi = -5.0, 40.0
            for _ in range(60):
                mid = (lo + hi) / 2
                if theory(mid) > ber:
                    lo = mid
                else:
                    hi = mid
            loss = e - (lo + hi) / 2
        else:
            loss = float('nan')
        print('%-6d %-10.2e %-10.2e %5d/%-6d %-7d %-6d %-6.2f'
              % (e, ber, theory(e), ne, nt, bad, nd, loss))
