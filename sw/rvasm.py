#!/usr/bin/env python3
"""Montador RV32I minimo, sem dependencias, para o firmware do projeto.

Gera o .hex da IMEM (uma palavra de 32 bits por linha, para $readmemh) a
partir de um .s. Existe porque o fluxo nao depende de toolchain RISC-V
instalada: so Python 3, como o model/golden.py.

Suporta:
  - as 37 instrucoes de usuario do RV32I, mais fence, ecall, ebreak e wfi;
  - pseudo-instrucoes: li, la, mv, not, neg, nop, j, jr, ret, call, seqz,
    snez, sltz, sgtz, beqz, bnez, blez, bgez, bltz, bgtz, bgt, ble, bgtu, bleu;
  - diretivas: .equ/.set, .include, .word, .align, .text/.globl/.section
    (aceitas e ignoradas);
  - expressoes inteiras com + - * << >> | & ^ ~ e parenteses, usando
    constantes do .equ e rotulos.

Convencoes, iguais as dos programas de tb/unit_cpu (branch processor-rv32i):
  - li com valor fora de [-2048, 2047] sempre vira lui + addi (2 instrucoes);
  - la vira auipc + addi.

Uso:
  python3 sw/rvasm.py sw/firmware.s -o build/fw/firmware.hex [-l firmware.lst]
  python3 sw/rvasm.py --defs c  sw/mailbox.inc -o sw/mailbox.h
  python3 sw/rvasm.py --defs sv sw/mailbox.inc -o sw/mailbox_pkg.sv
"""

import argparse
import ast
import os
import re
import sys

# ----------------------------------------------------------------- registradores
ABI = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1",
       "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7",
       "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
       "t3", "t4", "t5", "t6"]
REGS = {f"x{i}": i for i in range(32)}
REGS.update({name: i for i, name in enumerate(ABI)})
REGS["fp"] = 8

# ----------------------------------------------------------------- codificacao
R_OPS = {  # funct3, funct7
    "add": (0, 0x00), "sub": (0, 0x20), "sll": (1, 0x00), "slt": (2, 0x00),
    "sltu": (3, 0x00), "xor": (4, 0x00), "srl": (5, 0x00), "sra": (5, 0x20),
    "or": (6, 0x00), "and": (7, 0x00),
}
I_ALU = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
SHIFT_I = {"slli": (1, 0x00), "srli": (5, 0x00), "srai": (5, 0x20)}
LOADS = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
STORES = {"sb": 0, "sh": 1, "sw": 2}
BRANCHES = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}
FIXED = {"ecall": 0x00000073, "ebreak": 0x00100073, "wfi": 0x10500073,
         "fence": 0x0FF0000F}


class AsmError(Exception):
    pass


def enc_r(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def enc_i(imm, rs1, f3, rd, op):
    check_range(imm, -2048, 2047, "imediato de 12 bits")
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def enc_s(imm, rs2, rs1, f3, op):
    check_range(imm, -2048, 2047, "deslocamento de 12 bits")
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | op


def enc_b(off, rs2, rs1, f3):
    check_range(off, -4096, 4094, "desvio")
    if off & 1:
        raise AsmError("destino de desvio desalinhado")
    o = off & 0x1FFF
    return (((o >> 12) & 1) << 31) | (((o >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) \
        | (f3 << 12) | (((o >> 1) & 0xF) << 8) | (((o >> 11) & 1) << 7) | 0x63


def enc_u(imm20, rd, op):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op


def enc_j(off, rd):
    check_range(off, -(1 << 20), (1 << 20) - 2, "salto")
    if off & 1:
        raise AsmError("destino de salto desalinhado")
    o = off & 0x1FFFFF
    return (((o >> 20) & 1) << 31) | (((o >> 1) & 0x3FF) << 21) | (((o >> 11) & 1) << 20) \
        | (((o >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F


def check_range(v, lo, hi, what):
    if not lo <= v <= hi:
        raise AsmError(f"{what} fora da faixa: {v} (de {lo} a {hi})")


def hi_lo(value):
    """Divide um valor de 32 bits em (hi20 do lui/auipc, lo12 com sinal do addi)."""
    v = value & 0xFFFFFFFF
    lo = v & 0xFFF
    if lo >= 0x800:
        lo -= 0x1000
    hi = ((v - lo) >> 12) & 0xFFFFF
    return hi, lo


# ----------------------------------------------------------------- expressoes
_BINOPS = {ast.Add: lambda a, b: a + b, ast.Sub: lambda a, b: a - b,
           ast.Mult: lambda a, b: a * b, ast.LShift: lambda a, b: a << b,
           ast.RShift: lambda a, b: a >> b, ast.BitOr: lambda a, b: a | b,
           ast.BitAnd: lambda a, b: a & b, ast.BitXor: lambda a, b: a ^ b,
           ast.FloorDiv: lambda a, b: a // b}
_UNOPS = {ast.USub: lambda a: -a, ast.UAdd: lambda a: a, ast.Invert: lambda a: ~a}


def evaluate(expr, symbols):
    """Avalia uma expressao inteira. Levanta KeyError se usar simbolo indefinido."""
    text = expr.strip().replace("/", "//")
    try:
        tree = ast.parse(text, mode="eval")
    except SyntaxError:
        raise AsmError(f"expressao invalida: {expr!r}")

    def ev(node):
        if isinstance(node, ast.Expression):
            return ev(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, int):
            return node.value
        if isinstance(node, ast.Name):
            if node.id not in symbols:
                raise KeyError(node.id)
            return symbols[node.id]
        if isinstance(node, ast.BinOp) and type(node.op) in _BINOPS:
            return _BINOPS[type(node.op)](ev(node.left), ev(node.right))
        if isinstance(node, ast.UnaryOp) and type(node.op) in _UNOPS:
            return _UNOPS[type(node.op)](ev(node.operand))
        raise AsmError(f"expressao nao suportada: {expr!r}")

    return ev(tree)


# ----------------------------------------------------------------- leitura
class Line:
    def __init__(self, path, num, text):
        self.path, self.num, self.text = path, num, text

    def where(self):
        return f"{self.path}:{self.num}"


def read_source(path, seen=None):
    """Le o arquivo e os .include, devolvendo a lista de linhas com origem."""
    seen = seen or []
    full = os.path.abspath(path)
    if full in seen:
        raise AsmError(f"include circular: {path}")
    out = []
    with open(path, encoding="utf-8") as f:
        for num, raw in enumerate(f, 1):
            text = re.split(r"#|//", raw, maxsplit=1)[0].strip()
            m = re.match(r'\.include\s+"([^"]+)"$', text)
            if m:
                inc = os.path.join(os.path.dirname(path), m.group(1))
                out.extend(read_source(inc, seen + [full]))
            elif text:
                out.append(Line(path, num, text))
    return out


def split_operands(text):
    return [p.strip() for p in text.split(",")] if text.strip() else []


def reg(name):
    r = REGS.get(name.strip().lower())
    if r is None:
        raise AsmError(f"registrador invalido: {name!r}")
    return r


def mem_operand(text):
    """'imm(rs1)' -> (expressao do imm, rs1)."""
    m = re.match(r"^(.*)\(\s*([\w]+)\s*\)$", text.strip())
    if not m:
        raise AsmError(f"operando de memoria invalido: {text!r}")
    return (m.group(1).strip() or "0"), reg(m.group(2))


# ----------------------------------------------------------------- montador
class Assembler:
    def __init__(self):
        self.symbols = {}
        self.labels = set()
        self.equs = []          # (nome, valor) na ordem, para --defs

    def li_is_long(self, expr):
        """li vira lui + addi se o valor nao cabe em 12 bits ou depende de rotulo
        (o endereco pode mudar, entao o tamanho nao pode depender dele)."""
        try:
            tree = ast.parse(expr.strip(), mode="eval")
        except SyntaxError:
            raise AsmError(f"expressao invalida: {expr!r}")
        names = {n.id for n in ast.walk(tree) if isinstance(n, ast.Name)}
        if any(n in self.labels or n not in self.symbols for n in names):
            return True
        v = evaluate(expr, self.symbols)
        return not -2048 <= v <= 2047

    def size_of(self, mnem, ops):
        """Tamanho em bytes de uma linha (passo 1)."""
        if mnem == "li":
            return 8 if self.li_is_long(ops[1]) else 4
        if mnem == "la":
            return 8
        return 4

    def parse_line(self, text):
        """Separa rotulos, mnemonico e operandos."""
        labels = []
        while True:
            m = re.match(r"^([A-Za-z_.$][\w.$]*)\s*:\s*(.*)$", text)
            if not m:
                break
            labels.append(m.group(1))
            text = m.group(2)
        if not text:
            return labels, None, []
        parts = text.split(None, 1)
        return labels, parts[0].lower(), split_operands(parts[1] if len(parts) > 1 else "")

    def define(self, name, value, line):
        if name in self.symbols:
            raise AsmError(f"{line.where()}: simbolo redefinido: {name}")
        self.symbols[name] = value

    def assemble(self, lines):
        # passo 1: enderecos dos rotulos e valores das constantes
        pc = 0
        items = []
        for line in lines:
            try:
                labels, mnem, ops = self.parse_line(line.text)
                for lab in labels:
                    self.define(lab, pc, line)
                    self.labels.add(lab)
                if mnem is None:
                    continue
                if mnem in (".equ", ".set"):
                    if len(ops) != 2:
                        raise AsmError(".equ precisa de nome e valor")
                    v = evaluate(ops[1], self.symbols)
                    self.define(ops[0], v, line)
                    self.equs.append((ops[0], v))
                    continue
                if mnem in (".text", ".globl", ".global", ".section", ".option"):
                    continue
                if mnem == ".align":
                    step = 1 << evaluate(ops[0], self.symbols)
                    pad = (-pc) % step
                    if pad % 4:
                        raise AsmError(".align menor que 4 nao e suportado")
                    items.append((line, pc, ".pad", [pad // 4]))
                    pc += pad
                    continue
                if mnem == ".word":
                    items.append((line, pc, mnem, ops))
                    pc += 4 * len(ops)
                    continue
                if mnem.startswith("."):
                    raise AsmError(f"diretiva nao suportada: {mnem}")
                items.append((line, pc, mnem, ops))
                pc += self.size_of(mnem, ops)
            except (AsmError, KeyError) as e:
                raise AsmError(f"{line.where()}: {format_err(e)}  [{line.text}]")

        # passo 2: codificacao
        words = []
        listing = []
        for line, addr, mnem, ops in items:
            try:
                if mnem == ".pad":
                    enc = [0x00000013] * ops[0]
                else:
                    enc = self.encode(mnem, ops, addr)
                    if mnem not in (".word",) and len(enc) * 4 != self.size_of(mnem, ops):
                        raise AsmError("tamanho mudou entre os passos (li com rotulo?)")
            except (AsmError, KeyError) as e:
                raise AsmError(f"{line.where()}: {format_err(e)}  [{line.text}]")
            for i, w in enumerate(enc):
                words.append(w & 0xFFFFFFFF)
                listing.append((addr + 4 * i, w & 0xFFFFFFFF, line.text if i == 0 else ""))
        return words, listing

    def ev(self, expr):
        return evaluate(expr, self.symbols)

    def encode(self, m, ops, pc):
        n = len(ops)

        def need(k):
            if n != k:
                raise AsmError(f"{m} espera {k} operando(s), recebeu {n}")

        if m == ".word":
            return [self.ev(o) for o in ops]
        if m in FIXED:
            if m != "fence":
                need(0)
            return [FIXED[m]]
        if m in R_OPS:
            need(3)
            f3, f7 = R_OPS[m]
            return [enc_r(f7, reg(ops[2]), reg(ops[1]), f3, reg(ops[0]), 0x33)]
        if m in I_ALU:
            need(3)
            return [enc_i(self.ev(ops[2]), reg(ops[1]), I_ALU[m], reg(ops[0]), 0x13)]
        if m in SHIFT_I:
            need(3)
            f3, f7 = SHIFT_I[m]
            sh = self.ev(ops[2])
            check_range(sh, 0, 31, "shamt")
            return [enc_r(f7, sh, reg(ops[1]), f3, reg(ops[0]), 0x13)]
        if m in LOADS:
            need(2)
            off, rs1 = mem_operand(ops[1])
            return [enc_i(self.ev(off), rs1, LOADS[m], reg(ops[0]), 0x03)]
        if m in STORES:
            need(2)
            off, rs1 = mem_operand(ops[1])
            return [enc_s(self.ev(off), reg(ops[0]), rs1, STORES[m], 0x23)]
        if m in BRANCHES:
            need(3)
            return [enc_b(self.ev(ops[2]) - pc, reg(ops[1]), reg(ops[0]), BRANCHES[m])]
        if m in ("lui", "auipc"):
            need(2)
            v = self.ev(ops[1])
            check_range(v, -(1 << 19), (1 << 20) - 1, "imediato de 20 bits")
            return [enc_u(v, reg(ops[0]), 0x37 if m == "lui" else 0x17)]
        if m == "jal":
            if n == 1:
                return [enc_j(self.ev(ops[0]) - pc, 1)]
            need(2)
            return [enc_j(self.ev(ops[1]) - pc, reg(ops[0]))]
        if m == "jalr":
            if n == 1:
                return [enc_i(0, reg(ops[0]), 0, 1, 0x67)]
            if n == 2:
                off, rs1 = mem_operand(ops[1])
                return [enc_i(self.ev(off), rs1, 0, reg(ops[0]), 0x67)]
            need(3)
            return [enc_i(self.ev(ops[2]), reg(ops[1]), 0, reg(ops[0]), 0x67)]

        # pseudo-instrucoes
        if m == "nop":
            need(0)
            return [enc_i(0, 0, 0, 0, 0x13)]
        if m == "li":
            need(2)
            rd, v = reg(ops[0]), self.ev(ops[1])
            check_range(v, -(1 << 31), (1 << 32) - 1, "li")
            if not self.li_is_long(ops[1]):
                return [enc_i(v, 0, 0, rd, 0x13)]
            hi, lo = hi_lo(v)
            return [enc_u(hi, rd, 0x37), enc_i(lo, rd, 0, rd, 0x13)]
        if m == "la":
            need(2)
            rd = reg(ops[0])
            hi, lo = hi_lo(self.ev(ops[1]) - pc)
            return [enc_u(hi, rd, 0x17), enc_i(lo, rd, 0, rd, 0x13)]
        if m == "mv":
            need(2)
            return [enc_i(0, reg(ops[1]), 0, reg(ops[0]), 0x13)]
        if m == "not":
            need(2)
            return [enc_i(-1, reg(ops[1]), 4, reg(ops[0]), 0x13)]
        if m == "neg":
            need(2)
            return [enc_r(0x20, reg(ops[1]), 0, 0, reg(ops[0]), 0x33)]
        if m == "seqz":
            need(2)
            return [enc_i(1, reg(ops[1]), 3, reg(ops[0]), 0x13)]
        if m == "snez":
            need(2)
            return [enc_r(0, reg(ops[1]), 0, 3, reg(ops[0]), 0x33)]
        if m == "sltz":
            need(2)
            return [enc_r(0, 0, reg(ops[1]), 2, reg(ops[0]), 0x33)]
        if m == "sgtz":
            need(2)
            return [enc_r(0, reg(ops[1]), 0, 2, reg(ops[0]), 0x33)]
        if m == "j":
            need(1)
            return [enc_j(self.ev(ops[0]) - pc, 0)]
        if m == "call":
            need(1)
            return [enc_j(self.ev(ops[0]) - pc, 1)]
        if m == "jr":
            need(1)
            return [enc_i(0, reg(ops[0]), 0, 0, 0x67)]
        if m == "ret":
            need(0)
            return [enc_i(0, 1, 0, 0, 0x67)]
        zero_br = {"beqz": ("beq", False), "bnez": ("bne", False), "bltz": ("blt", False),
                   "bgez": ("bge", False), "blez": ("bge", True), "bgtz": ("blt", True)}
        if m in zero_br:
            need(2)
            base, swap = zero_br[m]
            rs = reg(ops[0])
            a, b = (0, rs) if swap else (rs, 0)
            return [enc_b(self.ev(ops[1]) - pc, b, a, BRANCHES[base])]
        swap_br = {"bgt": "blt", "ble": "bge", "bgtu": "bltu", "bleu": "bgeu"}
        if m in swap_br:
            need(3)
            return [enc_b(self.ev(ops[2]) - pc, reg(ops[0]), reg(ops[1]), BRANCHES[swap_br[m]])]
        raise AsmError(f"instrucao desconhecida: {m}")


def format_err(e):
    if isinstance(e, KeyError):
        return f"simbolo indefinido: {e.args[0]}"
    return str(e)


# ----------------------------------------------------------------- saidas
def write_hex(words, f):
    for w in words:
        f.write(f"{w:08X}\n")


def write_listing(listing, f):
    for addr, w, text in listing:
        f.write(f"{addr:08X}  {w:08X}  {text}\n")


def write_defs(equs, lang, src, f):
    name = os.path.basename(src)
    if lang == "c":
        guard = "MAILBOX_H"
        f.write(f"/* Gerado por sw/rvasm.py --defs c a partir de {name}. Nao edite: */\n")
        f.write(f"/* mude o {name} e rode de novo (make fw).                      */\n")
        f.write(f"#ifndef {guard}\n#define {guard}\n\n")
        for k, v in equs:
            f.write(f"#define {k:<20} 0x{v & 0xFFFFFFFF:08X}u\n")
        f.write(f"\n#endif /* {guard} */\n")
    else:
        f.write(f"// Gerado por sw/rvasm.py --defs sv a partir de {name}. Nao edite:\n")
        f.write(f"// mude o {name} e rode de novo (make fw).\n")
        f.write("`timescale 1ns/1ps\n")
        f.write("package mailbox_pkg;\n")
        for k, v in equs:
            f.write(f"    localparam logic [31:0] {k:<20} = 32'h{v & 0xFFFFFFFF:08X};\n")
        f.write("endpackage\n")


def main():
    ap = argparse.ArgumentParser(description="Montador RV32I minimo do projeto")
    ap.add_argument("source", help="arquivo .s")
    ap.add_argument("-o", "--output", help="saida (.hex, ou o arquivo de --defs); padrao: stdout")
    ap.add_argument("-l", "--listing", help="listagem com endereco, palavra e linha de origem")
    ap.add_argument("--defs", choices=["c", "sv"],
                    help="em vez de montar, exporta as constantes .equ como header C ou pacote SV")
    args = ap.parse_args()

    asm = Assembler()
    try:
        words, listing = asm.assemble(read_source(args.source))
    except AsmError as e:
        sys.exit(f"rvasm: erro: {e}")

    out = open(args.output, "w", newline="\n") if args.output else sys.stdout
    try:
        if args.defs:
            write_defs(asm.equs, args.defs, args.source, out)
        else:
            write_hex(words, out)
    finally:
        if args.output:
            out.close()
    if args.listing and not args.defs:
        with open(args.listing, "w", newline="\n") as f:
            write_listing(listing, f)


if __name__ == "__main__":
    main()
