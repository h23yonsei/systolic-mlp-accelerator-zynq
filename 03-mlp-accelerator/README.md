# MLP Hardware Accelerator

## Overview

A hardware accelerator that runs a four-layer MLP inference for the Google Speech Commands dataset
on a Xilinx Zynq-7020 (`xc7z020clg484-1`). A **16×16 output-stationary systolic array** with
tiling performs the int8 matrix multiplication of all four layers, classifying 16 audio
spectrograms into spoken digits in one batch; the PS prints the predictions over UART.

## Key Concepts

- 16×16 output-stationary systolic array
- Tiling for matrices larger than the PE array, with the partial sums carried across tiles
- Int8 quantization with static scale factors and requantization between layers
- ReLU activation with saturation to [0, 127]
- PS-PL interface: the ARM Cortex-A9 reads the results from PL block RAM after an interrupt

## Architecture

```text
Input (16x768) -> [W1: 128x768] -> [W2: 128x128] -> [W3: 128x128] -> [W4: 16x128] -> Output (16x16)
                   Layer 1           Layer 2           Layer 3           Layer 4
```

- **Systolic array:** 16×16 PEs, output-stationary dataflow
- **Tiling:** matrices larger than 16×16 are split into tiles, with the partial sums accumulated
  across them
- **Quantization:** all data and weights are int8, requantized between layers with static scale
  factors
- **Activation:** ReLU after each layer, saturating to [0, 127]

## Files

Provided by the course: the weights and input spectrograms in `reference/data/`,
`mlp_reference.py`, `gen_bram_init.py`, the BRAM image, the block design, `sw/main.c`, and the
port-level skeletons of `mlp_top.sv` and `mlp_axi_wrapper.v` (including the `bram_tdp` memory in
`mlp_top.sv`). Everything else in `rtl/` (the PE array, systolic core, sequencer, skewer and
post-processor) and the self-checking testbench were written for the project. Files and modules
were renamed for this repository (the course used `finalprj_*` and `helloworld.c`).

| Path | Description |
|------|-------------|
| **`rtl/`** | |
| `mlp_top.sv` | Top level: AXI slave, BRAM (`bram_tdp`), sequencer, systolic core |
| `systolic_core.sv`, `pe_array.sv`, `pe.sv` | 16×16 output-stationary PE array |
| `sequencer.sv`, `skewer.sv` | Tile sequencing and input skew |
| `post_proc.sv` | ReLU, requantization and saturation to int8 |
| `mlp_axi_wrapper.v` | AXI-facing wrapper, instantiated in the block design as a module reference |
| `bram_init.hex` | BRAM image the RTL loads, the output of `reference/gen_bram_init.py` |
| **`tb/`** | |
| `tb_mlp_top.sv` | Self-checking integration test against the NumPy reference |
| **`bd/`** | |
| `mlp_bd.tcl` | Block design: PS7, AXI interconnect, reset, the accelerator, `o_PROC_DONE` → `IRQ_F2P` |
| **`constraints/`** | |
| `zynq7020.xdc` | Pin constraints for the start and reset buttons |
| **`sw/`** | |
| `main.c` | PS application: waits for the interrupt, reads the 16×16 result matrix, prints predictions |
| `lscript.ld`, `platform.*`, `Xilinx.spec` | Linker script and standalone platform glue |
| **`reference/`** | |
| `mlp_reference.py` | Golden reference: the full four-layer MLP in NumPy |
| `gen_bram_init.py` | Packs `data/` into `rtl/bram_init.hex`, pre-tiled for the RTL's address counter |
| `data/input_spectrogram.bin` | 16 audio spectrograms (16×768, int8), evaluation-day set |
| `data/layer{1-4}_weights.bin` | Layer weights (int8) |
| `mlp_accelerator.xsa` | Hardware platform (bitstream and PS7 initialization) built by `tools/build_hw.tcl` |

## How to Run

All commands run from the repository root.

### NumPy Reference

```bash
python 03-mlp-accelerator/reference/mlp_reference.py
python 03-mlp-accelerator/reference/gen_bram_init.py   # regenerates rtl/bram_init.hex
```

### RTL Simulation

`python tools/run_sims.py` runs the integration test with the other checks. To run it by hand with
Vivado's simulator, work in a scratch directory, since the RTL loads `bram_init.hex` from the
simulator's working directory:

```bash
mkdir -p build/manual && cd build/manual
cp ../../03-mlp-accelerator/rtl/bram_init.hex .
M=../../03-mlp-accelerator
xvlog -sv $M/rtl/mlp_top.sv $M/rtl/systolic_core.sv $M/rtl/pe_array.sv $M/rtl/pe.sv \
    $M/rtl/post_proc.sv $M/rtl/sequencer.sv $M/rtl/skewer.sv $M/tb/tb_mlp_top.sv
xelab tb_mlp_top -s tb && xsim tb -R
```

Expected: `byte check: PASS (all 256 bytes match)` and `INTEGRATION TEST: PASS`.

### Hardware Deployment

With Vivado and Vitis 2022.1:

1. **Bitstream and platform:** `vivado -mode batch -nojournal -source tools/build_hw.tcl` creates
   the Vivado project in `build/vivado/` from `rtl/`, `constraints/` and `bd/mlp_bd.tcl`,
   implements it, and writes `build/hw/mlp_accelerator.xsa` plus utilization and timing reports.
   Open `build/vivado/mlp_accelerator.xpr` afterwards to inspect the design in the GUI.
2. **PS application:** `xsct tools/build_sw.tcl build/hw/mlp_accelerator.xsa` creates a Vitis
   platform and builds `build/vitis/mlp_app/Debug/mlp_app.elf` from `sw/`. Without an argument it
   uses the committed `mlp_accelerator.xsa`, so this step works without step 1.
3. Program the board, run `mlp_app.elf` from the Vitis IDE, and open a UART terminal at
   115200 baud. Press S2 (`push_n`) to start a batch; S1 (`rst_n`) resets the accelerator. When
   the done interrupt fires, the application prints the 16 predictions. This step is what the
   design was built for, but it has not been carried out here — every result in this repository
   comes from simulation and implementation reports.
