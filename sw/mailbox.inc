# =============================================================================
# mailbox.inc - Formato da caixa de correio entre o UVM (ou o TB) e o firmware
#
# Fonte unica das constantes. O sw/mailbox.h (C, para o golden em DPI) e o
# sw/mailbox_pkg.sv (SystemVerilog, para o UVM) sao gerados daqui pelo
# sw/rvasm.py --defs (alvo make fw). Mude so este arquivo.
#
# A caixa fica no inicio da DMEM (0x1000_0000, regiao "dados do firmware" do
# README §3.1) e ocupa 256 bytes. O firmware nao tem .data nem pilha: fora da
# caixa ele nao toca na DMEM, entao A, B e C ficam so com o DMA.
#
# Protocolo (detalhes em sw/README.md):
#   1. o UVM escreve A e B na DMEM e os campos de entrada da caixa;
#   2. por ultimo escreve MB_DOORBELL com o numero do job (diferente do
#      anterior e de 0);
#   3. o firmware ve MB_DOORBELL != MB_END, programa o DMA, dispara, espera,
#      preenche os campos de saida e escreve MB_END = numero do job. Essa
#      escrita e o "END": e a ultima do job, e o scoreboard confere tudo nela;
#   4. MB_DOORBELL = MB_EXIT faz o firmware escrever MB_END = MB_EXIT e parar
#      (ebreak).
# =============================================================================

.equ MB_BASE,          0x10000000

# --- entrada: escrita pelo UVM, so lida pelo firmware ------------------------
.equ MB_DOORBELL,      0x00    # numero do job; MB_EXIT encerra
.equ MB_FLAGS,         0x04    # modo do job (F_*)
.equ MB_ADDR_A,        0x08    # copiados para os registradores do DMA
.equ MB_ADDR_B,        0x0C
.equ MB_ADDR_C,        0x10
.equ MB_DIM_M,         0x14
.equ MB_DIM_N,         0x18
.equ MB_DIM_K,         0x1C
.equ MB_SR_DELAY,      0x20    # F_SOFT_RESET: voltas de espera antes do aborto

# --- saida: escrita pelo firmware ---------------------------------------------
.equ MB_STATE,         0x40    # ST_*
.equ MB_STATUS,        0x44    # STATUS no fim do job, antes do W1C
.equ MB_CYCLES,        0x48    # CYCLES no fim do job
.equ MB_CYC_COMPUTE,   0x4C    # CYC_COMPUTE no fim do job
.equ MB_INFO,          0x50    # INFO (T, PINGPONG, versao)
.equ MB_STATUS_W1C,    0x54    # STATUS depois do W1C (so sobra o ERR_CODE)
.equ MB_WAIT_COUNT,    0x58    # wfi executados, leituras de STATUS ou voltas
.equ MB_BUSY_STATUS,   0x5C    # F_BUSY_WR: STATUS lido antes das escritas
.equ MB_RB_ADDR_A,     0x60    # F_BUSY_WR: ADDR_A lido de volta
.equ MB_RB_DIM_M,      0x64    # F_BUSY_WR: DIM_M lido de volta
.equ MB_END,           0x7C    # numero do job concluido; escrito por ultimo

# --- rascunho do F_CONTEND -----------------------------------------------------
.equ MB_SCRATCH,       0x80    # 32 palavras, de 0x80 a 0xFC
.equ MB_SCRATCH_WORDS, 32
.equ MB_SIZE,          0x100

# --- MB_FLAGS --------------------------------------------------------------------
.equ F_IRQ,            0x1     # CTRL.IRQ_EN = 1 e espera no wfi (sem: polling)
.equ F_CONTEND,        0x2     # espera lendo e escrevendo o rascunho (disputa a DMEM)
.equ F_SOFT_RESET,     0x4     # aborta com SOFT_RESET depois de MB_SR_DELAY voltas
.equ F_BUSY_WR,        0x8     # com BUSY = 1, tenta reescrever ADDR_A, DIM_M e START

# --- MB_STATE e MB_DOORBELL ------------------------------------------------------
.equ ST_RESET,         0       # firmware ainda nao rodou (DMEM zerada)
.equ ST_IDLE,          1       # esperando um job
.equ ST_RUN,           2       # job em andamento
.equ ST_HALT,          3       # parou depois do MB_EXIT
.equ MB_EXIT,          0xFFFFFFFF
