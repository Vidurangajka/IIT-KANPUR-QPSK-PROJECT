"""
End to end harness.

  stage 1  prepare   : random payload bits for the RTL transmitter
  stage 2  channel   : read the RTL transmitter samples, apply frequency,
                       phase, timing and noise impairments, quantise
  stage 3  check     : read the RTL receiver bits and report the BER

Each stage is a separate invocation so the Verilog simulations can run in
between.
"""

import os
import sys
import numpy as np
from scipy.special import erfc
import qpsk_params as P
import qpsk_float as F
import qpsk_fixed as Q
from fx import sat

V = os.path.join(os.path.dirname(__file__), '..', 'vectors')


def theory(e):
    return 0.5 * erfc(np.sqrt(10 ** (e / 10)))


def prepare(npkt, seed):
    rng = np.random.default_rng(seed)
    bits = rng.integers(0, 2, npkt * P.DATA_BITS)
    os.makedirs(V, exist_ok=True)
    with open(os.path.join(V, 'e2e_bits.bin'), 'w') as f:
        for b in bits:
            f.write('%d\n' % int(b))
    with open(os.path.join(V, 'e2e_sizes.vh'), 'w') as f:
        f.write('localparam integer NPKT    = %d;\n' % npkt)
        f.write('localparam integer NTXBITS = %d;\n' % len(bits))
    print('prepared %d packets (%d bits)' % (npkt, len(bits)))


def channel(ebn0, fo, ph, toff, drift, scale, seed, headroom=0.85):
    raw = np.loadtxt(os.path.join(V, 'e2e_tx_samp.txt'), dtype=str)
    iq = np.array([[int(a, 16), int(b, 16)] for a, b in raw], dtype=np.int64)
    iq[iq >= 32768] -= 65536
    x = (iq[:, 0] + 1j * iq[:, 1]) / float(1 << P.FRAC)

    y = F.channel(x, ebn0_db=ebn0, fo=fo, phase_deg=ph, timing_off=toff,
                  drift_ppm=drift, scale=scale, seed=seed)
    pk = max(np.max(np.abs(y.real)), np.max(np.abs(y.imag)))
    y = y * (headroom / pk)
    q = Q.to_fx(y)

    for name, idx in (('e2e_rx_i.hex', 0), ('e2e_rx_q.hex', 1)):
        with open(os.path.join(V, name), 'w') as f:
            for s in q:
                f.write('%04x\n' % (s[idx] & 0xFFFF))
    print('channel: %d samples  EbN0 %.1f dB  fo %.4f  phase %.0f deg  '
          'timing %.2f  drift %.0f ppm  scale %.2f'
          % (len(q), ebn0, fo, ph, toff, drift, scale))


def check(npkt, ignore, ebn0):
    bits = np.loadtxt(os.path.join(V, 'e2e_bits.bin'), dtype=int)
    tx = [bits[p * P.DATA_BITS:(p + 1) * P.DATA_BITS] for p in range(npkt)]

    pkts = []
    with open(os.path.join(V, 'e2e_rx_bits.txt')) as f:
        for line in f:
            line = line.strip()
            if not line.startswith('P '):
                continue
            s = line[2:]
            if len(s) == P.DATA_BITS:
                pkts.append(np.array([int(c) for c in s], dtype=int))

    nerr = ntot = bad = 0
    matched = []
    for i, rb in enumerate(pkts):
        if i < ignore:
            continue
        e, p = min(((int(np.sum(tx[q] != rb)), q) for q in range(npkt)))
        nerr += e
        ntot += P.DATA_BITS
        bad += (e > 10)
        matched.append(p)
    ber = nerr / ntot if ntot else float('nan')

    print()
    print('  packets transmitted : %d' % npkt)
    print('  packets decoded     : %d  (%d analysed, %d ignored for'
          ' synchroniser warm up)' % (len(pkts), len(matched), ignore))
    print('  packet indices      : %s' % matched)
    print('  bit errors          : %d of %d' % (nerr, ntot))
    print('  BER                 : %.3e   (theory at EbN0 %.1f dB: %.3e)'
          % (ber, ebn0, theory(ebn0)))
    print('  packets with >10 errors : %d' % bad)
    ok = (ntot > 0 and bad == 0
          and sorted(matched) == list(range(ignore, ignore + len(matched))))
    print('  RESULT              : %s' % ('PASS' if ok and nerr == 0
                                          else ('PASS (errors consistent with noise)'
                                                if ok else 'FAIL')))
    return 0 if ok else 1


if __name__ == '__main__':
    cmd = sys.argv[1]
    kw = {}
    for a in sys.argv[2:]:
        k, v = a.split('=')
        kw[k] = float(v) if ('.' in v or 'e' in v.lower()) else int(v)
    if cmd == 'prepare':
        prepare(int(kw.get('npkt', 20)), int(kw.get('seed', 11)))
    elif cmd == 'channel':
        channel(kw.get('ebn0', 20.0), kw.get('fo', 0.025), kw.get('ph', 37.0),
                kw.get('toff', 0.51), kw.get('drift', 0.0),
                kw.get('scale', 1.0), int(kw.get('seed', 12)))
    elif cmd == 'check':
        sys.exit(check(int(kw.get('npkt', 20)), int(kw.get('ignore', 6)),
                       kw.get('ebn0', 20.0)))
