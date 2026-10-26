`timescale 1ns/1ps
// Banco de registradores + ULA: rd <= rs1 op (ALUSrc ? imm : rs2)
module datapath #(
    /** Macros for signal bit counts **/
    parameter PC_W      = 32,  // PC width
    parameter INSTR_W   = 32,  // Instruction width
    parameter DATA_W    = 32,  // Data width
    parameter DM_ADDR_W = 6,   // DataMem width
    parameter ALU_CC_W  = 4,   // ALU_Control width
    parameter PC_SEL_W  = 2,   // PC_sel width
    parameter REG_SEL_W = 2,   // REG_sel width
    parameter ADDR_W    = 5    // Register address width
)(
    input                  clk, rst_n, we_mem, we_reg, rs1_sel, rs2_sel,
    input  [ALU_CC_W-1:0]  ALU_Control,
    input  [PC_SEL_W-1:0]  PC_sel,
    input  [REG_SEL_W-1:0] REG_sel,
    output [DATA_W-1:0]    result,
    output [6:0]           opcode,
    output [6:0]           funct7,
    output [2:0]           funct3
);

    wire [DATA_W-1:0]  src_a, src_b, write_back_result, mem_o, rs1_o, rs2_o;
    wire [ADDR_W-1:0]  rd, rs1, rs2;
    wire [PC_W-1:0]    pc, pc_next, pc_plus4, pc_target;
    wire [INSTR_W-1:0] instr, imm_ext;

    assign rd  = instr[11:7];
    assign rs1 = instr[19:15];
    assign rs2 = instr[24:20];

    assign opcode = instr[6:0];
    assign funct3 = instr[14:12];
    assign funct7 = instr[31:25];

    mux2 u_mux_src_a (.s(rs1_sel), .b(rs1_o), .a(pc), .o(src_a));  // execução
    mux2 u_mux_src_b (.s(rs2_sel), .b(rs2_o), .a(imm_ext), .o(src_b));
    mux4 u_mux_write_back (.s(REG_sel), .a(mem_o), .b(result), .c(imm_ext), .d(pc_plus4), .o(write_back_result));  // write_back

    pc_logic u_pc_logic (
        .clk(clk), .rst_n(rst_n), .PC_sel(PC_sel), .imm_ext(imm_ext), .alu_result(result),
        .pc_o(pc), .pc_plus4(pc_plus4), .pc_next(pc_next), .pc_target(pc_target)
    );

    instruction_memory u_instruction_memory (.addr(pc), .data(instr));

    imm_gen u_imm_gen (.instr(instr), .imm_ext(imm_ext));

    reg_bank u_reg_bank (
        .clk(clk), .rst_n(rst_n), .we(we_reg),
        .rs1(rs1), .rs2(rs2), .rd(rd),
        .wr_rd(write_back_result),
        .rs1_o(rs1_o), .rs2_o(rs2_o)
    );

    alu u_alu (.a(src_a), .b(src_b), .ALU_Control(ALU_Control), .result(result));

    data_memory u_data_memory (
        .clk(clk), .rst_n(rst_n), .we(we_mem), .wdata(rs2_o),
        .addr(result[DM_ADDR_W+1:2]), .rdata(mem_o)
    );
endmodule
