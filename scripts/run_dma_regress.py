#!/usr/bin/env python3

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
STALL_SEEDS = [None, 1, 2, 3]       # None roda sem backpressure
ERROR_TESTS = list(range(1, 10))

TB_FILES = [
    "tb/unit_dma/tb_dma.v",
    "tb/common/axi_checker.v",
    "tb/common/axi_rand_stall.v",
    "tb/common/axi_master_bfm.v",
    "rtl/accel/accel.v",
    "rtl/accel/pe.v",
]

FAIL_PATTERNS = re.compile(r"FAIL|FALHA|VIOLACAO|ERRO|ERROR|timeout", re.IGNORECASE)

SIM = "icarus"
MEM = "ctrl"        # DMEM: ctrl (rtl/top/axi_mem_ctrl) ou model (tb/models/axi_mem_model.v)


def rtl_files():
    with open(os.path.join(ROOT, "rtl/dma/dma.f")) as f:
        return [line.strip() for line in f if line.strip()]


# Arquivos da DMEM. No ctrl, a ordem da filelist importa: os nossos arquivos
# vem antes dos copiados, que nao tem `timescale e herdam o deles.
def mem_files():
    if MEM == "model":
        return ["tb/models/axi_mem_model.v"]
    with open(os.path.join(ROOT, "rtl/top/axi_mem_ctrl.f")) as f:
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


# Compila uma vez por configuracao e devolve o que o sim() precisa para rodar:
# o .vvp no Icarus ou o diretorio do snapshot no Xcelium.
def compile_tb(t, pp):
    if SIM == "xcelium":
        lib = os.path.join(BUILD, f"xcelium_T{t}_PP{pp}_{MEM}")
        mem_def = ["-define", "MEM_CTRL"] if MEM == "ctrl" else []
        r = run(["xrun", "-q", "-sv", "-elaborate", "-define", "DMA_ASSERT", *mem_def,
                 "-incdir", "rtl/common", "-top", "tb_dma",
                 "-defparam", f"tb_dma.ARRAY_SIZE={t}", "-defparam", f"tb_dma.PINGPONG={pp}",
                 "-xmlibdirname", lib, "-l", lib + ".log",
                 *TB_FILES, *rtl_files(), *mem_files()])
        msgs = [l for l in (r.stdout + r.stderr).splitlines() if re.search(r"\*[WEF],", l)]
    else:
        lib = os.path.join(BUILD, f"tb_dma_T{t}_PP{pp}_{MEM}.vvp")
        mem_def = ["-DMEM_CTRL"] if MEM == "ctrl" else []
        r = run(["iverilog", "-g2012", "-Wall", "-DDMA_ASSERT", *mem_def, "-I", "rtl/common",
                 "-P", f"tb_dma.ARRAY_SIZE={t}", "-P", f"tb_dma.PINGPONG={pp}",
                 "-o", lib, *TB_FILES, *rtl_files(), *mem_files()])
        msgs = [l for l in r.stderr.splitlines() if "timescale" not in l and l.strip()]
    # aviso conta como erro: o criterio da equipe e compilar limpo
    if r.returncode != 0 or msgs:
        raise RuntimeError(f"compilacao T={t} PP={pp} ({SIM}, MEM={MEM}):\n" + "\n".join(msgs[:20]))
    return lib


def sim(lib, plusargs):
    if SIM == "xcelium":
        cmd = ["xrun", "-q", "-R", "-xmlibdirname", lib, "-nolog", *plusargs]
    else:
        cmd = ["vvp", "-n", lib, *plusargs]
    try:
        r = run(cmd, timeout=1800)
    except subprocess.TimeoutExpired:
        return "FAIL", None, "timeout"
    out = r.stdout + r.stderr
    clean = not any(FAIL_PATTERNS.search(l) for l in out.splitlines()
                    if ": PASS" not in l and ": SKIP" not in l)
    # SKIP: o teste nao se aplica a esta DMEM (teste 4 da 16.4 com MEM=ctrl)
    if ": SKIP" in out and clean:
        status = "SKIP"
    elif ": PASS" in out and clean:
        status = "PASS"
    else:
        status = "FAIL"
    m = re.search(r"PASS CYCLES=(\d+)", out)
    cycles = int(m.group(1)) if m else None
    bad = [l for l in out.splitlines() if FAIL_PATTERNS.search(l)][:5]
    return status, cycles, "\n".join(bad)


def count(rs):
    n_pass = sum(r[1] == "PASS" for r in rs)
    n_skip = sum(r[1] == "SKIP" for r in rs)
    line = f"{n_pass}/{len(rs) - n_skip} PASS"
    return line + (f", {n_skip} SKIP" if n_skip else "")


def main():
    global SIM, MEM
    ap = argparse.ArgumentParser(description="Regressao do TB-DMA (MAS 16.3, 16.4 e 16.5)")
    ap.add_argument("--quick", action="store_true",
                    help="so a matriz sem backpressure, sem os testes da 16.4")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--sim", choices=["icarus", "xcelium"], default="icarus",
                    help="simulador (default: icarus)")
    ap.add_argument("--mem", choices=["ctrl", "model"], default="ctrl",
                    help="DMEM: axi_mem_ctrl ou axi_mem_model (default: ctrl)")
    args = ap.parse_args()
    SIM = args.sim
    MEM = args.mem

    os.makedirs(BUILD, exist_ok=True)

    print(f"Compilando o tb_dma nas 6 configuracoes ({SIM}, MEM={MEM})...")
    libs = {(t, pp): compile_tb(t, pp) for t in TS for pp in PPS}

    print("Gerando os vetores com model/golden.py...")
    seeds = [None] if args.quick else STALL_SEEDS
    vec = {}
    for name, gargs, *_ in CASES:
        for s in seeds:
            vs = 1 if s is None else s
            vec[(name, vs)] = gen_vectors(name, gargs, vs)

    jobs = []
    # matriz da 16.3: todos os casos em todas as configuracoes
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
                    jobs.append(("16.3", name, t, pp, s, 0, libs[(t, pp)], plus))
    # testes de erro e dreno da 16.4, sempre com o caso 3
    if not args.quick:
        d = vec[("caso3", 1)]
        for t in TS:
            for pp in PPS:
                for tst in ERROR_TESTS:
                    step = {2: 4, 4: 2, 8: 1}[t]   # passo da varredura do teste 6
                    plus = [f"+DMEM={d}/dmem.hex", f"+CEXP={d}/c_expected.hex",
                            "+M=6", "+K=5", "+N=7", f"+TEST={tst}", f"+SR_STEP={step}"]
                    jobs.append(("16.4", "caso3", t, pp, None, tst, libs[(t, pp)], plus))

    print(f"Rodando {len(jobs)} simulacoes com {args.jobs} processos...")
    results = []
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {ex.submit(sim, j[6], j[7]): j for j in jobs}
        for f in cf.as_completed(futs):
            j = futs[f]
            st, cyc, msg = f.result()
            results.append((j, st, cyc, msg))
            if st == "FAIL":
                print(f"  FAIL {j[0]} {j[1]} T={j[2]} PP={j[3]} seed={j[4]} TEST={j[5]}\n    {msg}")

    fails = [r for r in results if r[1] == "FAIL"]
    n163 = [r for r in results if r[0][0] == "16.3"]
    n164 = [r for r in results if r[0][0] == "16.4"]
    print()
    print(f"Matriz 16.3: {count(n163)}")
    if n164:
        print(f"Testes 16.4: {count(n164)}")

    # Criterio 16.5: sem backpressure, PINGPONG = 1 nunca pode ser mais lento que
    # PINGPONG = 0, e tem que ser mais rapido quando ha mais de um bloco
    cyc = {(r[0][1], r[0][2], r[0][3]): r[2]
           for r in n163 if r[0][4] is None and r[1] == "PASS"}
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
