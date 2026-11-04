# =============================================================================
# 02_alu_imm.s - Operações com imediato de 12 bits (tipo I)
# Spec: riscv-spec.pdf, Seção 2.4 "Integer Computational Instructions"
#       (Integer Register-Immediate Instructions)
# Instruções testadas: addi, andi, ori, xori
# Foco: extensão de sinal do imediato de 12 bits (faixa -2048..2047)
# Convenção: x30 = nº do subteste atual | x31 = 1 sucesso, 0xBAD falha
# =============================================================================

        li   x31, 0

# --- 1: addi com o maior imediato positivo: 0 + 2047 = 0x7FF ------------------
        li   x30, 1
        addi x1, x0, 2047
        li   x29, 0x7FF
        bne  x1, x29, falha

# --- 2: addi com o menor imediato: 0 + (-2048) = 0xFFFFF800 -------------------
        li   x30, 2
        addi x1, x0, -2048
        li   x29, 0xFFFFF800
        bne  x1, x29, falha

# --- 3: addi negativo sobre valor positivo: 100 + (-1) = 99 -------------------
        li   x30, 3
        addi x1, x0, 100
        addi x2, x1, -1
        li   x29, 99
        bne  x2, x29, falha

# --- 4: addi com wrap-around: 0xFFFFFFFF + 1 = 0 ------------------------------
        li   x30, 4
        addi x1, x0, -1
        addi x2, x1, 1
        bne  x2, x0, falha

# --- 5: andi com máscara positiva: 0x12345678 & 0x0FF = 0x78 ------------------
        li   x30, 5
        li   x1, 0x12345678
        andi x2, x1, 0xFF
        li   x29, 0x78
        bne  x2, x29, falha

# --- 6: andi com -1 (0xFFFFFFFF após extensão) não altera o valor -------------
        li   x30, 6
        andi x2, x1, -1
        bne  x2, x1, falha

# --- 7: andi com -16 (0xFFFFFFF0) zera só os 4 bits baixos --------------------
        li   x30, 7
        andi x2, x1, -16
        li   x29, 0x12345670
        bne  x2, x29, falha

# --- 8: ori 0x12345600 | 0x0FF = 0x123456FF -----------------------------------
        li   x30, 8
        li   x1, 0x12345600
        ori  x2, x1, 0xFF
        li   x29, 0x123456FF
        bne  x2, x29, falha

# --- 9: ori com imediato negativo: 0x12345600 | 0xFFFFF800 = 0xFFFFFE00 -------
        li   x30, 9
        ori  x2, x1, -2048
        li   x29, 0xFFFFFE00
        bne  x2, x29, falha

# --- 10: xori com -1 equivale a NOT: ~0x12345678 = 0xEDCBA987 -----------------
        li   x30, 10
        li   x1, 0x12345678
        xori x2, x1, -1
        li   x29, 0xEDCBA987
        bne  x2, x29, falha

# --- 11: xori 0x55555555 ^ 0x555 = 0x55555000 ---------------------------------
        li   x30, 11
        li   x1, 0x55555555
        xori x2, x1, 0x555
        li   x29, 0x55555000
        bne  x2, x29, falha

# --- 12: addi x0, x0, 5 não altera x0 (forma de NOP) ---------------------------
        li   x30, 12
        addi x0, x0, 5
        addi x2, x0, 0
        bne  x2, x0, falha

# --- Fim ----------------------------------------------------------------------
        li   x31, 1
fim:    j    fim
falha:  li   x31, 0xBAD
        j    fim
