"""
Plot the recovered constellation from an ILA capture.

    python plot_ila.py [build/ila_symbols.csv]

The CSV is what hw.tcl (or File > Export ILA Data in the Hardware Manager)
writes.  Only rows with the symbol strobe high are used, so the capture can
be taken with or without storage qualification.
"""
import csv
import os
import sys

import matplotlib.pyplot as plt
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))


def column(header, key):
    for i, name in enumerate(header):
        if key in name:
            return i
    raise KeyError('no column matching %r in %s' % (key, header))


BASES = {'HEX': 16, 'BINARY': 2, 'OCTAL': 8, 'UNSIGNED': 10, 'SIGNED': 10}


def value(text, radix, signed16=False):
    v = int(text.strip(), BASES.get(radix, 16))
    if signed16 and v >= 32768:
        v -= 65536
    return v


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'build', 'ila_symbols.csv')
    with open(path) as f:
        rows = [r for r in csv.reader(f) if r]
    header = rows[0]
    # a Vivado export has a second line giving each column's radix
    if rows[1][0].startswith('Radix'):
        radix = [r.split('-')[-1].strip().upper() for r in rows[1]]
        body = rows[2:]
    else:
        radix = ['HEX'] * len(header)
        body = rows[1:]
    cv, ci, cq = column(header, 'ff_valid'), column(header, 'ff_i'), column(header, 'ff_q')

    pts = np.array([(value(r[ci], radix[ci], True), value(r[cq], radix[cq], True))
                    for r in body if value(r[cv], radix[cv]) == 1],
                   dtype=float) / 32768.0
    if len(pts) == 0:
        sys.exit('no rows with ff_valid = 1 in %s' % path)

    fig, ax = plt.subplots(figsize=(5, 5))
    ax.scatter(pts[:, 0], pts[:, 1], s=4, alpha=0.5)
    lim = 1.1 * np.max(np.abs(pts))
    ax.set_xlim(-lim, lim)
    ax.set_ylim(-lim, lim)
    ax.set_aspect('equal')
    ax.axhline(0, lw=0.5, color='grey')
    ax.axvline(0, lw=0.5, color='grey')
    ax.set_xlabel('I')
    ax.set_ylabel('Q')
    ax.set_title('Recovered symbols on the ZedBoard (%d)' % len(pts))
    out = os.path.splitext(path)[0] + '.png'
    fig.savefig(out, dpi=120, bbox_inches='tight')
    print('wrote', out)
    plt.show()


if __name__ == '__main__':
    main()
