`timescale 1ns/1ps
// Gerador de imediatos: confere os formatos I, S, B, U e J (riscv-spec, seção 2.3)
// com instruções reais e com instruções aleatórias contra um modelo de referência.
module tb_imm_gen;

  reg  [31:0] instr;
  wire [31:0] imm_ext;

  integer errors = 0;
  integer checks = 0;
  integer i, k;

  reg [6:0] opcodes [0:8];

  imm_gen dut (.instr(instr), .imm_ext(imm_ext));

  // modelo de referência, montado campo a campo como na Figura 2.4 da spec
  function [31:0] ref_imm(input [31:0] in);
    begin
      case (in[6:0])
        7'b0000011, 7'b0010011, 7'b1100111:                       // I
          ref_imm = {{21{in[31]}}, in[30:20]};
        7'b0100011:                                               // S
          ref_imm = {{21{in[31]}}, in[30:25], in[11:7]};
        7'b1100011:                                               // B
          ref_imm = {{20{in[31]}}, in[7], in[30:25], in[11:8], 1'b0};
        7'b0110111, 7'b0010111:                                   // U
          ref_imm = {in[31:12], 12'b0};
        7'b1101111:                                               // J
          ref_imm = {{12{in[31]}}, in[19:12], in[20], in[30:21], 1'b0};
        default:
          ref_imm = 32'd0;
      endcase
    end
  endfunction

  task check(input [31:0] in, input [31:0] exp, input [8*24-1:0] name);
    begin
      instr = in; #1;
      checks = checks + 1;
      if (imm_ext !== exp) begin
        errors = errors + 1;
        if (errors <= 20)
          $display("[ERRO] %0s: instr=%h -> imm=%h, esperado=%h", name, in, imm_ext, exp);
      end
    end
  endtask

  initial begin
    // tipo I (load, op-imm, jalr)
    check(32'hFFF00093, 32'hFFFF_FFFF, "addi -1");
    check(32'h7FF00093, 32'h0000_07FF, "addi 2047");
    check(32'h80000093, 32'hFFFF_F800, "addi -2048");
    check(32'h00812283, 32'h0000_0008, "lw 8");
    check(32'hFFC12283, 32'hFFFF_FFFC, "lw -4");
    check(32'h00C280E7, 32'h0000_000C, "jalr 12");
    check(32'hFF808067, 32'hFFFF_FFF8, "jalr -8");
    check(32'h00309093, 32'h0000_0003, "slli 3");
    check(32'h4030D093, 32'h0000_0403, "srai 3 (funct7 no imm)");

    // tipo S (store)
    check(32'h00512423, 32'h0000_0008, "sw 8");
    check(32'hFE512E23, 32'hFFFF_FFFC, "sw -4");
    check(32'h7E512FA3, 32'h0000_07FF, "sw 2047");

    // tipo B (branch): bit 0 sempre 0, bit 11 vem de instr[7]
    check(32'h00208463, 32'h0000_0008, "beq +8");
    check(32'hFE208EE3, 32'hFFFF_FFFC, "beq -4");
    check(32'h002090E3, 32'h0000_0800, "bne +2048 (bit 11)");
    check(32'h80208063, 32'hFFFF_F000, "beq -4096");

    // tipo U (lui, auipc)
    check(32'h123452B7, 32'h1234_5000, "lui 0x12345");
    check(32'hFFFFF2B7, 32'hFFFF_F000, "lui 0xFFFFF");
    check(32'h80000297, 32'h8000_0000, "auipc 0x80000");

    // tipo J (jal)
    check(32'h008000EF, 32'h0000_0008, "jal +8");
    check(32'h0000006F, 32'h0000_0000, "jal 0 (parada)");
    check(32'hFFDFF06F, 32'hFFFF_FFFC, "jal -4");
    check(32'h0010006F, 32'h0000_0800, "jal +2048 (bit 11)");
    check(32'h0000106F, 32'h0000_1000, "jal +4096 (bit 12)");
    check(32'h8000006F, 32'hFFF0_0000, "jal -1MiB");

    // tipo R não tem imediato: saída 0
    check(32'h002081B3, 32'h0000_0000, "add (sem imediato)");

    // aleatório: cada opcode com os outros 25 bits sorteados
    opcodes[0] = 7'b0000011; opcodes[1] = 7'b0010011; opcodes[2] = 7'b1100111;
    opcodes[3] = 7'b0100011; opcodes[4] = 7'b1100011; opcodes[5] = 7'b0110111;
    opcodes[6] = 7'b0010111; opcodes[7] = 7'b1101111; opcodes[8] = 7'b0110011;
    for (k = 0; k < 9; k = k + 1)
      for (i = 0; i < 500; i = i + 1) begin
        instr = {$random} & 32'hFFFF_FF80 | opcodes[k];
        check(instr, ref_imm(instr), "aleatorio");
      end

    if (errors == 0)
      $display("tb_imm_gen: PASSOU (%0d verificacoes)", checks);
    else
      $display("tb_imm_gen: FALHOU (%0d erros em %0d verificacoes)", errors, checks);
    $finish;
  end

endmodule
