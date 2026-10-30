#!/usr/bin/env python3
"""Modelo comum dos diagramas: um Diagram gera .drawio (editavel) e .svg (renderiza no GitHub).

Vertices e arestas sao posicionados em coordenadas absolutas. As arestas recebem os
pontos de saida/entrada (a, b) na borda dos blocos e waypoints opcionais; o draw.io
recebe isso como exitX/entryX relativos e o SVG desenha a mesma polilinha ortogonal.
O XML do draw.io e emitido sem compressao para ser editavel e versionavel.
"""
import html
import re
import xml.etree.ElementTree as ET

# ---------------------------------------------------------------- estilos
BASE = "whiteSpace=wrap;html=1;fontSize=12;fontStyle=1;"
ST_MASTER = BASE + "rounded=1;fillColor=#0E8FB4;strokeColor=#0B6F8A;fontColor=#FFFFFF;"
ST_ADAPTER = BASE + "rounded=1;fillColor=#1CC0DD;strokeColor=#119BB3;fontColor=#FFFFFF;"
ST_SWITCH = BASE + "rounded=1;fillColor=#7ED321;strokeColor=#5FA316;fontColor=#1B2A05;"
ST_GRAY = BASE + "rounded=1;fillColor=#808285;strokeColor=#5A5C5E;fontColor=#FFFFFF;"
ST_STATE = BASE + "rounded=1;fillColor=#FFFFFF;strokeColor=#0B6F8A;strokeWidth=2;fontColor=#1A1A1A;"
ST_STATE_END = BASE + "rounded=1;fillColor=#E8F6FA;strokeColor=#0B6F8A;strokeWidth=2;fontColor=#1A1A1A;"
ST_STATE_ERR = BASE + "rounded=1;fillColor=#FDECEC;strokeColor=#D0021B;strokeWidth=2;fontColor=#1A1A1A;"
ST_NOTE = ("rounded=0;whiteSpace=wrap;html=1;fontSize=11;fillColor=#FFF8DC;strokeColor=#C9B458;"
           "fontColor=#1A1A1A;")
ST_BOX = ("rounded=1;whiteSpace=wrap;html=1;fontSize=11;fillColor=#FFFFFF;strokeColor=#0B6F8A;"
          "fontColor=#1A1A1A;align=left;spacingLeft=8;")
ST_REGION = ("rounded=0;whiteSpace=wrap;html=1;fillColor=#E6ECEC;strokeColor=none;"
             "fontSize=11;fontStyle=2;fontColor=#4A5555;align=left;verticalAlign=top;spacingLeft=8;spacingTop=4;")
ST_FRAME = ("rounded=0;whiteSpace=wrap;html=1;fillColor=none;strokeColor=#888888;dashed=1;"
            "fontSize=11;fontStyle=2;fontColor=#4A5555;align=left;verticalAlign=top;spacingLeft=8;spacingTop=4;")
ST_LIFELINE = "rounded=0;html=1;fillColor=#BBBBBB;strokeColor=none;"
ST_TEXT = "text;html=1;strokeColor=none;fillColor=none;align=left;verticalAlign=middle;whiteSpace=wrap;"

EDGE = ("edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;fontSize=10;labelBackgroundColor=#FFFFFF;"
        "startArrow=classic;startFill=1;endArrow=classic;endFill=1;strokeWidth=2;strokeColor=#333333;")
ST_AXI = EDGE
ST_NATIVE = EDGE + "strokeWidth=1;startArrow=none;endArrow=classic;dashed=0;strokeColor=#0B6F8A;"
ST_SIDEBAND = EDGE + "dashed=1;strokeColor=#0E8FB4;"
ST_IRQ = EDGE + "dashed=1;startArrow=none;strokeColor=#D0021B;fontColor=#D0021B;"
ST_DATA = EDGE + "strokeWidth=1;startArrow=none;strokeColor=#333333;"
ST_TRANS = EDGE + "strokeWidth=1.5;startArrow=none;strokeColor=#333333;"
ST_MSG = ("edgeStyle=none;html=1;fontSize=10;labelBackgroundColor=#FFFFFF;startArrow=none;"
          "endArrow=block;endFill=1;strokeWidth=1;strokeColor=#333333;")
ST_RET = ST_MSG + "dashed=1;endArrow=open;endFill=0;"

FONT = "Helvetica, Arial, sans-serif"
CHAR_W = 0.56   # largura media de um caractere, em fracao do tamanho da fonte


def _style(style):
    """'a=1;b=2;text' -> {'a': '1', 'b': '2', 'text': ''}; chaves repetidas: vale a ultima."""
    d = {}
    for tok in style.split(";"):
        if not tok:
            continue
        k, _, v = tok.partition("=")
        d[k] = v
    return d


def _color(v):
    return None if v in (None, "", "none") else v


def _parse_label(label, size, bold):
    """HTML simples do draw.io -> linhas de segmentos (texto, negrito, tamanho)."""
    lines = [[]]
    stack = [(bold, size)]
    for tok in re.split(r"(<[^>]+>)", label):
        if not tok:
            continue
        if tok.startswith("<"):
            tag = tok.lower().replace(" ", "")
            if tag.startswith("<br"):
                lines.append([])
            elif tag == "<b>":
                stack.append((True, stack[-1][1]))
            elif tag.startswith("<span"):
                b, s = stack[-1]
                m = re.search(r"font-size:(\d+)px", tag)
                if m:
                    s = int(m.group(1))
                if "font-weight:normal" in tag:
                    b = False
                elif "font-weight:bold" in tag:
                    b = True
                stack.append((b, s))
            elif tag in ("</b>", "</span>") and len(stack) > 1:
                stack.pop()
        else:
            lines[-1].append((html.unescape(tok), *stack[-1]))
    return lines


def _line_h(line, size):
    return max([s for _, _, s in line] + [size]) * 1.25


def _text_w(line):
    return sum(len(t) * s * CHAR_W for t, _, s in line)


class Diagram:
    def __init__(self, diagram_id, name, page_w, page_h):
        self.diagram_id, self.name = diagram_id, name
        self.page_w, self.page_h = page_w, page_h
        self.cells = []   # ("v", attrs, geom) | ("e", attrs, (a, b, via, offset))
        self.geom = {}    # id -> (x, y, w, h)

    # ------------------------------------------------------------ modelo
    def vertex(self, cid, label, x, y, w, h, style):
        self.geom[cid] = (x, y, w, h)
        self.cells.append(("v", dict(id=cid, value=label, style=style), (x, y, w, h)))

    def _ratio(self, cid, pt):
        x, y, w, h = self.geom[cid]
        return (pt[0] - x) / w, (pt[1] - y) / h

    def edge(self, cid, src, dst, a, b, label, style, via=(), offset=(0, 0)):
        """Aresta de src (ponto absoluto a) ate dst (ponto absoluto b), com waypoints opcionais."""
        self.cells.append(("e", dict(id=cid, value=label, style=style, source=src, target=dst),
                           (a, b, list(via), offset)))

    # ------------------------------------------------------------ draw.io
    def build_drawio(self):
        ids = [a["id"] for _, a, _ in self.cells]
        assert len(ids) == len(set(ids)), "ids duplicados"

        mxfile = ET.Element("mxfile", host="app.diagrams.net", version="24.0.0")
        diagram = ET.SubElement(mxfile, "diagram", id=self.diagram_id, name=self.name)
        model = ET.SubElement(diagram, "mxGraphModel", dx=str(self.page_w), dy=str(self.page_h),
                              grid="1", gridSize="10", guides="1", tooltips="1", connect="1", arrows="1",
                              fold="1", page="1", pageScale="1", pageWidth=str(self.page_w),
                              pageHeight=str(self.page_h), math="0", shadow="0")
        root = ET.SubElement(model, "root")
        ET.SubElement(root, "mxCell", id="0")
        ET.SubElement(root, "mxCell", id="1", parent="0")
        for kind, a, extra in self.cells:
            if kind == "v":
                c = ET.SubElement(root, "mxCell", vertex="1", parent="1", **a)
                x, y, w, h = extra
                ET.SubElement(c, "mxGeometry", {"x": str(x), "y": str(y), "width": str(w),
                                                "height": str(h), "as": "geometry"})
                continue
            src, dst = a["source"], a["target"]
            assert src in self.geom and dst in self.geom, a["id"]
            pa, pb, via, offset = extra
            ex, ey = self._ratio(src, pa)
            nx, ny = self._ratio(dst, pb)
            st = (f"{a['style']}exitX={ex:.4f};exitY={ey:.4f};exitDx=0;exitDy=0;"
                  f"entryX={nx:.4f};entryY={ny:.4f};entryDx=0;entryDy=0;")
            c = ET.SubElement(root, "mxCell", edge="1", parent="1", **dict(a, style=st))
            g = ET.SubElement(c, "mxGeometry", {"relative": "1", "as": "geometry"})
            if via:
                arr = ET.SubElement(g, "Array", {"as": "points"})
                for px, py in via:
                    ET.SubElement(arr, "mxPoint", x=str(px), y=str(py))
            if offset != (0, 0):
                ET.SubElement(g, "mxPoint", {"x": str(offset[0]), "y": str(offset[1]), "as": "offset"})
        ET.indent(mxfile)
        return ET.ElementTree(mxfile)

    def write_drawio(self, path):
        self.build_drawio().write(path, encoding="utf-8", xml_declaration=False)

    # ------------------------------------------------------------ SVG
    def _route(self, src, a, b, via):
        """Polilinha ortogonal: insere cotovelos onde dois pontos nao estao alinhados."""
        out = [a]
        for i, p in enumerate([*via, b]):
            q = out[-1]
            if q[0] != p[0] and q[1] != p[1]:
                ex, ey = self._ratio(src, a)
                if i == 0 and not via and ey in (0.0, 1.0):     # sai por cima/baixo: vertical primeiro
                    mid = (q[1] + p[1]) / 2
                    out += [(q[0], mid), (p[0], mid)]
                elif i == 0 and not via:                       # sai pela lateral: horizontal primeiro
                    mid = (q[0] + p[0]) / 2
                    out += [(mid, q[1]), (mid, p[1])]
                else:
                    out.append((p[0], q[1]))
            out.append(p)
        return out

    @staticmethod
    def _midpoint(pts):
        segs = [(p, q, abs(q[0] - p[0]) + abs(q[1] - p[1])) for p, q in zip(pts, pts[1:])]
        half = sum(s[2] for s in segs) / 2
        for p, q, n in segs:
            if half <= n and n:
                t = half / n
                return p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t
            half -= n
        return pts[-1]

    def _svg_text(self, parent, lines, x, y, w, h, st, size):
        align = st.get("align", "center")
        valign = st.get("verticalAlign", "middle")
        italic = int(st.get("fontStyle", "0") or 0) & 2
        color = _color(st.get("fontColor")) or "#000000"
        total = sum(_line_h(ln, size) for ln in lines)
        if valign == "top":
            cy = y + float(st.get("spacingTop", 2))
        elif valign == "bottom":
            cy = y + h - total - float(st.get("spacingBottom", 4))
        else:
            cy = y + (h - total) / 2
        if align == "left":
            tx, anchor = x + float(st.get("spacingLeft", 4)), "start"
        else:
            tx, anchor = x + w / 2, "middle"
        for ln in lines:
            lh = _line_h(ln, size)
            if ln:
                t = ET.SubElement(parent, "text", {"x": f"{tx:.1f}", "y": f"{cy + lh * 0.78:.1f}",
                                                   "text-anchor": anchor, "fill": color})
                if italic:
                    t.set("font-style", "italic")
                for txt, bold, s in ln:
                    sp = ET.SubElement(t, "tspan", {"font-size": str(s),
                                                    "font-weight": "bold" if bold else "normal"})
                    sp.text = txt
            cy += lh

    def build_svg(self):
        xs, ys = [], []
        for kind, _, extra in self.cells:
            if kind == "v":
                x, y, w, h = extra
                xs += [x, x + w]
                ys += [y, y + h]
            else:
                for px, py in [extra[0], extra[1], *extra[2]]:
                    xs.append(px)
                    ys.append(py)
        W, H = max(xs) + 20, max(ys) + 20

        svg = ET.Element("svg", {"xmlns": "http://www.w3.org/2000/svg", "font-family": FONT})
        defs = ET.SubElement(svg, "defs")
        background = ET.SubElement(svg, "rect", {"x": "0", "y": "0", "fill": "#FFFFFF"})
        markers = set()

        def marker(kind, color):
            mid = f"m_{kind}_{color.lstrip('#')}"
            if mid not in markers:
                markers.add(mid)
                m = ET.SubElement(defs, "marker", {"id": mid, "viewBox": "0 0 10 10", "refX": "9",
                                                   "refY": "5", "markerWidth": "9", "markerHeight": "9",
                                                   "markerUnits": "userSpaceOnUse",
                                                   "orient": "auto-start-reverse"})
                if kind == "open":
                    ET.SubElement(m, "path", {"d": "M0,0 L10,5 L0,10", "fill": "none",
                                              "stroke": color, "stroke-width": "1.5"})
                else:
                    ET.SubElement(m, "path", {"d": "M0,0 L10,5 L0,10 z", "fill": color})
            return f"url(#{mid})"

        labels = []   # rotulos das arestas por ultimo, por cima das linhas
        for kind, a, extra in self.cells:
            st = _style(a["style"])
            size = int(st.get("fontSize", "12"))
            if kind == "v":
                x, y, w, h = extra
                fill, stroke = _color(st.get("fillColor")), _color(st.get("strokeColor"))
                if fill or stroke:
                    r = {"x": str(x), "y": str(y), "width": str(w), "height": str(h),
                         "fill": fill or "none", "stroke": stroke or "none",
                         "stroke-width": st.get("strokeWidth", "1")}
                    if st.get("rounded") == "1":
                        r["rx"] = r["ry"] = f"{min(10, 0.15 * min(w, h)):.1f}"
                    if st.get("dashed") == "1":
                        r["stroke-dasharray"] = "6,4"
                    ET.SubElement(svg, "rect", r)
                if a["value"]:
                    bold = int(st.get("fontStyle", "0") or 0) & 1
                    self._svg_text(svg, _parse_label(a["value"], size, bool(bold)), x, y, w, h, st, size)
                continue

            pa, pb, via, offset = extra
            pts = self._route(a["source"], pa, pb, via)
            color = _color(st.get("strokeColor")) or "#000000"
            p = {"points": " ".join(f"{px},{py}" for px, py in pts), "fill": "none",
                 "stroke": color, "stroke-width": st.get("strokeWidth", "1")}
            if st.get("dashed") == "1":
                p["stroke-dasharray"] = "6,4"
            end, start = st.get("endArrow", "classic"), st.get("startArrow", "none")
            if end != "none":
                p["marker-end"] = marker("open" if end == "open" else "fill", color)
            if start != "none":
                p["marker-start"] = marker("open" if start == "open" else "fill", color)
            ET.SubElement(svg, "polyline", p)
            if a["value"]:
                mx, my = self._midpoint(pts)
                labels.append((a["value"], mx + offset[0], my + offset[1], st, size))

        for value, mx, my, st, size in labels:
            lines = _parse_label(value, size, False)
            w = max(_text_w(ln) for ln in lines) + 8
            h = sum(_line_h(ln, size) for ln in lines) + 2
            x, y = mx - w / 2, my - h / 2
            W, H = max(W, x + w + 10), max(H, y + h + 10)
            bg = _color(st.get("labelBackgroundColor"))
            if bg:
                ET.SubElement(svg, "rect", {"x": f"{x:.1f}", "y": f"{y:.1f}", "width": f"{w:.1f}",
                                            "height": f"{h:.1f}", "fill": bg})
            self._svg_text(svg, lines, x, y, w, h, {**st, "align": "center", "verticalAlign": "middle"}, size)

        # tamanho final so e conhecido depois dos rotulos das arestas
        W, H = int(W), int(H)
        svg.set("width", str(W))
        svg.set("height", str(H))
        svg.set("viewBox", f"0 0 {W} {H}")
        background.set("width", str(W))
        background.set("height", str(H))
        ET.indent(svg)
        return ET.ElementTree(svg)

    def write_svg(self, path):
        self.build_svg().write(path, encoding="utf-8", xml_declaration=True)
