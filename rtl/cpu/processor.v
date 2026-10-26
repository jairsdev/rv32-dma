`timescale 1ns/1ps
module processor #(
    /** Macros for signal bit counts **/
    parameter ALU_CC_W  = 4,   // ALU_Control width
    parameter PC_SEL_W  = 2,   // PC_sel width
    parameter REG_SEL_W = 2   // REG_sel width
)(
    input clk,
    input rst_n,
    output [31:0] result
);

    wire we_mem, we_reg, rs1_sel, rs2_sel;
    wire [ALU_CC_W-1:0] ALU_Control;
    wire [PC_SEL_W-1:0] PC_sel;
    wire [REG_SEL_W-1:0] REG_sel;
    wire [6:0] opcode, funct7;
    wire [2:0] funct3;
    wire [1:0] ALU_Op;

    datapath u_datapath(.clk(clk), .rst_n(rst_n), .we_mem(we_mem), .we_reg(we_reg), 
    .rs1_sel(rs1_sel), .rs2_sel(rs2_sel), .ALU_Control(ALU_Control), .PC_sel(PC_sel),
    .REG_sel(REG_sel), .result(result), .opcode(opcode), .funct7(funct7), .funct3(funct3));

    alu_controller u_alu_controller(.ALU_Op(ALU_Op), .funct3(funct3), .funct7(funct7), .ALU_Control(ALU_Control));

    controller u_controller(.opcode(opcode), .result_lsb(result[0]), .PC_sel(PC_sel), .REG_sel(REG_sel), .ALU_Op(ALU_Op), 
    .we_mem(we_mem), .we_reg(we_reg), .rs1_sel(rs1_sel), .rs2_sel(rs2_sel));
endmodule