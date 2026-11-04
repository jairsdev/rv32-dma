# =============================================================================
# 08_branches.s - Desvios condicionais
# Spec: riscv-spec.pdf, Seção 2.5 "Control Transfer Instructions"
#       (Conditional Branches)
# Instruções testadas: beq, bne, blt, bge, bltu, bgeu
# Foco: cada desvio nos casos tomado e não tomado, comparação com e sem
#       sinal e desvios para trás (laços)
# Padrões:
#   tomado:     bXX ..., okN  /  j falha  /  okN:   (se não desviar, falha)
#   não tomado: bXX ..., falha                     (se desviar, falha)
# Convenção: x30 = nº do subteste atual | x31 = 1 sucesso, 0xBAD falha
# =============================================================================

        li   x31, 0
        li   x1, 5
        li   x2, 5
        li   x3, 6
        li   x4, -1              # 0xFFFFFFFF: negativo com sinal, enorme sem sinal
        li   x5, 1

# --- 1: beq tomado (5 == 5) ---------------------------------------------------
        li   x30, 1
        beq  x1, x2, ok1
        j    falha
ok1:
# --- 2: beq não tomado (5 == 6 é falso) ---------------------------------------
        li   x30, 2
        beq  x1, x3, falha

# --- 3: bne tomado (5 != 6) ---------------------------------------------------
        li   x30, 3
        bne  x1, x3, ok3
        j    falha
ok3:
# --- 4: bne não tomado (5 != 5 é falso) ---------------------------------------
        li   x30, 4
        bne  x1, x2, falha

# --- 5: blt tomado (-1 < 1 com sinal) -----------------------------------------
        li   x30, 5
        blt  x4, x5, ok5
        j    falha
ok5:
# --- 6: blt não tomado com valores iguais (5 < 5 é falso) ---------------------
        li   x30, 6
        blt  x1, x2, falha

# --- 7: bge tomado (1 >= -1 com sinal) ----------------------------------------
        li   x30, 7
        bge  x5, x4, ok7
        j    falha
ok7:
# --- 8: bge tomado com valores iguais (5 >= 5) --------------------------------
        li   x30, 8
        bge  x1, x2, ok8
        j    falha
ok8:
# --- 9: bge não tomado (-1 >= 1 é falso) --------------------------------------
        li   x30, 9
        bge  x4, x5, falha

# --- 10: bltu não tomado (0xFFFFFFFF < 1 sem sinal é falso) -------------------
        li   x30, 10
        bltu x4, x5, falha

# --- 11: bltu tomado (1 < 0xFFFFFFFF sem sinal) -------------------------------
        li   x30, 11
        bltu x5, x4, ok11
        j    falha
ok11:
# --- 12: bgeu tomado (0xFFFFFFFF >= 1 sem sinal) ------------------------------
        li   x30, 12
        bgeu x4, x5, ok12
        j    falha
ok12:
# --- 13: bgeu não tomado (1 >= 0xFFFFFFFF sem sinal é falso) ------------------
        li   x30, 13
        bgeu x5, x4, falha

# --- 14: desvio não tomado executa a instrução seguinte -----------------------
        li   x30, 14
        li   x6, 0
        beq  x1, x3, pula14      # não tomado
        addi x6, x6, 1           # deve executar
pula14: li   x29, 1
        bne  x6, x29, falha

# --- 15: desvio tomado pula a instrução seguinte ------------------------------
        li   x30, 15
        li   x6, 0
        beq  x1, x2, pula15      # tomado
        addi x6, x6, 1           # NÃO deve executar
pula15: bne  x6, x0, falha

# --- 16: laço com bne para trás: conta 5 iterações ----------------------------
        li   x30, 16
        li   x6, 5               # contador regressivo
        li   x7, 0               # iterações
laco1:  addi x7, x7, 1
        addi x6, x6, -1
        bne  x6, x0, laco1
        li   x29, 5
        bne  x7, x29, falha

# --- 17: laço com blt para trás: soma 0+1+...+9 = 45 --------------------------
        li   x30, 17
        li   x6, 0               # i
        li   x7, 0               # soma
        li   x8, 10              # limite
laco2:  add  x7, x7, x6
        addi x6, x6, 1
        blt  x6, x8, laco2
        li   x29, 45
        bne  x7, x29, falha

# --- 18: laço com bgeu para trás contando de 3 até 0 (sem sinal) --------------
        li   x30, 18
        li   x6, 3
        li   x7, 0
laco3:  addi x7, x7, 1
        addi x6, x6, -1
        bgeu x6, x5, laco3       # repete enquanto x6 >= 1
        li   x29, 3
        bne  x7, x29, falha

# --- Fim ----------------------------------------------------------------------
        li   x31, 1
fim:    j    fim
falha:  li   x31, 0xBAD
        j    fim
