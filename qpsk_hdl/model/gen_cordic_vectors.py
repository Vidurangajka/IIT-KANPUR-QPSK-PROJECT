"""Stimulus and expected results for tb_cordic."""
import os
import numpy as np
from cordic import cordic_rotate, cordic_unit, cordic_atan2

NV = 4096
OUT = os.path.join(os.path.dirname(__file__), '..', 'vectors')


def wr(name, vals, width=16):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name), 'w') as f:
        for v in vals:
            f.write('%0*x\n' % ((width + 3) // 4, int(v) & ((1 << width) - 1)))


rng = np.random.default_rng(12345)
xs, ys, zs = [], [], []

# a few deliberate corner cases first
corners = [(0, 0, 0), (32767, 0, 0), (-32768, 0, 0), (0, 32767, 0),
           (0, -32768, 0), (32767, 32767, 16384), (-32768, -32768, -16384),
           (1, 0, 32767), (0, 1, -32768), (23170, 23170, 8192),
           (-23170, 23170, -8192), (23170, -23170, 24576)]
for (a, b, c) in corners:
    xs.append(a); ys.append(b); zs.append(c)

while len(xs) < NV:
    xs.append(int(rng.integers(-32768, 32768)))
    ys.append(int(rng.integers(-32768, 32768)))
    zs.append(int(rng.integers(-32768, 32768)))

rot = [cordic_rotate(x, y, z) for x, y, z in zip(xs, ys, zs)]
uni = [cordic_unit(z) for z in zs]
atn = [cordic_atan2(x, y) for x, y in zip(xs, ys)]

wr('cordic_x.hex', xs)
wr('cordic_y.hex', ys)
wr('cordic_z.hex', zs)
wr('cordic_rot_x.hex', [r[0] for r in rot])
wr('cordic_rot_y.hex', [r[1] for r in rot])
wr('cordic_unit_x.hex', [u[0] for u in uni])
wr('cordic_unit_y.hex', [u[1] for u in uni])
wr('cordic_atan.hex', atn)
print('wrote %d CORDIC vectors to %s' % (NV, os.path.abspath(OUT)))
