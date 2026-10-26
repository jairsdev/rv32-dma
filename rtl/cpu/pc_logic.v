`timescale 1ns/1ps
module pc_logic (
    input         clk,
    input         rst_n,         // ativo em nível baixo
    input  [1:0]  PC_sel,
    input  [31:0] imm_ext,         // imediato estendido (Extnd)
    input  [31:0] alu_result,  // destino do JALR
    output [31:0] pc_o,        // PC atual (endereço da memória de instruções)
    output [31:0] pc_plus4,    // PC + 4 (também vai para REG_sel = 3: retorno de JAL/JALR)
    output [31:0] pc_target,   // PC + imm
    output [31:0] pc_next
);
    pc u_pc (
        .clk (clk),
        .rst_n (rst_n),
        .a   (pc_next),
        .o   (pc_o)
    );

    adder u_add4 (
        .a (pc_o),
        .b (32'd4),
        .o (pc_plus4)
    );

    adder u_add_imm (
        .a (pc_o),
        .b (imm_ext),
        .o (pc_target)
    );

    mux4 u_mux_pc (
        .s (PC_sel),
        .a (pc_plus4),
        .b ({alu_result[31:1], 1'b0}),
        .c (pc_target),
        .d (pc_plus4),
        .o (pc_next)
    );
endmodule
