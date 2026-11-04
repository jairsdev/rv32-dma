# =============================================================================
# 11_fence_ebreak.s - FENCE e EBREAK
# Spec: riscv-spec.pdf, Seções 2.7 "Memory Ordering Instructions" e
#       2.8 "Environment Call and Breakpoints"
# Instruções testadas: fence, ebreak
# Convenção: x30 = nº do subteste atual | x31 = 1 sucesso, 0xBAD falha
#
# Na CPU (sem cache e sem modo privilegiado):
#   - fence não tem efeito: só avança o PC;
#   - ebreak para a CPU (estado HALT): o PC fica parado na própria instrução e
#     nada mais é escrito. Por isso este programa termina em ebreak, e não no
#     laço "fim: j fim" dos programas 01 a 10.
# =============================================================================

        li   x31, 0              # status = 0 (em execução)

# --- 1: fence não altera registradores e o PC segue para a próxima ----------
        li   x30, 1
        li   x1, 5
        fence
        addi x1, x1, 1
        li   x29, 6
        bne  x1, x29, falha

# --- 2: store, fence, load: a memória continua coerente ----------------------
        li   x30, 2
        li   x10, 0x400
        li   x2, 0x1234
        sw   x2, 0(x10)
        fence
        lw   x3, 0(x10)
        bne  x3, x2, falha

# --- 3: fences seguidos e desvio logo depois ---------------------------------
        li   x30, 3
        fence
        fence
        beq  x0, x0, depois
        j    falha
depois:
        li   x29, 0x1234
        bne  x3, x29, falha

# --- Fim: ebreak para o processador -----------------------------------------
        li   x31, 1              # todos os subtestes passaram
        ebreak                   # parada: o PC fica aqui
        li   x31, 0xBAD          # não pode ser executada
fim:    j    fim
falha:  li   x31, 0xBAD          # x30 indica o subteste que falhou
        j    fim
