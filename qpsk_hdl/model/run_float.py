import sys
import numpy as np
import qpsk_params as P
import qpsk_float as F


def run(ebn0=30.0, fo=0.025, ph=37.0, toff=0.51, drift=0.0, scale=1.0,
        npkt=12, ignore=2, seed=7, verbose=True):
    rng = np.random.default_rng(seed)
    bits = rng.integers(0, 2, npkt * P.DATA_BITS)
    syms, sig = F.tx(bits, npkt)
    x = F.channel(sig, ebn0_db=ebn0, fo=fo, phase_deg=ph, timing_off=toff,
                  drift_ppm=drift, scale=scale, seed=seed + 1)
    r = F.rx(x)

    # map each detected packet onto the transmitted packet with the best match
    nerr = ntot = 0
    used = []
    for i, (s, rb, blk) in enumerate(r['pkts']):
        if i < ignore:
            continue
        best = None
        for p in range(npkt):
            tb = bits[p * P.DATA_BITS:(p + 1) * P.DATA_BITS]
            e = int(np.sum(tb != rb))
            if best is None or e < best[0]:
                best = (e, p)
        nerr += best[0]
        ntot += P.DATA_BITS
        used.append(best[1])
    ber = nerr / ntot if ntot else float('nan')
    if verbose:
        print('EbN0 %-5.1f fo %-7.4f ph %-5.1f toff %-5.2f drift %-5.0f scale %-5.2f'
              ' | det %2d  used %2d  errs %5d  BER %.2e  pkts %s'
              % (ebn0, fo, ph, toff, drift, scale, len(r['pkts']), len(used),
                 nerr, ber, used[:6]))
    return r, ber, nerr, len(r['pkts'])


if __name__ == '__main__':
    print('=== nominal ===')
    r, _, _, _ = run()
    print('   coarse freq estimates:', np.round(r['cests'], 5))
    print('   timing mu  mean %.3f  last100 std %.4f'
          % (np.mean(r['mu']), np.std(r['mu'][-100:])))
    print()
    print('=== sweeps ===')
    for ebn0 in (30, 20, 16, 13, 10):
        run(ebn0=ebn0)
    print()
    for fo in (-0.06, -0.03, 0.0, 0.03, 0.06):
        run(fo=fo)
    print()
    for toff in (0.0, 0.25, 0.5, 0.75, 0.99):
        run(toff=toff)
    print()
    for ph in (0, 45, 90, 135, 180, 270):
        run(ph=ph)
    print()
    for sc in (1.0, 0.5, 0.2, 0.05):
        run(scale=sc)
    print()
    for dr in (0, 50, 100, 200):
        run(drift=dr)
