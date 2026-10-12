"""Stimulus and expected results for tb_qpsk_tx."""
import os
import numpy as np
import qpsk_params as P
import qpsk_fixed as Q

NPKT = 8
OUT = os.path.join(os.path.dirname(__file__), '..', 'vectors')


def wr(name, vals, width=16, binary=False):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name), 'w') as f:
        for v in vals:
            if binary:
                f.write('%d\n' % int(v))
            else:
                f.write('%0*x\n' % ((width + 3) // 4,
                                    int(v) & ((1 << width) - 1)))


rng = np.random.default_rng(2024)
bits = rng.integers(0, 2, NPKT * P.DATA_BITS)
syms, samp = Q.tx(bits, NPKT)

wr('tx_bits.bin', bits, binary=True)
wr('tx_sym_i.hex', [s[0] for s in syms])
wr('tx_sym_q.hex', [s[1] for s in syms])
wr('tx_samp_i.hex', [s[0] for s in samp])
wr('tx_samp_q.hex', [s[1] for s in samp])
print('wrote %d bits, %d symbols, %d samples' % (len(bits), len(syms), len(samp)))
