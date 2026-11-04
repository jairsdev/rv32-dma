`timescale 1ns/1ps
// Controle da ULA: confere ALU_Control para todas as combinações de ALU_Op e funct3,
// com funct7 = 0000000, 0100000 e valores aleatórios.
//   ALU_Op = 00 -> ADD (load, store, lui, auipc, jal, jalr)
//   ALU_Op = 01 -> comparação do desvio (beq, bne, blt, bge, bltu, bgeu)
//   ALU_Op = 10 -> tipo R (funct7[5] escolhe SUB e SRA)
//   ALU_Op = 11 -> tipo I (funct7[5] só escolhe SRAI; em ADDI é bit do imediato)
module tb_alu_controller;

  localparam ADD  = 4'b0000, SLL  = 4'b0001, SLT  = 4'b0010, SLTU = 4'b0011,
             XOR  = 4'b0100, SRL  = 4'b0101, OR   = 4'b0110, AND  = 4'b0111,
             SUB  = 4'b1000, BEQ  = 4'b1001, BNE  = 4'b1010, BGE  = 4'b1011,
             BLT  = 4'b1100, SRA  = 4'b1101, BLTU = 4'b1110, BGEU = 4'b1111;

  reg  [1:0] ALU_Op;
  reg  [2:0] funct3;
  reg  [6:0] funct7;
  wire [3:0] ALU_Control;

  integer errors = 0;
  integer checks = 0;
  integer op, f3, n;

  alu_controller dut (.ALU_Op(ALU_Op), .funct3(funct3), .funct7(funct7), .ALU_Control(ALU_Control));

  function [3:0] ref_ctrl(input [1:0] o, input [2:0] f, input [6:0] f7);
    begin
      case (o)
        2'b00: ref_ctrl = ADD;
        2'b01:
          case (f)
            3'b000:  ref_ctrl = BEQ;    // beq
            3'b001:  ref_ctrl = BNE;    // bne
            3'b100:  ref_ctrl = BLT;    // blt
            3'b101:  ref_ctrl = BGE;    // bge
            3'b110:  ref_ctrl = BLTU;   // bltu
            3'b111:  ref_ctrl = BGEU;   // bgeu
            default: ref_ctrl = ADD;    // funct3 010/011 não existem em branch
          endcase
        default:
          case (f)
            3'b000:  ref_ctrl = (o == 2'b10 && f7[5]) ? SUB : ADD;  // add/sub, addi
            3'b001:  ref_ctrl = SLL;
            3'b010:  ref_ctrl = SLT;
            3'b011:  ref_ctrl = SLTU;
            3'b100:  ref_ctrl = XOR;
            3'b101:  ref_ctrl = f7[5] ? SRA : SRL;
            3'b110:  ref_ctrl = OR;
            default: ref_ctrl = AND;
          endcase
      endcase
    end
  endfunction

  task check;
    reg [3:0] exp;
    begin
      #1;
      exp = ref_ctrl(ALU_Op, funct3, funct7);
      checks = checks + 1;
      if (ALU_Control !== exp) begin
        errors = errors + 1;
        $display("[ERRO] ALU_Op=%b funct3=%b funct7=%b -> ALU_Control=%b, esperado=%b",
                 ALU_Op, funct3, funct7, ALU_Control, exp);
      end
    end
  endtask

  initial begin
    // casos que importam no processador
    ALU_Op = 2'b10; funct3 = 3'b000; funct7 = 7'b0000000; check;  // add
    ALU_Op = 2'b10; funct3 = 3'b000; funct7 = 7'b0100000; check;  // sub
    ALU_Op = 2'b10; funct3 = 3'b101; funct7 = 7'b0000000; check;  // srl
    ALU_Op = 2'b10; funct3 = 3'b101; funct7 = 7'b0100000; check;  // sra
    ALU_Op = 2'b11; funct3 = 3'b000; funct7 = 7'b1111111; check;  // addi -1: não pode virar sub
    ALU_Op = 2'b11; funct3 = 3'b000; funct7 = 7'b0100000; check;  // addi 1024: não pode virar sub
    ALU_Op = 2'b11; funct3 = 3'b101; funct7 = 7'b0100000; check;  // srai
    ALU_Op = 2'b11; funct3 = 3'b101; funct7 = 7'b0000000; check;  // srli
    ALU_Op = 2'b00; funct3 = 3'b010; funct7 = 7'b0100000; check;  // lw/sw: sempre add

    // todas as combinações de ALU_Op x funct3, com funct7 fixo e aleatório
    for (op = 0; op < 4; op = op + 1)
      for (f3 = 0; f3 < 8; f3 = f3 + 1) begin
        ALU_Op = op; funct3 = f3;
        funct7 = 7'b0000000; check;
        funct7 = 7'b0100000; check;
        for (n = 0; n < 8; n = n + 1) begin
          funct7 = $random; check;
        end
      end

    if (errors == 0)
      $display("tb_alu_controller: PASSOU (%0d verificacoes)", checks);
    else
      $display("tb_alu_controller: FALHOU (%0d erros em %0d verificacoes)", errors, checks);
    $finish;
  end

endmodule
