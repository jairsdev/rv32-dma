# =============================================================================
# firmware.s - Firmware do sistema RV32I + DMA + systolic array (Entrega 4)
#
# Um binario so para todos os testes: o firmware le cada job na caixa de
# correio (sw/mailbox.inc), programa o DMA, dispara, espera o fim e devolve o
# resultado na caixa. Nao tem .data, .bss nem pilha, entao na DMEM ele so toca
# na caixa (0x1000_0000 a 0x1000_00FF). A, B e C ficam so com o DMA.
#
# Fluxo de um job (README §7):
#   1. le ADDR_A/B/C e DIM_M/N/K na caixa e escreve nos registradores do DMA;
#   2. CTRL = START, mais IRQ_EN se F_IRQ;
#   3. espera o DONE de um destes jeitos:
#        F_IRQ       wfi, acordado pelo irq (padrao do enunciado)
#        sem F_IRQ   polling em STATUS
#        F_CONTEND   polling lendo e escrevendo o rascunho da caixa
#        F_SOFT_RESET  espera MB_SR_DELAY voltas, aborta e espera BUSY = 0
#   4. guarda STATUS, CYCLES, CYC_COMPUTE e INFO na caixa;
#   5. limpa DONE e ERROR (W1C, o irq cai) e guarda o STATUS de novo;
#   6. escreve MB_END = numero do job (o "END", sempre a ultima escrita).
#
# Registradores fixos:
#   s0 = base da caixa       s1 = base dos registradores do DMA
#   s2 = ultimo job atendido s3 = job atual
#   s4 = MB_FLAGS do job     s5 = contador de espera (MB_WAIT_COUNT)
#   s6 = valor escrito em CTRL no START
#
# Montar: python3 sw/rvasm.py sw/firmware.s -o build/fw/firmware.hex  (make fw)
# =============================================================================

.include "mailbox.inc"

# --- registradores do DMA (README §3.2) ---------------------------------------
.equ DMA_BASE,         0x40000000
.equ DMA_CTRL,         0x00
.equ DMA_STATUS,       0x04
.equ DMA_ADDR_A,       0x08
.equ DMA_ADDR_B,       0x0C
.equ DMA_ADDR_C,       0x10
.equ DMA_DIM_M,        0x14
.equ DMA_DIM_N,        0x18
.equ DMA_DIM_K,        0x1C
.equ DMA_CYCLES,       0x20
.equ DMA_INFO,         0x24
.equ DMA_CYC_COMPUTE,  0x28

.equ CTRL_START,       0x1
.equ CTRL_IRQ_EN,      0x2
.equ CTRL_SOFT_RESET,  0x4
.equ STATUS_BUSY,      0x1
.equ STATUS_DONE,      0x2
.equ STATUS_ERROR,     0x4

        .text
        .globl _start
_start:
        li   s0, MB_BASE
        li   s1, DMA_BASE
        li   s2, 0                      # nenhum job atendido ainda
        li   t0, ST_IDLE
        sw   t0, MB_STATE(s0)

# --- espera um job: MB_DOORBELL diferente do ultimo atendido --------------------
idle:
        lw   t0, MB_DOORBELL(s0)
        beq  t0, s2, idle
        li   t1, MB_EXIT
        beq  t0, t1, sair
        mv   s3, t0
        li   t0, ST_RUN
        sw   t0, MB_STATE(s0)

        # zera a saida do job anterior (MB_END fica: so muda no fim)
        sw   zero, MB_STATUS(s0)
        sw   zero, MB_CYCLES(s0)
        sw   zero, MB_CYC_COMPUTE(s0)
        sw   zero, MB_INFO(s0)
        sw   zero, MB_STATUS_W1C(s0)
        sw   zero, MB_WAIT_COUNT(s0)
        sw   zero, MB_BUSY_STATUS(s0)
        sw   zero, MB_RB_ADDR_A(s0)
        sw   zero, MB_RB_DIM_M(s0)

# --- 1: configuracao ---------------------------------------------------------------
        lw   t0, MB_ADDR_A(s0)
        sw   t0, DMA_ADDR_A(s1)
        lw   t0, MB_ADDR_B(s0)
        sw   t0, DMA_ADDR_B(s1)
        lw   t0, MB_ADDR_C(s0)
        sw   t0, DMA_ADDR_C(s1)
        lw   t0, MB_DIM_M(s0)
        sw   t0, DMA_DIM_M(s1)
        lw   t0, MB_DIM_N(s0)
        sw   t0, DMA_DIM_N(s1)
        lw   t0, MB_DIM_K(s0)
        sw   t0, DMA_DIM_K(s1)

# --- 2: START, com IRQ_EN se F_IRQ --------------------------------------------------
        lw   s4, MB_FLAGS(s0)
        andi s6, s4, F_IRQ
        slli s6, s6, 1                  # F_IRQ (bit 0) -> CTRL.IRQ_EN (bit 1)
        ori  s6, s6, CTRL_START
        sw   s6, DMA_CTRL(s1)
        li   s5, 0

# --- F_BUSY_WR: com BUSY = 1 essas escritas tem de ser ignoradas (README §3.2) --
        andi t0, s4, F_BUSY_WR
        beqz t0, espera
        lw   t0, DMA_STATUS(s1)
        sw   t0, MB_BUSY_STATUS(s0)     # o UVM confere que BUSY estava em 1
        lw   t0, MB_ADDR_A(s0)
        addi t0, t0, 0x100              # outro endereco, tambem alinhado
        sw   t0, DMA_ADDR_A(s1)
        lw   t0, MB_DIM_M(s0)
        addi t0, t0, 1
        sw   t0, DMA_DIM_M(s1)
        sw   s6, DMA_CTRL(s1)           # START de novo
        lw   t0, DMA_ADDR_A(s1)
        sw   t0, MB_RB_ADDR_A(s0)       # tem de ser o MB_ADDR_A
        lw   t0, DMA_DIM_M(s1)
        sw   t0, MB_RB_DIM_M(s0)        # tem de ser o MB_DIM_M

# --- 3: espera o fim -------------------------------------------------------------------
espera:
        andi t0, s4, F_SOFT_RESET
        bnez t0, aborta
        andi t0, s4, F_CONTEND
        bnez t0, disputa
        andi t0, s4, F_IRQ
        beqz t0, polling

# F_IRQ: dorme no wfi ate o irq. Se o irq ja estiver em 1 o wfi nao para, entao
# o DONE nunca se perde (README §4.4). MB_WAIT_COUNT = wfi executados.
dorme:
        lw   t0, DMA_STATUS(s1)
        andi t0, t0, STATUS_DONE
        bnez t0, fim
        addi s5, s5, 1
        wfi
        j    dorme

# Sem F_IRQ: polling. MB_WAIT_COUNT = leituras de STATUS.
polling:
        lw   t0, DMA_STATUS(s1)
        addi s5, s5, 1
        andi t0, t0, STATUS_DONE
        beqz t0, polling
        j    fim

# F_CONTEND: a cada volta soma 1 numa palavra do rascunho, na DMEM, enquanto o
# DMA usa a mesma memoria. MB_WAIT_COUNT = voltas = soma do que entrou no
# rascunho, que o UVM pode conferir.
disputa:
        andi t1, s5, MB_SCRATCH_WORDS - 1
        slli t1, t1, 2
        add  t1, t1, s0
        lw   t2, MB_SCRATCH(t1)
        addi t2, t2, 1
        sw   t2, MB_SCRATCH(t1)
        addi s5, s5, 1
        lw   t0, DMA_STATUS(s1)
        andi t0, t0, STATUS_DONE
        beqz t0, disputa
        j    fim

# F_SOFT_RESET: espera MB_SR_DELAY voltas, aborta e espera o dreno (BUSY = 0).
# Se o job ja tiver terminado antes do aborto, o SOFT_RESET nao tem efeito e o
# STATUS mostra o DONE; senao o STATUS fica zerado (MAS §6.1).
# MB_WAIT_COUNT = leituras de STATUS ate o BUSY cair.
aborta:
        lw   t1, MB_SR_DELAY(s0)
aborta_atraso:
        beqz t1, aborta_agora
        addi t1, t1, -1
        j    aborta_atraso
aborta_agora:
        andi t0, s6, CTRL_IRQ_EN
        ori  t0, t0, CTRL_SOFT_RESET
        sw   t0, DMA_CTRL(s1)
aborta_dreno:
        lw   t0, DMA_STATUS(s1)
        addi s5, s5, 1
        andi t0, t0, STATUS_BUSY
        bnez t0, aborta_dreno

# --- 4 a 6: resultado na caixa, W1C e END ----------------------------------------------
fim:
        lw   t0, DMA_STATUS(s1)
        sw   t0, MB_STATUS(s0)
        lw   t0, DMA_CYCLES(s1)
        sw   t0, MB_CYCLES(s0)
        lw   t0, DMA_CYC_COMPUTE(s1)
        sw   t0, MB_CYC_COMPUTE(s0)
        lw   t0, DMA_INFO(s1)
        sw   t0, MB_INFO(s0)
        sw   s5, MB_WAIT_COUNT(s0)

        li   t0, STATUS_DONE | STATUS_ERROR
        sw   t0, DMA_STATUS(s1)         # W1C: o irq cai
        lw   t0, DMA_STATUS(s1)
        sw   t0, MB_STATUS_W1C(s0)

        li   t0, ST_IDLE
        sw   t0, MB_STATE(s0)
        sw   s3, MB_END(s0)             # END: ultima escrita do job
        mv   s2, s3
        j    idle

# --- MB_EXIT: confirma e para ------------------------------------------------------------
sair:
        li   t0, ST_HALT
        sw   t0, MB_STATE(s0)
        sw   t1, MB_END(s0)             # t1 = MB_EXIT
        ebreak
parado:
        j    parado                     # nao chega aqui: o ebreak para a CPU
