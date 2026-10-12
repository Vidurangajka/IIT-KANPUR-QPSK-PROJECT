"""Parameter sweep over the bit exact fixed point receiver."""
import numpy as np
import qpsk_params as P
import qpsk_fixed as Q
from run_fixed import build_rx_input, check

NPKT, IGNORE = 20, 6


def one(label, **kw):
    rng = np.random.default_rng(7)
    bits = rng.integers(0, 2, NPKT * P.DATA_BITS)
    syms, xin = build_rx_input(bits, NPKT, seed=8, **kw)
    r = Q.rx(xin)
    ne, nt, bad = check(bits, r['pkts'], NPKT, IGNORE)
    # the very first spacing can be one symbol out because the correlator
    # only sees part of the first preamble, so judge from the second onwards
    sp = np.diff([d[0] for d in r['dets']])[1:]
    ok = (len(r['pkts']) >= NPKT - 2 and ne == 0
          and (len(sp) == 0 or np.all(sp == P.PKT_SYMS)))
    print('%-34s dets %2d  pkts %2d  errs %4d/%-5d  %s'
          % (label, len(r['dets']), len(r['pkts']), ne, nt,
             'PASS' if ok else 'check'))
    return ok


allok = True
print('--- carrier frequency offset (turns/symbol) ---')
for fo in (-0.08, -0.04, -0.01, 0.0, 0.01, 0.04, 0.08):
    allok &= one('fo = %+.3f' % fo, ebn0=20, fo=fo)

print('--- carrier phase offset ---')
for ph in (0, 45, 90, 135, 180, 225, 270, 315):
    allok &= one('phase = %3d deg' % ph, ebn0=20, ph=ph)

print('--- timing offset (fraction of a sample) ---')
for t in (0.0, 0.2, 0.4, 0.6, 0.8, 0.99):
    allok &= one('timing offset = %.2f' % t, ebn0=20, toff=t)

print('--- timing drift ---')
for d in (0, 50, 100, 200, 400):
    allok &= one('drift = %3d ppm' % d, ebn0=20, drift=d)

print('--- receiver input level ---')
for s in (1.0, 0.5, 0.2, 0.1, 0.05):
    allok &= one('input scale = %.2f' % s, ebn0=20, scale=s)

print('--- EbN0 ---')
for e in (30, 20, 15, 12, 10):
    allok &= one('EbN0 = %2d dB' % e, ebn0=e)

print()
print('ALL PASS' if allok else 'some cases need review')
