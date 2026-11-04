# =============================================================================
# 13_dma_wfi.s - Fluxo do firmware (README, secao 7) visto pela CPU
# Instrucoes testadas: wfi; sw/lw nos registradores do DMA (0x4000_0000);
#                      sb/sh/lb/lhu na DMEM (0x1000_0000)
# Convencao: x30 = no do subteste atual | x31 = 1 sucesso, 0xBAD falha
#
# Roda no tb_cpu_irq, que modela os registradores do DMA (README, secao 3.2):
# START liga BUSY e, alguns ciclos depois, o DMA termina (DONE = 1, BUSY = 0);
# irq = DONE & IRQ_EN. Termina em ebreak (a CPU para em HALT).
# =============================================================================

        li   x31, 0              # status = 0 (em execucao)
        li   x10, 0x40000000     # base dos registradores do DMA
        li   x11, 0x10000000     # base da DMEM

# --- 1: configura enderecos e dimensoes, confere e dispara com IRQ_EN ---------
        li   x30, 1
        li   x1, 0x10001000
        sw   x1, 8(x10)          # ADDR_A
        li   x1, 0x10004000
        sw   x1, 12(x10)         # ADDR_B
        li   x1, 0x10008000
        sw   x1, 16(x10)         # ADDR_C
        li   x1, 6
        sw   x1, 20(x10)         # DIM_M
        li   x1, 7
        sw   x1, 24(x10)         # DIM_N
        li   x1, 5
        sw   x1, 28(x10)         # DIM_K
        lw   x2, 20(x10)
        li   x29, 6
        bne  x2, x29, falha      # DIM_M lido de volta
        li   x1, 3
        sw   x1, 0(x10)          # CTRL = START | IRQ_EN

# --- 2: espera o fim dormindo em wfi (a CPU fica em WAIT ate o irq) -----------
        li   x30, 2
        li   x20, 0              # quantas vezes o wfi foi executado
espera: lw   x2, 4(x10)          # STATUS
        andi x3, x2, 2           # DONE
        bnez x3, pronto
        addi x20, x20, 1
        wfi
        j    espera
pronto: li   x29, 1
        bne  x20, x29, falha     # dormiu uma unica vez

# --- 3: W1C em STATUS.DONE zera o STATUS (e derruba o irq) ---------------------
        li   x30, 3
        li   x1, 6
        sw   x1, 4(x10)          # STATUS = DONE | ERROR (W1C)
        lw   x2, 4(x10)
        bnez x2, falha

# --- 4: irq ja em 1 quando o wfi executa: a CPU nao para ----------------------
        li   x30, 4
        li   x1, 3
        sw   x1, 0(x10)          # START | IRQ_EN; desta vez o DMA termina logo
        nop
        nop
        nop
        nop
        wfi                      # irq ja em 1: segue sem passar por WAIT
        lw   x2, 4(x10)
        andi x3, x2, 2
        beqz x3, falha
        li   x1, 2
        sw   x1, 4(x10)          # W1C

# --- 5: sem IRQ_EN, polling em STATUS --------------------------------------------
        li   x30, 5
        li   x1, 1
        sw   x1, 0(x10)          # so START
poll:   lw   x2, 4(x10)
        andi x3, x2, 2
        beqz x3, poll
        li   x1, 2
        sw   x1, 4(x10)          # W1C

# --- 6: sb/sh escrevem so os bytes da lane; lb/lhu extraem e estendem --------
        li   x30, 6
        li   x1, 0x11223344
        sw   x1, 0(x11)
        li   x1, 0xAA
        sb   x1, 1(x11)          # d_wstrb = 0010
        li   x1, 0xBBCC
        sh   x1, 2(x11)          # d_wstrb = 1100
        lw   x2, 0(x11)
        li   x29, 0xBBCCAA44
        bne  x2, x29, falha
        lb   x2, 1(x11)
        li   x29, -86            # 0xAA com sinal
        bne  x2, x29, falha
        lhu  x2, 2(x11)
        li   x29, 0xBBCC
        bne  x2, x29, falha

        li   x31, 1              # todos os subtestes passaram
        ebreak
falha:  li   x31, 0xBAD
        ebreak
