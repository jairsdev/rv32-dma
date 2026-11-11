#!/usr/bin/env python3
"""Gera os diagramas da especificacao em docs/img/ (.drawio editavel + .svg para o GitHub).

Uso: python3 scripts/gen_drawio.py [diretorio_saida]

Diagramas:
  top_level  - blocos do sistema: CPU multiciclo (porta I na IMEM local, porta D no AXI),
               axi_xbar 2x2 AXI4 (burst), DMA (master M1 + regs S1), DMEM, acelerador via sideband
  accel      - acelerador output-stationary (exemplo T = 4) com bancos ping-pong e banco C
  dma_fsm    - maquina de estados do DMA (tiling i0/j0/k0) e sub-FSM do master AXI4-Lite
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


def dma_fsm():
    d = Diagram("dma_fsm", "FSM do DMA", 920, 800)
    v, e = d.vertex, d.edge
    err = ST_TRANS + "dashed=1;strokeColor=#D0021B;fontColor=#D0021B;"

    v("idle", f"IDLE<br>{SMALL}BUSY = 0</span>", 300, 40, 240, 50, ST_STATE)
    v("check", f"CHECK<br>{SMALL}DIM ≥ 1 · ADDR alinhados<br>calcula STRIDE_A/B/C</span>", 300, 130, 240, 60, ST_STATE)
    v("load_a", f"LOAD_A<br>{SMALL}A[i0:+T][k0:+T] → buf A<br>(0 fora de M, K)</span>", 300, 230, 240, 60, ST_STATE)
    v("load_b", f"LOAD_B<br>{SMALL}B[k0:+T][j0:+T] → buf B<br>(0 fora de K, N)</span>", 300, 330, 240, 60, ST_STATE)
    v("compute", f"COMPUTE<br>{SMALL}tile_start, first_k = (k0 = 0)<br>espera tile_done</span>",
      300, 430, 240, 60, ST_STATE)
    v("store_c", f"STORE_C<br>{SMALL}acc → C[i0:+T][j0:+T]<br>só i &lt; M e j &lt; N</span>",
      300, 560, 240, 60, ST_STATE)
    v("error", f"ERROR<br>{SMALL}STATUS.ERROR = 1<br>ERR_CODE</span>", 620, 240, 220, 70, ST_STATE_ERR)
    v("done", f"DONE<br>{SMALL}STATUS.DONE = 1, BUSY = 0<br>irq = DONE ∧ IRQ_EN</span>",
      620, 560, 220, 60, ST_STATE_END)

    e("t_start", "idle", "check", (420, 90), (420, 130), "CTRL.START", ST_TRANS)
    e("t_ok", "check", "load_a", (420, 190), (420, 230), "ok · i0 = j0 = k0 = 0", ST_TRANS)
    e("t_bad", "check", "error", (540, 160), (730, 240), "config inválida", ST_TRANS, via=[(730, 160)])
    e("t_a", "load_a", "load_b", (420, 290), (420, 330), "buf A cheio", ST_TRANS)
    e("t_b", "load_b", "compute", (420, 390), (420, 430), "buf B cheio", ST_TRANS)
    e("t_k", "compute", "load_a", (300, 460), (300, 270), "tile_done e<br>falta bloco k0<br>k0 += T", ST_TRANS,
      via=[(240, 460), (240, 270)])
    e("t_last_k", "compute", "store_c", (420, 490), (420, 560), "tile_done e<br>último bloco k0", ST_TRANS)
    e("t_tile", "store_c", "load_a", (300, 590), (300, 250),
      "falta tile:<br>j0 += T (fim da linha:<br>i0 += T, j0 = 0)<br>k0 = 0", ST_TRANS,
      via=[(150, 590), (150, 250)], offset=(-50, 0))
    e("t_done", "store_c", "done", (540, 590), (620, 590), "último tile", ST_TRANS)
    e("t_resp", "load_b", "error", (540, 360), (620, 290), "RESP ≠ OKAY<br>(LOAD_A/B, STORE_C)", err,
      via=[(580, 360), (580, 290)], offset=(85, 20))
    e("t_err", "error", "done", (730, 310), (730, 560), "sinaliza fim<br>(DONE = 1)", ST_TRANS)
    e("t_idle", "done", "idle", (840, 590), (540, 65), "1 ciclo", ST_TRANS, via=[(890, 590), (890, 65)])

    # sub-FSM do master AXI4-Lite
    v("axi", "sub-FSM do master AXI4-Lite (usada por LOAD_A, LOAD_B e STORE_C)", 40, 655, 800, 130, ST_FRAME)
    v("rd_addr", f"RD_ADDR<br>{SMALL}ARVALID = 1</span>", 60, 690, 160, 50, ST_STATE)
    v("rd_data", f"RD_DATA<br>{SMALL}RREADY = 1</span>", 280, 690, 160, 50, ST_STATE)
    v("wr_req", f"WR_REQ<br>{SMALL}AWVALID = WVALID = 1</span>", 460, 690, 145, 50, ST_STATE)
    v("wr_resp", f"WR_RESP<br>{SMALL}BREADY = 1</span>", 665, 690, 155, 50, ST_STATE)
    e("a_ar", "rd_addr", "rd_data", (220, 715), (280, 715), "ARREADY", ST_TRANS, offset=(0, -12))
    e("a_r", "rd_data", "rd_addr", (360, 740), (140, 740), "RVALID: próxima palavra", ST_TRANS,
      via=[(360, 765), (140, 765)])
    e("a_aw", "wr_req", "wr_resp", (605, 715), (665, 715), "AW e W<br>aceitos", ST_TRANS, offset=(0, -18))
    e("a_b", "wr_resp", "wr_req", (742, 740), (532, 740), "BVALID: próxima palavra", ST_TRANS,
      via=[(742, 765), (532, 765)])
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
    for build in (top_level, accel, dma_fsm, sequencia):
        diagram = build()
        for ext, write in ((".drawio", diagram.write_drawio), (".svg", diagram.write_svg)):
            path = out / (diagram.diagram_id + ext)
            write(path)
            print(f"escrito {path}")
