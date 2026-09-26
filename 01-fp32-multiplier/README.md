# FP32 Multiplier

## Overview

A combinational IEEE 754 single-precision (FP32) floating-point multiplier in Verilog. It takes two
32-bit operands and produces their 32-bit FP32 product, with no clock.

## Key Concepts

- IEEE 754 FP32 format: sign, 8-bit exponent, 23-bit mantissa
- Sign by XOR; exponents added with the bias (127) removed once
- 24 × 24-bit mantissa multiplication into a 48-bit product
- Normalization by at most one position, and rounding to nearest, ties to even, from the guard bit
  and a sticky bit — including the carry when rounding turns 1.11…1 into 10.0
- Special values: NaN for a NaN operand or infinity × zero, infinity for infinity × a nonzero
  value and for overflow
- No subnormals: a subnormal operand is read as zero, and a product below the smallest normal
  number (2⁻¹²⁶ after rounding) is flushed to a signed zero

## Files

| Path | Description |
|------|-------------|
| `rtl/fp32_multiplier.v` | FP32 multiplier |
| `tb/tb_fp32_multiplier.sv` | Self-checking testbench: every vector in `vectors/fp32_vectors.hex`, compared bit for bit (any NaN matches any NaN) |
| `reference/fp32_reference.py` | Bit-exact reference model; writes the vectors and checks the model against NumPy's float32 multiplication |
| `vectors/fp32_vectors.hex` | 3,542 cases: 10 hand-picked cases, 32 special cases, and 3,500 random operand pairs across the exponent range |

## Verification

The reference model computes each product exactly with integers and rounds it by the rules above.
Wherever two normal operands give a normal or infinite product, `fp32_reference.py` asserts that
the model equals NumPy's float32 result before writing the vector; the two differ only where NumPy
would return a subnormal. The vectors are:

| Group | Cases |
|-------|------:|
| Ten hand-picked cases | 10 |
| Signed zeros, infinities, NaNs, subnormal operands, overflow, underflow, the rounding carry, ties rounding up and down | 32 |
| Random normal operands with normal products | 2,000 |
| Random products near and below the smallest normal | 500 |
| Random products near and above the largest normal | 500 |
| Random bit patterns over the whole exponent range, including 0 and 255 | 500 |

The edge groups are where a multiplier goes wrong: products that underflow or overflow the
exponent, a rounding carry out of the mantissa (1.0000001 × 1.9999998 = 2.0), NaN and infinity
operands, and exact ties. All 3,542 vectors pass bit for bit.

## How to Run

From the repository root, `python tools/run_sims.py` regenerates the vectors, confirms the
committed file matches, and runs this testbench with the other checks. To run it by hand, put
`vectors/fp32_vectors.hex` in the simulator's working directory and simulate `tb_fp32_multiplier`
with `rtl/fp32_multiplier.v` (Vivado behavioral simulation, or
`iverilog -g2012 rtl/fp32_multiplier.v tb/tb_fp32_multiplier.sv && vvp a.out`). It prints
`ALL PASSED: 3542 vectors`, or the first mismatches.

```bash
python 01-fp32-multiplier/reference/fp32_reference.py    # regenerate vectors/fp32_vectors.hex
```
