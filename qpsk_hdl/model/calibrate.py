import numpy as np
import qpsk_params as P
import qpsk_float as F


def stats(name, x, skip=2000):
    y = x[skip:]
    r = np.concatenate([y.real, y.imag])
    print('%-18s rail rms %.4f  rail peak %.4f  |.| peak %.4f  meanpow %.5f'
          % (name, np.sqrt(np.mean(r ** 2)), np.max(np.abs(r)),
             np.max(np.abs(y)), np.mean(np.abs(y) ** 2)))
    return np.sqrt(np.mean(r ** 2)), np.max(np.abs(r))


rng = np.random.default_rng(7)
NPKT = 12
bits = rng.integers(0, 2, NPKT * P.DATA_BITS)
syms, sig = F.tx(bits, NPKT)
stats('TX out', sig)

for ebn0 in (30, 13):
    for sc in (1.0, 0.05):
        x = F.channel(sig, ebn0_db=ebn0, fo=0.025, phase_deg=37,
                      timing_off=0.51, scale=sc, seed=3)
        print('--- EbN0 %d dB, input scale %.2f' % (ebn0, sc))
        stats('  channel out', x)
        a, gh = F.agc(x)
        stats('  agc out', a)
        mf = np.convolve(a, P.RRC_RX)
        rms, pk = stats('  mf out', mf)
        print('   -> mf rail rms/G_rx = %.4f   peak/G_rx = %.4f'
              % (rms / P.RX_GAIN, pk / P.RX_GAIN))
