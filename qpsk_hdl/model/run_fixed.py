"""Exercise the bit exact fixed point model end to end."""
import sys
import time
import numpy as np
from scipy.special import erfc
import qpsk_params as P
import qpsk_fxparams as X
import qpsk_float as F
import qpsk_fixed as Q


def theory(e):
    return 0.5 * erfc(np.sqrt(10 ** (e / 10)))


def build_rx_input(bits, npkt, ebn0=20.0, fo=0.025, ph=37.0, toff=0.51,
                   drift=0.0, scale=1.0, seed=3, headroom=0.85):
    """Fixed point transmitter -> floating point channel -> Q1.15 samples."""
    syms, tx = Q.tx(bits, npkt)
    sig = Q.to_cplx(tx)
    x = F.channel(sig, ebn0_db=ebn0, fo=fo, phase_deg=ph, timing_off=toff,
                  drift_ppm=drift, scale=scale, seed=seed)
    # scale so the quantised receiver input uses the word without clipping
    pk = max(np.max(np.abs(x.real)), np.max(np.abs(x.imag)))
    x = x * (headroom / pk)
    return syms, Q.to_fx(x)


def check(bits, pkts, npkt, ignore):
    nerr = ntot = bad = 0
    for i, rb in enumerate(pkts):
        if i < ignore:
            continue
        e = min(int(np.sum(bits[q * P.DATA_BITS:(q + 1) * P.DATA_BITS] != rb))
                for q in range(npkt))
        nerr += e
        ntot += P.DATA_BITS
        bad += (e > 10)
    return nerr, ntot, bad


def run(ebn0=20.0, npkt=20, ignore=6, seed=7, **kw):
    rng = np.random.default_rng(seed)
    bits = rng.integers(0, 2, npkt * P.DATA_BITS)
    syms, xin = build_rx_input(bits, npkt, ebn0=ebn0, seed=seed + 1, **kw)
    r = Q.rx(xin)
    ne, nt, bad = check(bits, r['pkts'], npkt, ignore)
    return r, ne, nt, bad, len(r['pkts'])


if __name__ == '__main__':
    t0 = time.time()
    print('=== fixed point receiver, nominal channel ===')
    r, ne, nt, bad, nd = run()
    print('detections %d   packets decoded %d   errors %d/%d   bad packets %d'
          % (nd, len(r['pkts']), ne, nt, bad))
    print('coarse NCO rate (turns/symbol): ',
          np.round(np.array(r['cests'][:8]) / float(1 << X.CF_PH_W), 6))
    print('AGC final gain %.3f' % (r['gain'][-1] / float(1 << X.AGC_GFRAC)))
    sym = Q.to_cplx(r['sym'])
    print('timing recovered |y| mean %.4f' % np.mean(np.abs(sym[len(sym) // 2:])))
    ff = Q.to_cplx(r['fine'])
    print('fine freq out    |y| mean %.4f' % np.mean(np.abs(ff[len(ff) // 2:])))
    print('detection spacing:', np.diff([d[0] for d in r['dets']])[:8])
    print('peak ages        :', [d[1] for d in r['dets']][:8])
    print()

    print('=== BER vs EbN0 (fixed point) ===')
    print('%-6s %-11s %-11s %-10s %-7s' % ('EbN0', 'BER', 'theory', 'errs/bits',
                                           'badpkt'))
    for e in (12, 10, 9, 8, 7, 6, 5):
        r, ne, nt, bad, nd = run(ebn0=e, npkt=24, ignore=6)
        print('%-6d %-11.2e %-11.2e %5d/%-5d %-7d'
              % (e, ne / nt if nt else float('nan'), theory(e), ne, nt, bad))
    print('\nelapsed %.1f s' % (time.time() - t0))
