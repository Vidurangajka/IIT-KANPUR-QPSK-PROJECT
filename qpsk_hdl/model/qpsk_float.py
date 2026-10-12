"""
Floating point behavioural model of the QPSK transmitter, channel and
receiver.  Used to validate the algorithm and tune the loop gains and
scaling before the fixed point / RTL implementation is written.
"""

import numpy as np
import qpsk_params as P


# ===========================================================================
#  Scrambler
# ===========================================================================
class Scrambler:
    """Additive scrambler, LFSR x^7 + x^4 + 1, reset at every packet."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.s = P.SCRAM_SEED

    def step(self, bit):
        fb = ((self.s >> 6) ^ (self.s >> 3)) & 1      # stages 7 and 4
        self.s = ((self.s << 1) | fb) & 0x7F
        return bit ^ fb


# ===========================================================================
#  Transmitter
# ===========================================================================
PREAMBLE = (P.BARKER13 + 1j * P.BARKER13) / np.sqrt(2)


def qpsk_map(b1, b0):
    return ((1 - 2 * b1) + 1j * (1 - 2 * b0)) / np.sqrt(2)


def tx(bits, n_pkt):
    """bits: payload bits, n_pkt packets of P.DATA_BITS.  Returns symbols, samples."""
    scr = Scrambler()
    syms = []
    k = 0
    for _ in range(n_pkt):
        syms.extend(PREAMBLE)
        scr.reset()
        for _ in range(P.DATA_SYMS):
            b1 = scr.step(bits[k]); k += 1
            b0 = scr.step(bits[k]); k += 1
            syms.append(qpsk_map(b1, b0))
    syms = np.array(syms)
    up = np.zeros(len(syms) * P.SPS, dtype=complex)
    up[::P.SPS] = syms
    sig = np.convolve(up, P.RRC_TX)
    return syms, sig


# ===========================================================================
#  Channel
# ===========================================================================
def channel(x, ebn0_db=30.0, fo=0.0, phase_deg=0.0, timing_off=0.0,
            drift_ppm=0.0, scale=1.0, seed=1):
    """fo in cycles/symbol, timing_off as a fraction of the sample period."""
    rng = np.random.default_rng(seed)
    n = np.arange(len(x))

    # fractional delay + drift, via sinc interpolation on a fine grid
    if timing_off != 0.0 or drift_ppm != 0.0:
        d = timing_off + drift_ppm * 1e-6 * n
        idx = n - d
        y = np.zeros_like(x)
        L = 8
        for i in range(len(x)):
            c = int(np.floor(idx[i])); mu = idx[i] - c
            lo, hi = c - L + 1, c + L + 1
            k = np.arange(lo, hi)
            w = np.sinc(mu - (k - c)) * np.hamming(2 * L)
            kk = np.clip(k, 0, len(x) - 1)
            y[i] = np.sum(x[kk] * w)
        x = y

    # carrier frequency / phase offset  (fo is per symbol -> /SPS per sample)
    x = x * np.exp(1j * (2 * np.pi * fo / P.SPS * n + np.deg2rad(phase_deg)))
    x = x * scale

    # AWGN.  With the sample period normalised to 1 the energy per symbol is
    # Es = mean|x|^2 * sps, Eb = Es/2 for QPSK, and the complex noise variance
    # per sample is N0 (N0/2 per rail).
    es = np.mean(np.abs(x) ** 2) * P.SPS
    eb = es / 2
    n0 = eb / (10 ** (ebn0_db / 10))
    sigma = np.sqrt(n0 / 2)
    x = x + sigma * (rng.standard_normal(len(x)) + 1j * rng.standard_normal(len(x)))
    return x


# ===========================================================================
#  Receiver blocks
# ===========================================================================
def agc(x, target=P.AGC_TARGET_POW, avg_shift=P.AGC_AVG_SHIFT,
        step_shift=P.AGC_STEP_SHIFT, gmin=P.AGC_GMIN, gmax=P.AGC_GMAX):
    g = 1.0
    p = target
    out = np.zeros_like(x)
    gh = np.zeros(len(x))
    for i, s in enumerate(x):
        y = s * g
        out[i] = y
        p += (abs(y) ** 2 - p) * 2.0 ** (-avg_shift)
        g += g * (target - p) * 2.0 ** (-step_shift)
        g = min(max(g, gmin), gmax)
        gh[i] = g
    return out, gh


def farrow(x3, x2, x1, x0, mu):
    """x3=x[n-1] x2=x[n] x1=x[n+1] x0=x[n+2]  ->  x(n+mu)"""
    v = np.array([x3, x2, x1, x0])
    c3 = P.FARROW[0] @ v
    c2 = P.FARROW[1] @ v
    c1 = P.FARROW[2] @ v
    c0 = P.FARROW[3] @ v
    return ((c3 * mu + c2) * mu + c1) * mu + c0


def symbol_timing_recovery(x, kp=P.STR_KP, ki=P.STR_KI, sps=P.SPS):
    """Gardner TED + cubic Farrow interpolator + modulo-1 decrementing NCO.

    The loop runs two strobes per symbol (on time and half symbol); only the
    on time strobes are output, so the output rate is Rsym.
    """
    w_nom = 2.0 / sps
    cnt = 0.0
    integ = 0.0
    buf = [0j, 0j, 0j, 0j]          # x[n-3..n]; interpolates at (n-2)+mu
    out, mus, errs = [], [], []
    y_mid = 0j
    y_prev = 0j
    is_ontime = True
    vctl = 0.0
    for n in range(len(x)):
        buf = buf[1:] + [x[n]]
        w = w_nom + vctl
        if cnt < w:
            mu = cnt / w if w > 1e-9 else 0.0
            y = farrow(buf[0], buf[1], buf[2], buf[3], mu)
            if is_ontime:
                e = (y_mid.real * (y.real - y_prev.real)
                     + y_mid.imag * (y.imag - y_prev.imag))
                integ += ki * e
                vctl = kp * e + integ
                out.append(y)
                mus.append(mu)
                errs.append(e)
                y_prev = y
            else:
                y_mid = y
            is_ontime = not is_ontime
            cnt = cnt - w + 1.0
        else:
            cnt = cnt - w
    return np.array(out), np.array(mus), np.array(errs)


def wrap(a):
    """wrap to [-0.5, 0.5) turns"""
    return (a + 0.5) % 1.0 - 0.5


def coarse_freq(y, blk=P.COARSE_BLK, fast_blk=P.COARSE_FAST_BLK,
                slow_shift=P.COARSE_SLOW_SHIFT):
    """Fourth power delay-and-multiply frequency estimator, feed forward NCO
    correction.

    Word length growth is avoided by working entirely in the phase domain:
    each symbol is reduced to its angle, the wrapped 4x phase difference
    between consecutive symbols is formed, and unit vectors at that angle are
    summed over the block.  This is the unit magnitude normalised version of
    sum(z[n]*conj(z[n-1])) with z = y**4.

    Returns the corrected symbols and the NCO rate after each block, in
    turns per symbol.
    """
    out = np.zeros_like(y)
    ests = []
    acc = 0j
    th_prev = None
    f = 0.0
    ph = 0.0
    nblk = 0
    for n in range(len(y)):
        out[n] = y[n] * np.exp(-1j * 2 * np.pi * ph)
        ph = (ph + f) % 1.0
        th = np.angle(y[n]) / (2 * np.pi)
        if th_prev is not None:
            acc += np.exp(1j * 2 * np.pi * wrap(4 * (th - th_prev)))
        th_prev = th
        if (n + 1) % blk == 0:
            e = wrap(np.angle(acc) / (2 * np.pi)) / 4.0
            f = e if nblk < fast_blk else f + (e - f) * 2.0 ** -slow_shift
            nblk += 1
            ests.append(f)
            acc = 0j
    return out, np.array(ests)


def wrap_quarter(a):
    """wrap to [-0.125, 0.125) turns  (i.e. modulo 90 degrees, centred)"""
    return (a + 0.125) % 0.25 - 0.125


def fine_freq(y, kp=P.FFR_KP, ki=P.FFR_KI):
    """Decision directed phase tracking.  The phase error is the angle of the
    rotated symbol taken modulo 90 degrees and centred on the 45 degree
    constellation points, which is exact and amplitude independent."""
    out = np.zeros_like(y)
    ph = 0.0
    integ = 0.0
    for n in range(len(y)):
        r = y[n] * np.exp(-1j * 2 * np.pi * ph)
        out[n] = r
        th = np.angle(r) / (2 * np.pi)
        e = wrap_quarter(th - 0.125)
        integ += ki * e
        ph = (ph + kp * e + integ) % 1.0
    return out


def packet_detector(y, win_shift=P.DET_WIN_SHIFT, peak_win=P.DET_PEAK_WIN,
                    pkt_syms=P.PKT_SYMS, thr_num=P.DET_THR_NUM,
                    thr_shift=P.DET_THR_SHIFT):
    """Barker correlation, dynamic threshold, peak pick, inhibit.

    The preamble symbols are A*b*(1+j), so correlating against their conjugate
    needs no multipliers: with u = yI+yQ and v = yQ-yI the correlator is two
    13 tap +-1 FIRs.  The constant A is absorbed into the threshold.
    """
    n = len(y)
    b = P.BARKER13
    u = y.real + y.imag
    v = y.imag - y.real
    cI = np.convolve(u, b[::-1], mode='full')[:n]
    cQ = np.convolve(v, b[::-1], mode='full')[:n]
    c2 = cI ** 2 + cQ ** 2
    pw = np.abs(y) ** 2
    # running SUM (not mean) over the window, exactly as the hardware keeps it
    run = np.convolve(pw, np.ones(1 << win_shift), mode='full')[:n]
    thr = run * thr_num / float(1 << thr_shift)

    dets = []
    i = 0
    inhibit = 0
    while i < n:
        if inhibit > 0:
            inhibit -= 1
            i += 1
            continue
        if c2[i] > thr[i]:
            j0, j1 = i, min(i + peak_win, n)
            k = j0 + int(np.argmax(c2[j0:j1]))
            dets.append((k, cI[k], cQ[k]))
            inhibit = pkt_syms - peak_win - 2
            i = j1
        else:
            i += 1
    return dets, c2, thr


def quadrant_derotate(y, cI, cQ):
    if abs(cI) >= abs(cQ):
        return y if cI >= 0 else -y
    return complex(y.imag, -y.real) if cQ >= 0 else complex(-y.imag, y.real)


def rx(x, verbose=True):
    a, gh = agc(x)
    mf = np.convolve(a, P.RRC_RX)
    sym, mus, errs = symbol_timing_recovery(mf)
    cf, ests = coarse_freq(sym)
    ff = fine_freq(cf)
    dets, c2, thr = packet_detector(ff)

    pkts = []
    for (k, cI, cQ) in dets:
        s = k + 1
        if s + P.DATA_SYMS > len(ff):
            break
        blk = ff[s:s + P.DATA_SYMS]
        blk = np.array([quadrant_derotate(z, cI, cQ) for z in blk])
        scr = Scrambler()
        bits = []
        for z in blk:
            b1 = 1 if z.real < 0 else 0
            b0 = 1 if z.imag < 0 else 0
            bits.append(scr.step(b1))
            bits.append(scr.step(b0))
        pkts.append((s, np.array(bits), blk))
    return dict(agc=a, gain=gh, mf=mf, sym=sym, mu=mus, terr=errs,
                coarse=cf, cests=ests, fine=ff, dets=dets, c2=c2, thr=thr,
                pkts=pkts)
