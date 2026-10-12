"""Stimulus and per stage expected results for tb_qpsk_rx."""
import os
import sys
import numpy as np
import qpsk_params as P
import qpsk_fixed as Q
from run_fixed import build_rx_input

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


def main(npkt=16, ebn0=20.0, fo=0.025, ph=37.0, toff=0.51, drift=0.0,
         scale=1.0, seed=7):
    rng = np.random.default_rng(seed)
    bits = rng.integers(0, 2, npkt * P.DATA_BITS)
    syms, xin = build_rx_input(bits, npkt, ebn0=ebn0, fo=fo, ph=ph,
                               toff=toff, drift=drift, scale=scale,
                               seed=seed + 1)
    r = Q.rx(xin)

    wr('rx_in_i.hex',  [s[0] for s in xin])
    wr('rx_in_q.hex',  [s[1] for s in xin])
    wr('rx_agc_i.hex', [s[0] for s in r['agc']])
    wr('rx_agc_q.hex', [s[1] for s in r['agc']])
    wr('rx_mf_i.hex',  [s[0] for s in r['mf']])
    wr('rx_mf_q.hex',  [s[1] for s in r['mf']])
    wr('rx_sym_i.hex', [s[0] for s in r['sym']])
    wr('rx_sym_q.hex', [s[1] for s in r['sym']])
    wr('rx_cf_i.hex',  [s[0] for s in r['coarse']])
    wr('rx_cf_q.hex',  [s[1] for s in r['coarse']])
    wr('rx_ff_i.hex',  [s[0] for s in r['fine']])
    wr('rx_ff_q.hex',  [s[1] for s in r['fine']])

    # detections: declaration index and peak age
    wr('rx_det_idx.hex', [d[0] for d in r['dets']], width=32)
    wr('rx_det_age.hex', [d[1] for d in r['dets']], width=8)

    # recovered payload bits, packed two per symbol in the order the RTL
    # emits them (I rail bit then Q rail bit)
    flat = []
    for pk in r['pkts']:
        flat.extend(int(b) for b in pk)
    wr('rx_exp_bits.bin', flat, binary=True)
    wr('tx_ref_bits.bin', bits, binary=True)

    with open(os.path.join(OUT, 'rx_sizes.vh'), 'w') as f:
        f.write('localparam integer NIN   = %d;\n' % len(xin))
        f.write('localparam integer NSYM  = %d;\n' % len(r['sym']))
        f.write('localparam integer NDET  = %d;\n' % len(r['dets']))
        f.write('localparam integer NRBIT = %d;\n' % len(flat))
        f.write('localparam integer NPKTS = %d;\n' % len(r['pkts']))
        f.write('localparam integer NTXB  = %d;\n' % len(bits))

    print('samples %d  symbols %d  detections %d  packets %d  bits %d'
          % (len(xin), len(r['sym']), len(r['dets']), len(r['pkts']), len(flat)))
    # sanity: the model must decode these cleanly
    nerr = 0
    for i, pk in enumerate(r['pkts']):
        if i < 6:
            continue
        nerr += min(int(np.sum(bits[q*P.DATA_BITS:(q+1)*P.DATA_BITS] != pk))
                    for q in range(npkt))
    print('model bit errors after 6 ignored packets: %d' % nerr)
    return nerr


if __name__ == '__main__':
    kw = {}
    for a in sys.argv[1:]:
        k, v = a.split('=')
        kw[k] = float(v) if '.' in v else int(v)
    main(**kw)
