import numpy as np
import qpsk_params as P

# Direct Lagrange basis on nodes t = -1, 0, 1, 2
def lagrange(mu):
    return np.array([
        -mu * (mu - 1) * (mu - 2) / 6.0,
        (mu + 1) * (mu - 1) * (mu - 2) / 2.0,
        -(mu + 1) * mu * (mu - 2) / 2.0,
        (mu + 1) * mu * (mu - 1) / 6.0,
    ])

worst = 0.0
for mu in np.linspace(0, 1, 101):
    direct = lagrange(mu)
    powers = np.array([mu ** 3, mu ** 2, mu, 1.0])
    farrow = powers @ P.FARROW
    worst = max(worst, np.max(np.abs(direct - farrow)))
print('max |Lagrange - Farrow| over mu in [0,1] : %.3e' % worst)

# interpolate a known band limited signal
n = np.arange(-1, 200)
f = 0.07
x = np.cos(2 * np.pi * f * n)
err = []
for mu in (0.0, 0.25, 0.5, 0.73, 0.99):
    y = []
    for i in range(1, len(n) - 2):
        v = x[i - 1:i + 3]
        c = P.FARROW @ v
        y.append(((c[0] * mu + c[1]) * mu + c[2]) * mu + c[3])
    ref = np.cos(2 * np.pi * f * (n[1:len(n) - 2] + mu))
    err.append(np.max(np.abs(np.array(y) - ref)))
print('cubic interpolation error vs mu :', ['%.2e' % e for e in err])
