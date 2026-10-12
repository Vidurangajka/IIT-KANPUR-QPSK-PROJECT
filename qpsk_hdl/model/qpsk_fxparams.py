"""
Quantised constants shared by the fixed point model and the RTL.

qpsk_params.py holds the floating point design; this module turns it into the
exact integers both implementations use, and emits rtl/qpsk_defs.vh so the
Verilog cannot drift away from the model.
"""

import numpy as np
import qpsk_params as P
from cordic import (ATAN_TBL, KINV_Q15, NITER, CORDIC_W, CORDIC_F, AW,
                    VEC_IN_W)

# ---------------------------------------------------------------------------
# filters
# ---------------------------------------------------------------------------
NT_TX = P.RRC_NTAPS + (-P.RRC_NTAPS) % P.SPS          # 44, padded for polyphase
H_TX = np.zeros(NT_TX, dtype=np.int64)
H_TX[:P.RRC_NTAPS] = P.q(P.RRC_TX)
NPHASE = P.SPS
NTAP_P = NT_TX // P.SPS                               # 11 taps per phase
# H_POLY[p][k] = H_TX[SPS*k + p]
H_POLY = [[int(H_TX[P.SPS * k + p]) for k in range(NTAP_P)] for p in range(NPHASE)]

H_RX = [int(v) for v in P.q(P.RRC_RX)]                # 41 symmetric taps
NT_RX = P.RRC_NTAPS
NHALF_RX = (NT_RX + 1) // 2                           # 21 unique coefficients

QPSK_A = P.QPSK_A                                     # 23170

# ---------------------------------------------------------------------------
# AGC
# ---------------------------------------------------------------------------
AGC_GW         = 20          # gain word, unsigned Q8.12
AGC_GFRAC      = 12
AGC_G_INIT     = 1 << AGC_GFRAC
AGC_G_MIN      = int(P.AGC_GMIN * (1 << AGC_GFRAC))
AGC_G_MAX      = int(P.AGC_GMAX * (1 << AGC_GFRAC))
AGC_PW         = 26          # power accumulator, Q4.22 signed
AGC_PFRAC      = 22
AGC_TARGET     = int(round(P.AGC_TARGET_POW * (1 << AGC_PFRAC)))
AGC_AVG_SHIFT  = P.AGC_AVG_SHIFT
AGC_STEP_SHIFT = P.AGC_STEP_SHIFT
# |y|^2 arrives as Q2.30; shift to Q4.22
AGC_P_ALIGN    = 30 - AGC_PFRAC                      # 8

# ---------------------------------------------------------------------------
# symbol timing recovery
# ---------------------------------------------------------------------------
STR_CW      = 16                       # modulo-1 counter, Q0.16
STR_W_NOM   = (1 << STR_CW) * 2 // P.SPS          # 32768 for sps = 4
STR_MU_SH   = P.SPS // 2 - 1           # mu = cnt * (1/W_NOM) = cnt << 1
STR_K6      = int(round((1 << 15) / 6.0))         # 5461, the 1/6 Farrow constant
STR_E_SH    = 14                       # TED output Q.30 -> Q.16
STR_KP_S    = 18
STR_KP_M    = int(round(P.STR_KP * (1 << STR_KP_S)))
STR_INTEG_F = 12                       # extra fractional bits in the integrator
STR_KI_S    = 14
STR_KI_M    = int(round(P.STR_KI * (1 << STR_INTEG_F) * (1 << STR_KI_S)))
STR_VCTL_LIM = 1 << 13                 # clamp the control word to +-0.125

# ---------------------------------------------------------------------------
# coarse frequency recovery
# ---------------------------------------------------------------------------
CF_BLK        = P.COARSE_BLK
CF_BLK_W      = int(np.ceil(np.log2(CF_BLK)))
CF_ACC_W      = 16 + CF_BLK_W + 1      # unit vectors summed over a block
# the block accumulator is wider than the CORDIC vectoring input, so it is
# shifted down before the angle is taken (only the ratio matters)
CF_ACC_SH     = max(0, CF_ACC_W - VEC_IN_W)
CF_PH_F       = 8                      # extra fractional bits below the angle LSB
CF_PH_W       = AW + CF_PH_F           # 24 bit phase accumulator
# the block estimate is ready a couple of symbol periods after the block
# ends (two pipelined CORDICs), so both model and RTL apply it at the symbol
# whose index is congruent to CF_GUARD modulo CF_BLK - a symbol aligned event
CF_GUARD      = 4
CF_FAST_BLK   = P.COARSE_FAST_BLK
CF_SLOW_SHIFT = P.COARSE_SLOW_SHIFT

# ---------------------------------------------------------------------------
# fine frequency recovery
# ---------------------------------------------------------------------------
FF_PH_F   = 8
FF_PH_W   = AW + FF_PH_F               # 24
FF_EW     = AW - 2                     # phase error is 14 bits, +-90/2 degrees
FF_OFFS   = 1 << (AW - 3)              # 8192 = 45 degrees
FF_KP_S   = 12
FF_KP_M   = int(round(P.FFR_KP * (1 << CF_PH_F) * (1 << FF_KP_S)))
FF_INTEG_F = 8
FF_KI_S   = 12
FF_KI_M   = int(round(P.FFR_KI * (1 << FF_PH_F) * (1 << FF_INTEG_F)
                      * (1 << FF_KI_S)))

# ---------------------------------------------------------------------------
# packet detector
# ---------------------------------------------------------------------------
DET_WIN_SHIFT = P.DET_WIN_SHIFT
DET_PEAK_WIN  = P.DET_PEAK_WIN
DET_THR_NUM   = P.DET_THR_NUM
DET_THR_SHIFT = P.DET_THR_SHIFT
# The symbol stream is delayed by exactly the peak search window, so a
# detection declared at the end of the window still has the payload in
# flight.  wait = DET_DLY - peak_age is then in 1..DET_PEAK_WIN, and the
# payload finishes PREAMBLE_SYMS - DET_DLY + peak_age symbols before the next
# packet is detected, so extraction never overlaps the next detection.
DET_DLY       = DET_PEAK_WIN + 1       # symbol delay line depth
DET_INHIBIT   = P.PKT_SYMS - DET_PEAK_WIN - 2
BARKER_BITS   = ''.join('1' if b > 0 else '0' for b in P.BARKER13)


def _vh_array(name, vals, width):
    """Emit a flat concatenated constant plus an unpacking generate block."""
    acc = 0
    for i, v in enumerate(vals):
        acc |= (int(v) & ((1 << width) - 1)) << (i * width)
    n = len(vals) * width
    return "localparam [%d:0] %s = %d'h%s;" % (
        n - 1, name, n, format(acc, 'x').rjust((n + 3) // 4, '0'))


def write_defs(path='../rtl/qpsk_defs.vh'):
    L = []
    a = L.append
    a('// ' + '-' * 72)
    a('// qpsk_defs.vh - generated by model/qpsk_fxparams.py.  Do not edit.')
    a('// Every constant here is also used by the Python golden model, so the')
    a('// RTL and the model cannot disagree.')
    a('//')
    a('// This file is included inside each module body and declares only')
    a('// localparams, which are module scoped.  It therefore carries no')
    a('// include guard: a guard would let the first include win and leave')
    a('// every later module without the constants.')
    a('// ' + '-' * 72)
    a('')
    a('// ---- sample format -------------------------------------------------')
    a('localparam integer W        = %d;   // sample word, s(16,15)' % P.W)
    a('localparam integer FRAC     = %d;' % P.FRAC)
    a('localparam integer AW       = %d;   // angle word, one turn = 2**16' % AW)
    a('')
    a('// ---- packet structure ----------------------------------------------')
    a('localparam integer SPS           = %d;' % P.SPS)
    a('localparam integer PREAMBLE_SYMS = %d;' % P.PREAMBLE_SYMS)
    a('localparam integer DATA_BITS     = %d;' % P.DATA_BITS)
    a('localparam integer DATA_SYMS     = %d;' % P.DATA_SYMS)
    a('localparam integer PKT_SYMS      = %d;' % P.PKT_SYMS)
    a("localparam [%d:0] BARKER = %d'b%s;  // b[0] is the first symbol"
      % (P.PREAMBLE_SYMS - 1, P.PREAMBLE_SYMS, BARKER_BITS[::-1]))
    a("localparam signed [W-1:0] QPSK_A = %d;   // 1/sqrt(2)" % QPSK_A)
    a('')
    a('// ---- scrambler ------------------------------------------------------')
    a("localparam [6:0] SCRAM_SEED = 7'h%02x;" % P.SCRAM_SEED)
    a('')
    a('// ---- transmit RRC, polyphase by %d ----------------------------------'
      % P.SPS)
    a('localparam integer TX_NTAP_P = %d;' % NTAP_P)
    for p in range(NPHASE):
        a(_vh_array('TX_H%d' % p, H_POLY[p], P.CW))
    a('')
    a('// ---- receive RRC matched filter, %d symmetric taps ------------------'
      % NT_RX)
    a('localparam integer RX_NTAPS = %d;' % NT_RX)
    a('localparam integer RX_NHALF = %d;' % NHALF_RX)
    a(_vh_array('RX_H', H_RX[:NHALF_RX], P.CW))
    a('')
    a('// ---- CORDIC ---------------------------------------------------------')
    a('localparam integer CORDIC_W     = %d;' % CORDIC_W)
    a('localparam integer CORDIC_F     = %d;' % CORDIC_F)
    a('localparam integer CORDIC_NITER = %d;' % NITER)
    a("localparam signed [15:0] CORDIC_KINV = %d;" % KINV_Q15)
    a(_vh_array('CORDIC_ATAN', ATAN_TBL, AW))
    a('')
    a('// ---- AGC ------------------------------------------------------------')
    a('localparam integer AGC_GW         = %d;' % AGC_GW)
    a('localparam integer AGC_GFRAC      = %d;' % AGC_GFRAC)
    a('localparam integer AGC_G_INIT     = %d;' % AGC_G_INIT)
    a('localparam integer AGC_G_MIN      = %d;' % AGC_G_MIN)
    a('localparam integer AGC_G_MAX      = %d;' % AGC_G_MAX)
    a('localparam integer AGC_PW         = %d;' % AGC_PW)
    a('localparam integer AGC_PFRAC      = %d;' % AGC_PFRAC)
    a('localparam integer AGC_P_ALIGN    = %d;' % AGC_P_ALIGN)
    a('localparam integer AGC_TARGET     = %d;' % AGC_TARGET)
    a('localparam integer AGC_AVG_SHIFT  = %d;' % AGC_AVG_SHIFT)
    a('localparam integer AGC_STEP_SHIFT = %d;' % AGC_STEP_SHIFT)
    a('')
    a('// ---- symbol timing recovery -----------------------------------------')
    a('localparam integer STR_CW        = %d;' % STR_CW)
    a('localparam integer STR_W_NOM     = %d;' % STR_W_NOM)
    a('localparam integer STR_MU_SH     = %d;' % STR_MU_SH)
    a('localparam integer STR_K6        = %d;' % STR_K6)
    a('localparam integer STR_E_SH      = %d;' % STR_E_SH)
    a('localparam integer STR_KP_S      = %d;' % STR_KP_S)
    a('localparam integer STR_KP_M      = %d;' % STR_KP_M)
    a('localparam integer STR_KI_S      = %d;' % STR_KI_S)
    a('localparam integer STR_KI_M      = %d;' % STR_KI_M)
    a('localparam integer STR_INTEG_F   = %d;' % STR_INTEG_F)
    a('localparam integer STR_VCTL_LIM  = %d;' % STR_VCTL_LIM)
    a('')
    a('// ---- coarse frequency recovery --------------------------------------')
    a('localparam integer CF_BLK        = %d;' % CF_BLK)
    a('localparam integer CF_BLK_W      = %d;' % CF_BLK_W)
    a('localparam integer CF_ACC_W      = %d;' % CF_ACC_W)
    a('localparam integer CF_ACC_SH     = %d;' % CF_ACC_SH)
    a('localparam integer VEC_IN_W      = %d;' % VEC_IN_W)
    a('localparam integer CF_PH_F       = %d;' % CF_PH_F)
    a('localparam integer CF_PH_W       = %d;' % CF_PH_W)
    a('localparam integer CF_GUARD      = %d;' % CF_GUARD)
    a('localparam integer CF_FAST_BLK   = %d;' % CF_FAST_BLK)
    a('localparam integer CF_SLOW_SHIFT = %d;' % CF_SLOW_SHIFT)
    a('')
    a('// ---- fine frequency recovery ----------------------------------------')
    a('localparam integer FF_PH_F    = %d;' % FF_PH_F)
    a('localparam integer FF_PH_W    = %d;' % FF_PH_W)
    a('localparam integer FF_EW      = %d;' % FF_EW)
    a('localparam integer FF_OFFS    = %d;' % FF_OFFS)
    a('localparam integer FF_KP_S    = %d;' % FF_KP_S)
    a('localparam integer FF_KP_M    = %d;' % FF_KP_M)
    a('localparam integer FF_KI_S    = %d;' % FF_KI_S)
    a('localparam integer FF_KI_M    = %d;' % FF_KI_M)
    a('localparam integer FF_INTEG_F = %d;' % FF_INTEG_F)
    a('')
    a('// ---- packet detector -------------------------------------------------')
    a('localparam integer DET_WIN_SHIFT = %d;' % DET_WIN_SHIFT)
    a('localparam integer DET_PEAK_WIN  = %d;' % DET_PEAK_WIN)
    a('localparam integer DET_THR_NUM   = %d;' % DET_THR_NUM)
    a('localparam integer DET_THR_SHIFT = %d;' % DET_THR_SHIFT)
    a('localparam integer DET_DLY       = %d;' % DET_DLY)
    a('localparam integer DET_INHIBIT   = %d;' % DET_INHIBIT)
    a('')
    txt = '\n'.join(L) + '\n'
    with open(path, 'w') as f:
        f.write(txt)
    return txt


if __name__ == '__main__':
    import sys
    out = sys.argv[1] if len(sys.argv) > 1 else '../rtl/qpsk_defs.vh'
    write_defs(out)
    print('wrote', out)
    print('STR  KP_M %d >>%d   KI_M %d >>%d  (integ frac %d)'
          % (STR_KP_M, STR_KP_S, STR_KI_M, STR_KI_S, STR_INTEG_F))
    print('FF   KP_M %d >>%d   KI_M %d >>%d' % (FF_KP_M, FF_KP_S,
                                                FF_KI_M, FF_KI_S))
    print('AGC  target %d  gmin %d gmax %d' % (AGC_TARGET, AGC_G_MIN, AGC_G_MAX))
    print('DET  thr %d>>%d  dly %d  inhibit %d'
          % (DET_THR_NUM, DET_THR_SHIFT, DET_DLY, DET_INHIBIT))
