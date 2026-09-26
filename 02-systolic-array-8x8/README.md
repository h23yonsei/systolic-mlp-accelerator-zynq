# 8×8 Systolic Array

## Overview

A systolic array for matrix multiplication in synthesizable SystemVerilog. A weight-stationary
**processing element (PE)** performs multiply-accumulate (MAC), and 64 PEs are connected into an
**8×8 systolic array**.

## Key Concepts

- Weight-stationary PE: latches its weight when `save_weight` is raised, then multiply-accumulates
- Signed 8-bit data and weights, 18-bit accumulator
- `generate` blocks instantiate and wire the 64 PEs
- Dataflow: data moves right, weights move down, and the partial sums flow down the columns
- The testbench reads the two 8×8 matrices with `$readmemh` from `vectors/` and checks all 64
  outputs against their product

## Architecture

```text
din_in[0] -> [PE00] -> [PE01] -> ... -> [PE07]
din_in[1] -> [PE10] -> [PE11] -> ... -> [PE17]
   ...         ...       ...              ...
din_in[7] -> [PE70] -> [PE71] -> ... -> [PE77]
                                          |
                                      acc_out[0..7]
```

## Files

| Path | Description |
|------|-------------|
| `rtl/pe.sv` | Processing element: weight-stationary MAC unit |
| `rtl/systolic_array_8x8.sv` | 8×8 systolic array: 64 PEs in a mesh |
| `tb/tb_systolic_array_8x8.sv` | Loads the weights, feeds the inputs, and checks every output on the clock it leaves the array |
| `vectors/tb_input.hex` | 8×8 input matrix |
| `vectors/tb_weight.hex` | 8×8 weight matrix |

## Verification

The weights are shifted in from the top, one array row per clock with the last row first, and
`save_weight` is raised together with the final row, so PE (i, j) latches `weight[j][i]`. The
inputs then enter from the left with row i delayed by i clocks, and column j outputs
Σᵢ `input[i][c]` · `weight[j][i]` for c = 0…7 on consecutive clocks: the result for input column c
leaves column j 7 + j clocks after row 0 samples that column. The testbench computes all 64
products from the same two files and checks each output on its clock, printing
`PASS: all 64 outputs match the matrix product`.

Inputs change 1 ns after the rising edge, clear of the edge the array samples, so the result does
not depend on how a simulator orders events at that edge.

## How to Run

From the repository root, `python tools/run_sims.py` runs this testbench with the other checks,
in Vivado's simulator or in Icarus Verilog. By hand, place `tb_input.hex` and `tb_weight.hex` in the
simulator's working directory and simulate `tb_systolic_array_8x8` with the two RTL files (Vivado
behavioral simulation, or `iverilog -g2012 rtl/*.sv tb/tb_systolic_array_8x8.sv && vvp a.out`).
