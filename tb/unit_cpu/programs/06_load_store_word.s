# =============================================================================
# 06_load_store_word.s - Acesso à memória com palavras de 32 bits
# Spec: riscv-spec.pdf, Seção 2.6 "Load and Store Instructions"
# Instruções testadas: sw, lw
# Foco: endereço = rs1 + offset de 12 bits com sinal, offsets positivos e
#       negativos, independência entre posições e cópia de vetor em laço
# Área de dados: 0x400 a 0x7FF (a memória precisa de pelo menos 2 KiB)
# Convenção: x30 = nº do subteste atual | x31 = 1 sucesso, 0xBAD falha
# =============================================================================

        li   x31, 0
        li   x10, 0x400          # base da área de dados

# --- 1: sw/lw no endereço base ------------------------------------------------
        li   x30, 1
        li   x1, 0x12345678
        sw   x1, 0(x10)
        lw   x2, 0(x10)
        bne  x2, x1, falha

# --- 2: sw/lw com offset positivo (0x404) -------------------------------------
        li   x30, 2
        li   x3, 0xDEADBEEF
        sw   x3, 4(x10)
        lw   x4, 4(x10)
        bne  x4, x3, falha

# --- 3: o sw em 0x404 não alterou a palavra em 0x400 --------------------------
        li   x30, 3
        lw   x2, 0(x10)
        bne  x2, x1, falha

# --- 4: offset negativo: sw em -8(0x410) = 0x408, lido com 8(0x400) -----------
        li   x30, 4
        addi x11, x10, 16        # x11 = 0x410
        li   x5, 0xCAFEF00D
        sw   x5, -8(x11)
        lw   x6, 8(x10)
        bne  x6, x5, falha

# --- 5: offset grande: 2044(x0) = endereço 0x7FC ------------------------------
        li   x30, 5
        li   x7, 0x0BADC0DE
        sw   x7, 2044(x0)
        lw   x8, 2044(x0)
        bne  x8, x7, falha

# --- 6: cópia de vetor de 4 palavras (0x420 -> 0x440) e soma do destino -------
        li   x30, 6
        li   x1, 10
        sw   x1, 0x20(x10)
        li   x1, 20
        sw   x1, 0x24(x10)
        li   x1, 30
        sw   x1, 0x28(x10)
        li   x1, 40
        sw   x1, 0x2C(x10)
        addi x12, x10, 0x20      # origem  = 0x420
        addi x13, x10, 0x40      # destino = 0x440
        li   x14, 4              # contador
copia:  lw   x15, 0(x12)
        sw   x15, 0(x13)
        addi x12, x12, 4
        addi x13, x13, 4
        addi x14, x14, -1
        bne  x14, x0, copia
        lw   x1, 0x40(x10)       # soma do vetor copiado
        lw   x2, 0x44(x10)
        add  x1, x1, x2
        lw   x2, 0x48(x10)
        add  x1, x1, x2
        lw   x2, 0x4C(x10)
        add  x1, x1, x2
        li   x29, 100            # 10 + 20 + 30 + 40
        bne  x1, x29, falha

# --- 7: lw em x0 é descartado -------------------------------------------------
        li   x30, 7
        lw   x0, 0(x10)
        add  x2, x0, x0
        bne  x2, x0, falha

# --- 8: sw de x0 grava zero ---------------------------------------------------
        li   x30, 8
        sw   x0, 0(x10)
        lw   x2, 0(x10)
        bne  x2, x0, falha

# --- Fim ----------------------------------------------------------------------
        li   x31, 1
fim:    j    fim
falha:  li   x31, 0xBAD
        j    fim
