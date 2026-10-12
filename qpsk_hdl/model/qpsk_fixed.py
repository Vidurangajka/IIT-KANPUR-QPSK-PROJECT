"""
Bit exact fixed point model of the QPSK transmitter and receiver.

Every block here performs exactly the arithmetic the corresponding Verilog
module performs: same word lengths, same rounding, same saturation.  The
Verilog testbenches compare against the vectors this model produces, so any
mismatch is a real RTL bug rather than a modelling difference.
"""

import numpy as np
import qpsk_params as P
import qpsk_fxparams as X
from fx import sat, swrap, rsh
from cordic import cordic_rotate, cordic_unit, cordic_atan2


# ===========================================================================
#  Transmitter
# ===========================================================================
class Scrambler:
    """Additive scrambler, LFSR x^7 + x^4 + 1, reloaded at every packet."""

    def __init__(self):
        self.s = P.SCRAM_SEED

    def reset(self):
        self.s = P.SCRAM_SEED

    def step(self, bit):
        fb = ((self.s >> 6) ^ (self.s >> 3)) & 1
        self.s = ((self.s << 1) | fb) & 0x7F
        return bit ^ fb


def qpsk_map(b1, b0):
    """Gray mapped QPSK: b1 picks the I rail, b0 the Q rail."""
    return (-X.QPSK_A if b1 else X.QPSK_A,
            -X.QPSK_A if b0 else X.QPSK_A)


PREAMBLE_FX = [(X.QPSK_A if b > 0 else -X.QPSK_A,
                X.QPSK_A if b > 0 else -X.QPSK_A) for b in P.BARKER13]


def tx_symbols(bits, n_pkt):
    """Framer + scrambler + symbol mapper."""
    scr = Scrambler()
    out = []
    k = 0
    for _ in range(n_pkt):
        out.extend(PREAMBLE_FX)
        scr.reset()
        for _ in range(P.DATA_SYMS):
            b1 = scr.step(int(bits[k])); k += 1
            b0 = scr.step(int(bits[k])); k += 1
            out.append(qpsk_map(b1, b0))
    return out


def tx_fir_interp(syms):
    """Polyphase interpolate by SPS.  One output sample per clock."""
    n = X.NTAP_P
    dI = [0] * n
    dQ = [0] * n
    out = []
    for (sI, sQ) in syms:
        dI = [sI] + dI[:-1]
        dQ = [sQ] + dQ[:-1]
        for p in range(P.SPS):
            h = X.H_POLY[p]
            aI = sum(h[k] * dI[k] for k in range(n))
            aQ = sum(h[k] * dQ[k] for k in range(n))
            out.append((sat(rsh(aI, P.FRAC), P.W), sat(rsh(aQ, P.FRAC), P.W)))
    return out


def tx(bits, n_pkt):
    syms = tx_symbols(bits, n_pkt)
    return syms, tx_fir_interp(syms)


# ===========================================================================
#  Receiver
# ===========================================================================
def rx_agc(x):
    """Gain g is unsigned Q8.12, updated by g += g*(target - p) >> step."""
    g = X.AGC_G_INIT
    p = X.AGC_TARGET
    out, gains = [], []
    for (xi, xq) in x:
        yi = sat(rsh(xi * g, X.AGC_GFRAC), P.W)
        yq = sat(rsh(xq * g, X.AGC_GFRAC), P.W)
        out.append((yi, yq))
        gains.append(g)
        pw = (yi * yi + yq * yq) >> X.AGC_P_ALIGN        # Q4.22
        p = swrap(p + ((pw - p) >> X.AGC_AVG_SHIFT), X.AGC_PW)
        err = X.AGC_TARGET - p
        dg = (g * err) >> (X.AGC_PFRAC + X.AGC_STEP_SHIFT)
        g = g + dg
        g = X.AGC_G_MIN if g < X.AGC_G_MIN else (X.AGC_G_MAX if g > X.AGC_G_MAX else g)
    return out, gains


def rx_rrc(x):
    """41 tap symmetric matched filter, folded pre-adder form."""
    nt = X.NT_RX
    nh = X.NHALF_RX
    dI = [0] * nt
    dQ = [0] * nt
    out = []
    for (xi, xq) in x:
        dI = [xi] + dI[:-1]
        dQ = [xq] + dQ[:-1]
        aI = aQ = 0
        for k in range(nh):
            j = nt - 1 - k
            if k == j:
                aI += X.H_RX[k] * dI[k]
                aQ += X.H_RX[k] * dQ[k]
            else:
                aI += X.H_RX[k] * (dI[k] + dI[j])
                aQ += X.H_RX[k] * (dQ[k] + dQ[j])
        out.append((sat(rsh(aI, P.FRAC), P.W), sat(rsh(aQ, P.FRAC), P.W)))
    return out


def _farrow(v, mu):
    """Cubic Lagrange interpolation at offset mu (Q0.16) between v[1] and
    v[2], where v = [x[n-3], x[n-2], x[n-1], x[n]].  Farrow / Horner form."""
    v0, v1, v2, v3 = v
    t3 = -v0 + 3 * v1 - 3 * v2 + v3
    t2 = v0 - 2 * v1 + v2
    t1 = -2 * v0 - 3 * v1 + 6 * v2 - v3
    c3 = rsh(t3 * X.STR_K6, 15)
    c2 = rsh(t2, 1)
    c1 = rsh(t1 * X.STR_K6, 15)
    c0 = v1
    a = rsh(c3 * mu, 16) + c2
    b = rsh(a * mu, 16) + c1
    c = rsh(b * mu, 16) + c0
    return sat(c, P.W)


def rx_timing_recovery(x):
    """Gardner TED, cubic Farrow interpolator, modulo-1 decrementing NCO.
    Returns the on time symbols."""
    cnt = 0
    integ = 0
    vctl = 0
    bI = [0] * 4
    bQ = [0] * 4
    yI = yQ = 0
    midI = midQ = 0
    prevI = prevQ = 0
    ontime = True
    out, mus = [], []
    for (xi, xq) in x:
        bI = bI[1:] + [xi]
        bQ = bQ[1:] + [xq]
        w = X.STR_W_NOM + vctl
        if cnt < w:
            mu = cnt << X.STR_MU_SH
            if mu > 0xFFFF:
                mu = 0xFFFF
            yI = _farrow(bI, mu)
            yQ = _farrow(bQ, mu)
            if ontime:
                dI = yI - prevI
                dQ = yQ - prevQ
                e = midI * dI + midQ * dQ               # Q.30
                es = e >> X.STR_E_SH                    # Q.16
                integ = integ + ((es * X.STR_KI_M) >> X.STR_KI_S)
                v = ((es * X.STR_KP_M) >> X.STR_KP_S) + (integ >> X.STR_INTEG_F)
                if v > X.STR_VCTL_LIM:
                    v = X.STR_VCTL_LIM
                elif v < -X.STR_VCTL_LIM:
                    v = -X.STR_VCTL_LIM
                vctl = v
                out.append((yI, yQ))
                mus.append(mu)
                prevI, prevQ = yI, yQ
            else:
                midI, midQ = yI, yQ
            ontime = not ontime
            cnt = (cnt - w) & 0xFFFF
        else:
            cnt = cnt - w
    return out, mus


def rx_coarse_freq(y):
    """Fourth power frequency estimate with feed forward NCO correction.

    Scheduling note.  Everything on the estimation side is feed forward, so
    no CORDIC sits inside a feedback loop, but the estimate for a block is
    only ready a few symbol periods after the block ends (two pipelined
    CORDICs).  Both the model and the RTL therefore latch the result as
    `pending` and apply it at the first symbol of the next block whose index
    is congruent to CF_GUARD modulo CF_BLK.  That makes the update instant a
    symbol aligned event in both, so the two stay bit identical.
    """
    accI = accQ = 0
    th_prev = 0
    have_prev = False
    ph = 0                                  # Q0.24 turns
    frate = 0                               # Q0.24 turns per symbol
    pending = 0
    have_pending = False
    nblk = 0
    acc_cnt = 0
    out, ests = [], []
    for n, (yi, yq) in enumerate(y):
        ang = swrap(-(ph >> X.CF_PH_F), P.AW)
        out.append(cordic_rotate(yi, yq, ang))
        ph = (ph + frate) & ((1 << X.CF_PH_W) - 1)

        th = cordic_atan2(yi, yq)
        if have_prev:
            d4 = swrap((th - th_prev) << 2, P.AW)       # wrap(4*dtheta)
            ui, uq = cordic_unit(d4)
            accI += ui
            accQ += uq
            acc_cnt += 1
        th_prev = th
        have_prev = True

        if acc_cnt == X.CF_BLK:
            acc_cnt = 0
            # only the ratio matters, so scale into the vectoring input width
            phi = cordic_atan2(accI >> X.CF_ACC_SH, accQ >> X.CF_ACC_SH)
            pending = (phi >> 2) << X.CF_PH_F           # /4 then align to Q0.24
            have_pending = True
            accI = accQ = 0

        if have_pending and (n % X.CF_BLK) == X.CF_GUARD:
            if nblk < X.CF_FAST_BLK:
                frate = pending
            else:
                frate = frate + ((pending - frate) >> X.CF_SLOW_SHIFT)
            nblk += 1
            have_pending = False
            ests.append(frate)
    return out, ests


def rx_fine_freq(y):
    """Decision directed phase tracking.

    The phase error is the angle of the derotated symbol taken modulo 90
    degrees and centred on the 45 degree constellation points.  Rotation
    preserves angles exactly, so that angle is obtained as
    angle(y) + rotation_angle rather than by measuring the rotated symbol.
    The CORDICs are then both feed forward and the feedback path is just a
    subtract, a mask and the loop filter - a few clocks, which is what makes
    this loop implementable at a sensible clock rate.
    """
    ph = 0                                   # Q0.24 turns
    integ = 0                                # Q0.32 turns per symbol
    out, errs = [], []
    for (yi, yq) in y:
        ang = swrap(-(ph >> X.FF_PH_F), P.AW)
        out.append(cordic_rotate(yi, yq, ang))
        th_y = cordic_atan2(yi, yq)
        th_r = swrap(th_y + ang, P.AW)       # angle of the derotated symbol
        e = swrap(th_r - X.FF_OFFS, X.FF_EW)  # modulo 90 deg, centred
        errs.append(e)
        integ = integ + ((e * X.FF_KI_M) >> X.FF_KI_S)
        inc = ((e * X.FF_KP_M) >> X.FF_KP_S) + (integ >> X.FF_INTEG_F)
        ph = (ph + inc) & ((1 << X.FF_PH_W) - 1)
    return out, errs


def rx_packet_detector(y):
    """Barker correlator, dynamic threshold, peak pick and inhibit.

    Returns (declare_index, peak_age, cI, cQ) for every detection, where
    peak_age is how many symbols before the declaration the peak occurred.
    """
    n = P.PREAMBLE_SYMS
    b = [1 if v > 0 else -1 for v in P.BARKER13]
    uh = [0] * n
    vh = [0] * n
    pw_hist = [0] * (1 << X.DET_WIN_SHIFT)
    runsum = 0
    searching = False
    win = 0
    best = (-1, 0, 0, 0)
    inhibit = 0
    dets = []
    c2s, thrs = [], []
    for idx, (yi, yq) in enumerate(y):
        u = yi + yq
        v = yq - yi
        uh = [u] + uh[:-1]
        vh = [v] + vh[:-1]
        # Correlate against the conjugate preamble: a +-1 adder tree, no
        # multipliers.  uh[k] holds y[idx-k], so tap k carries b[N-1-k] and
        # the sum peaks when the last preamble symbol has just arrived.
        cI = sum(b[n - 1 - k] * uh[k] for k in range(n))
        cQ = sum(b[n - 1 - k] * vh[k] for k in range(n))
        c2 = cI * cI + cQ * cQ
        pw = yi * yi + yq * yq
        runsum += pw - pw_hist[-1]
        pw_hist = [pw] + pw_hist[:-1]
        thr = (runsum * X.DET_THR_NUM) >> X.DET_THR_SHIFT
        c2s.append(c2)
        thrs.append(thr)

        if inhibit > 0:
            inhibit -= 1
            continue
        if not searching:
            if c2 > thr:
                searching = True
                win = 1
                best = (c2, 0, cI, cQ)
        else:
            if c2 > best[0]:
                best = (c2, win, cI, cQ)
            win += 1
            if win == X.DET_PEAK_WIN:
                age = win - 1 - best[1]
                dets.append((idx, age, best[2], best[3]))
                searching = False
                inhibit = X.DET_INHIBIT
    return dets, c2s, thrs


def _derotate(yi, yq, cI, cQ):
    """Remove the 0/90/180/270 degree ambiguity using the correlator phase."""
    if abs(cI) >= abs(cQ):
        return (yi, yq) if cI >= 0 else (-yi, -yq)
    return (yq, -yi) if cQ >= 0 else (-yq, yi)


IDLE, WAIT, PAYLOAD = 0, 1, 2


def rx_extract(y, dets):
    """Symbol delay line, payload gating, phase derotation, slicer and
    descrambler.  Written as the three state machine the RTL implements."""
    dly = [(0, 0)] * X.DET_DLY
    det_by_idx = {d[0]: d for d in dets}
    state = IDLE
    cnt = 0
    remain = 0
    cI = cQ = 0
    scr = Scrambler()
    pkts, starts, cur = [], [], []
    for idx, s in enumerate(y):
        dly = [s] + dly[:-1]
        outsym = dly[-1]                       # symbol index idx-(DET_DLY-1)

        if state == IDLE:
            if idx in det_by_idx:
                _, age, cI, cQ = det_by_idx[idx]
                cnt = X.DET_DLY - age          # 1 .. DET_PEAK_WIN
                state = WAIT
        elif state == WAIT:
            cnt -= 1

        if state == WAIT and cnt == 0:
            state = PAYLOAD
            remain = P.DATA_SYMS
            scr.reset()
            cur = []
            starts.append(idx - (X.DET_DLY - 1))

        if state == PAYLOAD:
            zi, zq = _derotate(outsym[0], outsym[1], cI, cQ)
            cur.append(scr.step(1 if zi < 0 else 0))
            cur.append(scr.step(1 if zq < 0 else 0))
            remain -= 1
            if remain == 0:
                state = IDLE
                pkts.append(np.array(cur, dtype=int))
    return pkts, starts


def rx(x):
    """Full fixed point receiver.  x is a list of (I,Q) Q1.15 pairs."""
    agc_out, gains = rx_agc(x)
    mf = rx_rrc(agc_out)
    sym, mus = rx_timing_recovery(mf)
    cf, ests = rx_coarse_freq(sym)
    ff, ferrs = rx_fine_freq(cf)
    dets, c2, thr = rx_packet_detector(ff)
    pkts, starts = rx_extract(ff, dets)
    return dict(agc=agc_out, gain=gains, mf=mf, sym=sym, mu=mus,
                coarse=cf, cests=ests, fine=ff, ferr=ferrs,
                dets=dets, c2=c2, thr=thr, pkts=pkts, starts=starts)


# ---------------------------------------------------------------------------
def to_fx(z):
    """complex ndarray -> list of saturated Q1.15 (I,Q) pairs"""
    return [(sat(int(np.round(v.real * (1 << P.FRAC))), P.W),
             sat(int(np.round(v.imag * (1 << P.FRAC))), P.W)) for v in z]


def to_cplx(pairs):
    return np.array([complex(i, q) for (i, q) in pairs]) / float(1 << P.FRAC)
