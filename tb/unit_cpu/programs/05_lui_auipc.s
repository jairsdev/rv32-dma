# =============================================================================
# 05_lui_auipc.s - Instruções tipo U (imediato superior de 20 bits)
# Spec: riscv-spec.pdf, Seção 2.4 "Integer Computational Instructions"
#       (LUI e AUIPC)
# Instruções testadas: lui, auipc (+ addi para completar constantes)
# Foco: montagem de constantes de 32 bits com correção de sinal do addi e
#       cálculo de endereços relativos ao PC
# Convenção: x30 = nº do subteste atual | x31 = 1 sucesso, 0xBAD falha
# Obs.: "li xN, rotulo" carrega o endereço absoluto do rótulo (programa em 0x0)
# =============================================================================

        li   x31, 0

# --- 1: lui 0x12345 -> 0x12345000 (12 bits baixos zerados) --------------------
        li   x30, 1
        lui  x1, 0x12345
        li   x29, 0x12345000
        bne  x1, x29, falha

# --- 2: lui 0xFFFFF -> 0xFFFFF000 ---------------------------------------------
        li   x30, 2
        lui  x1, 0xFFFFF
        li   x29, -4096          # 0xFFFFF000
        bne  x1, x29, falha

# --- 3: lui + addi sem correção: 0x12345000 + 0x678 = 0x12345678 --------------
        li   x30, 3
        lui  x1, 0x12345
        addi x1, x1, 0x678
        li   x29, 0x12345678
        bne  x1, x29, falha

# --- 4: lui + addi com correção de sinal: 0xDEADBEEF ---------------------------
#     0xEEF tem o bit 11 = 1, logo addi soma -273; o lui precisa ser 0xDEADC
        li   x30, 4
        lui  x1, 0xDEADC
        addi x1, x1, -273
        li   x29, 0xDEADBEEF
        bne  x1, x29, falha

# --- 5: lui em x0 é ignorado ---------------------------------------------------
        li   x30, 5
        lui  x0, 0xABCDE
        bne  x0, x29, ok5        # x0 (0) != x29 -> segue
        j    falha
ok5:    add  x2, x0, x0
        bne  x2, x0, falha

# --- 6: auipc x1, 0 -> x1 = endereço da própria instrução ---------------------
        li   x30, 6
aqui:   auipc x1, 0
        li   x29, aqui
        bne  x1, x29, falha

# --- 7: auipc x1, 1 -> x1 = PC + 0x1000 ---------------------------------------
        li   x30, 7
aqui2:  auipc x1, 1
        li   x29, aqui2
        lui  x28, 1              # 0x1000
        add  x29, x29, x28
        bne  x1, x29, falha

# --- 8: auipc com imediato negativo: x1 = PC + 0xFFFFF000 = PC - 4096 ---------
        li   x30, 8
aqui3:  auipc x1, 0xFFFFF
        li   x29, aqui3
        li   x28, -4096
        add  x29, x29, x28
        bne  x1, x29, falha

# --- 9: la (auipc + addi) calcula o endereço do rótulo 'alvo' ------------------
        li   x30, 9
        la   x1, alvo
        li   x29, alvo
        bne  x1, x29, falha

# --- Fim ----------------------------------------------------------------------
        li   x31, 1
fim:    j    fim
falha:  li   x31, 0xBAD
        j    fim
alvo:   nop                      # apenas um endereço de referência
