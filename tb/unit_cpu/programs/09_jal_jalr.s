# =============================================================================
# 09_jal_jalr.s - Desvios incondicionais, chamada e retorno de sub-rotina
# Spec: riscv-spec.pdf, Seção 2.5 "Control Transfer Instructions"
#       (Unconditional Jumps)
# Instruções testadas: jal, jalr
# Foco: rd recebe PC+4, retorno via jalr, jalr com offset, bit 0 do alvo
#       zerado, rd == rs1, chamadas aninhadas e salto para trás
# Convenção: x30 = nº do subteste atual | x31 = 1 sucesso, 0xBAD falha
# Obs.: "li xN, rotulo" carrega o endereço absoluto do rótulo (programa em 0x0)
# =============================================================================

        li   x31, 0

# --- 1: jal chama func1, que faz x5 = 0x11 e retorna -------------------------
        li   x30, 1
        li   x5, 0
        jal  ra, func1
volta1: li   x29, 0x11
        bne  x5, x29, falha

# --- 2: ra recebeu o endereço da instrução seguinte ao jal (PC+4) -------------
        li   x30, 2
        li   x29, volta1
        bne  ra, x29, falha

# --- 3: jal x0 (j) pula instruções sem salvar retorno -------------------------
        li   x30, 3
        li   x6, 0
        j    pula3
        li   x6, 0x333           # NÃO deve executar
pula3:  bne  x6, x0, falha

# --- 4: jalr com offset: alvo = (alvo4 - 8) + 8 -------------------------------
        li   x30, 4
        li   x8, 0
        li   x7, alvo4
        addi x7, x7, -8
        jalr ra, 8(x7)
        li   x29, 0x44
        bne  x8, x29, falha

# --- 5: jalr zera o bit 0 do endereço calculado (alvo5 + 1 -> alvo5) ----------
        li   x30, 5
        li   x8, 0
        li   x7, alvo5
        addi x7, x7, 1           # endereço ímpar
        jalr ra, 0(x7)
        li   x29, 0x55
        bne  x8, x29, falha

# --- 6: jalr com rd == rs1: usa o valor antigo de rs1 como alvo ---------------
        li   x30, 6
        li   x7, alvo6
        jalr x7, 0(x7)           # salta para alvo6 e x7 = volta6
volta6: li   x29, volta6
        bne  x7, x29, falha

# --- 7: chamadas aninhadas: externa chama interna; x9 = 2 + 1 = 3 -------------
        li   x30, 7
        li   x9, 0
        jal  ra, externa
        li   x29, 3
        bne  x9, x29, falha

# --- 8: jal para trás ---------------------------------------------------------
        li   x30, 8
        li   x10, 0
        j    frente
tras:   addi x10, x10, 1
        j    depois8
frente: addi x10, x10, 1
        j    tras                # salto com deslocamento negativo
depois8:
        li   x29, 2
        bne  x10, x29, falha

# --- Fim ----------------------------------------------------------------------
        li   x31, 1
fim:    j    fim
falha:  li   x31, 0xBAD
        j    fim

# ============================ Sub-rotinas =====================================
func1:  li   x5, 0x11
        jalr x0, 0(ra)           # retorno (ret)

alvo4:  li   x8, 0x44
        ret

alvo5:  li   x8, 0x55
        ret

alvo6:  jalr x0, 0(x7)           # volta para o endereço salvo em x7

externa:
        mv   x20, ra             # salva o endereço de retorno
        jal  ra, interna
        addi x9, x9, 1
        mv   ra, x20             # restaura
        ret

interna:
        li   x9, 2
        ret
