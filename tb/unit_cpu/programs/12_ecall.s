# =============================================================================
# 12_ecall.s - ECALL
# Spec: riscv-spec.pdf, Seção 2.8 "Environment Call and Breakpoints"
# Instrução testada: ecall
# Convenção: x30 = nº do subteste atual | x31 = 1 sucesso, 0xBAD falha
#
# Sem modo privilegiado nem CSRs, ecall para a CPU (estado HALT, igual ao ebreak):
# o PC fica parado na instrução e nada mais é escrito.
# =============================================================================

        li   x31, 0
        li   x30, 1
        li   x17, 93             # a7 = 93: "exit" na convenção do Linux
        li   x10, 0              # a0 = código de saída
        li   x31, 1
        ecall                    # parada: o PC fica aqui
        li   x31, 0xBAD          # não pode ser executada
        li   x10, 1
fim:    j    fim
