#!/usr/bin/env python3
"""Gera os diagramas da especificacao em docs/img/ (.drawio editavel + .svg para o GitHub).

Uso: python3 scripts/gen_drawio.py [diretorio_saida]

Diagramas:
  top_level        - blocos do sistema: CPU multiciclo (porta I na IMEM local, porta D no AXI),
                     axi_xbar 2x2 AXI4 (burst), DMA (master M1 + regs S1), DMEM, acelerador via sideband
  accel            - acelerador output-stationary (exemplo T = 4) com bancos ping-pong e banco C
  dma_blocks       - diagrama de blocos interno do DMA (MAS secao 5)
  dma_ctrl_fsm     - FSM principal do DMA (MAS 9.1)
  dma_load_fsm     - FSM produtora de blocos (MAS 9.2)
  dma_compute_fsm  - FSM de disparo dos tiles (MAS 9.3)
  dma_store_fsm    - FSM de gravacao de C (MAS 9.4)
  axi_rd_wr_fsm    - FSMs dos motores AXI de leitura e escrita (MAS 9.5)
  axi_xbar         - crossbar AXI4 2x2 (MAS 12.1)
  axi_mem_ctrl_fsm - FSM do controlador de memoria AXI4 (MAS 12.2)
  sequencia  - sequencia de uma operacao completa: configuracao, wfi, tiles, irq, W1C
"""
import sys
from pathlib import Path

from diagram_lib import (Diagram, ST_ADAPTER, ST_AXI, ST_BOX, ST_DATA, ST_FRAME, ST_GRAY, ST_IRQ,
                         ST_LIFELINE, ST_MASTER, ST_MSG, ST_NATIVE, ST_NOTE, ST_REGION, ST_RET,
                         ST_SIDEBAND, ST_STATE, ST_STATE_END, ST_STATE_ERR, ST_SWITCH, ST_TEXT, ST_TRANS)

DEFAULT_OUT = Path(__file__).resolve().parent.parent / "docs" / "img"

BUS = "<b>/</b> 32 · AXI4 burst"
SMALL = "<span style='font-weight:normal;font-size:11px'>"


def top_level():
    d = Diagram("top_level", "Top-Level", 1100, 690)
    v, e = d.vertex, d.edge

    # CPU (regiao com as duas portas)
    v("reg_cpu", "CPU RV32I multiciclo<br>FETCH → DECODE → EXEC → MEM → WB (+ WAIT p/ wfi)",
      20, 20, 400, 120, ST_REGION)
    v("cpu_i", "Porta I<br>(fetch)", 35, 60, 175, 60, ST_MASTER)
    v("cpu_d", "Porta D<br>(load/store)", 230, 60, 175, 60, ST_MASTER)

    # IMEM local e adapter da porta D
    v("imem", f"SRAM IMEM (local)<br>{SMALL}0x0000_0000 · 64 KiB<br>firmware · $readmemh<br>fora do barramento</span>",
      35, 200, 175, 80, ST_GRAY)
    v("ad_d", "cpu_axi_adapter", 230, 200, 175, 50, ST_ADAPTER)

    # DMA e acelerador
    v("dma", f"DMA Controller<br>{SMALL}3 FSMs concorrentes<br>master AXI4 burst (M1)<br>"
             "regs CTRL/STATUS/ADDR/DIM<br>(slave AXI4, S1)</span>",
      460, 30, 230, 160, ST_GRAY)
    v("acc", f"Acelerador MatMul<br>{SMALL}buf A, buf B × 2 bancos<br>systolic array T×T (OS)<br>"
             "banco C (T×T int32)<br>T ∈ {2, 4, 8} · PINGPONG</span>",
      870, 30, 210, 160, ST_MASTER)

    # crossbar
    v("xbar", f"axi_xbar 2×2 — AXI4 32 bits, burst INCR<br>{SMALL}M0 = CPU-D · M1 = DMA → S0 = DMEM · S1 = REGS · "
              "decode addr[31:28] · RR por slave e direção · lock por burst · DECERR</span>",
      230, 310, 850, 60, ST_SWITCH)

    # controlador de memoria + DMEM
    v("mc", f"axi_mem_ctrl<br>{SMALL}slave AXI4 (burst) → SRAM · WSTRB</span>", 430, 430, 300, 60, ST_ADAPTER)
    v("dmem", f"SRAM DMEM compartilhada<br>{SMALL}0x1000_0000 · 64 KiB<br>"
              "dados do fw · A, B (int8) · C (int32) · pilha</span>",
      430, 540, 300, 80, ST_GRAY)

    # CPU -> IMEM / adapter (interface nativa estilo PicoRV32)
    e("e_cpu_i", "cpu_i", "imem", (122, 120), (122, 200), "nativa<br>valid/ready · 32", ST_NATIVE)
    e("e_cpu_d", "cpu_d", "ad_d", (317, 120), (317, 200), "nativa<br>valid/ready · 32", ST_NATIVE)

    # masters / slaves do xbar
    e("e_m0", "ad_d", "xbar", (317, 250), (317, 310), "M0 · " + BUS, ST_AXI)
    e("e_m1", "dma", "xbar", (520, 190), (520, 310), "M1 · " + BUS, ST_AXI)
    e("e_s1", "xbar", "dma", (670, 310), (670, 190), "S1 · REGS 0x4000_0000<br>" + BUS, ST_AXI)
    e("e_s0", "xbar", "mc", (580, 370), (580, 430), "S0 · DMEM 0x1000_0000<br>" + BUS, ST_AXI)
    e("e_ram", "mc", "dmem", (580, 490), (580, 540), "interface SRAM · 32", ST_NATIVE)

    # sideband DMA <-> acelerador (nao-AXI) e IRQ
    e("e_side", "dma", "acc", (690, 110), (870, 110),
      "sideband (não-AXI)<br>A/B: bank, row, word, data[32]<br>C: rd, row, col, data[32]<br>"
      "tile_start/bank · first/last_k<br>busy · done · c_valid/release", ST_SIDEBAND)
    e("e_irq", "dma", "reg_cpu", (460, 100), (420, 100), "irq", ST_IRQ)

    # legenda
    v("leg_box", "", 800, 430, 280, 210, "rounded=0;html=1;fillColor=#FFFFFF;strokeColor=#BBBBBB;")
    v("leg_title", "Legenda", 810, 435, 100, 20, ST_TEXT + "fontStyle=1;fontSize=12;")
    legend = [
        ("leg_1", ST_MASTER, "CPU / Acelerador"),
        ("leg_2", ST_ADAPTER, "Adapter / controlador de memória"),
        ("leg_3", ST_SWITCH, "Crossbar AXI4"),
        ("leg_4", ST_GRAY, "DMA / memórias"),
    ]
    for i, (lid, st, txt) in enumerate(legend):
        y = 460 + i * 24
        v(lid, "", 815, y, 28, 16, st)
        v(lid + "_t", txt, 852, y - 2, 220, 20, ST_TEXT + "fontSize=11;")
    notes = ["<b>/</b> 32 · AXI4 burst = AXI4, 32 bits",
             "linha fina = interface nativa valid/ready",
             "tracejado azul = sideband DMA ↔ Acelerador",
             "tracejado vermelho = interrupção (irq)"]
    for i, txt in enumerate(notes):
        v(f"leg_l{i}", txt, 815, 560 + i * 20, 260, 20, ST_TEXT + "fontSize=11;")

    v("title", "<b>RV32I + DMA + Systolic Array — Top-Level</b> (MAS v1, AXI4)", 20, 650, 700, 30,
      ST_TEXT + "fontSize=16;")
    return d


def accel(T=4):
    d = Diagram("accel", "Acelerador", 1100, 670)
    v, e = d.vertex, d.edge
    one_way = ST_SIDEBAND + "startArrow=none;"
    grid_region = ST_REGION.replace("verticalAlign=top", "verticalAlign=bottom") + "fillColor=#D5E3E6;"

    v("reg", f"Acelerador MatMul — exemplo com T = ARRAY_SIZE = {T} · output-stationary · PINGPONG = 1",
      20, 10, 1060, 640, ST_REGION)
    v("grid", "malha T×T de PEs · acc int32 em cada PE (copiado para o banco C)", 315, 185, 370, 300, grid_region)

    # escrita dos buffers pelo DMA
    v("dma_w", f"DMA<br>{SMALL}escrita dos buffers<br>1 palavra (4 int8)/ciclo</span>", 40, 40, 200, 100, ST_GRAY)
    v("buf_b", f"buf B × 2 bancos (T×T int8)<br>{SMALL}leitura: banco tile_bank, linha k</span>", 330, 40, 340, 50, ST_GRAY)
    v("skew_b", "skew B: coluna j atrasada j ciclos", 330, 120, 340, 40, ST_ADAPTER + "fontSize=11;")
    v("buf_a", f"buf A<br>{SMALL}× 2 bancos<br>T×T int8<br><br>leitura:<br>banco<br>tile_bank,<br>coluna k</span>",
      40, 210, 120, 250, ST_GRAY)
    v("skew_a", f"skew A<br>{SMALL}linha i<br>atrasada<br>i ciclos</span>", 180, 210, 100, 250, ST_ADAPTER)

    e("e_wa", "dma_w", "buf_a", (100, 140), (100, 210), "A: we, bank, row,<br>word, data[32]", one_way)
    e("e_wb", "dma_w", "buf_b", (240, 65), (330, 65), "B: we, bank, row,<br>word, data[32]", one_way)
    e("e_bs", "buf_b", "skew_b", (500, 90), (500, 120), "", ST_DATA)
    e("e_as", "buf_a", "skew_a", (160, 335), (180, 335), "", ST_DATA)

    # malha de PEs: A flui para a direita, B flui para baixo
    for i in range(T):
        for j in range(T):
            x, y = 330 + 90 * j, 215 + 65 * i
            v(f"pe{i}{j}", f"PE{i}{j}", x, y, 70, 45, ST_MASTER + "fontSize=11;")
            if j == 0:
                e(f"e_a{i}", "skew_a", f"pe{i}0", (280, y + 22), (330, y + 22), "", ST_DATA)
            else:
                e(f"e_h{i}{j}", f"pe{i}{j - 1}", f"pe{i}{j}", (x - 20, y + 22), (x, y + 22), "", ST_DATA)
            if i == 0:
                e(f"e_b{j}", "skew_b", f"pe0{j}", (x + 35, 160), (x + 35, 215), "", ST_DATA)
            else:
                e(f"e_v{i}{j}", f"pe{i - 1}{j}", f"pe{i}{j}", (x + 35, y - 20), (x + 35, y), "", ST_DATA)

    # leitura de C (acumuladores) pelo DMA
    v("mux_c", f"banco C<br>{SMALL}T×T int32<br>cópia dos acc<br>em 1 ciclo (last_k)<br><br>+ mux T²:1<br>por (c_row, c_col)</span>",
      740, 210, 150, 250, ST_ADAPTER)
    v("dma_c", f"DMA<br>{SMALL}c_rd, c_row, c_col →<br>← c_rdata[31:0]<br>← c_valid<br>c_release →</span>", 920, 280, 150, 110, ST_GRAY)
    e("e_mux", "grid", "mux_c", (685, 335), (740, 335), "cópia T²×32", ST_DATA)
    e("e_c", "mux_c", "dma_c", (890, 335), (920, 335), "", ST_SIDEBAND)

    # controle do tile
    v("ctrl", f"controle do tile<br>{SMALL}contador t = 0 … 3T−2 · first_k → clr_acc<br>last_k → cópia p/ banco C (S_WAIT_C se c_valid)</span>",
      360, 520, 310, 70, ST_SWITCH)
    v("dma_ctl", f"DMA<br>{SMALL}controle do tile</span>", 40, 520, 170, 70, ST_GRAY)
    e("e_ctl", "dma_ctl", "ctrl", (210, 555), (360, 555), "tile_start, tile_bank,<br>first_k, last_k →<br>← busy, tile_done", ST_SIDEBAND)
    e("e_en", "ctrl", "grid", (500, 520), (500, 485), "en, clr_acc", ST_DATA)

    v("pe_det", "<b>PE(i,j)</b><br>a_out ← a_in · b_out ← b_in (registrados)<br>acc ← acc + a_in × b_in<br>"
                "a, b: int8 · produto: int16 · acc: int32<br>clr_acc (first_k = 1) zera acc antes do tile",
      740, 500, 330, 130, ST_BOX)
    v("lat", "Latência de um tile: 1 ciclo (clr_acc) + T passos + 2(T−1) de skew = 3T−1 ciclos",
      40, 600, 640, 30, ST_TEXT + "fontSize=11;")
    return d


SW, SH = 260, 60          # tamanho padrao de um estado
ERR = ST_TRANS + "dashed=1;strokeColor=#D0021B;fontColor=#D0021B;"


def _st(v, cid, name, desc, x, y, style=ST_STATE, w=SW, h=SH):
    v(cid, f"{name}<br>{SMALL}{desc}</span>", x, y, w, h, style)


def dma_blocks():
    d = Diagram("dma_blocks", "DMA - blocos", 1100, 800)
    v, e = d.vertex, d.edge
    one_way = ST_SIDEBAND + "startArrow=none;"
    ctl = ST_TRANS + "strokeColor=#0B6F8A;fontColor=#0B6F8A;"

    v("reg", "dma.v — parâmetros ARRAY_SIZE, PINGPONG, MAX_BURST", 20, 10, 800, 690, ST_REGION)
    v("regs", f"dma_regs<br>{SMALL}slave AXI4 (S1)<br>registradores · irq</span>",
      40, 30, 180, 70, ST_GRAY)
    v("ctrl", f"dma_ctrl<br>{SMALL}IDLE → CHECK → RUN → DRAIN → ERROR/DONE<br>"
              "strides · n_tiles · n_blocks · erro · soft reset</span>", 340, 30, 440, 70, ST_SWITCH)
    v("load", f"dma_load<br>{SMALL}produtor · itera i0 → j0 → k0<br>T linhas de A + T de B</span>",
      40, 180, 220, 80, ST_MASTER)
    v("bank", f"dma_bank_ctrl<br>{SMALL}estado dos bancos<br>EMPTY/LOADING/FULL/COMPUTING<br>"
              "ld_ptr · cp_ptr</span>", 300, 180, 220, 80, ST_ADAPTER)
    v("comp", f"dma_compute<br>{SMALL}tile_start por banco cheio<br>first_k · last_k</span>",
      560, 180, 220, 80, ST_MASTER)
    v("rd", f"dma_rd_engine<br>{SMALL}AR/R · 1 burst por linha<br>4 KB · alinhamento · padding</span>",
      40, 330, 220, 80, ST_GRAY)
    v("store", f"dma_store<br>{SMALL}consumidor · linhas válidas de C<br>c_release por tile</span>",
      560, 440, 220, 70, ST_MASTER)
    v("wr", f"dma_wr_engine<br>{SMALL}AW/W/B · bursts de C · WLAST<br>fila de 2 entradas (c_rdata)</span>",
      560, 560, 220, 80, ST_GRAY)
    v("acc", f"Acelerador<br>{SMALL}buf A/B × 2 bancos<br>malha T×T<br>banco C</span>",
      860, 180, 220, 460, ST_MASTER)
    v("cpu", "CPU RV32I", 860, 30, 220, 50, ST_MASTER)
    v("xbar", "axi_xbar (AXI4)", 40, 720, 740, 50, ST_SWITCH)

    e("e_rc", "regs", "ctrl", (220, 65), (340, 65), "", ctl)
    v("rc_lbl", f"{SMALL}start · soft_reset →<br>← done · error · err_code</span>", 160, 104, 170, 30,
      ST_TEXT + "fontSize=10;fontColor=#0B6F8A;")
    e("e_irq", "regs", "cpu", (200, 30), (970, 30), "irq", ST_IRQ, via=[(200, 15), (970, 15)])
    e("e_cl", "ctrl", "load", (360, 100), (100, 180), "run · stop", ctl, via=[(360, 150), (100, 150)], offset=(-60, 0))
    e("e_cb", "ctrl", "bank", (410, 100), (410, 180), "reset dos<br>bancos", ctl)
    e("e_cc", "ctrl", "comp", (670, 100), (670, 180), "run · stop<br>n_blocks", ctl)
    e("e_cs", "ctrl", "store", (540, 100), (620, 440), "run · stop", ctl, via=[(540, 420), (620, 420)],
      offset=(0, -30))
    e("e_lb", "load", "bank", (260, 220), (300, 220), "", ST_DATA + "startArrow=classic;")
    e("e_bc", "bank", "comp", (520, 220), (560, 220), "", ST_DATA + "startArrow=classic;")
    e("e_lr", "load", "rd", (150, 260), (150, 330), "rd_cmd →<br>← rd_done", ctl)
    e("e_sw", "store", "wr", (670, 510), (670, 560), "wr_cmd → ← wr_done", ctl)
    e("e_rx", "rd", "xbar", (150, 410), (150, 720), "M1 · AR / R<br>" + BUS, ST_AXI)
    e("e_wx", "wr", "xbar", (670, 640), (670, 720), "M1 · AW / W / B<br>" + BUS, ST_AXI)
    e("e_s1", "xbar", "regs", (40, 745), (40, 65), "S1 · AXI4", ST_AXI, via=[(10, 745), (10, 65)],
      offset=(30, 200))
    e("e_ra", "rd", "acc", (260, 360), (860, 360), "buf_a_we / buf_b_we · bank · row · word · data[32]", one_way)
    e("e_ca", "comp", "acc", (780, 220), (860, 220), "tile_start, tile_bank,<br>first_k, last_k →<br>← busy, tile_done",
      ST_SIDEBAND, offset=(0, -35))
    e("e_as", "acc", "store", (860, 475), (780, 475), "c_valid →<br>← c_release", ST_SIDEBAND)
    e("e_wa", "wr", "acc", (780, 600), (860, 600), "c_rd, row, col →<br>← c_rdata", ST_SIDEBAND)
    return d


def dma_ctrl_fsm():
    d = Diagram("dma_ctrl_fsm", "dma_ctrl", 1000, 540)
    v, e = d.vertex, d.edge
    _st(v, "idle", "IDLE", "busy = 0", 300, 40)
    _st(v, "check", "CHECK", "dimensões ≥ 1 · ADDR alinhados · strides", 300, 140)
    _st(v, "run", "RUN", "run = 1 · load, compute, store ativos", 300, 240)
    _st(v, "done", "DONE", "pulso done → STATUS.DONE, irq", 300, 440, ST_STATE_END)
    _st(v, "drain", "DRAIN", "stop = 1 · termina bursts e tile", 650, 240, ST_STATE_ERR)
    _st(v, "error", "ERROR", "STATUS.ERROR = 1 · ERR_CODE", 650, 340, ST_STATE_ERR)

    e("t1", "idle", "check", (430, 100), (430, 140), "start", ST_TRANS)
    e("t2", "check", "run", (430, 200), (430, 240), "config válida", ST_TRANS)
    e("t3", "check", "error", (560, 170), (910, 370), "dimensão 0 (1) ·<br>desalinhado (2)", ERR,
      via=[(950, 170), (950, 370)], offset=(0, -40))
    e("t4", "run", "drain", (560, 270), (650, 270), "rd_err · wr_err<br>· soft_reset", ERR, offset=(0, -25))
    e("t5", "drain", "error", (780, 300), (780, 340), "ociosos ∧ erro", ERR, offset=(50, 0))
    e("t6", "drain", "idle", (780, 240), (560, 70), "ociosos ∧ soft_reset", ST_TRANS, via=[(780, 70)])
    e("t7", "error", "done", (780, 400), (560, 470), "1 ciclo", ST_TRANS, via=[(780, 470)])
    e("t8", "run", "done", (430, 300), (430, 440), "load_end ∧ compute_end<br>∧ store_end", ST_TRANS)
    e("t9", "done", "idle", (300, 470), (300, 70), "1 ciclo", ST_TRANS, via=[(200, 470), (200, 70)])
    v("note", "ociosos = rd_idle ∧ wr_idle ∧ ¬busy ∧ ¬c_valid", 40, 500, 500, 25, ST_TEXT + "fontSize=11;")
    return d


def dma_load_fsm():
    d = Diagram("dma_load_fsm", "dma_load", 1100, 780)
    v, e = d.vertex, d.edge
    _st(v, "idle", "L_IDLE", "—", 320, 40)
    _st(v, "wait", "L_WAIT_BANK", "espera banco ld_ptr livre", 320, 140)
    _st(v, "row", "L_ROW", "rd_cmd: addr, nbytes, sel, bank, row", 320, 240)
    _st(v, "wrd", "L_WAIT_RD", "espera rd_done", 320, 340)
    _st(v, "nxt", "L_NEXT_ROW", "r += 1 · ptr += STRIDE", 320, 440)
    _st(v, "blk", "L_BLOCK_DONE", "banco → FULL (first_k, last_k)<br>ld_ptr ^= PINGPONG · avança k0/j0/i0",
        320, 560, h=70)
    _st(v, "end", "L_END", "load_end = 1", 320, 690, ST_STATE_END)

    e("t1", "idle", "wait", (450, 100), (450, 140), "run · i0 = j0 = k0 = 0", ST_TRANS)
    e("t2", "wait", "row", (450, 200), (450, 240), "bank[ld_ptr] = EMPTY ∧ serial_ok<br>→ LOADING", ST_TRANS)
    e("t3", "row", "wrd", (450, 300), (450, 340), "rd_cmd_ready", ST_TRANS)
    e("t4", "wrd", "nxt", (450, 400), (450, 440), "rd_done", ST_TRANS)
    e("t5", "nxt", "row", (320, 470), (320, 270), "r &lt; T−1, ou<br>fim de A → B", ST_TRANS,
      via=[(220, 470), (220, 270)], offset=(-30, 0))
    e("t6", "nxt", "blk", (450, 500), (450, 560), "r = T−1 ∧ sel = B", ST_TRANS)
    e("t7", "blk", "wait", (580, 595), (580, 170), "falta bloco", ST_TRANS, via=[(680, 595), (680, 170)],
      offset=(40, 0))
    e("t8", "blk", "end", (450, 630), (450, 690), "último bloco", ST_TRANS)
    e("t9", "wait", "end", (320, 185), (320, 720), "stop", ERR, via=[(120, 185), (120, 720)])
    e("t10", "end", "idle", (580, 720), (580, 70), "¬run", ST_TRANS, via=[(780, 720), (780, 70)])
    v("note", "<b>serial_ok</b><br>PINGPONG = 1: sempre 1<br>PINGPONG = 0: ¬(k0 = 0 ∧ tile_pendente)<br><br>"
              "<b>nbytes</b><br>A: i0+r ≥ M → 0, senão min(T, K−k0)<br>B: k0+r ≥ K → 0, senão min(T, N−j0)<br>"
              "0 = linha de padding, sem AR", 820, 40, 270, 200, ST_BOX)
    return d


def dma_compute_fsm():
    d = Diagram("dma_compute_fsm", "dma_compute", 1000, 660)
    v, e = d.vertex, d.edge
    _st(v, "idle", "C_IDLE", "—", 320, 40)
    _st(v, "wait", "C_WAIT_FULL", "espera banco cp_ptr cheio", 320, 140)
    _st(v, "start", "C_START", "tile_start · tile_bank = cp_ptr<br>banco → COMPUTING", 320, 240)
    _st(v, "wdone", "C_WAIT_DONE", "malha calculando (3T−1 ciclos)", 320, 340)
    _st(v, "free", "C_FREE", "banco → EMPTY · cp_ptr ^= PINGPONG · cnt += 1", 320, 440)
    _st(v, "end", "C_END", "compute_end = 1", 320, 560, ST_STATE_END)

    e("t1", "idle", "wait", (450, 100), (450, 140), "run · cnt = 0", ST_TRANS)
    e("t2", "wait", "start", (450, 200), (450, 240), "bank[cp_ptr] = FULL ∧ ¬busy", ST_TRANS)
    e("t3", "start", "wdone", (450, 300), (450, 340), "1 ciclo", ST_TRANS)
    e("t4", "wdone", "free", (450, 400), (450, 440), "tile_done", ST_TRANS)
    e("t5", "free", "wait", (580, 470), (580, 170), "cnt &lt; n_blocks", ST_TRANS, via=[(680, 470), (680, 170)],
      offset=(45, 0))
    e("t6", "free", "end", (450, 500), (450, 560), "cnt = n_blocks", ST_TRANS)
    e("t7", "wait", "end", (320, 170), (320, 590), "stop ∧ ¬busy", ERR, via=[(180, 170), (180, 590)])
    e("t8", "end", "idle", (580, 590), (580, 70), "¬run", ST_TRANS, via=[(780, 590), (780, 70)])
    return d


def dma_store_fsm():
    d = Diagram("dma_store_fsm", "dma_store", 1100, 780)
    v, e = d.vertex, d.edge
    _st(v, "idle", "S_IDLE", "—", 320, 40)
    _st(v, "wait", "S_WAIT_C", "espera c_valid", 320, 140)
    _st(v, "row", "S_ROW", "wr_cmd: addr = ptr_c, nwords = min(T, N−j0s)", 320, 240)
    _st(v, "wwr", "S_WAIT_WR", "espera wr_done", 320, 340)
    _st(v, "nxt", "S_NEXT_ROW", "r += 1 · ptr_c += STRIDE_C", 320, 440)
    _st(v, "rel", "S_RELEASE", "c_release · avança j0s (e i0s)", 320, 560)
    _st(v, "end", "S_END", "store_end = 1", 320, 690, ST_STATE_END)

    e("t1", "idle", "wait", (450, 100), (450, 140), "run · i0s = j0s = 0", ST_TRANS)
    e("t2", "wait", "row", (450, 200), (450, 240), "c_valid ∧ ¬stop · r = 0", ST_TRANS)
    e("t3", "row", "wwr", (450, 300), (450, 340), "wr_cmd_ready", ST_TRANS)
    e("t4", "wwr", "nxt", (450, 400), (450, 440), "wr_done", ST_TRANS)
    e("t5", "nxt", "row", (320, 470), (320, 270), "r &lt; T−1", ST_TRANS, via=[(220, 470), (220, 270)],
      offset=(-25, 0))
    e("t6", "nxt", "rel", (450, 500), (450, 560), "r = T−1", ST_TRANS)
    e("t7", "rel", "wait", (580, 575), (580, 180), "falta tile", ST_TRANS, via=[(680, 575), (680, 180)],
      offset=(35, 0))
    e("t8", "row", "rel", (580, 260), (580, 598), "linha fora<br>(i0s + r ≥ M)", ST_TRANS,
      via=[(760, 260), (760, 598)], offset=(0, 60))
    e("t9", "wait", "rel", (580, 150), (580, 612), "c_valid ∧ stop<br>(descarta)", ERR,
      via=[(860, 150), (860, 612)], offset=(0, 100))
    e("t10", "rel", "end", (450, 620), (450, 690), "último tile", ST_TRANS)
    e("t11", "wait", "end", (320, 185), (320, 720), "stop ∧ ¬c_valid<br>∧ compute_end", ERR,
      via=[(120, 185), (120, 720)])
    e("t12", "end", "idle", (580, 720), (580, 70), "¬run", ST_TRANS, via=[(960, 720), (960, 70)])
    return d


def axi_rd_wr_fsm():
    d = Diagram("axi_rd_wr_fsm", "Motores AXI", 1100, 580)
    v, e = d.vertex, d.edge
    w = 220
    v("fr", "dma_rd_engine — canais AR / R", 20, 20, 500, 540, ST_FRAME)
    v("fw", "dma_wr_engine — canais AW / W / B", 560, 20, 520, 540, ST_FRAME)

    _st(v, "ri", "R_IDLE", "rd_cmd_ready = 1", 150, 60, w=w)
    _st(v, "ra", "R_AR", "ARVALID · ARLEN = seg_len−1", 150, 160, w=w)
    _st(v, "rd", "R_DATA", "RREADY = 1 · 1 palavra/beat → buffer", 150, 260, w=w)
    _st(v, "rz", "R_ZERO", "escreve 0 nas palavras restantes", 150, 380, w=w)
    _st(v, "rdn", "R_DONE", "pulso rd_done", 150, 480, ST_STATE_END, w=w)
    e("r1", "ri", "ra", (260, 120), (260, 160), "cmd · nbytes &gt; 0", ST_TRANS)
    e("r2", "ra", "rd", (260, 220), (260, 260), "ARREADY", ST_TRANS)
    e("r3", "rd", "ra", (150, 290), (150, 190), "RLAST ∧<br>resta seg.", ST_TRANS, via=[(80, 290), (80, 190)],
      offset=(-5, 0))
    e("r4", "rd", "rz", (260, 320), (260, 380), "RLAST ∧ word &lt; WPR", ST_TRANS)
    e("r5", "rd", "rdn", (370, 290), (370, 500), "RLAST ∧<br>word = WPR", ST_TRANS, via=[(440, 290), (440, 500)],
      offset=(-10, 40))
    e("r6", "ri", "rz", (370, 80), (370, 400), "cmd ·<br>nbytes = 0", ST_TRANS, via=[(490, 80), (490, 400)],
      offset=(0, -90))
    e("r7", "rz", "rdn", (260, 440), (260, 480), "word = WPR−1", ST_TRANS)
    e("r8", "rdn", "ri", (150, 510), (150, 80), "", ST_TRANS, via=[(40, 510), (40, 80)])

    _st(v, "wi", "W_IDLE", "wr_cmd_ready = 1 · enche fila de C", 690, 60, w=w)
    _st(v, "wa", "W_ADDR", "AWVALID · WVALID = fila ≠ ∅", 690, 160, w=w)
    _st(v, "wd", "W_DATA", "WVALID = fila ≠ ∅ · WLAST no fim", 690, 260, w=w)
    _st(v, "wb", "W_RESP", "BREADY = 1", 690, 380, w=w)
    _st(v, "wdn", "W_DONE", "pulso wr_done", 690, 480, ST_STATE_END, w=w)
    e("w1", "wi", "wa", (800, 120), (800, 160), "cmd aceito", ST_TRANS)
    e("w2", "wa", "wd", (800, 220), (800, 260), "AWREADY (W ainda em curso)", ST_TRANS)
    e("w3", "wa", "wb", (910, 190), (910, 400), "aw_done ∧<br>w_done", ST_TRANS, via=[(1000, 190), (1000, 400)],
      offset=(0, 0))
    e("w4", "wd", "wb", (800, 320), (800, 380), "último beat aceito", ST_TRANS)
    e("w5", "wb", "wa", (690, 410), (690, 190), "BVALID ∧<br>resta seg.", ST_TRANS, via=[(620, 410), (620, 190)],
      offset=(-5, 0))
    e("w6", "wb", "wdn", (800, 440), (800, 480), "BVALID ∧ fim da linha", ST_TRANS)
    e("w7", "wdn", "wi", (690, 510), (690, 80), "", ST_TRANS, via=[(590, 510), (590, 80)])
    return d


def axi_xbar():
    d = Diagram("axi_xbar", "axi_xbar", 980, 610)
    v, e = d.vertex, d.edge
    v("m0", f"M0 · cpu_axi_adapter<br>{SMALL}ID_W = 1 (ID = 0)</span>", 120, 30, 240, 60, ST_ADAPTER)
    v("m1", f"M1 · DMA<br>{SMALL}ID_W = 1 (ID = 0)</span>", 620, 30, 240, 60, ST_GRAY)
    v("reg", "axi_xbar 2×2 — AXI4", 40, 130, 900, 330, ST_REGION)
    v("d0", f"decodificador M0<br>{SMALL}AxADDR[31:28]</span>", 100, 160, 280, 50, ST_SWITCH)
    v("d1", f"decodificador M1<br>{SMALL}AxADDR[31:28]</span>", 600, 160, 280, 50, ST_SWITCH)
    v("a0", f"S0 (0x1): árbitro AR + árbitro AW<br>{SMALL}round-robin · lock até RLAST / B</span>",
      60, 280, 260, 90, ST_SWITCH)
    v("a1", f"S1 (0x4): árbitro AR + árbitro AW<br>{SMALL}round-robin · lock até RLAST / B</span>",
      360, 280, 260, 90, ST_SWITCH)
    v("df", f"slave padrão<br>{SMALL}DECERR · ARLEN+1 beats<br>consome W até WLAST</span>",
      660, 280, 260, 90, ST_STATE_ERR)
    v("nt", "W → wr_target[m] (WREADY = 0 até o AW)<br>"
            "ID lado slave = {m_idx, ID}<br>resposta volta pelo bit m_idx", 660, 380, 270, 70,
      ST_TEXT + "fontSize=11;")
    v("s0", f"S0 · axi_mem_ctrl<br>{SMALL}DMEM 0x1000_0000</span>", 60, 520, 260, 60, ST_ADAPTER)
    v("s1", f"S1 · dma_regs<br>{SMALL}0x4000_0000</span>", 360, 520, 260, 60, ST_GRAY)

    e("e_m0", "m0", "d0", (240, 90), (240, 160), "", ST_AXI)
    e("e_m1", "m1", "d1", (740, 90), (740, 160), "", ST_AXI)
    e("e00", "d0", "a0", (150, 210), (150, 280), "", ST_DATA)
    e("e01", "d0", "a1", (300, 210), (400, 280), "", ST_DATA, via=[(300, 240), (400, 240)])
    e("e0d", "d0", "df", (360, 210), (700, 280), "", ST_DATA, via=[(360, 230), (700, 230)])
    e("e10", "d1", "a0", (620, 210), (260, 280), "", ST_DATA, via=[(620, 260), (260, 260)])
    e("e11", "d1", "a1", (650, 210), (560, 280), "", ST_DATA, via=[(650, 250), (560, 250)])
    e("e1d", "d1", "df", (820, 210), (820, 280), "", ST_DATA)
    e("e_s0", "a0", "s0", (190, 370), (190, 520), "AXI4 · S_ID_W = 2", ST_AXI)
    e("e_s1", "a1", "s1", (490, 370), (490, 520), "AXI4 · S_ID_W = 2", ST_AXI)
    return d


def axi_mem_ctrl_fsm():
    d = Diagram("axi_mem_ctrl_fsm", "axi_mem_ctrl", 960, 530)
    v, e = d.vertex, d.edge
    _st(v, "idle", "M_IDLE", "escolhe AR ou AW (round-robin)", 360, 40)
    _st(v, "rd", "M_RD", "lê SRAM · fila de 2 · RVALID · RLAST", 120, 180)
    _st(v, "wr", "M_WR", "WREADY = 1 · escreve com WSTRB", 560, 180)
    _st(v, "wresp", "M_WR_RESP", "BVALID · BRESP · BID", 560, 320)
    v("sram", f"SRAM DMEM<br>{SMALL}16 K × 32 · single-port · leitura 1 ciclo</span>", 240, 440, 400, 60, ST_GRAY)

    e("t1", "idle", "rd", (400, 100), (250, 180), "AR · ARREADY", ST_TRANS, via=[(400, 140), (250, 140)])
    e("t2", "idle", "wr", (590, 100), (590, 180), "AW · AWREADY", ST_TRANS)
    e("t3", "rd", "idle", (120, 210), (360, 70), "beat com RLAST aceito", ST_TRANS, via=[(60, 210), (60, 70)],
      offset=(80, -12))
    e("t4", "wr", "wresp", (690, 240), (690, 320), "WLAST", ST_TRANS)
    e("t5", "wresp", "idle", (820, 350), (620, 70), "BREADY", ST_TRANS, via=[(900, 350), (900, 70)])
    e("t6", "rd", "sram", (300, 240), (300, 440), "addr, rd", ST_DATA)
    e("t7", "wr", "sram", (560, 210), (520, 440), "addr, wdata, WSTRB", ST_DATA, via=[(520, 210)])
    return d


def sequencia():
    d = Diagram("sequencia", "Sequência", 960, 800)
    v, e = d.vertex, d.edge
    irq = ST_MSG + "strokeColor=#D0021B;fontColor=#D0021B;"
    up = (0, -10)   # rotulo acima da seta

    # quadros de loop primeiro (ficam ao fundo)
    v("loop_tile", "loop [cada tile (i0, j0)]", 310, 215, 630, 420, ST_FRAME)
    v("loop_k", "loop [cada bloco k0]", 325, 245, 600, 245, ST_FRAME)

    lanes = [("cpu", "CPU RV32I", 100, ST_MASTER), ("regs", "Regs DMA (S1)", 290, ST_GRAY),
             ("dma", "DMA", 480, ST_GRAY), ("dmem", "DMEM", 670, ST_GRAY), ("acc", "Acelerador", 860, ST_MASTER)]
    x = {}
    for key, label, cx, st in lanes:
        x[key] = cx
        v(f"ll_{key}", "", cx - 1, 60, 2, 720, ST_LIFELINE)
        v(f"hd_{key}", label, cx - 70, 20, 140, 40, st)

    def msg(cid, src, dst, y, label, style=ST_MSG):
        e(cid, f"ll_{src}", f"ll_{dst}", (x[src], y), (x[dst], y), label, style, offset=up)

    msg("m1", "cpu", "regs", 95, "sw ADDR_A/B/C, DIM_M/N/K")
    msg("m2", "cpu", "regs", 135, "sw CTRL = START | IRQ_EN")
    msg("m3", "regs", "dma", 175, "start")
    v("n_wfi", "wfi → WAIT", 40, 195, 120, 30, ST_NOTE)
    msg("m4", "dma", "dmem", 285, "AR burst: linhas de A e B")
    msg("m5", "dmem", "dma", 315, "R: 4 × int8 por palavra", ST_RET)
    msg("m6", "dma", "acc", 350, "buf A/B: bank, row, word, data[32]")
    msg("m7", "dma", "acc", 390, "tile_start (tile_bank, first_k, last_k)")
    v("n_comp", "3T−1 ciclos", 790, 405, 140, 30, ST_NOTE)
    msg("m8", "acc", "dma", 465, "tile_done")
    msg("m9", "dma", "acc", 520, "c_valid → c_rd, c_row, c_col")
    msg("m10", "acc", "dma", 550, "c_rdata[31:0]", ST_RET)
    msg("m11", "dma", "dmem", 585, "AW + W burst: linha de C (int32)")
    msg("m12", "dmem", "dma", 612, "B: OKAY → c_release", ST_RET)
    msg("m13", "dma", "cpu", 670, "irq = DONE ∧ IRQ_EN (acorda do wfi)", irq)
    msg("m14", "cpu", "regs", 710, "lw STATUS (DONE = 1)")
    msg("m15", "cpu", "regs", 750, "sw STATUS = DONE (W1C)")
    v("n_irq", "irq = 0", 300, 735, 70, 30, ST_NOTE)
    return d


if __name__ == "__main__":
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    out.mkdir(parents=True, exist_ok=True)
    for build in (top_level, accel, dma_blocks, dma_ctrl_fsm, dma_load_fsm, dma_compute_fsm,
                  dma_store_fsm, axi_rd_wr_fsm, axi_xbar, axi_mem_ctrl_fsm, sequencia):
        diagram = build()
        for ext, write in ((".drawio", diagram.write_drawio), (".svg", diagram.write_svg)):
            path = out / (diagram.diagram_id + ext)
            write(path)
            print(f"escrito {path}")
