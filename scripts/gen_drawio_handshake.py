#!/usr/bin/env python3
"""Gera docs/img/top_level_handshake.drawio (top-level só com handshake valid/ready).

Uso: python3 scripts/gen_drawio.py [saida.drawio]

Mesmo estilo de gen_drawio.py, mas sem AXI: todos os links entre CPU, DMA,
memorias e crossbar usam handshake simples valid/ready de 32 bits.
O XML e emitido sem compressao para ser editavel no draw.io e versionavel.
"""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

DEFAULT_OUT = Path(__file__).resolve().parent.parent / "docs" / "img" / "top_level_handshake.drawio"

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

BUS = "<b>/</b> 32 · valid/ready"

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
vertex("reg_core", "", 20, 255, 1080, 110, ST_REGION)

# masters
vertex("cpu_i", "CPU RV32I<br>Porta I (fetch)", 40, 40, 150, 60, ST_MASTER)
vertex("cpu_d", "CPU RV32I<br>Porta D (load/store)", 220, 40, 150, 60, ST_MASTER)
vertex("dma", "DMA Controller<br><span style='font-weight:normal;font-size:11px'>FSM própria · porta master<br>+ regs DMA 0x4000_0000 (slave)</span>",
       420, 40, 220, 110, ST_GRAY)

# acelerador
vertex("acc", "Acelerador MatMul<br><span style='font-weight:normal;font-size:11px'>Buffers A/B/C + Systolic Array<br>ARRAY_SIZE×ARRAY_SIZE (2/4/8)</span>",
       880, 30, 200, 100, ST_MASTER)

# crossbar
vertex("xbar", "bus_xbar<br><span style='font-weight:normal;font-size:11px'>"
       "3 masters × 3 slaves · decode addr[31:28] · round-robin · valid/ready 32 bits</span>",
       40, 280, 1040, 60, ST_SWITCH)

# memorias
vertex("mem_i", "Memória de instruções<br><span style='font-weight:normal;font-size:11px'>0x0000_0000 · firmware · 64 KiB</span>",
       100, 410, 300, 60, ST_GRAY)
vertex("mem_d", "Memória de dados compartilhada<br><span style='font-weight:normal;font-size:11px'>0x1000_0000 · matrizes A, B, C · 64 KiB</span>",
       450, 410, 300, 60, ST_GRAY)

# CPU -> xbar
edge("e_m0", "cpu_i", "xbar", (115, 100), (115, 280), "M0 · " + BUS, ST_AXI)
edge("e_m1", "cpu_d", "xbar", (295, 100), (295, 280), "M1 · " + BUS, ST_AXI)
# DMA <-> xbar
edge("e_m2", "dma", "xbar", (480, 150), (480, 280), "M2 · " + BUS, ST_AXI)
edge("e_s2", "xbar", "dma", (580, 280), (580, 150), "S2 · regs DMA 0x4000_0000<br>" + BUS, ST_AXI)

# xbar -> memorias
edge("e_s0", "xbar", "mem_i", (250, 340), (250, 410), "S0 · IMEM<br>" + BUS, ST_AXI)
edge("e_s1", "xbar", "mem_d", (600, 340), (600, 410), "S1 · DMEM<br>" + BUS, ST_AXI)

# sideband DMA -> acelerador (nao usa o barramento principal) e IRQ
edge("e_side", "dma", "acc", (640, 62), (880, 62),
     "sideband<br>buf A/B: we, addr, data[8] · C: rd, data[32]<br>tile_start, first_k, busy, tile_done",
     ST_SIDEBAND)
edge("e_irq", "dma", "cpu_d", (420, 70), (370, 70), "irq", ST_IRQ)

# legenda
vertex("leg_box", "", 800, 410, 300, 200, "rounded=0;html=1;fillColor=#FFFFFF;strokeColor=#BBBBBB;")
vertex("leg_title", "Legenda", 810, 415, 100, 20, ST_TEXT + "fontStyle=1;fontSize=12;")
legend = [
    ("leg_1", ST_MASTER, "CPU / Acelerador"),
    ("leg_2", ST_SWITCH, "Crossbar valid/ready"),
    ("leg_3", ST_GRAY, "DMA / memórias"),
]
for i, (lid, st, txt) in enumerate(legend):
    y = 440 + i * 24
    vertex(lid, "", 815, y, 28, 16, st)
    vertex(lid + "_t", txt, 852, y - 2, 240, 20, ST_TEXT + "fontSize=11;")
vertex("leg_l1", "mestre→escravo: valid, addr, we, wstrb, wdata", 815, 520, 280, 20, ST_TEXT + "fontSize=11;")
vertex("leg_l2", "escravo→mestre: ready, rdata (transfere com valid=ready=1)", 815, 540, 280, 20, ST_TEXT + "fontSize=11;")
vertex("leg_l3", "tracejado azul = sideband DMA→Acelerador", 815, 560, 280, 20, ST_TEXT + "fontSize=11;")
vertex("leg_l4", "tracejado vermelho = interrupção (irq)", 815, 580, 280, 20, ST_TEXT + "fontSize=11;")

vertex("title", "<b>RV32I + DMA + Systolic Array — Top-Level (handshake valid/ready)</b>", 20, 620, 800, 30,
       ST_TEXT + "fontSize=16;")


# ---------------------------------------------------------------- emissao
def build():
    ids = [a["id"] for _, a, _ in cells]
    assert len(ids) == len(set(ids)), "ids duplicados"
    for kind, a, _ in cells:
        if kind == "e":
            assert a["source"] in geom and a["target"] in geom, a["id"]

    mxfile = ET.Element("mxfile", host="app.diagrams.net", version="24.0.0")
    diagram = ET.SubElement(mxfile, "diagram", id="top_level_handshake", name="Top-Level handshake")
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
