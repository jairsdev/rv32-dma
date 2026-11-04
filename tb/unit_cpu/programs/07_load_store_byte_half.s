# =============================================================================
# 07_load_store_byte_half.s - Acessos de 8 e 16 bits
# Spec: riscv-spec.pdf, Seção 2.6 "Load and Store Instructions"
# Instruções testadas: lb, lbu, lh, lhu, sb, sh (+ sw/lw de apoio)
# Foco: extensão de sinal (lb/lh) x extensão com zeros (lbu/lhu), ordem
#       little-endian e escrita parcial sem corromper os bytes vizinhos
# Área de dados: 0x400 a 0x40F
# Convenção: x30 = nº do subteste atual | x31 = 1 sucesso, 0xBAD falha
# =============================================================================

        li   x31, 0
        li   x10, 0x400

# Palavra 0x80FF7F01 em 0x400 -> bytes na memória (little-endian):
#   [0x400]=01  [0x401]=7F  [0x402]=FF  [0x403]=80
        li   x1, 0x80FF7F01
        sw   x1, 0(x10)

# --- 1: lb byte positivo 0x01 -> 0x00000001 -----------------------------------
        li   x30, 1
        lb   x2, 0(x10)
        li   x29, 0x01
        bne  x2, x29, falha

# --- 2: lb byte 0x7F (maior positivo) -> 0x0000007F ---------------------------
        li   x30, 2
        lb   x2, 1(x10)
        li   x29, 0x7F
        bne  x2, x29, falha

# --- 3: lb byte 0xFF -> 0xFFFFFFFF (estende o sinal) --------------------------
        li   x30, 3
        lb   x2, 2(x10)
        li   x29, -1
        bne  x2, x29, falha

# --- 4: lbu byte 0xFF -> 0x000000FF (estende com zeros) -----------------------
        li   x30, 4
        lbu  x2, 2(x10)
        li   x29, 0xFF
        bne  x2, x29, falha

# --- 5: lb byte 0x80 -> 0xFFFFFF80 --------------------------------------------
        li   x30, 5
        lb   x2, 3(x10)
        li   x29, 0xFFFFFF80
        bne  x2, x29, falha

# --- 6: lbu byte 0x80 -> 0x00000080 -------------------------------------------
        li   x30, 6
        lbu  x2, 3(x10)
        li   x29, 0x80
        bne  x2, x29, falha

# --- 7: lh meia-palavra baixa 0x7F01 -> 0x00007F01 ----------------------------
        li   x30, 7
        lh   x2, 0(x10)
        li   x29, 0x7F01
        bne  x2, x29, falha

# --- 8: lh meia-palavra alta 0x80FF -> 0xFFFF80FF -----------------------------
        li   x30, 8
        lh   x2, 2(x10)
        li   x29, 0xFFFF80FF
        bne  x2, x29, falha

# --- 9: lhu meia-palavra alta 0x80FF -> 0x000080FF ----------------------------
        li   x30, 9
        lhu  x2, 2(x10)
        li   x29, 0x80FF
        bne  x2, x29, falha

# --- 10: sb altera só 1 byte: 0x11223344 com sb 0xAA em +1 -> 0x1122AA44 ------
        li   x30, 10
        li   x1, 0x11223344
        sw   x1, 4(x10)
        li   x2, 0xAA
        sb   x2, 5(x10)
        lw   x3, 4(x10)
        li   x29, 0x1122AA44
        bne  x3, x29, falha

# --- 11: sh altera só 2 bytes: sh 0xBEEF em +2 -> 0xBEEFAA44 ------------------
        li   x30, 11
        li   x2, 0xBEEF
        sh   x2, 6(x10)
        lw   x3, 4(x10)
        li   x29, 0xBEEFAA44
        bne  x3, x29, falha

# --- 12: sb grava apenas o byte baixo do registrador (0x123456CC -> 0xCC) -----
        li   x30, 12
        li   x2, 0x123456CC
        sb   x2, 4(x10)
        lw   x3, 4(x10)
        li   x29, 0xBEEFAACC
        bne  x3, x29, falha

# --- 13: sh grava apenas 16 bits baixos (0xFFFF8001 -> 0x8001) e lh lê sinal --
        li   x30, 13
        li   x2, 0xFFFF8001
        sh   x2, 0(x10)
        lw   x3, 0(x10)
        li   x29, 0x80FF8001
        bne  x3, x29, falha
        lh   x4, 0(x10)
        bne  x4, x2, falha       # lh devolve 0xFFFF8001

# --- 14: sb com offset negativo: -1(0x408) = 0x407 (byte mais alto de 0x404) --
        li   x30, 14
        addi x11, x10, 8
        li   x2, 0x5A
        sb   x2, -1(x11)
        lw   x3, 4(x10)
        li   x29, 0x5AEFAACC
        bne  x3, x29, falha

# --- Fim ----------------------------------------------------------------------
        li   x31, 1
fim:    j    fim
falha:  li   x31, 0xBAD
        j    fim
