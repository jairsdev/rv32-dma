# =============================================================================
# 10_algoritmo_final.s - Teste de integração com pequenos algoritmos
# Spec: riscv-spec.pdf, Seções 2.4, 2.5 e 2.6 (RV32I completo)
# Algoritmos (sem multiplicação): soma de vetor, Fibonacci iterativo,
#       bubble sort em memória, contagem de bits (sub-rotina) e
#       comprimento de string terminada em zero
# Área de dados: 0x400 (vetor), 0x500 (Fibonacci), 0x600 (string)
# Convenção: x30 = nº do subteste atual | x31 = 1 sucesso, 0xBAD falha
# =============================================================================

        li   x31, 0
        li   x10, 0x400          # vetor de 8 palavras

# Inicializa o vetor: [5, -2, 17, 8, 0, 100, -30, 2]
        li   x1, 5
        sw   x1, 0(x10)
        li   x1, -2
        sw   x1, 4(x10)
        li   x1, 17
        sw   x1, 8(x10)
        li   x1, 8
        sw   x1, 12(x10)
        sw   x0, 16(x10)
        li   x1, 100
        sw   x1, 20(x10)
        li   x1, -30
        sw   x1, 24(x10)
        li   x1, 2
        sw   x1, 28(x10)

# --- 1: soma do vetor = 5 - 2 + 17 + 8 + 0 + 100 - 30 + 2 = 100 ---------------
        li   x30, 1
        mv   x11, x10            # ponteiro
        li   x12, 8              # n
        li   x13, 0              # soma
soma:   lw   x14, 0(x11)
        add  x13, x13, x14
        addi x11, x11, 4
        addi x12, x12, -1
        bne  x12, x0, soma
        li   x29, 100
        bne  x13, x29, falha

# --- 2: Fibonacci F(0..20) gravado em 0x500; F(20) = 6765 ---------------------
        li   x30, 2
        li   x11, 0x500
        li   x14, 0              # F(i)
        li   x15, 1              # F(i+1)
        li   x12, 21             # 21 termos
fib:    sw   x14, 0(x11)
        add  x16, x14, x15
        mv   x14, x15
        mv   x15, x16
        addi x11, x11, 4
        addi x12, x12, -1
        bne  x12, x0, fib
        li   x11, 0x500
        lw   x1, 80(x11)         # F(20) em 0x500 + 20*4
        li   x29, 6765
        bne  x1, x29, falha
        lw   x1, 40(x11)         # F(10) = 55
        li   x29, 55
        bne  x1, x29, falha

# --- 3: bubble sort crescente (com sinal) do vetor em 0x400 -------------------
#     Resultado esperado: [-30, -2, 0, 2, 5, 8, 17, 100]
        li   x30, 3
        li   x12, 7              # passadas = n - 1
externo:
        mv   x11, x10
        mv   x13, x12            # comparações nesta passada
interno:
        lw   x14, 0(x11)
        lw   x15, 4(x11)
        bge  x15, x14, semtroca  # já em ordem: a[i+1] >= a[i]
        sw   x15, 0(x11)         # troca
        sw   x14, 4(x11)
semtroca:
        addi x11, x11, 4
        addi x13, x13, -1
        bne  x13, x0, interno
        addi x12, x12, -1
        bne  x12, x0, externo
        # verifica ordenação: a[i] <= a[i+1] para todo i
        mv   x11, x10
        li   x13, 7
verifica:
        lw   x14, 0(x11)
        lw   x15, 4(x11)
        blt  x15, x14, falha
        addi x11, x11, 4
        addi x13, x13, -1
        bne  x13, x0, verifica
        # extremos
        lw   x1, 0(x10)
        li   x29, -30
        bne  x1, x29, falha
        lw   x1, 28(x10)
        li   x29, 100
        bne  x1, x29, falha

# --- 4: contagem de bits 1 (sub-rotina): popcount(0xF0F0F0F1) = 17 ------------
        li   x30, 4
        li   a0, 0xF0F0F0F1
        jal  ra, popcount
        li   x29, 17
        bne  a0, x29, falha

# --- 5: comprimento da string "RISC-V\0" gravada byte a byte em 0x600 = 6 -----
        li   x30, 5
        li   x11, 0x600
        li   x1, 82             # 'R'
        sb   x1, 0(x11)
        li   x1, 73              # 'I'
        sb   x1, 1(x11)
        li   x1, 83              # 'S'
        sb   x1, 2(x11)
        li   x1, 67              # 'C'
        sb   x1, 3(x11)
        li   x1, 45              # '-'
        sb   x1, 4(x11)
        li   x1, 86              # 'V'
        sb   x1, 5(x11)
        sb   x0, 6(x11)          # terminador
        li   x12, 0              # comprimento
strlen: add  x13, x11, x12
        lbu  x14, 0(x13)
        beq  x14, x0, fimstr
        addi x12, x12, 1
        j    strlen
fimstr: li   x29, 6
        bne  x12, x29, falha

# --- Fim ----------------------------------------------------------------------
        li   x31, 1
fim:    j    fim
falha:  li   x31, 0xBAD
        j    fim

# ============================ Sub-rotinas =====================================
# popcount: a0 = número de bits 1 em a0 (usa t0, t1)
popcount:
        li   t0, 0
pc_laco:
        beq  a0, x0, pc_fim
        andi t1, a0, 1
        add  t0, t0, t1
        srli a0, a0, 1
        j    pc_laco
pc_fim: mv   a0, t0
        ret
