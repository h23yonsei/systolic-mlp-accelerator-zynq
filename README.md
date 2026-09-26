# Systolic-Array MLP Accelerator on Zynq-7020

[![checks](https://github.com/h23yonsei/systolic-mlp-accelerator-zynq/actions/workflows/checks.yml/badge.svg)](https://github.com/h23yonsei/systolic-mlp-accelerator-zynq/actions/workflows/checks.yml)

A **16×16 output-stationary systolic array** for quantized multilayer-perceptron inference on
a Xilinx Zynq-7020. 256 processing elements, each an int8×int8 multiply into a 32-bit
accumulator, are fed 16×16 tiles of every layer from on-chip BRAM by a hardware sequencer; the
ARM PS collects the results over AXI. Implemented, routed, and **closing timing at 100 MHz**; in
simulation its output matches the NumPy reference byte for byte on all 16 audio clips.

Built for EEE4473 Embedded System Lab at Yonsei University, Spring 2026. The final project
(`03-mlp-accelerator`) was built jointly with Heewon Lee, with the work divided evenly between us.
The course provided the int8 weights and test spectrograms
(`03-mlp-accelerator/reference/data/*.bin`), the per-layer scale factors, the reference model and
BRAM-image generator, the BRAM image, the block design, the PS application, and the port-level
skeletons of `mlp_top.sv` and `mlp_axi_wrapper.v`; no training code is part of this repository. The
work here is the systolic array, tiling sequencer and post-processor that fill that skeleton, plus
their verification.

## Architecture

```text
PL  mlp_top
  bram_tdp    16,384 × 128-bit words: weights, inputs, and each layer's output
     │ port B: weight tile          │ port A: input tile in, results written back
     ▼                              ▼
  sequencer   layer and tile FSM  ──▶  skewer   diagonal feed of each tile pair
                                          │
                                          ▼
  pe_array    16×16 PEs: int8 × int8 → int32 accumulate, carried across k-tiles
                                          │ drain, bottom row
                                          ▼
  post_proc   ReLU → × per-layer scale → round, saturate to int8 → next layer's input in BRAM
  o_PROC_DONE ──▶ IRQ_F2P

PS  Cortex-A9, sw/main.c
  on the interrupt: read the 16×16 result over AXI4-Lite, argmax, print over UART

Start: push button S2 (push_n)   Reset: S1 (rst_n)
```

**Why output-stationary.** Each PE owns one accumulator, and that accumulator is the output
element. Input and weight values shift through the array from its left and top edges, while
each partial sum stays in its PE across every k-tile and moves only once, when the finished
result is drained down the array into `post_proc`. The weight-stationary array in
[`02-systolic-array-8x8`](02-systolic-array-8x8) does the opposite: weights stay put and the
partial sums flow down the array every cycle. Keeping partial sums in place is what lets a
16×16 array accumulate a 768-wide reduction without a separate adder tree.

**Why tiling.** The array is 16×16; the layers are not (layer 1's weight matrix is 128×768).
The sequencer cuts each GEMM into 16×16 tiles: for every block of the output it walks the
reduction dimension in 16-wide steps (48 steps for layer 1, 8 for layers 2–4), and the PE
accumulators carry the partial sums between steps, clearing only on the first.
`gen_bram_init.py` stores the matrices pre-tiled in the BRAM image, so the sequencer addresses
every tile with a linear counter.

**Why int8 with a 32-bit accumulator.** Each PE multiplies two signed 8-bit operands into a
16-bit product and sign-extends it into a 32-bit accumulator. The deepest reduction is layer
1's 768 input columns, so the worst case is 768 products of magnitude at most 2^14 — about
1.3 × 10^7, far inside the int32 range. Saturation is needed only once, in `post_proc`, when
requantizing back to int8.

**One register in the middle of the MAC.** The product is latched in `mul_reg` before it
reaches the adder, splitting multiply and accumulate into separate timing paths at the cost
of a cycle of latency.

## Results

Implemented and routed in Vivado 2022.1 by `tools/build_hw.tcl`; reports are committed under
[`reports/`](reports/). These are synthesis, implementation and simulation results: no design
here has been run on a board.

| Metric | Value |
| --- | --- |
| Target device | `xc7z020clg484-1` (Zynq-7020) |
| Array | 16 × 16 PEs, output-stationary |
| Arithmetic | int8 × int8 → int16 product → int32 accumulate, requantized to int8 |
| Clock constraint | 100 MHz (`clk_fpga_0`, 10 ns) |
| Worst negative slack | **+0.331 ns** — timing met, 0 of 49,823 endpoints failing |
| Worst hold slack | +0.015 ns |
| Maximum frequency | **≈ 103.4 MHz** |
| LUT | 31,457 / 53,200 — **59.1%** (31,397 logic, 60 memory) |
| Flip-flops | 22,854 / 106,400 — 21.5% |
| Block RAM | 64 / 140 tiles — 45.7% (64 × RAMB36E1) |
| DSP48 | 64 / 220 — 29.1% |

**Where the LUTs went.** None of the 256 PE multipliers land on DSP48 slices. All 64 DSPs
belong to `post_proc` — sixteen 32×32 requantization multipliers at four DSPs each — while the
PE array is built entirely in fabric: 29,201 LUTs and 16,384 flip-flops, an average of 114
LUTs per PE (84 in the top row, up to 131 in the bottom row). That array is most of the 59%
LUT occupancy, and it is the real constraint on scaling: even if the tools were forced to map
the PEs onto DSPs, a 7020 has 220 of them against 256 multipliers.
Going wider on this part means time-multiplexing the PEs or accepting fabric multipliers and
the frequency they bring. (Per-module breakdown from synthesis:
[`reports/utilization_hierarchical_synth.rpt`](reports/utilization_hierarchical_synth.rpt).)

## Verification

Every check below can be re-run with one command, in Vivado 2022.1's simulator
(`xvlog`/`xelab`/`xsim`) or in open-source ones (Icarus Verilog 12 and Verilator 5), with
Python 3 and NumPy:

```bash
pip install -r requirements.txt
python tools/run_sims.py --vivado C:/Xilinx/Vivado/2022.1   # Vivado's simulator
python tools/run_sims.py --sim oss                          # Icarus Verilog and Verilator
python tools/run_sims.py --skip-hdl                         # the Python checks only
```

Without `--vivado` or `--sim`, Vivado is used if it is installed and the open-source simulators
otherwise; the whole run takes about ten seconds with them. It runs the NumPy reference and
confirms the integration testbench expects exactly its output, confirms `rtl/bram_init.hex`
matches `gen_bram_init.py` output, regenerates the FP32 multiplier's 3,542 test vectors from its
reference model (checked against NumPy's float32 arithmetic) and simulates them, checks all 64
outputs of the 8×8 systolic array against the matrix product, and runs the integration test
below. Simulation output goes to `build/sim/`.

All six checks pass with the open-source simulators, which the repository runs on every push (the
badge above), and in Vivado 2022.1's simulator.

The self-checking testbench `tb/tb_mlp_top.sv` runs the full four-layer inference on 16
audio clips in behavioral simulation and compares the hardware's output bytes against the
NumPy reference in [`reference/`](03-mlp-accelerator/reference). Excerpt of its output:

```text
  byte check: PASS (all 256 bytes match)
  clip  1: six    (class 5) OK
  ...
  clip 16: three  (class 2) OK
 INTEGRATION TEST: PASS
```

`rtl/bram_init.hex` is generated from the committed weight and input `.bin` files by
`reference/gen_bram_init.py`; the image the RTL loads must be byte-identical to that output,
or the hardware computes on different inputs than the reference.

The committed inputs are the course's evaluation-day set, which occupies the BRAM image's input
region (`0x2400`–`0x26FF`). `input_spectrogram.bin` is that region with the tiling of
`gen_bram_init.py` inverted, and regenerating the image from it reproduces the evaluation-day file
byte for byte. The testbench's expected values come from the NumPy reference on these inputs.

## What's in here

| Directory | Contents |
| --- | --- |
| `01-fp32-multiplier` | IEEE-754 single-precision combinational multiplier |
| `02-systolic-array-8x8` | Processing element and 8×8 systolic array |
| `03-mlp-accelerator` | Final 16×16 systolic-array MLP accelerator, block design and PS application |
| `tools` | `run_sims.py`, `build_hw.tcl` (Vivado), `build_sw.tcl` (Vitis) |
| `reports` | Utilization and timing reports produced by `build_hw.tcl` |

Directories are numbered in build order.

## Build

- **EDA:** Xilinx Vivado 2022.1 / Vitis
- **Reference model:** Python 3, NumPy

From the repository root:

```bash
vivado -mode batch -nojournal -source tools/build_hw.tcl   # project in build/vivado, bitstream + build/hw/mlp_accelerator.xsa
xsct tools/build_sw.tcl build/hw/mlp_accelerator.xsa         # PS application, build/vitis/mlp_app/Debug/mlp_app.elf
```

The Vivado project is generated from the committed RTL, constraints and block-design script
(`03-mlp-accelerator/bd/mlp_bd.tcl`); no Vivado project files are committed. See
[`03-mlp-accelerator/README.md`](03-mlp-accelerator/README.md#hardware-deployment) for
programming the board.

## License

MIT for the original work in this repository. `03-mlp-accelerator/sw/` is based on Xilinx's
standalone application template and keeps Xilinx's license in the file headers; the
course-provided materials listed at the top remain the course's.
