"""
Bit exact CORDIC, rotation and vectoring, in the same arithmetic the RTL uses.

Angle format: signed 16 bit, one full turn = 2**16, so the representable
range is [-0.5, 0.5) turns and multiplying an angle by 4 is a left shift that
wraps automatically - exactly what the fourth power frequency estimator
needs.

Internal data format: signed CORDIC_W bits, Q(CORDIC_W-1-CORDIC_F . F) with
two guard bits above the Q1.15 input so that the CORDIC magnitude growth
cannot overflow.
"""

import math
from fx import sat, swrap, rsh

CORDIC_W = 20          # internal x/y word length
CORDIC_F = 17          # internal fractional bits  (Q2.17 in 20 bits)
NITER = 16
AW = 16                # angle word length
ZW = 18                # internal angle accumulator width

# atan(2^-i) expressed in the 16 bit turn format
ATAN_TBL = [int(round(math.atan(2.0 ** -i) / (2 * math.pi) * (1 << AW)))
            for i in range(NITER)]

# 1/K pre-scaling constant, Q1.15
_K = 1.0
for i in range(NITER):
    _K *= math.sqrt(1 + 2.0 ** (-2 * i))
KINV = 1.0 / _K
KINV_Q15 = int(round(KINV * (1 << 15)))         # 19898

QUARTER = 1 << (AW - 2)          # 90 degrees = 16384


def _iterate(x, y, z, vectoring):
    for i in range(NITER):
        if vectoring:
            d = -1 if y >= 0 else 1          # drive y to zero
        else:
            d = 1 if z >= 0 else -1          # drive z to zero
        xs = x >> i                          # arithmetic
        ys = y >> i
        nx = x - d * ys
        ny = y + d * xs
        z = z - d * ATAN_TBL[i]
        x, y = nx, ny
        x = swrap(x, CORDIC_W)
        y = swrap(y, CORDIC_W)
        z = swrap(z, ZW)
    return x, y, z


def cordic_rotate(xin, yin, zin):
    """Rotate the Q1.15 vector (xin, yin) by the angle zin (16 bit turns).
    Returns Q1.15 x, y with the CORDIC gain removed."""
    # pre-scale by 1/K so the output comes back at unit gain
    x = rsh(xin * KINV_Q15, 15) << (CORDIC_F - 15)
    y = rsh(yin * KINV_Q15, 15) << (CORDIC_F - 15)
    z = swrap(zin, AW)

    x, y, z = _prerotate(x, y, z)
    x, y, _ = _iterate(x, y, z, vectoring=False)
    return (sat(rsh(x, CORDIC_F - 15), 16),
            sat(rsh(y, CORDIC_F - 15), 16))


def _prerotate(x, y, z):
    """Fold the rotation angle into the +-99.9 degree convergence range by
    rotating a quadrant first.  One step is enough: 90 + 99.9 > 180."""
    if z > QUARTER:
        return -y, x, z - QUARTER
    if z < -QUARTER:
        return y, -x, z + QUARTER
    return x, y, z


def cordic_unit(zin):
    """exp(j*zin) as a Q1.15 pair.  The input vector is the constant
    (1/K, 0), so no pre-scaling multiplier is needed."""
    x = KINV_Q15 << (CORDIC_F - 15)
    y = 0
    x, y, z = _prerotate(x, y, swrap(zin, AW))
    x, y, _ = _iterate(x, y, z, vectoring=False)
    return (sat(rsh(x, CORDIC_F - 15), 16),
            sat(rsh(y, CORDIC_F - 15), 16))


# the vectoring input must fit in this many bits so the CORDIC gain of 1.6476
# applied to a 45 degree vector cannot overflow the internal word
VEC_IN_W = CORDIC_W - 2


def cordic_atan2(xin, yin):
    """Angle of (xin, yin) in the 16 bit turn format.  Inputs are saturated
    to VEC_IN_W bits; only the ratio matters, so the caller is free to scale
    a wide accumulator down before calling."""
    x = sat(xin, VEC_IN_W)
    y = sat(yin, VEC_IN_W)
    z = 0
    if x < 0:                       # fold into the right half plane
        if y >= 0:
            x, y, z = y, -x, QUARTER
        else:
            x, y, z = -y, x, -QUARTER
    _, _, z = _iterate(x, y, z, vectoring=True)
    return sat(z, AW)


# ---------------------------------------------------------------------------
if __name__ == '__main__':
    import numpy as np
    rng = np.random.default_rng(0)

    print('ATAN_TBL =', ATAN_TBL)
    print('KINV_Q15 =', KINV_Q15, ' K =', _K)

    # rotation accuracy
    err = []
    for _ in range(20000):
        a = rng.uniform(-0.9, 0.9)
        b = rng.uniform(-0.9, 0.9)
        if a * a + b * b > 0.81:
            continue
        t = rng.uniform(-0.5, 0.5)
        xi, yi = int(a * 32768), int(b * 32768)
        zi = int(round(t * 65536))
        if zi > 32767:
            zi = 32767
        xo, yo = cordic_rotate(xi, yi, zi)
        ref = (xi + 1j * yi) * np.exp(1j * 2 * np.pi * (zi / 65536.0))
        err.append(max(abs(xo - ref.real), abs(yo - ref.imag)))
    print('rotate  : max err %.2f LSB   rms %.2f LSB'
          % (max(err), np.sqrt(np.mean(np.square(err)))))

    # unit vector accuracy
    err = []
    for _ in range(20000):
        zi = int(rng.integers(-32768, 32768))
        xo, yo = cordic_unit(zi)
        ref = np.exp(1j * 2 * np.pi * (zi / 65536.0)) * 32768
        err.append(max(abs(xo - ref.real), abs(yo - ref.imag)))
    print('unit    : max err %.2f LSB   rms %.2f LSB'
          % (max(err), np.sqrt(np.mean(np.square(err)))))

    # atan2 accuracy
    err = []
    for _ in range(20000):
        a = rng.uniform(-1, 1)
        b = rng.uniform(-1, 1)
        if a * a + b * b < 0.01:
            continue
        xi, yi = int(a * 32768), int(b * 32768)
        zo = cordic_atan2(xi, yi)
        ref = np.angle(xi + 1j * yi) / (2 * np.pi) * 65536
        d = (zo - ref + 32768) % 65536 - 32768
        err.append(abs(d))
    print('atan2   : max err %.2f LSB (%.4f deg)   rms %.2f LSB'
          % (max(err), max(err) / 65536 * 360, np.sqrt(np.mean(np.square(err)))))
