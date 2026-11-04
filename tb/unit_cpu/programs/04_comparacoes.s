# =============================================================================
# 04_comparacoes.s - Comparações "set less than" com e sem sinal
# Spec: riscv-spec.pdf, Seção 2.4 "Integer Computational Instructions"
# Instruções testadas: slt, sltu, slti, sltiu
# Foco: o mesmo padrão de bits dá resultados diferentes em comparação
#       com sinal (complemento de 2) e sem sinal
# Convenção: x30 = nº do subteste atual | x31 = 1 sucesso, 0xBAD falha
# =============================================================================

        li   x31, 0
        li   x1, -1              # 0xFFFFFFFF
        li   x2, 1
        li   x28, 1              # constante 1 para comparação

# --- 1: slt  -1 < 1 (com sinal) = 1 -------------------------------------------
        li   x30, 1
        slt  x3, x1, x2
        bne  x3, x28, falha

# --- 2: sltu 0xFFFFFFFF < 1 (sem sinal) = 0 -----------------------------------
        li   x30, 2
        sltu x3, x1, x2
        bne  x3, x0, falha

# --- 3: slt  1 < -1 (com sinal) = 0 -------------------------------------------
        li   x30, 3
        slt  x3, x2, x1
        bne  x3, x0, falha

# --- 4: sltu 1 < 0xFFFFFFFF (sem sinal) = 1 -----------------------------------
        li   x30, 4
        sltu x3, x2, x1
        bne  x3, x28, falha

# --- 5: slt com valores iguais: 5 < 5 = 0 -------------------------------------
        li   x30, 5
        li   x4, 5
        li   x5, 5
        slt  x3, x4, x5
        bne  x3, x0, falha

# --- 6: slti -1 < 0 = 1 -------------------------------------------------------
        li   x30, 6
        slti x3, x1, 0
        bne  x3, x28, falha

# --- 7: slti 5 < -3 = 0 -------------------------------------------------------
        li   x30, 7
        slti x3, x4, -3
        bne  x3, x0, falha

# --- 8: sltiu x0 < 1 = 1 (idioma "seqz": rd = (rs1 == 0)) ---------------------
        li   x30, 8
        sltiu x3, x0, 1
        bne  x3, x28, falha

# --- 9: sltiu 7 < 1 = 0 (7 não é zero) -----------------------------------------
        li   x30, 9
        li   x6, 7
        sltiu x3, x6, 1
        bne  x3, x0, falha

# --- 10: sltiu 1 < -1: imediato estendido vira 0xFFFFFFFF (sem sinal) = 1 -----
        li   x30, 10
        sltiu x3, x2, -1
        bne  x3, x28, falha

# --- 11: slt  0x80000000 (mínimo) < 0x7FFFFFFF (máximo) = 1 -------------------
        li   x30, 11
        li   x7, 0x80000000
        li   x8, 0x7FFFFFFF
        slt  x3, x7, x8
        bne  x3, x28, falha

# --- 12: sltu 0x80000000 < 0x7FFFFFFF = 0 -------------------------------------
        li   x30, 12
        sltu x3, x7, x8
        bne  x3, x0, falha

# --- 13: sltu x0 < rs2 = 1 se rs2 != 0 (idioma "snez") ------------------------
        li   x30, 13
        sltu x3, x0, x6
        bne  x3, x28, falha

# --- Fim ----------------------------------------------------------------------
        li   x31, 1
fim:    j    fim
falha:  li   x31, 0xBAD
        j    fim
