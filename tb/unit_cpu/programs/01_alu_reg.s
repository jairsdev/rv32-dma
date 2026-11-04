# =============================================================================
# 01_alu_reg.s - Operações aritméticas e lógicas registrador-registrador
# Spec: riscv-spec.pdf, Seção 2.4 "Integer Computational Instructions"
#       (Integer Register-Register Operations)
# Instruções testadas: add, sub, and, or, xor
# Convenção: x30 = nº do subteste atual | x31 = 1 sucesso, 0xBAD falha
# Pré-requisitos usados na verificação: addi/lui (li), bne, jal (j)
# =============================================================================

        li   x31, 0              # status = 0 (em execução)

# --- 1: add simples 5 + 7 = 12 -----------------------------------------------
        li   x30, 1
        li   x1, 5
        li   x2, 7
        add  x3, x1, x2
        li   x29, 12
        bne  x3, x29, falha

# --- 2: add com operando negativo: -3 + 10 = 7 --------------------------------
        li   x30, 2
        li   x1, -3
        li   x2, 10
        add  x3, x1, x2
        li   x29, 7
        bne  x3, x29, falha

# --- 3: overflow sem exceção: 0x7FFFFFFF + 1 = 0x80000000 ---------------------
        li   x30, 3
        li   x1, 0x7FFFFFFF
        li   x2, 1
        add  x3, x1, x2
        li   x29, 0x80000000
        bne  x3, x29, falha

# --- 4: sub 10 - 3 = 7 --------------------------------------------------------
        li   x30, 4
        li   x1, 10
        li   x2, 3
        sub  x3, x1, x2
        li   x29, 7
        bne  x3, x29, falha

# --- 5: sub com resultado negativo: 3 - 10 = -7 (0xFFFFFFF9) -----------------
        li   x30, 5
        sub  x3, x2, x1
        li   x29, -7
        bne  x3, x29, falha

# --- 6: sub com wrap-around: 0 - 0x80000000 = 0x80000000 ---------------------
        li   x30, 6
        li   x1, 0x80000000
        sub  x3, x0, x1
        li   x29, 0x80000000
        bne  x3, x29, falha

# --- 7: and 0xF0F0F0F0 & 0x0FF00FF0 = 0x00F000F0 ------------------------------
        li   x30, 7
        li   x1, 0xF0F0F0F0
        li   x2, 0x0FF00FF0
        and  x3, x1, x2
        li   x29, 0x00F000F0
        bne  x3, x29, falha

# --- 8: or  0xF0F0F0F0 | 0x0FF00FF0 = 0xFFF0FFF0 ------------------------------
        li   x30, 8
        or   x3, x1, x2
        li   x29, 0xFFF0FFF0
        bne  x3, x29, falha

# --- 9: xor 0xF0F0F0F0 ^ 0x0FF00FF0 = 0xFF00FF00 ------------------------------
        li   x30, 9
        xor  x3, x1, x2
        li   x29, 0xFF00FF00
        bne  x3, x29, falha

# --- 10: xor de um registrador com ele mesmo = 0 ------------------------------
        li   x30, 10
        xor  x3, x1, x1
        bne  x3, x0, falha

# --- 11: escrita em x0 é ignorada (x0 sempre vale 0) --------------------------
        li   x30, 11
        add  x0, x1, x2
        add  x3, x0, x0
        bne  x3, x0, falha

# --- 12: rd igual a rs1 e rs2 (x4 = x4 + x4) ----------------------------------
        li   x30, 12
        li   x4, 21
        add  x4, x4, x4
        li   x29, 42
        bne  x4, x29, falha

# --- Fim ----------------------------------------------------------------------
        li   x31, 1              # todos os subtestes passaram
fim:    j    fim                 # parada: laço infinito
falha:  li   x31, 0xBAD          # x30 indica o subteste que falhou
        j    fim
