#!/usr/bin/env python3
"""
Reproduce every verification result in this repository.

    python tools/run_sims.py                                  # everything
    python tools/run_sims.py --vivado C:/Xilinx/Vivado/2022.1
    python tools/run_sims.py --sim oss                        # Icarus Verilog and Verilator
    python tools/run_sims.py --skip-hdl                       # Python checks only

Checks, in order:

1. NumPy reference      03-mlp-accelerator/reference/mlp_reference.py runs and classifies all
                        16 clips.
2. BRAM image           reference/gen_bram_init.py regenerates rtl/bram_init.hex from the
                        committed .bin files, and the committed image is byte-identical to that
                        output. A mismatch means the hardware computes on different inputs than
                        the reference.
3. FP32 vectors         01-fp32-multiplier/reference/fp32_reference.py regenerates
                        vectors/fp32_vectors.hex (checking its model against NumPy on the way),
                        and the committed file is identical to that output.
4. FP32 multiplier      01-fp32-multiplier/tb/tb_fp32_multiplier.sv checks every vector in
                        vectors/fp32_vectors.hex.
5. 8x8 systolic array   02-systolic-array-8x8/tb/tb_systolic_array_8x8.sv checks all 64 outputs
                        against the matrix product of vectors/tb_input.hex and
                        vectors/tb_weight.hex.
6. MLP accelerator      03-mlp-accelerator/tb/tb_mlp_top.sv, the full four-layer inference on
                        16 clips, byte-compared against the NumPy reference.

HDL checks use Vivado's simulator (xvlog/xelab/xsim) when Vivado is installed. Otherwise, or with
--sim oss, they use Icarus Verilog for checks 4 and 5 and Verilator for check 6, whose
SystemVerilog Icarus does not parse. Output goes to build/sim/, which is git-ignored.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BUILD = REPO / "build" / "sim"
MLP = REPO / "03-mlp-accelerator"
RTL = MLP / "rtl"
REF = MLP / "reference"


# ---------------------------------------------------------------------------
def find_vivado(explicit: str | None) -> Path | None:
    for cand in (explicit, os.environ.get("XILINX_VIVADO")):
        if cand and (Path(cand) / "bin").exists():
            return Path(cand) / "bin"
    exe = shutil.which("xvlog") or shutil.which("xvlog.bat")
    return Path(exe).parent if exe else None


def tool(bindir: Path, name: str) -> str:
    return str(bindir / (name + ".bat" if os.name == "nt" else name))


def run(cmd: list[str], cwd: Path, log: Path, timeout: int = 3600) -> tuple[int, str]:
    with log.open("w") as fh:
        code = subprocess.run(cmd, cwd=cwd, stdout=fh, stderr=subprocess.STDOUT,
                              timeout=timeout, shell=(os.name == "nt")).returncode
    return code, log.read_text(errors="ignore")


def simulate(sim: str | Path, work: Path, sources: list[tuple[Path, bool]], top: str) -> str:
    """Compile the sources, elaborate `top` and run it to completion; return the simulation log.

    `sim` is Vivado's bin/ directory for xsim (each source compiled with or without -sv as
    flagged), or "icarus" or "verilator". The check_* functions take Vivado's bin/ directory or
    "oss" and pick the open-source simulator for their testbench."""
    work.mkdir(parents=True, exist_ok=True)
    files = [str(src) for src, _ in sources]
    if sim == "icarus":
        code, out = run(["iverilog", "-g2012", "-s", top, "-o", "sim.vvp", *files], work, work / "iverilog.log")
        if code:
            raise RuntimeError(f"compile failed: {out.strip().splitlines()[0] if out.strip() else code}")
        run(["vvp", "-n", "sim.vvp"], work, work / "sim.log")
    elif sim == "verilator":
        code, out = run(["verilator", "--binary", "--timing", "-j", "0", "-Wno-fatal", "-Wno-WIDTH",
                         "--top-module", top, "-Mdir", "obj_dir", *files], work, work / "verilator.log")
        if code:
            raise RuntimeError(f"build failed: {re.search(r'(?m)^%Error.*', out).group(0) if '%Error' in out else code}")
        run([str(work / "obj_dir" / f"V{top}")], work, work / "sim.log")
    else:
        for src, is_sv in sources:
            _, out = run([tool(sim, "xvlog")] + (["-sv"] if is_sv else []) + [str(src)],
                         work, work / f"xvlog_{src.stem}.log")
            if re.search(r"(?m)^ERROR", out):
                raise RuntimeError(f"compile failed: {src.name}: {re.search(r'(?m)^ERROR.*', out).group(0)}")
        _, out = run([tool(sim, "xelab"), top, "-s", "snap", "-timescale", "1ns/1ps"], work, work / "xelab.log")
        if re.search(r"(?m)^ERROR", out):
            raise RuntimeError(f"elaboration failed: {re.search(r'(?m)^ERROR.*', out).group(0)}")
        (work / "run.tcl").write_text("run all\nquit\n")
        run([tool(sim, "xsim"), "snap", "-tclbatch", "run.tcl", "-log", "sim.log"], work, work / "xsim.out")
    return (work / "sim.log").read_text(errors="ignore")


# ---------------------------------------------------------------------------
def check_reference() -> tuple[bool, str]:
    """The reference runs, and its final 16x16 output is the GOLDEN matrix tb_mlp_top.sv expects."""
    res = subprocess.run([sys.executable, str(REF / "mlp_reference.py")], cwd=REF,
                         capture_output=True, text=True)
    preds = re.findall(r"Audio Clip \d+: Predicted = '(\w+)'", res.stdout)
    if res.returncode != 0 or len(preds) != 16:
        return False, f"{len(preds)}/16 clips classified (exit {res.returncode})"
    printed = res.stdout.split("--- Final Batch Predictions ---")[0]
    reference = [int(v) for v in re.findall(r"-?\d+", printed[printed.rindex("[["):])]
    tb = (MLP / "tb" / "tb_mlp_top.sv").read_text()
    golden_block = re.search(r"GOLDEN \[0:15\]\[0:15\] = '\{(.*?)\};", tb, re.S).group(1)
    golden = [int(v) for v in re.findall(r"-?\d+", golden_block)]
    if reference != golden:
        return False, "tb_mlp_top.sv's GOLDEN differs from the reference output"
    return True, "16/16 clips classified; the testbench's expected output is the reference's"


def check_bram_image() -> tuple[bool, str]:
    # regenerate into a scratch copy of the reference/ + rtl/ layout so the committed image is untouched
    work = BUILD / "bram_image"
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(REF, work / "reference", ignore=shutil.ignore_patterns("__pycache__"))
    (work / "rtl").mkdir(parents=True)
    subprocess.run([sys.executable, str(work / "reference" / "gen_bram_init.py")], check=True, capture_output=True)
    norm = lambda p: p.read_bytes().replace(b"\r\n", b"\n").strip()
    if norm(work / "rtl" / "bram_init.hex") != norm(RTL / "bram_init.hex"):
        return False, "rtl/bram_init.hex differs from gen_bram_init.py output"
    return True, "rtl/bram_init.hex matches gen_bram_init.py output"


def check_fp32_vectors() -> tuple[bool, str]:
    d = REPO / "01-fp32-multiplier"
    out = BUILD / "fp32_vectors" / "fp32_vectors.hex"
    res = subprocess.run([sys.executable, str(d / "reference" / "fp32_reference.py"), "-o", str(out)],
                         capture_output=True, text=True)
    if res.returncode:
        return False, (res.stderr.strip().splitlines() or ["fp32_reference.py failed"])[-1]
    if out.read_bytes().replace(b"\r\n", b"\n") != (d / "vectors" / "fp32_vectors.hex").read_bytes().replace(b"\r\n", b"\n"):
        return False, "vectors/fp32_vectors.hex differs from fp32_reference.py output"
    return True, "vectors/fp32_vectors.hex matches fp32_reference.py output; model agrees with NumPy"


def check_fp32(sim: str | Path) -> tuple[bool, str]:
    d = REPO / "01-fp32-multiplier"
    work = BUILD / "fp32"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    shutil.copy(d / "vectors" / "fp32_vectors.hex", work / "fp32_vectors.hex")
    log = simulate("icarus" if sim == "oss" else sim, work,
                   [(d / "rtl" / "fp32_multiplier.v", False), (d / "tb" / "tb_fp32_multiplier.sv", True)],
                   "tb_fp32_multiplier")
    m = re.search(r"ALL PASSED: (\d+) vectors", log)
    fail = re.search(r"FAILED: (.*?) ----", log)
    return bool(m), (f"{m.group(1)} vectors passed" if m else f"FAILED: {fail.group(1) if fail else 'no result'}")


def check_pe_array(sim: str | Path) -> tuple[bool, str]:
    d = REPO / "02-systolic-array-8x8"
    work = BUILD / "pe_array"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    for f in ("tb_input.hex", "tb_weight.hex"):
        shutil.copy(d / "vectors" / f, work / f)
    log = simulate("icarus" if sim == "oss" else sim, work,
                   [(d / "rtl" / "pe.sv", True), (d / "rtl" / "systolic_array_8x8.sv", True),
                    (d / "tb" / "tb_systolic_array_8x8.sv", True)], "tb_systolic_array_8x8")
    ok = "PASS: all 64 outputs match" in log
    fail = re.search(r"FAIL: (.*)", log)
    return ok, ("64/64 outputs match the matrix product" if ok else (fail.group(1) if fail else "no result"))


def check_mlp(sim: str | Path) -> tuple[bool, str]:
    work = BUILD / "mlp"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    shutil.copy(RTL / "bram_init.hex", work / "bram_init.hex")
    design = [RTL / f for f in ("mlp_top.sv", "systolic_core.sv", "pe_array.sv", "pe.sv", "post_proc.sv",
                                "sequencer.sv", "skewer.sv")] + [MLP / "tb" / "tb_mlp_top.sv"]
    # Icarus Verilog does not parse this SystemVerilog, so the open-source run uses Verilator here
    log = simulate("verilator" if sim == "oss" else sim, work, [(f, True) for f in design], "tb_mlp_top")
    ok_clips = len(re.findall(r"clip\s+\d+:\s+\w+\s+\(class \d+\) OK", log))
    ok = "INTEGRATION TEST: PASS" in log and "byte check: PASS" in log
    return ok, f"256-byte check {'passed' if 'byte check: PASS' in log else 'FAILED'}, {ok_clips}/16 predictions match"


# ---------------------------------------------------------------------------
def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vivado", help="Vivado install directory (contains bin/xvlog)")
    ap.add_argument("--sim", choices=["xsim", "oss"],
                    help="xsim, or oss for Icarus Verilog and Verilator "
                         "(default: xsim if Vivado is found, otherwise oss)")
    ap.add_argument("--skip-hdl", action="store_true", help="run only the Python checks")
    args = ap.parse_args()

    checks = [("NumPy reference", check_reference), ("BRAM image", check_bram_image),
              ("FP32 vectors", check_fp32_vectors)]
    if not args.skip_hdl:
        bindir = find_vivado(args.vivado)
        sim = args.sim or ("xsim" if bindir else "oss")
        if sim == "xsim":
            if bindir is None:
                sys.exit("xvlog not found: pass --vivado <install dir>, put Vivado's bin/ on PATH, "
                         "or use --sim oss or --skip-hdl")
            hdl = bindir
        else:
            missing = [t for t in ("iverilog", "vvp", "verilator") if not shutil.which(t)]
            if missing:
                sys.exit(f"{', '.join(missing)} not found: install Icarus Verilog and Verilator, "
                         "pass --vivado <install dir>, or use --skip-hdl")
            hdl = "oss"
        print(f"HDL simulator: {'Vivado xsim' if sim == 'xsim' else 'Icarus Verilog and Verilator'}")
        checks += [("FP32 multiplier", lambda: check_fp32(hdl)),
                   ("8x8 systolic array", lambda: check_pe_array(hdl)),
                   ("MLP accelerator", lambda: check_mlp(hdl))]

    results = []
    for name, fn in checks:
        try:
            ok, note = fn()
        except Exception as exc:  # report and keep going so one failure doesn't hide the rest
            ok, note = False, str(exc)
        results.append((name, ok, note))
        print(f"{'PASS' if ok else 'FAIL'}  {name:20s} {note}", flush=True)

    sys.exit(0 if all(ok for _, ok, _ in results) else 1)


if __name__ == "__main__":
    main()
