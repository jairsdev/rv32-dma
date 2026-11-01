#!/usr/bin/env python3
"""
Golden model para o coprocessador de multiplicacao matricial com DMA.
Simula a multiplicacao em blocos (tiling) do hardware e gera os arquivos
.hex para alimentar os testbenches e o ambiente de verificacao.
"""

import argparse
import math
import os
import random
import sys
from typing import List, Tuple, Dict, Optional

# Enderecos padrao da DMEM definidos na especificacao
DEFAULT_DMEM_BASE = 0x1000_0000
DEFAULT_ADDR_A    = 0x1000_1000
DEFAULT_ADDR_B    = 0x1000_4000
DEFAULT_ADDR_C    = 0x1000_8000
DMEM_SIZE_BYTES   = 0x1_0000  # 64 KiB
DMEM_WORDS        = DMEM_SIZE_BYTES // 4

Matrix = List[List[int]]


# Operacoes aritmeticas com sinal (int8 e int32)

def to_int8(val: int) -> int:
    val = val & 0xFF
    return val - 256 if val >= 128 else val


def to_int32(val: int) -> int:
    # Trunca para 32 bits com sinal em complemento de 2
    val = val & 0xFFFF_FFFF
    return val - 0x1_0000_0000 if val >= 0x8000_0000 else val


def to_hex32(val: int) -> str:
    return f"{val & 0xFFFF_FFFF:08x}"


# Funcoes utilitarias de matrizes

def create_matrix(rows: int, cols: int, init_val: int = 0) -> Matrix:
    return [[init_val for _ in range(cols)] for _ in range(rows)]


def generate_random_matrix(rows: int, cols: int, min_val: int = -128, max_val: int = 127) -> Matrix:
    return [[random.randint(min_val, max_val) for _ in range(cols)] for _ in range(rows)]


def print_matrix(mat: Matrix, name: str, max_rows: int = 8, max_cols: int = 8):
    rows = len(mat)
    cols = len(mat[0]) if rows > 0 else 0
    print(f"\n{name} ({rows}x{cols}):")
    r_limit = min(rows, max_rows)
    c_limit = min(cols, max_cols)

    for r in range(r_limit):
        row_str = " ".join(f"{mat[r][c]:6d}" for c in range(c_limit))
        if cols > max_cols:
            row_str += "  ..."
        print(f"  [{r:2d}] {row_str}")
    if rows > max_rows:
        print("  ...")


# Multiplicacao direta (referencia baseline)

def matmul_naive(A: Matrix, B: Matrix) -> Matrix:
    M = len(A)
    K = len(A[0])
    N = len(B[0])
    assert len(B) == K, f"Dimensoes divisiveis incorretas: A={M}x{K}, B={len(B)}x{N}"

    C = create_matrix(M, N, 0)
    for i in range(M):
        for j in range(N):
            acc = 0
            for k in range(K):
                acc = to_int32(acc + A[i][k] * B[k][j])
            C[i][j] = acc
    return C


# Multiplicacao em blocos (modelo exato do hardware)

def matmul_tiled(
    A: Matrix,
    B: Matrix,
    T: int,
    verbose: bool = False
) -> Tuple[Matrix, Dict[str, int]]:
    M = len(A)
    K = len(A[0])
    N = len(B[0])
    assert len(B) == K, f"Dimensao incompativel: A={M}x{K}, B={len(B)}x{N}"

    C = create_matrix(M, N, 0)

    num_tiles_m = math.ceil(M / T)
    num_tiles_n = math.ceil(N / T)
    num_tiles_k = math.ceil(K / T)
    total_compute_tiles = num_tiles_m * num_tiles_n * num_tiles_k

    # Latencia estimada no hardware: 3T - 1 ciclos por tile de calculo
    tile_cycles = 3 * T - 1
    total_cycles = total_compute_tiles * tile_cycles

    stats = {
        "M": M,
        "N": N,
        "K": K,
        "T": T,
        "tiles_m": num_tiles_m,
        "tiles_n": num_tiles_n,
        "tiles_k": num_tiles_k,
        "total_compute_tiles": total_compute_tiles,
        "accel_cycles_estimate": total_cycles,
    }

    if verbose:
        print(f"[tiling] matriz {M}x{K} * {K}x{N} em blocos {T}x{T} ({total_compute_tiles} tiles)")

    # Varre os blocos do tile de saida C (i0, j0)
    for i0 in range(0, M, T):
        for j0 in range(0, N, T):
            acc = create_matrix(T, T, 0)

            # Acumulacao interna na dimensao K (output-stationary)
            for k0 in range(0, K, T):
                # first_k indica o inicio da acumulacao para este bloco de C
                if k0 == 0:
                    acc = create_matrix(T, T, 0)

                # Preenche buffer A com zero-padding quando fora do limite
                buf_A = create_matrix(T, T, 0)
                for r in range(T):
                    for c in range(T):
                        if (i0 + r < M) and (k0 + c < K):
                            buf_A[r][c] = A[i0 + r][k0 + c]

                # Preenche buffer B com zero-padding
                buf_B = create_matrix(T, T, 0)
                for r in range(T):
                    for c in range(T):
                        if (k0 + r < K) and (j0 + c < N):
                            buf_B[r][c] = B[k0 + r][j0 + c]

                # Executa passos MAC na malha sistolica T x T
                for r in range(T):
                    for c in range(T):
                        soma = 0
                        for t in range(T):
                            soma += buf_A[r][t] * buf_B[t][c]
                        acc[r][c] = to_int32(acc[r][c] + soma)

            # Salva o resultado acumulado mascarando os limites reais de C
            for r in range(T):
                for c in range(T):
                    if (i0 + r < M) and (j0 + c < N):
                        C[i0 + r][j0 + c] = acc[r][c]

    return C, stats


# Formatacao e layout de memoria

def calculate_strides(K: int, N: int) -> Tuple[int, int, int]:
    # Linhas de A e B alinhadas em palavras de 4 bytes
    stride_a = math.ceil(K / 4) * 4
    stride_b = math.ceil(N / 4) * 4
    stride_c = 4 * N
    return stride_a, stride_b, stride_c


def pack_matrix_int8(matrix: Matrix, stride_bytes: int) -> List[int]:
    # Empacota 4 elementos int8 por palavra de 32 bits (little-endian)
    rows = len(matrix)
    cols = len(matrix[0]) if rows > 0 else 0
    words_per_row = stride_bytes // 4

    packed = []
    for r in range(rows):
        for w in range(words_per_row):
            b0 = matrix[r][4 * w + 0] & 0xFF if (4 * w + 0) < cols else 0
            b1 = matrix[r][4 * w + 1] & 0xFF if (4 * w + 1) < cols else 0
            b2 = matrix[r][4 * w + 2] & 0xFF if (4 * w + 2) < cols else 0
            b3 = matrix[r][4 * w + 3] & 0xFF if (4 * w + 3) < cols else 0
            word = (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
            packed.append(word)
    return packed


def generate_dmem_words(
    A: Matrix,
    B: Matrix,
    dmem_base: int = DEFAULT_DMEM_BASE,
    addr_a: int = DEFAULT_ADDR_A,
    addr_b: int = DEFAULT_ADDR_B,
) -> Dict[int, int]:
    K = len(A[0])
    N = len(B[0])
    stride_a, stride_b, _ = calculate_strides(K, N)

    packed_a = pack_matrix_int8(A, stride_a)
    packed_b = pack_matrix_int8(B, stride_b)

    offset_a_words = (addr_a - dmem_base) // 4
    offset_b_words = (addr_b - dmem_base) // 4

    dmem = {}
    for i, w in enumerate(packed_a):
        dmem[offset_a_words + i] = w
    for i, w in enumerate(packed_b):
        dmem[offset_b_words + i] = w
    return dmem


def export_dmem_hex(dmem_map: Dict[int, int], filepath: str, full_dense: bool = False):
    os.makedirs(os.path.dirname(os.path.abspath(filepath)), exist_ok=True)
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(f"// Imagem da memoria DMEM para $readmemh (base 0x{DEFAULT_DMEM_BASE:08x})\n")

        if full_dense:
            for w in range(DMEM_WORDS):
                val = dmem_map.get(w, 0)
                f.write(f"{to_hex32(val)}\n")
        else:
            sorted_indices = sorted(dmem_map.keys())
            if not sorted_indices:
                return
            curr_addr = None
            for idx in sorted_indices:
                if curr_addr is None or idx != curr_addr:
                    f.write(f"\n@{idx:08x}\n")
                    curr_addr = idx
                f.write(f"{to_hex32(dmem_map[idx])}\n")
                curr_addr += 1


def export_c_expected_hex(C: Matrix, filepath: str):
    os.makedirs(os.path.dirname(os.path.abspath(filepath)), exist_ok=True)
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(f"// Matriz C esperada ({len(C)}x{len(C[0]) if C else 0}), int32 row-major\n")
        for row in C:
            for elem in row:
                f.write(f"{to_hex32(elem)}\n")


# Casos de teste da especificacao

def get_predefined_case(case_num: int, seed: Optional[int] = None) -> Tuple[Matrix, Matrix, int, str]:
    if seed is not None:
        random.seed(seed)

    if case_num == 1:
        # Cabe direto na malha
        M, K, N, T = 2, 2, 2, 2
        desc = "Caso 1 (2x2x2, T=2)"
        A = generate_random_matrix(M, K, -10, 10)
        B = generate_random_matrix(K, N, -10, 10)
    elif case_num == 2:
        # 1 tile exato para T=4
        M, K, N, T = 4, 4, 4, 4
        desc = "Caso 2 (4x4x4, T=4)"
        A = generate_random_matrix(M, K, -30, 30)
        B = generate_random_matrix(K, N, -30, 30)
    elif case_num == 3:
        # Dimensoes nao multiplas de T (valida padding e mascara)
        M, K, N, T = 6, 5, 7, 4
        desc = "Caso 3 (6x5x7, T=4: nao multiplo de T)"
        A = generate_random_matrix(M, K, -20, 20)
        B = generate_random_matrix(K, N, -20, 20)
    elif case_num == 4:
        # Valores extremos para checar saturacao/overflow
        M, K, N, T = 8, 8, 8, 4
        desc = "Caso 4 (8x8x8, T=4: valores extremos -128 e 127)"
        A = [[-128 if (i + k) % 2 == 0 else 127 for k in range(K)] for i in range(M)]
        B = [[127 if (k + j) % 2 == 0 else -128 for j in range(N)] for k in range(K)]
    elif case_num == 5:
        # Dimensao minima
        M, K, N, T = 1, 1, 1, 2
        desc = "Caso 5 (1x1x1, T=2: escalar)"
        A = [[42]]
        B = [[-3]]
    elif case_num == 6:
        # K longo acumulando muitos blocos
        M, K, N, T = 3, 64, 3, 4
        desc = "Caso 6 (3x64x3, T=4: K longo)"
        A = generate_random_matrix(M, K, -15, 15)
        B = generate_random_matrix(K, N, -15, 15)
    else:
        raise ValueError(f"Caso {case_num} invalido (1 a 6).")

    return A, B, T, desc


def run_all_tests() -> bool:
    print("Executando bateria de testes do golden model...")
    all_ok = True

    for c in range(1, 7):
        A, B, T, desc = get_predefined_case(c, seed=42 + c)
        C_naive = matmul_naive(A, B)
        C_tiled, stats = matmul_tiled(A, B, T=T)
        ok = (C_naive == C_tiled)
        if not ok:
            all_ok = False
        tag = "OK" if ok else "ERRO"
        print(f"  [{tag}] {desc} -> {stats['total_compute_tiles']} tiles, {stats['accel_cycles_estimate']} ciclos est.")

    # Testes parametricos com malhas de tamanhos diferentes
    extra = [(3, 3, 3, 2), (5, 4, 6, 2), (7, 9, 5, 4), (10, 10, 10, 8)]
    for m, k, n, t in extra:
        A = generate_random_matrix(m, k)
        B = generate_random_matrix(k, n)
        ok = (matmul_naive(A, B) == matmul_tiled(A, B, T=t)[0])
        if not ok:
            all_ok = False
        tag = "OK" if ok else "ERRO"
        print(f"  [{tag}] Matriz {m}x{k}x{n} com T={t}")

    print("\nResultado:", "Todos os testes passaram com sucesso." if all_ok else "Falha em testes.")
    return all_ok


def main():
    parser = argparse.ArgumentParser(description="Golden model do acelerador systolic array e DMA")
    parser.add_argument("--m", type=int, default=6, help="Linhas de A e C")
    parser.add_argument("--k", type=int, default=5, help="Colunas de A e linhas de B")
    parser.add_argument("--n", type=int, default=7, help="Colunas de B e C")
    parser.add_argument("--t", "--array-size", type=int, default=4, dest="t", help="Tamanho T da malha")
    parser.add_argument("--seed", type=int, default=1, help="Semente pseudoaleatoria")
    parser.add_argument("--case", type=int, choices=range(1, 7), default=None, help="Caso de teste (1 a 6)")
    parser.add_argument("--test-all", action="store_true", help="Roda todos os testes e sai")
    parser.add_argument("--out-dir", type=str, default="model", help="Diretorio de saida dos arquivos .hex")
    parser.add_argument("--dense", action="store_true", help="Gera dmem.hex completo de 64 KiB")
    parser.add_argument("--verbose", "-v", action="store_true", help="Exibe detalhes da execucao")
    parser.add_argument("--no-export", action="store_true", help="Nao grava arquivos .hex")

    args = parser.parse_args()

    if args.test_all:
        sys.exit(0 if run_all_tests() else 1)

    if args.case is not None:
        A, B, T, desc = get_predefined_case(args.case, seed=args.seed)
        M, K, N = len(A), len(A[0]), len(B[0])
        print(f"Rodando {desc}")
    else:
        M, K, N, T = args.m, args.k, args.n, args.t
        random.seed(args.seed)
        A = generate_random_matrix(M, K)
        B = generate_random_matrix(K, N)

    s_a, s_b, s_c = calculate_strides(K, N)
    print(f"Configuracao: {M}x{K} * {K}x{N} -> {M}x{N} (malha {T}x{T})")
    print(f"Strides: A={s_a}B, B={s_b}B, C={s_c}B")

    # Calcula naive e tiled
    C_naive = matmul_naive(A, B)
    C_tiled, stats = matmul_tiled(A, B, T=T, verbose=args.verbose)

    coincidem = (C_naive == C_tiled)
    print(f"Validacao: {'OK (resultados identicos)' if coincidem else 'ERRO (divergencia)'}")
    print(f"Tiles: {stats['total_compute_tiles']} | Estimativa acelerador: {stats['accel_cycles_estimate']} ciclos")

    if args.verbose or (M <= 8 and N <= 8 and K <= 8):
        print_matrix(A, "Matriz A")
        print_matrix(B, "Matriz B")
        print_matrix(C_tiled, "Matriz C")

    if not args.no_export:
        dmem_map = generate_dmem_words(A, B)
        dmem_path = os.path.join(args.out_dir, "dmem.hex")
        c_path = os.path.join(args.out_dir, "c_expected.hex")
        export_dmem_hex(dmem_map, dmem_path, full_dense=args.dense)
        export_c_expected_hex(C_tiled, c_path)
        print(f"\nArquivos salvos em '{args.out_dir}/': dmem.hex, c_expected.hex")

    if not coincidem:
        sys.exit(1)


if __name__ == "__main__":
    main()
