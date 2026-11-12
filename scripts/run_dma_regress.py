#!/usr/bin/env python3
"""Regressao do DMA (MAS secao 16.3 e 16.4).

Matriz 16.3: casos 1 a 6 + 16x16x16  x  T = 2, 4, 8  x  PINGPONG = 0, 1
             x  {sem backpressure, backpressure aleatoria com 3 sementes}
             = 7 x 3 x 2 x 4 = 168 execucoes do tb_dma.
Testes 16.4: TEST = 1 ... 9 para T = 2, 4, 8 e PINGPONG = 0, 1 (caso 3).
Criterio 16.5: PINGPONG = 1 com CYCLES <= PINGPONG = 0 em todos os casos sem
backpressure, e estritamente menor quando ha mais de um bloco.

Uso:
    python3 scripts/run_dma_regress.py            # tudo
    python3 scripts/run_dma_regress.py --quick    # so sem backpressure, sem 16.4
    python3 scripts/run_dma_regress.py --jobs 8
"""

import argparse
import concurrent.futures as cf
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build")

# (nome, argumentos do golden, M, K, N)
CASES = [
    ("caso1", ["--case", "1"], 2, 2, 2),
    ("caso2", ["--case", "2"], 4, 4, 4),
    ("caso3", ["--case", "3"], 6, 5, 7),
    ("caso4", ["--case", "4"], 8, 8, 8),
    ("caso5", ["--case", "5"], 1, 1, 1),
    ("caso6", ["--case", "6"], 3, 64, 3),
    ("16x16x16", ["--m", "16", "--k", "16", "--n", "16"], 16, 16, 16),
]
TS = [2, 4, 8]
PPS = [0, 1]
STALL_SEEDS = [None, 1, 2, 3]       # None = sem backpressure
ERROR_TESTS = list(range(1, 10))

TB_FILES = [
    "tb/unit_dma/tb_dma.v",
    "tb/common/axi_checker.v",
    "tb/common/axi_rand_stall.v",
    "tb/common/axi_master_bfm.v",
    "tb/models/axi_mem_model.v",
    "tb/models/accel_model.v",
]

FAIL_PATTERNS = re.compile(r"FAIL|FALHA|VIOLACAO|ERRO|ERROR|timeout", re.IGNORECASE)


def rtl_files():
    with open(os.path.join(ROOT, "rtl/dma/dma.f")) as f:
        return [line.strip() for line in f if line.strip()]


def run(cmd, timeout=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)


def gen_vectors(name, args, seed):
    out = os.path.join(BUILD, "vec", f"{name}_s{seed}")
    if not os.path.exists(os.path.join(out, "c_expected.hex")):
        r = run([sys.executable, "model/golden.py", *args, "--seed", str(seed),
                 "--out-dir", out])
        if r.returncode != 0:
            raise RuntimeError(f"golden.py falhou para {name}: {r.stderr}")
    return out


def compile_tb(t, pp):
    out = os.path.join(BUILD, f"tb_dma_T{t}_PP{pp}.vvp")
    r = run(["iverilog", "-g2012", "-Wall", "-DDMA_ASSERT", "-I", "rtl/common",
             "-P", f"tb_dma.ARRAY_SIZE={t}", "-P", f"tb_dma.PINGPONG={pp}",
             "-o", out, *TB_FILES, *rtl_files()])
    warnings = [l for l in r.stderr.splitlines() if "timescale" not in l and l.strip()]
    if r.returncode != 0 or warnings:
        raise RuntimeError(f"compilacao T={t} PP={pp}:\n" + "\n".join(warnings))
    return out


def sim(vvp, plusargs):
    try:
        r = run(["vvp", "-n", vvp, *plusargs], timeout=1800)
    except subprocess.TimeoutExpired:
        return False, None, "timeout"
    out = r.stdout + r.stderr
    passed = (": PASS" in out) and not any(
        FAIL_PATTERNS.search(l) for l in out.splitlines() if ": PASS" not in l)
    m = re.search(r"PASS CYCLES=(\d+)", out)
    cycles = int(m.group(1)) if m else None
    bad = [l for l in out.splitlines() if FAIL_PATTERNS.search(l)][:5]
    return passed, cycles, "\n".join(bad)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true",
                    help="so a matriz sem backpressure, sem os testes 16.4")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    args = ap.parse_args()

    os.makedirs(BUILD, exist_ok=True)

    print("Compilando o tb_dma (6 configuracoes)...")
    vvps = {(t, pp): compile_tb(t, pp) for t in TS for pp in PPS}

    print("Gerando vetores com model/golden.py...")
    seeds = [None] if args.quick else STALL_SEEDS
    vec = {}
    for name, gargs, *_ in CASES:
        for s in seeds:
            vs = 1 if s is None else s
            vec[(name, vs)] = gen_vectors(name, gargs, vs)

    jobs = []
    # Matriz 16.3
    for name, _, m, k, n in CASES:
        for t in TS:
            for pp in PPS:
                for s in seeds:
                    vs = 1 if s is None else s
                    d = vec[(name, vs)]
                    plus = [f"+DMEM={d}/dmem.hex", f"+CEXP={d}/c_expected.hex",
                            f"+M={m}", f"+K={k}", f"+N={n}", "+TEST=0"]
                    if s is not None:
                        plus += ["+STALL", f"+SEED={s}"]
                    jobs.append(("16.3", name, t, pp, s, 0, vvps[(t, pp)], plus))
    # Testes 16.4
    if not args.quick:
        d = vec[("caso3", 1)]
        for t in TS:
            for pp in PPS:
                for tst in ERROR_TESTS:
                    step = {2: 4, 4: 2, 8: 1}[t]   # varredura do teste 6
                    plus = [f"+DMEM={d}/dmem.hex", f"+CEXP={d}/c_expected.hex",
                            "+M=6", "+K=5", "+N=7", f"+TEST={tst}", f"+SR_STEP={step}"]
                    jobs.append(("16.4", "caso3", t, pp, None, tst, vvps[(t, pp)], plus))

    print(f"Executando {len(jobs)} simulacoes com {args.jobs} processos...")
    results = []
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {ex.submit(sim, j[6], j[7]): j for j in jobs}
        for f in cf.as_completed(futs):
            j = futs[f]
            ok, cyc, msg = f.result()
            results.append((j, ok, cyc, msg))
            if not ok:
                print(f"  FAIL {j[0]} {j[1]} T={j[2]} PP={j[3]} seed={j[4]} TEST={j[5]}\n    {msg}")

    # ---------------- Relatorio ----------------
    fails = [r for r in results if not r[1]]
    n163 = [r for r in results if r[0][0] == "16.3"]
    n164 = [r for r in results if r[0][0] == "16.4"]
    print()
    print(f"Matriz 16.3: {sum(r[1] for r in n163)}/{len(n163)} PASS")
    if n164:
        print(f"Testes 16.4: {sum(r[1] for r in n164)}/{len(n164)} PASS")

    # CYCLES sem backpressure: PINGPONG 0 x 1
    cyc = {(r[0][1], r[0][2], r[0][3]): r[2]
           for r in n163 if r[0][4] is None and r[1]}
    print()
    print("CYCLES sem backpressure (PINGPONG=0 / PINGPONG=1, ganho):")
    print(f"  {'caso':10s} " + " ".join(f"{'T=' + str(t):>22s}" for t in TS))
    pp_fail = 0
    for name, _, m, k, n in CASES:
        cells = []
        for t in TS:
            c0, c1 = cyc.get((name, t, 0)), cyc.get((name, t, 1))
            if c0 is None or c1 is None:
                cells.append(f"{'-':>22s}")
                continue
            blocks = -(-m // t) * -(-n // t) * -(-k // t)
            if c1 > c0 or (blocks > 1 and c1 >= c0):
                pp_fail += 1
                print(f"  FAIL 16.5: {name} T={t}: PP1={c1} PP0={c0} (blocos={blocks})")
            gain = 100.0 * (c0 - c1) / c0
            cells.append(f"{c0:>7d} / {c1:>6d} {gain:5.1f}%")
        print(f"  {name:10s} " + " ".join(cells))

    total_fail = len(fails) + pp_fail
    print()
    print("REGRESSAO: " + ("PASS" if total_fail == 0 else f"FAIL ({total_fail})"))
    return 0 if total_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
