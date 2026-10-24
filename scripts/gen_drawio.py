#!/usr/bin/env python3
"""Gera docs/img/top_level.drawio (diagrama de blocos top-level).

Uso: python3 scripts/gen_drawio.py [saida.drawio]

O diagrama segue o padrao da figura de referencia (ARM CoreLink NIC-400):
masters -> adapters -> switch central -> switch secundario aninhado ->
controladores de memoria -> memorias. Todos os links AXI sao AXI4-Lite 32 bits.
O XML e emitido sem compressao para ser editavel no draw.io e versionavel.
"""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

DEFAULT_OUT = Path(__file__).resolve().parent.parent / "docs" / "img" / "top_level.drawio"

# ---------------------------------------------------------------- estilos
BASE = "whiteSpace=wrap;html=1;fontSize=12;fontStyle=1;"
ST_MASTER = BASE + "rounded=1;fillColor=#0E8FB4;strokeColor=#0B6F8A;fontColor=#FFFFFF;"
ST_ADAPTER = BASE + "rounded=1;fillColor=#1CC0DD;strokeColor=#119BB3;fontColor=#FFFFFF;"
ST_SWITCH = BASE + "rounded=1;fillColor=#7ED321;strokeColor=#5FA316;fontColor=#1B2A05;"
ST_GRAY = BASE + "rounded=1;fillColor=#808285;strokeColor=#5A5C5E;fontColor=#FFFFFF;"
ST_REGION = ("rounded=0;whiteSpace=wrap;html=1;fillColor=#E6ECEC;strokeColor=none;"
             "fontSize=11;fontStyle=2;fontColor=#4A5555;align=left;verticalAlign=top;spacingLeft=8;spacingTop=4;")
ST_TEXT = "text;html=1;strokeColor=none;fillColor=none;align=left;verticalAlign=middle;whiteSpace=wrap;"

EDGE = ("edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;fontSize=10;labelBackgroundColor=#FFFFFF;"
        "startArrow=classic;startFill=1;endArrow=classic;endFill=1;strokeWidth=2;strokeColor=#333333;")
ST_AXI = EDGE
ST_NATIVE = EDGE + "strokeWidth=1;startArrow=none;endArrow=classic;dashed=0;strokeColor=#0B6F8A;"
ST_SIDEBAND = EDGE + "dashed=1;strokeColor=#0E8FB4;"
ST_IRQ = EDGE + "dashed=1;startArrow=none;strokeColor=#D0021B;fontColor=#D0021B;"

BUS = "<b>/</b> 32 · AXI4-Lite"

# ---------------------------------------------------------------- modelo
cells = []   # (kind, attrs, children)
geom = {}    # id -> (x, y, w, h)


def vertex(cid, label, x, y, w, h, style):
    geom[cid] = (x, y, w, h)
    cells.append(("v", dict(id=cid, value=label, style=style), (x, y, w, h)))


def _ratio(cid, pt):
    x, y, w, h = geom[cid]
    return (pt[0] - x) / w, (pt[1] - y) / h


def edge(cid, src, dst, a, b, label, style, via=()):
    """Aresta de src (ponto absoluto a) ate dst (ponto absoluto b), com waypoints opcionais."""
    ex, ey = _ratio(src, a)
    nx, ny = _ratio(dst, b)
    st = (f"{style}exitX={ex:.4f};exitY={ey:.4f};exitDx=0;exitDy=0;"
          f"entryX={nx:.4f};entryY={ny:.4f};entryDx=0;entryDy=0;")
    cells.append(("e", dict(id=cid, value=label, style=st, source=src, target=dst), list(via)))


# ---------------------------------------------------------------- diagrama
# regioes sombreadas (primeiro, para ficarem ao fundo)
vertex("reg_core", "", 20, 255, 1080, 110, ST_REGION)
vertex("reg_periph", "NIC-400 secundário (periféricos)", 650, 15, 450, 225, ST_REGION)

# masters
vertex("cpu_i", "CPU RV32I<br>Porta I (fetch)", 40, 40, 150, 60, ST_MASTER)
vertex("cpu_d", "CPU RV32I<br>Porta D (load/store)", 220, 40, 150, 60, ST_MASTER)
vertex("dma", "DMA Controller<br><span style='font-weight:normal;font-size:11px'>FSM própria · master AXI4-Lite<br>+ regs DMA (slave AXI4-Lite)</span>",
       420, 40, 200, 110, ST_GRAY)

# adapters (equivalentes ao L2C-310 da figura)
vertex("ad_i", "cpu_axi_adapter", 40, 150, 150, 50, ST_ADAPTER)
vertex("ad_d", "cpu_axi_adapter", 220, 150, 150, 50, ST_ADAPTER)

# switch secundario + acelerador
vertex("acc", "Acelerador MatMul<br><span style='font-weight:normal;font-size:11px'>Buffers A/B/C + Systolic Array<br>ARRAY_SIZE×ARRAY_SIZE (2/4/8)<br>+ regs ACC (slave AXI4-Lite)</span>",
       880, 30, 200, 100, ST_MASTER)
vertex("sw", "axi_periph_switch<br><span style='font-weight:normal;font-size:11px'>1×2 · decode addr[15:12]<br>0x4000_0000 regs DMA · 0x4000_1000 regs ACC</span>",
       670, 165, 410, 60, ST_SWITCH)

# switch central
vertex("xbar", "axi_xbar — Core Link (equiv. NIC-400)<br><span style='font-weight:normal;font-size:11px'>"
       "3 masters × 3 slaves · decode addr[31:28] · round-robin · AXI4-Lite 32 bits</span>",
       40, 280, 1040, 60, ST_SWITCH)

# controladores de memoria + memorias
vertex("mc_i", "axi_mem_ctrl #0<br><span style='font-weight:normal;font-size:11px'>slave AXI4-Lite → interface SRAM</span>",
       100, 410, 300, 60, ST_ADAPTER)
vertex("mc_d", "axi_mem_ctrl #1<br><span style='font-weight:normal;font-size:11px'>slave AXI4-Lite → interface SRAM</span>",
       450, 410, 300, 60, ST_ADAPTER)
vertex("ram_i", "SRAM IMEM<br><span style='font-weight:normal;font-size:11px'>firmware · 64 KiB</span>",
       100, 520, 300, 60, ST_GRAY)
vertex("ram_d", "SRAM DMEM compartilhada<br><span style='font-weight:normal;font-size:11px'>matrizes A, B, C · 64 KiB</span>",
       450, 520, 300, 60, ST_GRAY)

# CPU -> adapter (interface nativa estilo PicoRV32)
edge("e_cpu_i", "cpu_i", "ad_i", (115, 100), (115, 150), "nativa<br>valid/ready · 32", ST_NATIVE)
edge("e_cpu_d", "cpu_d", "ad_d", (295, 100), (295, 150), "nativa<br>valid/ready · 32", ST_NATIVE)

# masters -> xbar
edge("e_m0", "ad_i", "xbar", (115, 200), (115, 280), "M0 · " + BUS, ST_AXI)
edge("e_m1", "ad_d", "xbar", (295, 200), (295, 280), "M1 · " + BUS, ST_AXI)
edge("e_m2", "dma", "xbar", (520, 150), (520, 280), "M2 · " + BUS, ST_AXI)

# xbar -> slaves
edge("e_s0", "xbar", "mc_i", (250, 340), (250, 410), "S0 · IMEM 0x0000_0000<br>" + BUS, ST_AXI)
edge("e_s1", "xbar", "mc_d", (600, 340), (600, 410), "S1 · DMEM 0x1000_0000<br>" + BUS, ST_AXI)
edge("e_s2", "sw", "xbar", (900, 225), (900, 280), "S2 · PERIPH 0x4000_0000<br>" + BUS, ST_AXI)

# controlador -> memoria
edge("e_r0", "mc_i", "ram_i", (250, 470), (250, 520), "interface SRAM · 32", ST_NATIVE)
edge("e_r1", "mc_d", "ram_d", (600, 470), (600, 520), "interface SRAM · 32", ST_NATIVE)

# periféricos
edge("e_acc", "acc", "sw", (980, 130), (980, 165), "regs ACC · " + BUS, ST_AXI)
edge("e_dmareg", "dma", "sw", (620, 128), (730, 165), "regs DMA · " + BUS, ST_AXI,
     via=[(730, 128)])

# sideband DMA <-> acelerador (nao-AXI) e IRQ
edge("e_side", "dma", "acc", (620, 62), (880, 62),
     "sideband (não-AXI)<br>buf A/B: we, addr, data[8] · C: rd, data[32]<br>tile_start, first_k, busy, tile_done",
     ST_SIDEBAND)
edge("e_irq", "dma", "cpu_d", (420, 70), (370, 70), "irq", ST_IRQ)

# legenda
vertex("leg_box", "", 800, 410, 300, 200, "rounded=0;html=1;fillColor=#FFFFFF;strokeColor=#BBBBBB;")
vertex("leg_title", "Legenda", 810, 415, 100, 20, ST_TEXT + "fontStyle=1;fontSize=12;")
legend = [
    ("leg_1", ST_MASTER, "CPU / Acelerador"),
    ("leg_2", ST_ADAPTER, "Adapter / controlador de memória"),
    ("leg_3", ST_SWITCH, "Switch / crossbar AXI4-Lite"),
    ("leg_4", ST_GRAY, "DMA / memórias"),
]
for i, (lid, st, txt) in enumerate(legend):
    y = 440 + i * 24
    vertex(lid, "", 815, y, 28, 16, st)
    vertex(lid + "_t", txt, 852, y - 2, 240, 20, ST_TEXT + "fontSize=11;")
vertex("leg_l1", "<b>/</b> 32 · AXI4-Lite = barramento AXI4-Lite de 32 bits", 815, 540, 280, 20, ST_TEXT + "fontSize=11;")
vertex("leg_l2", "tracejado azul = sideband DMA↔Acelerador", 815, 560, 280, 20, ST_TEXT + "fontSize=11;")
vertex("leg_l3", "tracejado vermelho = interrupção (irq)", 815, 580, 280, 20, ST_TEXT + "fontSize=11;")

vertex("title", "<b>RV32I + DMA + Systolic Array — Top-Level</b> (Entrega 1)", 20, 620, 700, 30,
       ST_TEXT + "fontSize=16;")


# ---------------------------------------------------------------- emissao
def build():
    ids = [a["id"] for _, a, _ in cells]
    assert len(ids) == len(set(ids)), "ids duplicados"
    for kind, a, _ in cells:
        if kind == "e":
            assert a["source"] in geom and a["target"] in geom, a["id"]

    mxfile = ET.Element("mxfile", host="app.diagrams.net", version="24.0.0")
    diagram = ET.SubElement(mxfile, "diagram", id="top_level", name="Top-Level")
    model = ET.SubElement(diagram, "mxGraphModel", dx="1120", dy="700", grid="1", gridSize="10",
                          guides="1", tooltips="1", connect="1", arrows="1", fold="1", page="1",
                          pageScale="1", pageWidth="1120", pageHeight="680", math="0", shadow="0")
    root = ET.SubElement(model, "root")
    ET.SubElement(root, "mxCell", id="0")
    ET.SubElement(root, "mxCell", id="1", parent="0")
    for kind, a, extra in cells:
        if kind == "v":
            c = ET.SubElement(root, "mxCell", vertex="1", parent="1", **a)
            x, y, w, h = extra
            ET.SubElement(c, "mxGeometry", {"x": str(x), "y": str(y), "width": str(w),
                                            "height": str(h), "as": "geometry"})
        else:
            c = ET.SubElement(root, "mxCell", edge="1", parent="1", **a)
            g = ET.SubElement(c, "mxGeometry", {"relative": "1", "as": "geometry"})
            if extra:
                arr = ET.SubElement(g, "Array", {"as": "points"})
                for px, py in extra:
                    ET.SubElement(arr, "mxPoint", x=str(px), y=str(py))
    ET.indent(mxfile)
    return ET.ElementTree(mxfile)


if __name__ == "__main__":
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    out.parent.mkdir(parents=True, exist_ok=True)
    build().write(out, encoding="utf-8", xml_declaration=False)
    print(f"escrito {out}")
