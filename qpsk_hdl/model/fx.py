"""
Fixed point primitives shared by the golden model.

Every operation here has a one-to-one Verilog equivalent so that the model
and the RTL produce identical bits.  Python's >> on negative integers is an
arithmetic (floor) shift, which is what Verilog's >>> does on a signed value,
so shifts map across directly.
"""


def sat(v, width):
    """Saturate a signed value to `width` bits."""
    lo = -(1 << (width - 1))
    hi = (1 << (width - 1)) - 1
    return lo if v < lo else (hi if v > hi else v)


def wrap(v, width):
    """Truncate to `width` bits, interpreted unsigned."""
    return v & ((1 << width) - 1)


def swrap(v, width):
    """Truncate to `width` bits, interpreted signed (what a Verilog
    assignment to a signed reg of that width does)."""
    v &= (1 << width) - 1
    return v - (1 << width) if v >> (width - 1) else v


def rsh(v, s):
    """Arithmetic right shift with round-half-up, matching
    (v + (1<<(s-1))) >>> s in Verilog."""
    if s <= 0:
        return v << (-s)
    return (v + (1 << (s - 1))) >> s


def rsh_sat(v, s, width):
    return sat(rsh(v, s), width)


def clz(v, width):
    """Count leading zeros of an unsigned `width` bit value."""
    for i in range(width - 1, -1, -1):
        if v & (1 << i):
            return width - 1 - i
    return width
