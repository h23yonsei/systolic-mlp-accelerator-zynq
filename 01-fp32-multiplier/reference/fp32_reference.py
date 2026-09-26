#!/usr/bin/env python3
"""
Reference model and test vectors for the FP32 multiplier (rtl/fp32_multiplier.v).

    python 01-fp32-multiplier/reference/fp32_reference.py            # write vectors/fp32_vectors.hex
    python 01-fp32-multiplier/reference/fp32_reference.py -o FILE    # write the vectors elsewhere

The model computes the product exactly with integers and rounds it the way the RTL is specified
to: round to nearest, ties to even; NaN for a NaN operand or infinity times zero; infinity for
infinity times anything else and for overflow; subnormal operands read as zero and results below
the normal range flushed to a signed zero. Wherever the product of two normal numbers is normal or
infinite, the model is checked against NumPy's float32 multiplication before a vector is written;
it differs from NumPy only where NumPy would produce a subnormal.

Each line of the vector file is one case: operand a, operand b and the expected product, in hex.
The groups follow one another in this order: the testbench's original ten cases, the special
cases, random normal operands with normal products, random products near underflow and near
overflow, and random bit patterns over the whole exponent range.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

OUT = Path(__file__).resolve().parent.parent / "vectors" / "fp32_vectors.hex"
QNAN = 0x7FC00000


def fields(x: int) -> tuple[int, int, int]:
    return x >> 31, (x >> 23) & 0xFF, x & 0x7FFFFF


def mul(a: int, b: int) -> int:
    """FP32 product of the bit patterns a and b, with the RTL's rounding and flushing rules."""
    sa, ea, ma = fields(a)
    sb, eb, mb = fields(b)
    sign = (sa ^ sb) << 31
    nan_a, nan_b = ea == 0xFF and ma != 0, eb == 0xFF and mb != 0
    inf_a, inf_b = ea == 0xFF and ma == 0, eb == 0xFF and mb == 0
    zero_a, zero_b = ea == 0, eb == 0                  # zero, or a subnormal read as zero

    if nan_a or nan_b or (inf_a and zero_b) or (zero_a and inf_b):
        return QNAN
    if inf_a or inf_b:
        return sign | 0x7F800000
    if zero_a or zero_b:
        return sign

    # exact product of the 24-bit significands: 47 or 48 bits
    prod = ((1 << 23) | ma) * ((1 << 23) | mb)
    drop = prod.bit_length() - 24
    kept, rest = prod >> drop, prod & ((1 << drop) - 1)
    half = 1 << (drop - 1)
    if rest > half or (rest == half and kept & 1):     # nearest, ties to even
        kept += 1
    if kept == 1 << 24:                                # rounding carried into a new leading bit
        kept >>= 1
        drop += 1

    exp = ea + eb - 127 + (drop - 23)                  # biased result exponent
    if exp >= 0xFF:
        return sign | 0x7F800000
    if exp <= 0:
        return sign
    return sign | (exp << 23) | (kept & 0x7FFFFF)


def numpy_mul(a: int, b: int) -> int:
    x = np.array([a], dtype=np.uint32).view(np.float32)
    y = np.array([b], dtype=np.uint32).view(np.float32)
    with np.errstate(all="ignore"):
        return int((x * y).view(np.uint32)[0])


def f32(value: float) -> int:
    return int(np.array([value], dtype=np.float32).view(np.uint32)[0])


def check_against_numpy(a: int, b: int, expected: int) -> None:
    """For two normal operands, a normal or infinite result must equal NumPy's float32 product. A
    flushed result must be one NumPy gives as a subnormal (or zero), or one NumPy rounds up to the
    smallest normal only because it rounds subnormals at their coarser precision."""
    if not (0 < fields(a)[1] < 0xFF and 0 < fields(b)[1] < 0xFF):
        return
    ref = numpy_mul(a, b)
    if fields(expected)[1] != 0:
        assert ref == expected, f"model {expected:08x} != numpy {ref:08x} for {a:08x} * {b:08x}"
    else:
        assert fields(ref)[1] == 0 or ref & 0x7FFFFFFF == 0x00800000, \
            f"model flushed {a:08x} * {b:08x} but numpy gives {ref:08x}"


def normal(rng: np.random.Generator, n: int, lo: int, hi: int) -> list[int]:
    s = rng.integers(0, 2, n)
    e = rng.integers(lo, hi + 1, n)
    m = rng.integers(0, 1 << 23, n)
    return [int(x) for x in (s << 31) | (e << 23) | m]


def groups() -> list[tuple[str, list[tuple[int, int]]]]:
    rng = np.random.default_rng(2026)

    original = [(1.5, 2.0), (-1.5, 2.0), (0.5, -0.5), (1.25, 1.5), (-2.5, -4.0),
                (6.0, 0.25), (3.0, 3.0), (0.75, 8.0), (1.3, 4.0), (0.0, -7.25)]

    special = [
        (0x00000000, 0x3F800000), (0x80000000, 0x3F800000), (0x00000000, 0x80000000),
        (0x7F800000, 0x3F800000), (0xFF800000, 0x3F800000), (0x7F800000, 0xFF800000),
        (0x7F800000, 0x00000000), (0x80000000, 0xFF800000),              # infinity x zero: NaN
        (0x7FC00000, 0x3F800000), (0x3F800000, 0xFFC00001), (0x7F800001, 0x00000000),
        (0x00000001, 0x40000000), (0x007FFFFF, 0x7F000000),              # subnormal operands
        (0x7F000000, 0x40000000), (0x7F7FFFFF, 0x7F7FFFFF), (0xFF7FFFFF, 0x40000000),
        (0x7EFFFFFF, 0x40000000), (0x5F800000, 0x5F800000), (0x5FC00000, 0x5FC00000),
        (0x00800000, 0x3F000000), (0x1F800000, 0x1F800000), (0x00800000, 0x3F7FFFFF),
        (0x20000000, 0x1F800000), (0x80800000, 0x3F800000), (0x00800000, 0x3F800000),
        (0x3F800001, 0x3FFFFFFE), (0x3F800002, 0x3FFFFFFC), (0x3FFFFFFF, 0x3F800001),
        (0x3F800002, 0x3FA00000), (0x3F800006, 0x3FA00000), (0x3F800001, 0x3FC00000),
        (0x3F800003, 0x3FC00000),                                        # ties to even
    ]

    random = [
        ("normal operands, normal products", list(zip(normal(rng, 2000, 64, 190), normal(rng, 2000, 64, 190)))),
        ("products near and below the smallest normal", list(zip(normal(rng, 500, 1, 80), normal(rng, 500, 1, 80)))),
        ("products near and above the largest normal", list(zip(normal(rng, 500, 150, 254), normal(rng, 500, 150, 254)))),
        ("operands over the whole exponent range, including 0 and 255",
         list(zip([int(x) for x in rng.integers(0, 1 << 32, 500, dtype=np.uint64)],
                  [int(x) for x in rng.integers(0, 1 << 32, 500, dtype=np.uint64)]))),
    ]
    return ([("original testbench cases", [(f32(x), f32(y)) for x, y in original]),
             ("zeros, infinities, NaNs, subnormal operands, overflow, underflow, rounding carry "
              "and ties", special)] + random)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--output", type=Path, default=OUT, help="vector file to write")
    args = ap.parse_args()

    lines = []
    for title, pairs in groups():
        for a, b in pairs:
            expected = mul(a, b)
            check_against_numpy(a, b, expected)
            lines.append(f"{a:08x} {b:08x} {expected:08x}")
        print(f"  {len(pairs):5d}  {title}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    print(f"Wrote {len(lines)} vectors to {args.output}")


if __name__ == "__main__":
    main()
