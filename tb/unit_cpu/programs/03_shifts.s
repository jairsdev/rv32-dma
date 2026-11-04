# =============================================================================
# 03_shifts.s - Deslocamentos lógicos e aritméticos
# Spec: riscv-spec.pdf, Seção 2.4 "Integer Computational Instructions"
# Instruções testadas: slli, srli, srai, sll, srl, sra
# Foco: shamt 0 e 31, preservação do sinal em srai/sra e uso apenas dos
#       5 bits baixos de rs2 nos deslocamentos por registrador
# Convenção: x30 = nº do subteste atual | x31 = 1 sucesso, 0xBAD falha
# =============================================================================

        li   x31, 0

# --- 1: slli 1 << 31 = 0x80000000 ---------------------------------------------
        li   x30, 1
        li   x1, 1
        slli x2, x1, 31
        li   x29, 0x80000000
        bne  x2, x29, falha

# --- 2: slli com shamt 0 não altera o valor -----------------------------------
        li   x30, 2
        li   x1, 0x12345678
        slli x2, x1, 0
        bne  x2, x1, falha

# --- 3: srli 0x80000000 >> 31 = 1 (preenche com zeros) ------------------------
        li   x30, 3
        li   x1, 0x80000000
        srli x2, x1, 31
        li   x29, 1
        bne  x2, x29, falha

# --- 4: srai 0x80000000 >> 31 = 0xFFFFFFFF (replica o bit de sinal) -----------
        li   x30, 4
        srai x2, x1, 31
        li   x29, -1
        bne  x2, x29, falha

# --- 5: srai de número positivo: 0x40000000 >> 30 = 1 -------------------------
        li   x30, 5
        li   x1, 0x40000000
        srai x2, x1, 30
        li   x29, 1
        bne  x2, x29, falha

# --- 6: srli 0xF0000000 >> 4 = 0x0F000000 -------------------------------------
        li   x30, 6
        li   x1, 0xF0000000
        srli x2, x1, 4
        li   x29, 0x0F000000
        bne  x2, x29, falha

# --- 7: srai 0xF0000000 >> 4 = 0xFF000000 -------------------------------------
        li   x30, 7
        srai x2, x1, 4
        li   x29, 0xFF000000
        bne  x2, x29, falha

# --- 8: sll por registrador: 1 << 4 = 16 --------------------------------------
        li   x30, 8
        li   x1, 1
        li   x3, 4
        sll  x2, x1, x3
        li   x29, 16
        bne  x2, x29, falha

# --- 9: sll usa só rs2[4:0]: 1 << 33 equivale a 1 << 1 = 2 --------------------
        li   x30, 9
        li   x3, 33
        sll  x2, x1, x3
        li   x29, 2
        bne  x2, x29, falha

# --- 10: srl usa só rs2[4:0]: 0x80000000 >> 63 equivale a >> 31 = 1 -----------
        li   x30, 10
        li   x1, 0x80000000
        li   x3, 63
        srl  x2, x1, x3
        li   x29, 1
        bne  x2, x29, falha

# --- 11: sra 0x80000000 >> 1 = 0xC0000000 -------------------------------------
        li   x30, 11
        li   x3, 1
        sra  x2, x1, x3
        li   x29, 0xC0000000
        bne  x2, x29, falha

# --- 12: sra de positivo: 0x7FFFFFFF >> 31 = 0 --------------------------------
        li   x30, 12
        li   x1, 0x7FFFFFFF
        li   x3, 31
        sra  x2, x1, x3
        bne  x2, x0, falha

# --- 13: sll com rs2 negativo 0xFFFFFFE4 (bits baixos = 4): 1 << 4 = 16 -------
        li   x30, 13
        li   x1, 1
        li   x3, -28             # 0xFFFFFFE4
        sll  x2, x1, x3
        li   x29, 16
        bne  x2, x29, falha

# --- Fim ----------------------------------------------------------------------
        li   x31, 1
fim:    j    fim
falha:  li   x31, 0xBAD
        j    fim
